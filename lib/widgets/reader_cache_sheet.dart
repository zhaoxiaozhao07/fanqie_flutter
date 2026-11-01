import 'package:flutter/material.dart';

import '../models/chapter.dart';
import '../services/reader_cache_service.dart';

class ReaderCacheSheet extends StatefulWidget {
  final String bookId;
  final List<Chapter> chapters;
  final int currentIndex;
  final String? warning;
  final void Function(int count) onDownload;
  final void Function(ReaderCachePolicy policy) onPolicyChanged;

  const ReaderCacheSheet({
    super.key,
    required this.bookId,
    required this.chapters,
    required this.currentIndex,
    required this.onDownload,
    required this.onPolicyChanged,
    this.warning,
  });

  @override
  State<ReaderCacheSheet> createState() => _ReaderCacheSheetState();
}

class _ReaderCacheSheetState extends State<ReaderCacheSheet> {
  final _cache = ReaderCacheService();
  ReaderCachePolicy? _policy;
  int? _through;
  int? _bytes;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final policy = await ReaderCachePolicy.load();
      final through = await _cache.contiguousEnd(
        widget.bookId,
        widget.chapters.map((chapter) => chapter.itemId).toList(),
        widget.currentIndex,
      );
      final bytes = await _cache.temporaryBytes();
      if (!mounted) return;
      setState(() {
        _policy = policy;
        _through = through;
        _bytes = bytes;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '读取缓存状态失败，可关闭后重试');
    }
  }

  Future<void> _change({
    ReaderCacheMode? mode,
    bool? wifiOnly,
    int? maxBytes,
  }) async {
    final old = _policy;
    if (old == null || _busy) return;
    final next = ReaderCachePolicy(
      mode: mode ?? old.mode,
      wifiOnly: wifiOnly ?? old.wifiOnly,
      maxBytes: maxBytes ?? old.maxBytes,
    );
    setState(() => _busy = true);
    try {
      await next.save();
      widget.onPolicyChanged(next);
      await _cache.trim(next.maxBytes);
      if (mounted) setState(() => _policy = next);
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = '缓存设置保存失败，请检查存储空间');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理临时阅读缓存？'),
        content: const Text('仅清理自动缓存。已下载的章节、本地导入、书签和笔记不会删除。当前正文仍可阅读。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _cache.trim(0, includePinned: true);
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = '部分缓存清理失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final policy = _policy;
    final remaining = widget.chapters.length - widget.currentIndex - 1;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('离线与缓存', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(
              _through == null
                  ? '正在检查磁盘缓存…'
                  : _through! < widget.currentIndex
                  ? '当前章节尚未完整缓存'
                  : '从当前位置可离线读至第 ${_through! + 1} 章',
              semanticsLabel: _through == null ? '正在检查缓存' : null,
            ),
            if (widget.warning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.warning!),
              ),
            if (_error != null) Text(_error!),
            const SizedBox(height: 16),
            if (policy != null) ...[
              const Text('自动预取策略'),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    ReaderCacheMode.saver: '省流量 · 1章',
                    ReaderCacheMode.standard: '标准 · 4章',
                    ReaderCacheMode.commute: '通勤 · 12章',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: policy.mode == entry.key,
                      onSelected: _busy
                          ? null
                          : (_) => _change(mode: entry.key),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅 Wi-Fi 自动预取'),
                subtitle: const Text('主动翻章和手动下载不受此限制'),
                value: policy.wifiOnly,
                onChanged: _busy ? null : (value) => _change(wifiOnly: value),
              ),
              const Text('临时缓存上限'),
              Wrap(
                spacing: 8,
                children: [
                  for (final mb in [100, 300, 500])
                    ChoiceChip(
                      label: Text('$mb MB'),
                      selected: policy.maxBytes == mb * 1024 * 1024,
                      onSelected: _busy
                          ? null
                          : (_) => _change(maxBytes: mb * 1024 * 1024),
                    ),
                ],
              ),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('清理临时缓存'),
              subtitle: Text(
                _bytes == null
                    ? '统计中…'
                    : '${(_bytes! / 1024 / 1024).toStringAsFixed(1)} MB · 不删除下载与导入',
              ),
              trailing: const Icon(Icons.cleaning_services_outlined),
              onTap: _busy ? null : _clear,
            ),
            const Divider(),
            const Text('保留离线章节（不会被自动清理）'),
            for (final count in {20, 50, remaining}.where((n) => n > 0))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  count == remaining ? '下载全部未读 $remaining 章' : '下载后续 $count 章',
                ),
                trailing: const Icon(Icons.download_outlined),
                enabled: remaining > 0 && !_busy,
                onTap: () {
                  Navigator.pop(context);
                  widget.onDownload(count.clamp(0, remaining));
                },
              ),
          ],
        ),
      ),
    );
  }
}
