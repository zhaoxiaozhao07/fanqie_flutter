import 'package:flutter/material.dart';

class NoteEditData {
  final String note;
  final int colorIndex;
  final List<String> tags;
  const NoteEditData(this.note, this.colorIndex, this.tags);
}

class NoteEditorDialog extends StatefulWidget {
  final String quote;
  final String initialNote;
  final int initialColor;
  final List<String> initialTags;
  const NoteEditorDialog({
    super.key,
    required this.quote,
    this.initialNote = '',
    this.initialColor = 0,
    this.initialTags = const [],
  });
  @override
  State<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<NoteEditorDialog> {
  late final _note = TextEditingController(text: widget.initialNote);
  late final _tags = TextEditingController(text: widget.initialTags.join('，'));
  late int _color = widget.initialColor;
  @override
  void dispose() {
    _note.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('阅读笔记'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.quote,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 3,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(
                hintText: '写下你的想法…',
                labelText: '笔记',
              ),
            ),
            TextField(
              controller: _tags,
              maxLength: 256,
              decoration: const InputDecoration(labelText: '标签（逗号分隔，最多 10 个）'),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < 4; i++)
                  ChoiceChip(
                    label: Text(const ['黄色', '绿色', '蓝色', '粉色'][i]),
                    selected: _color == i,
                    onSelected: (_) => setState(() => _color = i),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          NoteEditData(
            _note.text.trim(),
            _color,
            _tags.text
                .split(RegExp('[,，]'))
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .map((t) => t.characters.take(32).toString())
                .toSet()
                .take(10)
                .toList(),
          ),
        ),
        child: const Text('保存'),
      ),
    ],
  );
}
