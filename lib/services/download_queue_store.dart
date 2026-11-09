import 'dart:convert';
import 'dart:io';

import '../models/download_task.dart';
import 'app_storage.dart';
import 'atomic_file.dart';

class DownloadQueueStore {
  static const maxTasks = 200;
  static const maxBytes = 16 * 1024 * 1024;
  final Future<Directory> Function() documents;

  DownloadQueueStore({Future<Directory> Function()? documents})
    : documents = documents ?? AppStorage.documents;

  Future<File> get file async =>
      File('${(await documents()).path}/download_queue_v1.json');

  Future<List<DownloadTask>> load() async {
    final source = await file;
    if (!await source.exists()) return [];
    if (await source.length() > maxBytes) {
      throw const FormatException('下载队列超过容量上限');
    }
    final raw = jsonDecode(await source.readAsString());
    if (raw is! Map || raw['version'] != 1 || raw['tasks'] is! List) {
      throw const FormatException('下载队列格式或版本不受支持');
    }
    final tasks = raw['tasks'] as List;
    if (tasks.length > maxTasks) {
      throw const FormatException('下载队列任务过多');
    }
    final result = [
      for (final task in tasks)
        DownloadTask.fromJson(Map<String, dynamic>.from(task as Map)),
    ];
    if (result.map((task) => task.id).toSet().length != result.length) {
      throw const FormatException('下载队列含重复任务');
    }
    return result;
  }

  Future<void> save(List<DownloadTask> tasks) async {
    final raw = jsonEncode({
      'version': 1,
      'tasks': tasks.map((task) => task.toJson()).toList(),
    });
    if (tasks.length > maxTasks || utf8.encode(raw).length > maxBytes) {
      throw StateError('下载队列已达容量上限，请清理旧任务');
    }
    await AtomicFile.writeString(await file, raw);
  }
}
