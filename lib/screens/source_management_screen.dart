import 'package:flutter/material.dart';
import '../models/api_source.dart';
import '../services/source_service.dart';
import '../app_theme.dart';

class SourceManagementScreen extends StatefulWidget {
  const SourceManagementScreen({super.key});

  @override
  State<SourceManagementScreen> createState() => _SourceManagementScreenState();
}

class _SourceManagementScreenState extends State<SourceManagementScreen> {
  final SourceService _sourceService = SourceService();
  final TextEditingController _urlController = TextEditingController();
  List<ApiSource> _sources = [];
  bool _isChecking = false;

  // Track which sources are currently being tested
  final Map<String, bool> _testingMap = {};

  @override
  void initState() {
    super.initState();
    _refreshSources();
  }

  void _refreshSources() {
    setState(() {
      _sources = List.from(_sourceService.sources);
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _checkAllConnectivity() async {
    setState(() => _isChecking = true);

    final sourcesToCheck = List.from(_sources);

    // Mark all as testing first? Or sequential?
    // Let's do parallel but update UI individually?
    // Actually, simple iteration is clearer for "animation" per item if we want to see it progressing.
    // Check concurrently but track status.

    final List<Future> futures = [];

    for (var source in sourcesToCheck) {
      if (!source.isEnabled) continue; // Skip disabled

      setState(() {
        _testingMap[source.baseUrl] = true;
      });

      futures.add(() async {
        await _sourceService.checkSource(source);
        if (mounted) {
          setState(() {
            _testingMap.remove(source.baseUrl);
            _sources = List.from(
              _sourceService.sources,
            ); // Refresh list to show results
          });
        }
      }());
    }

    await Future.wait(futures);

    if (mounted) {
      setState(() => _isChecking = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连通性检测完成')));
    }
  }

  Future<void> _addSource() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入以 http:// 或 https:// 开头的完整 URL')),
      );
      return;
    }

    await _sourceService.addSource(url);
    _urlController.clear();
    if (mounted) Navigator.pop(context);
    _refreshSources();
  }

  Future<void> _removeSource(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定要删除源 $url 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _sourceService.removeSource(url);
      _refreshSources();
    }
  }

  Future<void> _toggleSource(String url, bool value) async {
    await _sourceService.toggleSource(url, value);
    _refreshSources();
  }

  void _setAsCurrent(String url) {
    if (_sourceService.setCurrentSource(url)) {
      _refreshSources();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已切换当前源为: $url')));
    }
  }

  void _showAddSourceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 API 源'),
        content: TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            labelText: 'API 地址',
            hintText: 'https://example.com',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () {
              _urlController.clear();
              Navigator.pop(context);
            },
            child: const Text('取消'),
          ),
          ElevatedButton(onPressed: _addSource, child: const Text('添加')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentActiveUrl = _sourceService.currentActiveUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('API 源管理'),
        actions: [
          IconButton(
            icon: _isChecking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.network_check),
            tooltip: '检测连通性',
            onPressed: _isChecking ? null : _checkAllConnectivity,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加源',
            onPressed: _showAddSourceDialog,
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _sources.length,
        itemBuilder: (context, index) {
          final source = _sources[index];
          final isCurrent = source.baseUrl == currentActiveUrl;

          return Card(
            elevation: isCurrent ? 4 : 2,
            shape: isCurrent
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(
                      color: AppTheme.primaryColor,
                      width: 2,
                    ),
                  )
                : null,
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              onTap: (source.isEnabled && !isCurrent)
                  ? () => _setAsCurrent(source.baseUrl)
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: Checkbox(
                value: source.isEnabled,
                onChanged: (val) => _toggleSource(source.baseUrl, val ?? false),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.baseUrl,
                      style: TextStyle(
                        color: source.isEnabled ? Colors.black : Colors.grey,
                        decoration: source.isEnabled
                            ? null
                            : TextDecoration.lineThrough,
                        fontWeight: isCurrent
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isCurrent)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppTheme.primaryColor),
                      ),
                      child: const Text(
                        '当前使用',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              subtitle: _buildStatusRow(source),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                color: Colors.grey,
                onPressed: () => _removeSource(source.baseUrl),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusRow(ApiSource source) {
    if (_testingMap.containsKey(source.baseUrl)) {
      return Row(
        children: const [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text('正在检测...', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      );
    }

    if (source.latency == null && !source.isWorking && source.error == null) {
      return const Text('未检测', style: TextStyle(fontSize: 12));
    }

    final List<Widget> children = [];

    if (source.isWorking) {
      children.add(
        const Icon(Icons.check_circle, size: 14, color: Colors.green),
      );
      children.add(const SizedBox(width: 4));
      children.add(
        Text(
          '${source.latency}ms',
          style: const TextStyle(
            color: Colors.green,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    } else {
      children.add(const Icon(Icons.error, size: 14, color: Colors.red));
      children.add(const SizedBox(width: 4));
      children.add(
        Flexible(
          child: Text(
            source.error ?? '无法访问',
            style: const TextStyle(color: Colors.red, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Row(children: children);
  }
}
