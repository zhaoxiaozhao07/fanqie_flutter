import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../services/external_reader_fonts.dart';

class ReaderFontsDialog extends StatefulWidget {
  final String selected;
  const ReaderFontsDialog({super.key, required this.selected});
  @override
  State<ReaderFontsDialog> createState() => _ReaderFontsDialogState();
}

class _ReaderFontsDialogState extends State<ReaderFontsDialog> {
  final _library = ExternalReaderFonts();
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _run(_library.reload);
  }

  Future<void> _run(Future<void> Function() work) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : '字体操作失败，原设置已保留',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _run(() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    if (selected == null || !mounted) return;
    final length = selected.lengthSync();
    if (length != null && length > ExternalReaderFonts.maxFileBytes) {
      throw const FormatException('字体超过 20 MB');
    }
    final font = selected.path != null
        ? await _library.importFile(File(selected.path!))
        : await _library.importStream(selected.readAsByteStream());
    if (mounted) {
      await _preview(font);
    }
  });

  Future<void> _preview(ExternalReaderFont font) async {
    await _library.ensureLoaded(font.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(font.name),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Text(
              '春风轻拂书页，故事从这里继续。\n'
              '閱讀是一段安靜而悠長的旅程。\n'
              '「中文标点」——（测试）！？\n'
              'The quick brown fox. 0123456789\n👨‍👩‍👧‍👦 é',
              style: TextStyle(
                fontFamily: _library.familyFor(font.id),
                fontSize: 22,
                height: 1.8,
                fontFamilyFallback: const ['sans-serif', 'Roboto'],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭预览'),
          ),
        ],
      ),
    );
  }

  Future<void> _remove(ExternalReaderFont font) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${font.name}」？'),
        content: const Text('仅删除应用内副本，不影响原文件或系统字体。其他书引用此字体时会回退系统字体，阅读位置与批注保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(() => _library.remove(font.id));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本地字体库'),
    content: SizedBox(
      width: 540,
      height: 390,
      child: Column(
        children: [
          const Text('仅支持独立 TTF / OTF；单个最多 20 MB。字体只在本应用使用，请确认拥有使用授权。'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              itemCount: _library.fonts.length,
              itemBuilder: (context, index) {
                final font = _library.fonts[index];
                return ListTile(
                  key: ValueKey('reader-font-${font.id}'),
                  title: Text(font.name),
                  subtitle: Text(
                    '${font.format.toUpperCase()} · ${(font.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                  selected: widget.selected == font.id,
                  onTap: _busy
                      ? null
                      : () => _run(() async {
                          await _library.ensureLoaded(font.id);
                          if (context.mounted) Navigator.pop(context, font.id);
                        }),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '预览',
                        onPressed: _busy
                            ? null
                            : () => _run(() => _preview(font)),
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                      IconButton(
                        tooltip: '删除应用内字体',
                        onPressed: _busy ? null : () => _remove(font),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: _busy ? null : _pick,
        icon: const Icon(Icons.add),
        label: const Text('导入字体'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
