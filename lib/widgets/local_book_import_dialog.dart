import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../services/local_book_service.dart';
import '../services/safe_zip_reader.dart';

class LocalBookImportDialog extends StatefulWidget {
  final File? initialFile;
  final String? initialError;
  final bool autoPreview;
  final LocalBookService? service;
  const LocalBookImportDialog({
    super.key,
    this.initialFile,
    this.initialError,
    this.autoPreview = false,
    this.service,
  });
  @override
  State<LocalBookImportDialog> createState() => _LocalBookImportDialogState();
}

class _LocalBookImportDialogState extends State<LocalBookImportDialog> {
  late final _service = widget.service ?? LocalBookService();
  File? _file;
  final _ownedPicks = <Directory>[];
  LocalImportPreview? _preview;
  LocalImportToken? _token;
  String _encoding = 'auto';
  LocalChapterRule _rule = LocalChapterRule.automatic;
  bool _busy = false;
  bool _committing = false;
  String _progress = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _file = widget.initialFile;
    _error = widget.initialError;
    if (widget.autoPreview && _file != null && _error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_prepare());
      });
    }
  }

  Future<void> _pick() async {
    final token = _token = LocalImportToken();
    setState(() {
      _busy = true;
      _error = null;
      _progress = '请选择 TXT 或 EPUB 文件';
    });
    try {
      final selected = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
      );
      if (selected == null || !mounted) return;
      final length = selected.lengthSync();
      if (length != null && length > SafeZipReader.maxFileBytes) {
        throw const FormatException('文件超过 128 MB');
      }
      if (selected.path != null &&
          path.extension(selected.path!).toLowerCase() ==
              path.extension(selected.name).toLowerCase()) {
        _file = File(selected.path!);
      } else {
        final root = await getTemporaryDirectory();
        final ownedPick = await root.createTemp('reader-picked-');
        _ownedPicks.add(ownedPick);
        final target = File(
          '${ownedPick.path}/${path.basename(selected.name)}',
        );
        final input = selected.readAsByteStream();
        var size = 0;
        final output = target.openWrite();
        try {
          await for (final chunk in input) {
            token.check();
            if (!mounted) throw const LocalImportCancelled();
            size += chunk.length;
            if (size > SafeZipReader.maxFileBytes) {
              throw const FormatException('文件超过 128 MB');
            }
            output.add(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        _file = target;
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    if (_file == null || _busy) return;
    final token = _token = LocalImportToken();
    setState(() {
      _busy = true;
      _error = null;
      _progress = '准备预览…';
    });
    try {
      final preview = await _service.prepare(
        _file!,
        token: token,
        options: LocalImportOptions(encoding: _encoding, chapterRule: _rule),
        onProgress: (message) {
          if (mounted) setState(() => _progress = message);
        },
      );
      if (!mounted) {
        await preview.dispose();
        return;
      }
      setState(() => _preview = preview);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = token.cancelled ? '处理已取消，可调整选项后重试' : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    if (preview == null || _busy) return;
    setState(() {
      _busy = true;
      _committing = true;
      _progress = '正在保存到书架…';
    });
    try {
      final result = await _service.commit(preview);
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    if (!_committing) _token?.cancel();
    unawaited(_preview?.dispose().catchError((_) {}));
    for (final owned in _ownedPicks) {
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
  Widget build(BuildContext context) {
    final preview = _preview;
    return PopScope(
      canPop: !_committing,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '本地小说导入',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭导入',
                      onPressed: _committing
                          ? null
                          : () {
                              _token?.cancel();
                              Navigator.pop(context);
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_progress),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (preview == null) ...[
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : _pick,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('选择 TXT / EPUB 文件'),
                          ),
                          if (_file != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                path.basename(_file!.path),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (_file?.path.toLowerCase().endsWith('.txt') ==
                              true) ...[
                            DropdownButtonFormField<String>(
                              initialValue: _encoding,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '文本编码（乱码时可手动选择）',
                              ),
                              items:
                                  const {
                                        'auto': '自动识别',
                                        'UTF-8': 'UTF-8',
                                        'UTF-16LE': 'UTF-16 LE',
                                        'UTF-16BE': 'UTF-16 BE',
                                        'GB18030': 'GB18030 / GBK',
                                        'Big5': 'Big5 繁体中文',
                                      }.entries
                                      .map(
                                        (entry) => DropdownMenuItem(
                                          value: entry.key,
                                          child: Text(entry.value),
                                        ),
                                      )
                                      .toList(),
                              onChanged: _busy
                                  ? null
                                  : (value) =>
                                        setState(() => _encoding = value!),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<LocalChapterRule>(
                              initialValue: _rule,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '目录识别规则',
                              ),
                              items:
                                  const {
                                        LocalChapterRule.automatic:
                                            '自动（中文 / 英文章节）',
                                        LocalChapterRule.chinese: '仅中文章节',
                                        LocalChapterRule.english: '仅英文章节',
                                        LocalChapterRule.length: '按长度分段',
                                      }.entries
                                      .map(
                                        (entry) => DropdownMenuItem(
                                          value: entry.key,
                                          child: Text(entry.value),
                                        ),
                                      )
                                      .toList(),
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(() => _rule = value!),
                            ),
                          ],
                          const SizedBox(height: 12),
                          const Text(
                            '先预览再确认导入。原文件会保留在本地；不同内容或分章规则使用独立版本，不覆盖同名书。最大文件 128 MB。不支持 DRM 加密正文。',
                          ),
                        ] else ...[
                          Text(
                            preview.book.bookName,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            '${preview.book.author} · ${preview.chapters.length} 章 · ${preview.encoding}',
                          ),
                          if (preview.chapters.any(
                            (c) => c.illustrations.isNotEmpty,
                          ))
                            Text(
                              '含 ${preview.chapters.fold<int>(0, (sum, c) => sum + c.illustrations.length)} 幅插图，支持阅读时点开缩放',
                            ),
                          if (preview.illustrationUpgrade)
                            const Text('确认后补齐原书插图；原正文、章节 ID、进度与批注保持不变。'),
                          if (preview.alreadyExists)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text('检测到相同内容：确认后沿用原书，保留已有阅读进度、书签和笔记。'),
                            ),
                          const SizedBox(height: 12),
                          const Text(
                            '目录预览',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          for (final chapter in preview.chapters.take(12))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(
                                '${chapter.order}. ${chapter.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (preview.chapters.length > 12) const Text('…'),
                          const Divider(),
                          const Text(
                            '正文预览（请检查编码）',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(preview.sample),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (_busy && !_committing)
                      TextButton(
                        onPressed: () => _token?.cancel(),
                        child: const Text('取消处理'),
                      ),
                    if (preview != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                await preview.dispose();
                                if (mounted) setState(() => _preview = null);
                              },
                        child: const Text('返回调整'),
                      ),
                    FilledButton(
                      key: ValueKey(
                        preview == null
                            ? 'local-import-preview'
                            : 'local-import-confirm',
                      ),
                      onPressed: _busy || _file == null
                          ? null
                          : preview == null
                          ? _prepare
                          : _commit,
                      child: Text(
                        preview == null
                            ? '预览目录与编码'
                            : preview.illustrationUpgrade
                            ? '补齐原书插图'
                            : preview.alreadyExists
                            ? '保留原书并加入书架'
                            : '确认导入',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
