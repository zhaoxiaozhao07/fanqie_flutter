import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/download_history.dart';
import '../services/history_service.dart';
import '../widgets/history_card.dart';
import '../widgets/download_dialog.dart';
import '../widgets/loading_widget.dart';
import 'book_detail_screen.dart';

/// 下载历史页面
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  HistoryScreenState createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  final HistoryService _historyService = HistoryService();

  List<DownloadHistory> _historyList = [];
  bool _isLoading = true;
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  /// 公开的刷新方法，供外部调用
  void refreshHistory() {
    _loadHistory();
  }

  /// 加载历史记录
  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);

    try {
      final list = await _historyService.getHistoryList();
      setState(() {
        _historyList = list;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _historyList = [];
        _isLoading = false;
      });
    }
  }

  /// 跳转到书籍详情页
  void _navigateToDetail(DownloadHistory history) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BookDetailScreen(book: history.toBook()),
      ),
    );
  }

  /// 进入选择模式
  void _enterSelectionMode(String bookId) {
    setState(() {
      _isSelectionMode = true;
      _selectedIds.add(bookId);
    });
  }

  /// 退出选择模式
  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
    });
  }

  /// 切换选择状态
  void _toggleSelection(String bookId) {
    setState(() {
      if (_selectedIds.contains(bookId)) {
        _selectedIds.remove(bookId);
        if (_selectedIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedIds.add(bookId);
      }
    });
  }

  /// 全选
  void _selectAll() {
    setState(() {
      _selectedIds.addAll(_historyList.map((h) => h.bookId));
    });
  }

  /// 删除选中的记录
  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirmed = await DeleteConfirmDialog.show(
      context,
      title: '删除记录',
      content: '确定要删除选中的 ${_selectedIds.length} 条下载记录吗？',
    );

    if (confirmed == true) {
      await _historyService.deleteHistories(_selectedIds.toList());
      _exitSelectionMode();
      _loadHistory();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除选中的记录')));
    }
  }

  /// 清空所有记录
  Future<void> _clearAll() async {
    if (_historyList.isEmpty) return;

    final confirmed = await DeleteConfirmDialog.show(
      context,
      title: '清空记录',
      content: '确定要清空所有下载记录吗？此操作不可恢复。',
    );

    if (confirmed == true) {
      await _historyService.clearAllHistory();
      _loadHistory();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已清空所有记录')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '已选择 ${_selectedIds.length} 项' : '下载历史'),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : null,
        actions: _buildAppBarActions(),
      ),
      body: _buildBody(),
      bottomNavigationBar: _isSelectionMode ? _buildBottomBar() : null,
    );
  }

  /// 构建 AppBar 动作按钮
  List<Widget> _buildAppBarActions() {
    if (_isSelectionMode) {
      return [
        IconButton(
          icon: const Icon(Icons.select_all),
          onPressed: _selectAll,
          tooltip: '全选',
        ),
      ];
    }

    return [
      if (_historyList.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.delete_sweep),
          onPressed: _clearAll,
          tooltip: '清空全部',
        ),
    ];
  }

  /// 构建主体内容
  Widget _buildBody() {
    if (_isLoading) {
      return const LoadingWidget(message: '加载中...');
    }

    if (_historyList.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.history,
        title: '暂无下载记录',
        subtitle: '下载的小说会显示在这里',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView.builder(
        itemCount: _historyList.length,
        itemBuilder: (context, index) {
          final history = _historyList[index];
          final isSelected = _selectedIds.contains(history.bookId);

          return HistoryCard(
            history: history,
            isSelectionMode: _isSelectionMode,
            isSelected: isSelected,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(history.bookId);
              } else {
                // 非选择模式下，跳转到书籍详情页
                _navigateToDetail(history);
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) {
                _enterSelectionMode(history.bookId);
              }
            },
            onCheckChanged: (value) {
              _toggleSelection(history.bookId);
            },
          );
        },
      ),
    );
  }

  /// 构建底部操作栏
  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _exitSelectionMode,
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete),
              label: Text('删除 (${_selectedIds.length})'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
