import 'package:flutter/material.dart';

class ReaderTextInputDialog extends StatefulWidget {
  final String title, initial, hint, action;
  final int maxLength;
  const ReaderTextInputDialog({
    super.key,
    required this.title,
    this.initial = '',
    this.hint = '',
    this.action = '保存',
    this.maxLength = 24,
  });
  @override
  State<ReaderTextInputDialog> createState() => _ReaderTextInputDialogState();
}

class _ReaderTextInputDialogState extends State<ReaderTextInputDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: widget.maxLength,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (value) => Navigator.pop(context, value.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: Text(widget.action),
      ),
    ],
  );
}
