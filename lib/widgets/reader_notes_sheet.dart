import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/bookmark.dart';
import '../models/reader_theme.dart';
import '../services/bookmark_service.dart';
import '../services/reader_export_service.dart';
import 'note_editor_dialog.dart';
import 'reader_undo.dart';

class ReaderNotesSheet extends StatefulWidget {
  final Book book;
  final ReaderTheme theme;
  const ReaderNotesSheet({super.key, required this.book, required this.theme});
  @override
  State<ReaderNotesSheet> createState() => _ReaderNotesSheetState();
}

class _ReaderNotesSheetState extends State<ReaderNotesSheet> {
  final _query = TextEditingController();
  final _service = BookmarkService();
  List<ReadingNote> _notes = [];
  bool _busy = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _service.changeNotifier.addListener(_load);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final notes = await _service.getNotes(widget.book.bookId);
    if (mounted && generation == _generation) setState(() => _notes = notes);
  }

  @override
  void dispose() {
    _service.changeNotifier.removeListener(_load);
    _query.dispose();
    super.dispose();
  }

  Future<void> _edit(ReadingNote note) async {
    final edit = await showDialog<NoteEditData>(
      context: context,
      builder: (_) => widget.theme.wrap(
        NoteEditorDialog(
          quote: note.text,
          initialNote: note.note,
          initialColor: note.colorIndex,
          initialTags: note.tags,
        ),
      ),
    );
    if (edit == null) return;
    final undo = await _service.updateNoteWithUndo(
      note.edited(
        note: edit.note,
        colorIndex: edit.colorIndex,
        tags: edit.tags,
      ),
      expectedUpdatedAt: note.updatedAt,
    );
    if (mounted && undo != null) showReaderUndo(context, '笔记已更新', [undo]);
  }

  Future<void> _delete(ReadingNote note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => widget.theme.wrap(
        AlertDialog(
          title: const Text('删除这条笔记？'),
          content: Text(
            note.text,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
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
      ),
    );
    if (confirmed == true) {
      final undo = await _service.deleteNotes(note.bookId, {note.id});
      if (mounted && undo != null) showReaderUndo(context, '笔记已移入回收站', [undo]);
    }
  }

  Future<void> _export(bool markdown) async {
    setState(() => _busy = true);
    try {
      await _service.flush();
      final exporter = ReaderExportService();
      final file = await exporter.exportNotes(widget.book, markdown: markdown);
      final location = await exporter.saveToDownloads(file);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(location == null ? '已取消导出，原笔记未改变' : '已导出到 $location'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导出失败，请检查存储空间')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final notes = query.isEmpty
        ? _notes
        : _notes
              .where(
                (note) =>
                    '${note.text}\n${note.note}\n${note.tags.join(' ')}\n${note.chapterTitle}'
                        .toLowerCase()
                        .contains(query),
              )
              .toList();
    return widget.theme.wrap(
      Material(
        color: widget.theme.backgroundColor,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '笔记管理',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    PopupMenuButton<bool>(
                      tooltip: '导出笔记',
                      enabled: !_busy,
                      onSelected: _export,
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: true, child: Text('导出 Markdown')),
                        PopupMenuItem(value: false, child: Text('导出 JSON')),
                      ],
                      icon: const Icon(Icons.ios_share),
                    ),
                    IconButton(
                      tooltip: '关闭笔记',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    hintText: '搜索摘录、笔记、标签或章节',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: notes.isEmpty
                    ? const Center(child: Text('暂无匹配笔记'))
                    : ListView.builder(
                        itemCount: notes.length,
                        itemBuilder: (context, index) {
                          final note = notes[index];
                          return Card(
                            color: widget.theme.highlightColor,
                            margin: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    note.chapterTitle,
                                    style: TextStyle(
                                      color: widget.theme.secondaryColor,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    note.text,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (note.note.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(note.note),
                                    ),
                                  if (note.tags.isNotEmpty)
                                    Text(
                                      note.tags.map((tag) => '#$tag').join(' '),
                                    ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : () =>
                                                  Navigator.pop(context, note),
                                        icon: const Icon(
                                          Icons.my_location,
                                          size: 18,
                                        ),
                                        label: const Text('定位原文'),
                                      ),
                                      IconButton(
                                        tooltip: '编辑笔记',
                                        onPressed: _busy
                                            ? null
                                            : () => _edit(note),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      IconButton(
                                        tooltip: '删除笔记',
                                        onPressed: _busy
                                            ? null
                                            : () => _delete(note),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                  if (note.startOffset < 0)
                                    const Text(
                                      '旧版笔记：定位时将校验引用，歧义位置不会自动跳转。',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
