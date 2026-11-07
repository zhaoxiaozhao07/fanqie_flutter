import 'dart:io';
import 'package:flutter/material.dart';
import '../services/reader_auto_backup_service.dart';

class ReaderAutoBackupPanel extends StatefulWidget {
  final Future<void> Function(File) onChoose;
  const ReaderAutoBackupPanel({super.key, required this.onChoose});
  @override
  State<ReaderAutoBackupPanel> createState() => _ReaderAutoBackupPanelState();
}

class _ReaderAutoBackupPanelState extends State<ReaderAutoBackupPanel> {
  final _service = ReaderAutoBackupService();
  bool _changing = false;
  List<File> _files = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.initialize();
    try {
      final files = await _service.snapshots();
      if (mounted) setState(() => _files = files);
    } catch (_) {
      if (mounted) setState(() => _error = '自动快照目录不可读');
    }
  }

  Future<void> _change(Future<void> Function() work) async {
    setState(() {
      _changing = true;
      _error = null;
    });
    try {
      await work();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，旧快照仍保留');
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _service,
    builder: (_, _) {
      final policy = _service.policy;
      final busy = _changing || _service.busy;
      return ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('自动快照（应用内）'),
        subtitle: Text(
          policy.enabled
              ? '每 ${policy.hours} 小时检查 · 保留 ${policy.retain} 份'
              : '未启用',
        ),
        children: [
          const Text(
            '默认关闭。仅备份阅读数据和字体索引，不复制原书、字体文件或语音密钥；最多 128 MB。卸载或丢失应用数据仍可能丢失快照，请另做外部备份。',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('启用自动快照'),
            value: policy.enabled,
            onChanged: busy
                ? null
                : (v) => _change(() => _service.configure(enabled: v)),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final hours in [6, 24, 72, 168])
                ChoiceChip(
                  label: Text('$hours 小时'),
                  selected: policy.hours == hours,
                  onSelected: busy
                      ? null
                      : (_) => _change(() => _service.configure(hours: hours)),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final count in [3, 7, 14, 30])
                ChoiceChip(
                  label: Text('$count 份'),
                  selected: policy.retain == count,
                  onSelected: busy
                      ? null
                      : (_) => _change(() => _service.configure(retain: count)),
                ),
            ],
          ),
          Text(
            policy.lastCreated == null
                ? '尚无自动快照'
                : '最近快照：${policy.lastCreated!.toLocal().toString().split('.').first}',
          ),
          if (_error != null || _service.lastError != null)
            Text(
              _error ?? _service.lastError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (busy) const LinearProgressIndicator(),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => _change(() async {
                        await _service.runDue(force: true);
                      }),
                child: const Text('立即创建应用内快照'),
              ),
              TextButton(
                onPressed: busy ? null : _load,
                child: const Text('刷新快照列表'),
              ),
            ],
          ),
          for (final file in _files)
            ListTile(
              dense: true,
              title: Text(
                file.uri.pathSegments.last,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed: busy ? null : () => widget.onChoose(file),
                child: const Text('用于恢复'),
              ),
            ),
        ],
      );
    },
  );
}
