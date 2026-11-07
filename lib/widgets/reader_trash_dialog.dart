import 'package:flutter/material.dart';
import '../services/reader_trash_service.dart';
import '../services/reader_trash_coordinator.dart';

class ReaderTrashDialog extends StatefulWidget {
  const ReaderTrashDialog({super.key});
  @override
  State<ReaderTrashDialog> createState() => _ReaderTrashDialogState();
}

class _ReaderTrashDialogState extends State<ReaderTrashDialog> {
  final _service = ReaderTrashService();
  List<ReaderTrashEntry> _entries = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await _service.entries();
      if (mounted) setState(() => _entries = entries);
    } catch (_) {
      if (mounted) setState(() => _error = '回收站不可读，原记录已保留');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(ReaderTrashEntry entry, bool restore) async {
    if (!restore) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('永久清除此回收站副本？'),
          content: const Text('无法再撤销。不会删除任何原书文件，也不会更改当前笔记。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('永久清除'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (restore) {
        await ReaderTrashCoordinator.restore(entry);
      } else {
        await _service.discard(entry.id);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '存在后续修改或保存失败，未覆盖新记录；此副本仍保留');
    }
    await _load();
  }

  Future<void> _view(ReaderTrashEntry entry) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${entry.kind}旧版本 · ${entry.label}'),
      content: SizedBox(
        width: 500,
        height: 350,
        child: SingleChildScrollView(
          child: SelectableText(
            entry.items
                .map(
                  (e) =>
                      '${e['book_name'] ?? e['chapter_title'] ?? ''}\n'
                      '${e['text'] ?? e['content_preview'] ?? ''}\n${e['note'] ?? ''}',
                )
                .join('\n\n'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('回收站与修改历史'),
    content: SizedBox(
      width: 620,
      height: 430,
      child: Column(
        children: [
          const Text(
            '保存 30 天；最多 1000 次操作 / 16 MB。满时拒绝新删除，不清空阅读数据。移出书架不会删除原书文件。',
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: _entries.isEmpty
                ? const Center(child: Text('暂无回收记录'))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        title: Text(
                          '${entry.kind} · ${entry.label}（${entry.items.length} 项）',
                        ),
                        subtitle: Text(
                          '${entry.action == 'edit' ? '修改前版本' : '删除'} · ${entry.deletedAt.toLocal().toString().split('.').first}',
                        ),
                        onTap: () => _view(entry),
                        trailing: Wrap(
                          children: [
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _action(entry, true),
                              child: Text(
                                entry.action == 'edit' ? '撤销修改' : '恢复',
                              ),
                            ),
                            IconButton(
                              tooltip: '永久清除此副本',
                              onPressed: _busy
                                  ? null
                                  : () => _action(entry, false),
                              icon: const Icon(Icons.delete_forever_outlined),
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
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
