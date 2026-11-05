import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../services/reader_backup_service.dart';
import '../services/reader_export_service.dart';

class ReaderBackupDialog extends StatefulWidget {
  const ReaderBackupDialog({super.key});
  @override
  State<ReaderBackupDialog> createState() => _ReaderBackupDialogState();
}

class _ReaderBackupDialogState extends State<ReaderBackupDialog> {
  final _service = ReaderBackupService();
  bool _includeBooks = false;
  bool _busy = false;
  String _message = '';
  ReaderRestoreMode _mode = ReaderRestoreMode.merge;
  File? _file;
  Directory? _owned;
  ReaderBackupInfo? _info;

  Future<void> _run(Future<void> Function() action, String message) async {
    setState(() {
      _busy = true;
      _message = message;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '操作未完成：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() => _run(() async {
    final file = await _service.create(includeBooks: _includeBooks);
    final location = await ReaderExportService().saveToDownloads(file);
    if (mounted) {
      setState(
        () => _message = location == null
            ? '已取消另存为；生成的备份仍保留在应用内'
            : '备份已保存到 $location',
      );
    }
  }, '正在生成备份，不会修改原数据…');

  Future<void> _pick() => _run(() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (picked == null) {
      if (mounted) setState(() => _message = '未选择文件');
      return;
    }
    final size = picked.lengthSync();
    if (size != null && size > 1024 * 1024 * 1024) {
      throw const FormatException('备份超过 1 GB');
    }
    File file;
    if (picked.path != null) {
      file = File(picked.path!);
    } else {
      final old = _owned;
      if (old != null && await old.exists()) await old.delete(recursive: true);
      _owned = await (await getTemporaryDirectory()).createTemp(
        'reader-backup-pick-',
      );
      file = File('${_owned!.path}/${path.basename(picked.name)}');
      var total = 0;
      final output = file.openWrite();
      try {
        await output.addStream(
          picked.readAsByteStream().map((chunk) {
            total += chunk.length;
            if (total > 1024 * 1024 * 1024) {
              throw const FormatException('备份超过 1 GB');
            }
            return chunk;
          }),
        );
      } finally {
        await output.close();
      }
    }
    final info = await _service.inspect(file);
    if (!mounted) return;
    setState(() {
      _file = file;
      _info = info;
      _message = '格式校验通过，确认后才会恢复';
    });
  }, '正在读取备份摘要…');

  Future<void> _restore() async {
    final file = _file;
    if (file == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复阅读数据？'),
        content: Text(
          _mode == ReaderRestoreMode.merge
              ? '合并书架和批注，保留较新的进度及当前偏好。已有书籍文件不覆盖。当前听书会停止。'
              : '用备份替换阅读数据与偏好，并替换备份包含的书籍文件。未包含的书籍文件及语音配置不会删除。当前听书会停止。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await _service.restore(file, mode: _mode);
      if (mounted) setState(() => _message = '恢复完成，书架与阅读数据已刷新');
    }, '正在校验文件并恢复，请等待完成…');
  }

  @override
  void dispose() {
    final owned = _owned;
    if (owned != null) {
      unawaited(
        owned
            .exists()
            .then((exists) async {
              if (exists) await owned.delete(recursive: true);
            })
            .catchError((_) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('备份与恢复'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('备份包含书架、进度、偏好、书签和笔记，不包含语音密钥。文件可能含私人阅读信息，请妥善保管。'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('同时备份书籍文件'),
                subtitle: const Text('包含下载、本地原文件与目录；体积可能较大'),
                value: _includeBooks,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _includeBooks = value),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _create,
                icon: const Icon(Icons.save_alt),
                label: const Text('创建备份'),
              ),
              const Divider(),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择备份 ZIP'),
              ),
              if (_info != null) ...[
                const SizedBox(height: 10),
                Text(
                  '书籍 ${_info!.books} · 笔记 ${_info!.notes} · 书签 ${_info!.bookmarks} · 文件 ${_info!.files}',
                ),
                Text(
                  '创建于 ${_info!.createdAt.toLocal().toString().split('.').first}',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('合并（推荐）'),
                      selected: _mode == ReaderRestoreMode.merge,
                      onSelected: _busy
                          ? null
                          : (_) =>
                                setState(() => _mode = ReaderRestoreMode.merge),
                    ),
                    ChoiceChip(
                      label: const Text('替换'),
                      selected: _mode == ReaderRestoreMode.replace,
                      onSelected: _busy
                          ? null
                          : (_) => setState(
                              () => _mode = ReaderRestoreMode.replace,
                            ),
                    ),
                  ],
                ),
                FilledButton(
                  onPressed: _busy ? null : _restore,
                  child: const Text('恢复此备份'),
                ),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_message),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
