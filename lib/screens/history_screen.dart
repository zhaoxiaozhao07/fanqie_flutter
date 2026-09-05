import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../app_theme.dart';
import '../main.dart';
import '../models/download_history.dart';
import '../models/reading_history.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/history_service.dart';
import '../services/reading_history_service.dart';
import '../widgets/history_card.dart';
import '../widgets/loading_widget.dart';
import 'book_detail_screen.dart';
import 'reader_screen.dart';

/// 历史页面 - 分为“阅读历史”与“下载历史”
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  HistoryScreenState createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  final HistoryService _downloadHistoryService = HistoryService();
  final ReadingHistoryService _readingHistoryService = ReadingHistoryService();
  final ApiService _apiService = ApiService();

  late TabController _tabController;

  // 阅读历史状态
  List<ReadingHistory> _readingList = [];
  bool _isLoadingReading = true;
  bool _isReadingSelectionMode = false;
  final Set<String> _selectedReadingIds = {};

  // 下载历史状态
  List<DownloadHistory> _downloadList = [];
  bool _isLoadingDownload = true;
  bool _isDownloadSelectionMode = false;
  final Set<String> _selectedDownloadIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadAllHistory();
    _readingHistoryService.changeNotifier.addListener(_onReadingHistoryChanged);
  }

  @override
  void dispose() {
    _readingHistoryService.changeNotifier.removeListener(_onReadingHistoryChanged);
    _tabController.dispose();
    _apiService.dispose();
    super.dispose();
  }

  void _onReadingHistoryChanged() {
    _loadReadingHistory(silent: true);
  }

  /// 公开的刷新方法
  void refreshHistory() {
    _loadAllHistory();
  }

  Future<void> _loadAllHistory() async {
    await Future.wait([
      _loadReadingHistory(),
      _loadDownloadHistory(),
    ]);
  }

  Future<void> _loadReadingHistory({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoadingReading = true);
    }
    try {
      final list = await _readingHistoryService.getHistoryList();
      if (mounted) {
        setState(() {
          _readingList = list;
          _isLoadingReading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _readingList = [];
          _isLoadingReading = false;
        });
      }
    }
  }

  Future<void> _loadDownloadHistory() async {
    setState(() => _isLoadingDownload = true);
    try {
      final list = await _downloadHistoryService.getHistoryList();
      if (mounted) {
        setState(() {
          _downloadList = list;
          _isLoadingDownload = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloadList = [];
          _isLoadingDownload = false;
        });
      }
    }
  }

  bool get _isCurrentSelectionMode =>
      _tabController.index == 0 ? _isReadingSelectionMode : _isDownloadSelectionMode;

  int get _currentSelectedCount =>
      _tabController.index == 0 ? _selectedReadingIds.length : _selectedDownloadIds.length;

  int get _currentListCount =>
      _tabController.index == 0 ? _readingList.length : _downloadList.length;

  void _toggleSelectAll() {
    setState(() {
      if (_tabController.index == 0) {
        if (_selectedReadingIds.length == _readingList.length) {
          _selectedReadingIds.clear();
        } else {
          _selectedReadingIds.addAll(_readingList.map((r) => r.bookId));
        }
      } else {
        if (_selectedDownloadIds.length == _downloadList.length) {
          _selectedDownloadIds.clear();
        } else {
          _selectedDownloadIds.addAll(_downloadList.map((d) => d.bookId));
        }
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      if (_tabController.index == 0) {
        _isReadingSelectionMode = false;
        _selectedReadingIds.clear();
      } else {
        _isDownloadSelectionMode = false;
        _selectedDownloadIds.clear();
      }
    });
  }

  Future<void> _deleteSelected() async {
    final count = _currentSelectedCount;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确定要删除选中的 $count 条历史记录吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      if (_tabController.index == 0) {
        await _readingHistoryService.deleteHistories(_selectedReadingIds.toList());
        _isReadingSelectionMode = false;
        _selectedReadingIds.clear();
        _loadReadingHistory();
      } else {
        await _downloadHistoryService.deleteHistories(_selectedDownloadIds.toList());
        _isDownloadSelectionMode = false;
        _selectedDownloadIds.clear();
        _loadDownloadHistory();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除选中的记录')),
        );
      }
    }
  }

  Future<void> _clearCurrentTab() async {
    final isReading = _tabController.index == 0;
    final title = isReading ? '清空阅读历史' : '清空下载历史';
    final content = isReading ? '确定要清空所有阅读历史吗？' : '确定要清空所有下载记录吗？';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      if (isReading) {
        await _readingHistoryService.clearAll();
        _loadReadingHistory();
      } else {
        await _downloadHistoryService.clearAllHistory();
        _loadDownloadHistory();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空全部记录')),
        );
      }
    }
  }

  /// 直接从阅读历史中快速续读
  Future<void> _continueReading(ReadingHistory item) async {
    final book = item.toBook();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    List<Chapter> chapters = [];
    try {
      chapters = await _apiService.getBookChapters(book.bookId);
    } catch (_) {}

    if (mounted) {
      Navigator.pop(context);
    }

    if (!mounted) return;

    if (chapters.isEmpty) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => BookDetailScreen(book: book)),
      );
      return;
    }

    final targetIndex = item.lastReadChapterIndex.clamp(0, chapters.length - 1);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          chapters: chapters,
          initialChapterIndex: targetIndex,
        ),
      ),
    ).then((_) => _loadReadingHistory(silent: true));
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${time.month}月${time.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isCurrentSelectionMode
              ? '已选择 $_currentSelectedCount 项'
              : (_tabController.index == 0 ? '阅读历史' : '下载历史'),
        ),
        leading: _isCurrentSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : null,
        actions: [
          if (!_isCurrentSelectionMode && _currentListCount > 0) ...[
            IconButton(
              icon: const Icon(Icons.checklist_rounded),
              tooltip: '批量管理',
              onPressed: () {
                setState(() {
                  if (_tabController.index == 0) {
                    _isReadingSelectionMode = true;
                  } else {
                    _isDownloadSelectionMode = true;
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: '清空记录',
              onPressed: _clearCurrentTab,
            ),
          ],
          if (_isCurrentSelectionMode)
            IconButton(
              icon: Icon(
                _currentSelectedCount == _currentListCount
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              tooltip: _currentSelectedCount == _currentListCount ? '取消全选' : '全选',
              onPressed: _toggleSelectAll,
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primaryColor,
          labelColor: AppTheme.primaryColor,
          unselectedLabelColor: AppTheme.textSecondary,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          tabs: [
            Tab(text: '阅读历史 (${_readingList.length})'),
            Tab(text: '下载历史 (${_downloadList.length})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildReadingHistoryList(),
          _buildDownloadHistoryList(),
        ],
      ),
      bottomNavigationBar: _isCurrentSelectionMode ? _buildBatchBottomBar() : null,
    );
  }

  Widget _buildReadingHistoryList() {
    if (_isLoadingReading) {
      return const LoadingWidget(message: '加载阅读历史...');
    }

    if (_readingList.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.auto_stories_outlined,
        title: '暂无阅读历史',
        subtitle: '打开阅读过的书籍会在这里展示',
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadReadingHistory(silent: false),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _readingList.length,
        itemBuilder: (context, index) {
          final item = _readingList[index];
          final isSelected = _selectedReadingIds.contains(item.bookId);

          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isReadingSelectionMode)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (_) {
                          setState(() {
                            if (isSelected) {
                              _selectedReadingIds.remove(item.bookId);
                              if (_selectedReadingIds.isEmpty) {
                                _isReadingSelectionMode = false;
                              }
                            } else {
                              _selectedReadingIds.add(item.bookId);
                            }
                          });
                        },
                      ),
                    ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 50,
                      height: 70,
                      child: item.thumbUrl != null && item.thumbUrl!.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.thumbUrl!,
                              fit: BoxFit.cover,
                              cacheManager: BookCoverCacheManager.instance,
                              placeholder: (context, url) => Container(color: AppTheme.primaryLight),
                              errorWidget: (context, url, error) => Container(
                                color: AppTheme.primaryLight,
                                child: const Icon(Icons.book, size: 24, color: AppTheme.primaryColor),
                              ),
                            )
                          : Container(
                              color: AppTheme.primaryLight,
                              child: const Icon(Icons.book, size: 24, color: AppTheme.primaryColor),
                            ),
                    ),
                  ),
                ],
              ),
              title: Text(
                item.bookName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    '作者: ${item.author}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                    maxLines: 1,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '读至: ${item.lastReadChapterTitle}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.primaryColor,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatTime(item.lastReadTime),
                        style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
                      ),
                    ],
                  ),
                ],
              ),
              trailing: !_isReadingSelectionMode
                  ? OutlinedButton(
                      onPressed: () => _continueReading(item),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: const Size(0, 32),
                        side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.6)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: const Text('续读', style: TextStyle(fontSize: 12, color: AppTheme.primaryColor)),
                    )
                  : null,
              onTap: () {
                if (_isReadingSelectionMode) {
                  setState(() {
                    if (isSelected) {
                      _selectedReadingIds.remove(item.bookId);
                      if (_selectedReadingIds.isEmpty) {
                        _isReadingSelectionMode = false;
                      }
                    } else {
                      _selectedReadingIds.add(item.bookId);
                    }
                  });
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BookDetailScreen(book: item.toBook()),
                    ),
                  ).then((_) => _loadReadingHistory(silent: true));
                }
              },
              onLongPress: () {
                if (!_isReadingSelectionMode) {
                  setState(() {
                    _isReadingSelectionMode = true;
                    _selectedReadingIds.add(item.bookId);
                  });
                }
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildDownloadHistoryList() {
    if (_isLoadingDownload) {
      return const LoadingWidget(message: '加载下载历史...');
    }

    if (_downloadList.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.download_done_rounded,
        title: '暂无下载记录',
        subtitle: '下载完结的小说会展示在这里',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDownloadHistory,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _downloadList.length,
        itemBuilder: (context, index) {
          final history = _downloadList[index];
          final isSelected = _selectedDownloadIds.contains(history.bookId);

          return HistoryCard(
            history: history,
            isSelectionMode: _isDownloadSelectionMode,
            isSelected: isSelected,
            onTap: () {
              if (_isDownloadSelectionMode) {
                setState(() {
                  if (isSelected) {
                    _selectedDownloadIds.remove(history.bookId);
                    if (_selectedDownloadIds.isEmpty) {
                      _isDownloadSelectionMode = false;
                    }
                  } else {
                    _selectedDownloadIds.add(history.bookId);
                  }
                });
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => BookDetailScreen(book: history.toBook()),
                  ),
                );
              }
            },
            onLongPress: () {
              if (!_isDownloadSelectionMode) {
                setState(() {
                  _isDownloadSelectionMode = true;
                  _selectedDownloadIds.add(history.bookId);
                });
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildBatchBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            '已选 $_currentSelectedCount 项',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const Spacer(),
          TextButton(
            onPressed: _exitSelectionMode,
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _currentSelectedCount == 0 ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text('删除 ($countText)'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
          ),
        ],
      ),
    );
  }

  String get countText => '$_currentSelectedCount';
}
