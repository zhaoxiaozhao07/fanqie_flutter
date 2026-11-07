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
              child: Text(
                '春风轻拂书页，故事从这里继续。\nAa 0123，阅读不止。',
                style: TextStyle(color: preview.textColor, fontSize: 18),
              ),
            ),
            if (!valid) const Text('请输入有效的六位颜色值'),
            if (valid)
              Text(
                '对比度 ${preview.contrastRatio.toStringAsFixed(1)}:1'
                '${preview.contrastRatio < 4.5 ? '；建议至少 4.5:1' : ''}',
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
          onPressed: valid && preview.contrastRatio >= 3
              ? () => Navigator.pop(context, (bg, fg))
              : null,
          child: const Text('应用'),
        ),
      ],
    );
  }
}
