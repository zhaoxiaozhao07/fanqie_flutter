import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chapter.dart';

/// Returns an index only. Loading, cancellation and jump history remain owned
/// by the reader, so a failed jump cannot discard the previous reading anchor.
class ReaderChapterJumpDialog extends StatefulWidget {
  final List<Chapter> chapters;
  final int currentIndex;

  const ReaderChapterJumpDialog({
    super.key,
    required this.chapters,
    required this.currentIndex,
  });

  @override
  State<ReaderChapterJumpDialog> createState() =>
      _ReaderChapterJumpDialogState();
}

class _ReaderChapterJumpDialogState extends State<ReaderChapterJumpDialog> {
  late final _number = TextEditingController(text: '${widget.currentIndex + 1}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.currentIndex + 1}'.length,
    );

  int? get _index {
    final number = int.tryParse(_number.text.trim());
    return number != null && number > 0 && number <= widget.chapters.length
        ? number - 1
        : null;
  }

  void _submit() {
    if (_number.value.composing.isValid &&
        !_number.value.composing.isCollapsed) {
      return;
    }
    final index = _index;
    if (index != null) Navigator.pop(context, index);
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    return AlertDialog(
      title: const Text('跳转章节'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('reader-chapter-number'),
              controller: _number,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '章节序号',
                helperText: '1 – ${widget.chapters.length}',
                errorText: index == null ? '请输入范围内的章节序号' : null,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              index == null
                  ? '按 Enter 跳转，Esc 取消'
                  : widget.chapters[index].title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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
          key: const ValueKey('reader-confirm-chapter-jump'),
          onPressed: index == null ? null : _submit,
          child: const Text('跳转'),
        ),
      ],
    );
  }
}
