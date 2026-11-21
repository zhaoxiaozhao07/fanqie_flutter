import 'package:flutter/material.dart';
import '../models/reader_theme.dart';

class ReaderColorsDialog extends StatefulWidget {
  final ReaderTheme theme;
  const ReaderColorsDialog({super.key, required this.theme});
  @override
  State<ReaderColorsDialog> createState() => _ReaderColorsDialogState();
}

class _ReaderColorsDialogState extends State<ReaderColorsDialog> {
  String _hex(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  late final _background = TextEditingController(
    text: _hex(widget.theme.backgroundColor),
  );
  late final _text = TextEditingController(text: _hex(widget.theme.textColor));
  int? _parse(String value) => RegExp(r'^[a-fA-F0-9]{6}$').hasMatch(value)
      ? 0xFF000000 | int.parse(value, radix: 16)
      : null;

  @override
  void dispose() {
    _background.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = _parse(_background.text);
    final fg = _parse(_text.text);
    final preview = widget.theme.withColors(background: bg, text: fg);
    final valid = bg != null && fg != null;
    return AlertDialog(
      scrollable: true,
      title: const Text('自定义阅读配色'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _background,
              maxLength: 6,
              decoration: const InputDecoration(labelText: '背景色（六位 HEX，不含 #）'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              controller: _text,
              maxLength: 6,
              decoration: const InputDecoration(labelText: '文字颜色（六位 HEX）'),
              onChanged: (_) => setState(() {}),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: preview.backgroundColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '正文：春风轻拂书页，故事从这里继续。\nAa 0123，阅读不止。',
                    style: TextStyle(color: preview.textColor, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '次要文字：章节与进度',
                    style: TextStyle(color: preview.secondaryColor),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: preview.highlightColor,
                    child: Text(
                      '高亮：选中内容',
                      style: TextStyle(color: preview.textColor),
                    ),
                  ),
                ],
              ),
            ),
            if (!valid) const Text('请输入有效的六位颜色值'),
            if (valid)
              Text(
                '正文对比度 ${preview.contrastRatio.toStringAsFixed(2)}:1\n'
                '次要文字对比度 ${preview.secondaryContrastRatio.toStringAsFixed(2)}:1\n'
                '高亮文字对比度 ${preview.highlightContrastRatio.toStringAsFixed(2)}:1'
                '${preview.contrastRatio < 4.5 ? '\n应用配色须至少 4.5:1' : ''}',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              valid &&
                  preview.contrastRatio >= 4.5 &&
                  preview.secondaryContrastRatio >= 4.5 &&
                  preview.highlightContrastRatio >= 4.5
              ? () => Navigator.pop(context, (bg, fg))
              : null,
          child: const Text('应用'),
        ),
      ],
    );
  }
}
