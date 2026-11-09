import 'package:flutter/material.dart';
import '../services/reader_library_service.dart';
import 'reader_text_input_dialog.dart';

class ReaderLibraryDialog extends StatefulWidget {
  final Set<String> bookIds;
  final bool hasRead;
  const ReaderLibraryDialog({
    super.key,
    this.bookIds = const {},
    this.hasRead = false,
  });
  @override
  State<ReaderLibraryDialog> createState() => _ReaderLibraryDialogState();
}

class _ReaderLibraryDialogState extends State<ReaderLibraryDialog> {
  final _service = ReaderLibraryService();
  bool _busy = true;
  String? _error;
  String _group = '';
  ReaderBookStatus _status = ReaderBookStatus.toRead;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _run(() async {
      await _service.load();
      if (widget.bookIds.isNotEmpty) {
        _group = _service.groupFor(widget.bookIds.first);
        _status = _service.statusFor(
          widget.bookIds.first,
          hasRead: widget.hasRead,
        );
      }
    });
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
    } catch (_) {
      if (mounted) setState(() => _error = '操作未保存，请检查名称或数据后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _name({String initial = ''}) => showDialog<String>(
    context: context,
    builder: (_) => ReaderTextInputDialog(title: '分组名称', initial: initial),
  );

  Future<void> _delete(String id) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除此分组？'),
        content: const Text('书籍只会变成未分组，不删除书架、原文、进度或笔记。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除分组'),
          ),
        ],
      ),
    );
    if (sure == true) {
      await _run(() async {
        await _service.deleteGroup(id);
        if (_group == id) _group = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.bookIds.isEmpty ? '管理书架分组' : '分组与阅读状态（${widget.bookIds.length} 本）',
    ),
    content: SizedBox(
      width: 480,
      height: MediaQuery.sizeOf(context).height < 650 ? 260 : 360,
      child: Column(
        children: [
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (widget.bookIds.isNotEmpty) ...[
            DropdownButton<String>(
              isExpanded: true,
              value: _group,
              items: [
                const DropdownMenuItem(value: '', child: Text('未分组')),
                for (final entry in _service.snapshot.groups.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value['name']),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _group = value ?? ''),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final status in ReaderBookStatus.values)
                  ChoiceChip(
                    label: Text(readerBookStatusLabels[status]!),
                    selected: _status == status,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _status = status),
                  ),
              ],
            ),
          ],
          Expanded(
            child: ListView(
              children: [
                for (final entry in _service.snapshot.groups.entries)
                  ListTile(
                    title: Text(entry.value['name']),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: '重命名分组',
                          onPressed: _busy
                              ? null
                              : () async {
                                  final name = await _name(
                                    initial: entry.value['name'],
                                  );
                                  if (name != null) {
                                    await _run(
                                      () =>
                                          _service.renameGroup(entry.key, name),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.edit_outlined, size: 18),
                        ),
                        IconButton(
                          tooltip: '删除分组',
                          onPressed: _busy ? null : () => _delete(entry.key),
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: _busy
            ? null
            : () async {
                final name = await _name();
                if (name != null) {
                  await _run(() async {
                    await _service.createGroup(name);
                  });
                }
              },
        icon: const Icon(Icons.add),
        label: const Text('新建分组'),
      ),
      if (widget.bookIds.isNotEmpty)
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await _service.setBooks(
                    widget.bookIds,
                    groupId: _group,
                    status: _status,
                  );
                  if (context.mounted) Navigator.pop(context, true);
                }),
          child: const Text('应用'),
        ),
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
