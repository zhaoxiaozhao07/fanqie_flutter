import 'dart:convert';
import 'dart:io';

import '../models/chapter.dart';
import 'atomic_file.dart';
import 'reader_cache_service.dart';

class SavedBookDirectory {
  final List<Chapter> chapters;
  final bool complete;
  const SavedBookDirectory(this.chapters, {required this.complete});
}

/// Directory metadata is needed to open already downloaded text. It belongs
/// with protected book data, not in the temporary text/image eviction pool.
class BookDirectoryCache {
  final ReaderCacheService cache;
  BookDirectoryCache(this.cache);
  static const maxBytes = 8 * 1024 * 1024;
  static const maxChapters = 50000;

  Future<File> _file(String book, String name) async => File(
    '${(await cache.documents()).path}/offline_books/'
    '${ReaderCacheService.segment(book)}/$name',
  );

  static List<Chapter> parseSaved(dynamic data) {
    if (data is! List || data.isEmpty || data.length > maxChapters) {
      throw const FormatException('目录为空或格式无效');
    }
    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final raw in data) {
      if (raw is! Map) throw const FormatException('目录章节无效');
      final value = Map<String, dynamic>.from(raw);
      final id = (value['item_id'] ?? value['itemId'])?.toString().trim() ?? '';
      if (id.isEmpty || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
        throw const FormatException('目录章节 ID 无效');
      }
      if (!seen.add(id)) throw const FormatException('目录章节 ID 重复');
      chapters.add(
        Chapter.fromDirectoryJson({...value, 'item_id': id}, chapters.length),
      );
    }
    return chapters;
  }

  Future<dynamic> _read(File file) async {
    if (await FileSystemEntity.isLink(file.parent.path) ||
        await FileSystemEntity.isLink(file.parent.parent.path) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > maxBytes) {
      return null;
    }
    return jsonDecode(await file.readAsString());
  }

  Future<List<Chapter>?> readLocal(String book) async {
    try {
      return parseSaved(await _read(await _file(book, 'directory.json')));
    } catch (_) {
      return null;
    }
  }

  Future<SavedBookDirectory?> readRemote(String book) async {
    try {
      final raw = await _read(await _file(book, 'directory.remote.json'));
      if (raw is! Map || raw['version'] != 1 || raw['book_id'] != book) {
        return null;
      }
      return SavedBookDirectory(
        parseSaved(raw['chapters']),
        complete: raw['complete'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    String book,
    List<Chapter> chapters, {
    required bool complete,
  }) async {
    if (book.startsWith('local_')) {
      return; // Never rewrite imported directories.
    }
    final data = chapters.map((c) => c.toJson()..remove('content')).toList();
    parseSaved(
      data,
    ); // Never commit an empty or structurally incomplete response.
    final file = await _file(book, 'directory.remote.json');
    if (await FileSystemEntity.isLink(file.parent.path) ||
        await FileSystemEntity.isLink(file.parent.parent.path)) {
      throw const FileSystemException('目录存储路径无效');
    }
    final json = jsonEncode({
      'version': 1,
      'book_id': book,
      'complete': complete,
      'chapters': data,
    });
    if (utf8.encode(json).length > maxBytes) {
      throw const FormatException('目录过大');
    }
    await AtomicFile.writeString(file, json);
  }

  Future<void> saveDownloaded(String book, List<Chapter> chapters) async {
    if (book.startsWith('local_') || chapters.isEmpty) return;
    final previous = await readRemote(book);
    final byId = {
      for (final c in previous?.chapters ?? <Chapter>[]) c.itemId: c,
    };
    if (previous?.complete == true &&
        chapters.every((c) => byId.containsKey(c.itemId))) {
      return; // A range download must not truncate a complete book directory.
    }
    for (final c in chapters) {
      byId[c.itemId] = c;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    await save(book, merged, complete: false);
  }
}
