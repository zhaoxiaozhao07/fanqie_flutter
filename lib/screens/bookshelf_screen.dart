import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_theme.dart';
import '../main.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/download_history.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/history_service.dart';
import 'book_detail_screen.dart';
import 'reader_screen.dart';

enum BookshelfSortType {
  recentRead, // 最近阅读
  recentAdded, // 最近加入
  bookName, // 书名
}

enum BookshelfViewMode {
  list, // 单列列表
  grid3, // 三列宫格
}

class BookshelfScreen extends StatefulWidget {
  final VoidCallback? onGoToDiscover;

  const BookshelfScreen({super.key, this.onGoToDiscover});

  @override
  State<BookshelfScreen> createState() => BookshelfScreenState();
}

class BookshelfScreenState extends State<BookshelfScreen> {
  final BookshelfService _bookshelfService = BookshelfService();
  final HistoryService _downloadHistoryService = HistoryService();
  final ApiService _apiService = ApiService();

  // 0: 全部收藏, 1: 已下载
  int _currentSubTab = 0;

  List<BookshelfBook> _books = [];
  List<DownloadHistory> _downloadedBooks = [];
  bool _isLoading = true;

  bool _isSelectionMode = false;
  final Set<String> _selectedBookIds = {};
  BookshelfSortType _sortType = BookshelfSortType.recentRead;
  BookshelfViewMode _viewMode = BookshelfViewMode.list;

  @override
  void initState() {
    super.initState();
    _loadPreferences().then((_) {
      _loadData();
    });
    _bookshelfService.changeNotifier.addListener(_onBookshelfChanged);
  }

  @override
  void dispose() {
    _bookshelfService.changeNotifier.removeListener(_onBookshelfChanged);
    _apiService.dispose();
    super.dispose();
  }

  void _onBookshelfChanged() {
    if (mounted) {
      _loadData(silent: true);
    }
  }

  /// 外部调用刷新方法
  void refresh() {
    _loadData();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString('bookshelf_view_mode') ?? 'list';
    if (mounted) {
      setState(() {
        _viewMode = modeStr == 'grid3' ? BookshelfViewMode.grid3 : BookshelfViewMode.list;
      });
    }
  }

  Future<void> _toggleViewMode() async {
    final nextMode = _viewMode == BookshelfViewMode.list
        ? BookshelfViewMode.grid3
        : BookshelfViewMode.list;
    setState(() {
      _viewMode = nextMode;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bookshelf_view_mode', nextMode == BookshelfViewMode.grid3 ? 'grid3' : 'list');
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }
    await _bookshelfService.initialize();

    var shelfList = List<BookshelfBook>.from(_bookshelfService.books);
    _sortBooks(shelfList);

    List<DownloadHistory> downloads = [];
    try {
      downloads = await _downloadHistoryService.getHistoryList();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _books = shelfList;
        _downloadedBooks = downloads;
        _isLoading = false;
      });
    }
  }

  void _sortBooks(List<BookshelfBook> list) {
    switch (_sortType) {
      case BookshelfSortType.recentRead:
        list.sort((a, b) {
          final aTime = a.lastReadTime ?? a.addedTime;
          final bTime = b.lastReadTime ?? b.addedTime;
          return bTime.compareTo(aTime);
        });
        break;
      case BookshelfSortType.recentAdded:
        list.sort((a, b) => b.addedTime.compareTo(a.addedTime));
        break;
      case BookshelfSortType.bookName:
        list.sort((a, b) => a.bookName.compareTo(b.bookName));
        break;
    }
  }

  void _changeSort(BookshelfSortType type) {
    setState(() {
      _sortType = type;
      _sortBooks(_books);
    });
  }

  void _toggleSelection(String bookId) {
    setState(() {
      if (_selectedBookIds.contains(bookId)) {
        _selectedBookIds.remove(bookId);
        if (_selectedBookIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedBookIds.add(bookId);
      }
    });
  }

  int get _currentTabTotalCount =>
      _currentSubTab == 0 ? _books.length : _downloadedBooks.length;

  void _selectAll() {
    setState(() {
      if (_selectedBookIds.length == _currentTabTotalCount) {
        _selectedBookIds.clear();
      } else {
        if (_currentSubTab == 0) {
          _selectedBookIds.addAll(_books.map((b) => b.bookId));
        } else {
          _selectedBookIds.addAll(_downloadedBooks.map((d) => d.bookId));
        }
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedBookIds.isEmpty) return;

    final isDownloadedTab = _currentSubTab == 1;
    final dialogTitle = isDownloadedTab ? '删除已下载书籍' : '移出书架';
    final dialogContent = isDownloadedTab
        ? '确定要删除选中的 ${_selectedBookIds.length} 条已下载小说吗？'
        : '确定将选中的 ${_selectedBookIds.length} 本书籍移出书架吗？';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      if (isDownloadedTab) {
        await _downloadHistoryService.deleteHistories(_selectedBookIds.toList());
      } else {
        await _bookshelfService.removeMultiple(_selectedBookIds.toList());
      }

      setState(() {
        _selectedBookIds.clear();
        _isSelectionMode = false;
      });
      _loadData();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isDownloadedTab ? '已删除选中的下载记录' : '已将选中的书籍移出书架')),
        );
      }
    }
  }

  /// 阅读书架中的书籍
  Future<void> _continueReading(BookshelfBook shelfBook) async {
    final book = shelfBook.toBook();

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

    final targetIndex = (shelfBook.lastReadChapterIndex ?? 0).clamp(0, chapters.length - 1);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          chapters: chapters,
          initialChapterIndex: targetIndex,
        ),
      ),
    ).then((_) => _loadData(silent: true));
  }

  /// 直接阅读已下载的小说
  Future<void> _readDownloadedBook(DownloadHistory download) async {
    final book = download.toBook();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    List<Chapter> chapters = [];
    // 优先尝试联网获取完整章节结构
    try {
      chapters = await _apiService.getBookChapters(book.bookId);
    } catch (_) {}

    // 如果未获取到章节，尝试从本地文件解析
    if (chapters.isEmpty) {
      chapters = await _parseChaptersFromLocalFile(download.filePath);
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (!mounted) return;

    if (chapters.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法解析小说章节，请检查网络或文件')),
        );
      }
      return;
    }

    // 读取最后阅读进度
    final prefs = await SharedPreferences.getInstance();
    final savedIndex = prefs.getInt('read_progress_index_${book.bookId}') ?? 0;
    final targetIndex = savedIndex.clamp(0, chapters.length - 1);

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          book: book,
          chapters: chapters,
          initialChapterIndex: targetIndex,
        ),
      ),
    ).then((_) => _loadData(silent: true));
  }

  /// 从本地 TXT 文件解析章节
  Future<List<Chapter>> _parseChaptersFromLocalFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final reg = RegExp(r'\n(?=(?:第[0-9一二三四五六七八九十百千]+[章回节卷集幕篇部]|[0-9]+[、\s]))');
      final splits = content.split(reg);

      final chapters = <Chapter>[];
      for (int i = 0; i < splits.length; i++) {
        final part = splits[i].trim();
        if (part.isEmpty) continue;
        final lines = part.split('\n');
        final title = lines.first.trim();
        chapters.add(Chapter(
          itemId: 'local_$i',
          title: title.length > 40 ? title.substring(0, 40) : title,
          order: i + 1,
          content: part,
        ));
      }
      return chapters;
    } catch (_) {
      return [];
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '未读';
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
          _isSelectionMode
              ? '已选择 ${_selectedBookIds.length} 项'
              : '我的书架 (${_currentSubTab == 0 ? _books.length : _downloadedBooks.length})',
        ),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedBookIds.clear();
                  });
                },
              )
            : null,
        actions: [
          if (!_isSelectionMode) ...[
            // 切换 列表 / 三列 视图按钮
            IconButton(
              icon: Icon(
                _viewMode == BookshelfViewMode.list
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
              ),
              tooltip: _viewMode == BookshelfViewMode.list ? '切换为三列视图' : '切换为列表视图',
              onPressed: _toggleViewMode,
            ),
            // 排序选项 (仅收藏页支持)
            if (_currentSubTab == 0 && _books.isNotEmpty)
              PopupMenuButton<BookshelfSortType>(
                icon: const Icon(Icons.sort_rounded),
                tooltip: '排序方式',
                onSelected: _changeSort,
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(
                    value: BookshelfSortType.recentRead,
                    checked: _sortType == BookshelfSortType.recentRead,
                    child: const Text('最近阅读优先'),
                  ),
                  CheckedPopupMenuItem(
                    value: BookshelfSortType.recentAdded,
                    checked: _sortType == BookshelfSortType.recentAdded,
                    child: const Text('最近加入优先'),
                  ),
                  CheckedPopupMenuItem(
                    value: BookshelfSortType.bookName,
                    checked: _sortType == BookshelfSortType.bookName,
                    child: const Text('按书名排序'),
                  ),
                ],
              ),
            // 批量管理
            if (_currentTabTotalCount > 0)
              IconButton(
                icon: const Icon(Icons.checklist_rounded),
                tooltip: '批量管理',
                onPressed: () {
                  setState(() => _isSelectionMode = true);
                },
              ),
          ],
          if (_isSelectionMode)
            IconButton(
              icon: Icon(
                _selectedBookIds.length == _currentTabTotalCount
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              tooltip: _selectedBookIds.length == _currentTabTotalCount ? '取消全选' : '全选',
              onPressed: _selectAll,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildSubTabBar(),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: _isSelectionMode ? _buildBatchBottomBar() : null,
    );
  }

  /// 顶部快捷子标签：全部收藏 vs 已下载
  Widget _buildSubTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          _buildPillTab(0, '全部收藏 (${_books.length})', Icons.collections_bookmark_rounded),
          const SizedBox(width: 8),
          _buildPillTab(1, '已下载 (${_downloadedBooks.length})', Icons.download_done_rounded),
          const Spacer(),
          Text(
            _viewMode == BookshelfViewMode.grid3 ? '三列视图' : '单列列表',
            style: const TextStyle(fontSize: 12, color: AppTheme.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildPillTab(int index, String label, IconData icon) {
    final isSelected = _currentSubTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        debugPrint('TAPPED PILL $index');
        setState(() {
          _currentSubTab = index;
          _isSelectionMode = false;
          _selectedBookIds.clear();
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryColor.withValues(alpha: 0.12)
              : const Color(0xFFF2F4F7),
          borderRadius: BorderRadius.circular(20),
          border: isSelected
              ? Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.5), width: 1.5)
              : Border.all(color: Colors.transparent, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? AppTheme.primaryColor : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_currentSubTab == 0) {
      return _buildFavoritesView();
    } else {
      return _buildDownloadsView();
    }
  }

  /// 构建收藏列表（支持列表和三列展示）
  Widget _buildFavoritesView() {
    if (_books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.collections_bookmark_outlined, size: 72, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                '书架空空如也',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 8),
              const Text(
                '在主页或搜索中，点击卡片上的书签即可收藏到书架',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: widget.onGoToDiscover,
                icon: const Icon(Icons.explore_outlined),
                label: const Text('去发现好书'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadData(silent: false),
      child: _viewMode == BookshelfViewMode.grid3
          ? _buildFavoritesGrid()
          : _buildFavoritesList(),
    );
  }

  /// 单列列表呈现
  Widget _buildFavoritesList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final shelfBook = _books[index];
        final isSelected = _selectedBookIds.contains(shelfBook.bookId);

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
                if (_isSelectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => _toggleSelection(shelfBook.bookId),
                    ),
                  ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 50,
                    height: 70,
                    child: shelfBook.thumbUrl != null && shelfBook.thumbUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: shelfBook.thumbUrl!,
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
              shelfBook.bookName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '作者: ${shelfBook.author}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  maxLines: 1,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        shelfBook.lastReadChapterTitle != null
                            ? '读至: ${shelfBook.lastReadChapterTitle}'
                            : '尚未开始阅读',
                        style: TextStyle(
                          fontSize: 11,
                          color: shelfBook.lastReadChapterTitle != null
                              ? AppTheme.primaryColor
                              : AppTheme.textHint,
                          fontWeight: shelfBook.lastReadChapterTitle != null
                              ? FontWeight.w500
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatTime(shelfBook.lastReadTime),
                      style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
                    ),
                  ],
                ),
              ],
            ),
            trailing: !_isSelectionMode
                ? OutlinedButton(
                    onPressed: () => _continueReading(shelfBook),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: const Size(0, 32),
                      side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.6)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(
                      shelfBook.lastReadChapterIndex != null ? '续读' : '开读',
                      style: const TextStyle(fontSize: 12, color: AppTheme.primaryColor),
                    ),
                  )
                : null,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(shelfBook.bookId);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BookDetailScreen(book: shelfBook.toBook()),
                  ),
                ).then((_) => _loadData(silent: true));
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) {
                setState(() {
                  _isSelectionMode = true;
                  _selectedBookIds.add(shelfBook.bookId);
                });
              }
            },
          ),
        );
      },
    );
  }

  /// 三列宫格呈现
  Widget _buildFavoritesGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 900;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.60,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _books.length,
          itemBuilder: (context, index) {
            final shelfBook = _books[index];
            final isSelected = _selectedBookIds.contains(shelfBook.bookId);

            return GestureDetector(
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(shelfBook.bookId);
                } else {
                  _continueReading(shelfBook);
                }
              },
              onLongPress: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    _selectedBookIds.add(shelfBook.bookId);
                  });
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 封面与选择框
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 6,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: shelfBook.thumbUrl != null && shelfBook.thumbUrl!.isNotEmpty
                                ? CachedNetworkImage(
                                    imageUrl: shelfBook.thumbUrl!,
                                    fit: BoxFit.cover,
                                    cacheManager: BookCoverCacheManager.instance,
                                    placeholder: (context, url) => Container(color: AppTheme.primaryLight),
                                    errorWidget: (context, url, error) => Container(
                                      color: AppTheme.primaryLight,
                                      child: const Icon(Icons.book, size: 28, color: AppTheme.primaryColor),
                                    ),
                                  )
                                : Container(
                                    color: AppTheme.primaryLight,
                                    child: const Icon(Icons.book, size: 28, color: AppTheme.primaryColor),
                                  ),
                          ),
                        ),
                        if (_isSelectionMode)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4),
                                ],
                              ),
                              child: Icon(
                                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                size: 24,
                                color: isSelected ? AppTheme.primaryColor : Colors.grey,
                              ),
                            ),
                          ),
                        // 阅读进度标签浮层
                        if (!_isSelectionMode && shelfBook.lastReadChapterIndex != null)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                              ),
                              child: Text(
                                '读至第${(shelfBook.lastReadChapterIndex ?? 0) + 1}章',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w500),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 书名
                  Text(
                    shelfBook.bookName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // 作者
                  Text(
                    shelfBook.author,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 构建已下载小说视图（支持列表和三列展示）
  Widget _buildDownloadsView() {
    if (_downloadedBooks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_done_rounded, size: 72, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              const Text(
                '暂无已下载小说',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 8),
              const Text(
                '在书籍详情中下载的小说会直接保存在这里，离线也可快速阅读',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: widget.onGoToDiscover,
                icon: const Icon(Icons.search),
                label: const Text('去挑选书籍下载'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadData(silent: false),
      child: _viewMode == BookshelfViewMode.grid3
          ? _buildDownloadsGrid()
          : _buildDownloadsList(),
    );
  }

  /// 已下载书籍单列列表
  Widget _buildDownloadsList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _downloadedBooks.length,
      itemBuilder: (context, index) {
        final download = _downloadedBooks[index];
        final isSelected = _selectedBookIds.contains(download.bookId);

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
                if (_isSelectionMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => _toggleSelection(download.bookId),
                    ),
                  ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 50,
                    height: 70,
                    child: download.thumbUrl != null && download.thumbUrl!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: download.thumbUrl!,
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
              download.bookName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '作者: ${download.author}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  maxLines: 1,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        download.format,
                        style: const TextStyle(fontSize: 10, color: AppTheme.primaryColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      download.formattedFileSize,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
                    ),
                  ],
                ),
              ],
            ),
            trailing: !_isSelectionMode
                ? ElevatedButton.icon(
                    onPressed: () => _readDownloadedBook(download),
                    icon: const Icon(Icons.menu_book_rounded, size: 16),
                    label: const Text('阅读', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  )
                : null,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(download.bookId);
              } else {
                _readDownloadedBook(download);
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) {
                setState(() {
                  _isSelectionMode = true;
                  _selectedBookIds.add(download.bookId);
                });
              }
            },
          ),
        );
      },
    );
  }

  /// 已下载书籍三列宫格
  Widget _buildDownloadsGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 900;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.60,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _downloadedBooks.length,
          itemBuilder: (context, index) {
            final download = _downloadedBooks[index];
            final isSelected = _selectedBookIds.contains(download.bookId);

            return GestureDetector(
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(download.bookId);
                } else {
                  _readDownloadedBook(download);
                }
              },
              onLongPress: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    _selectedBookIds.add(download.bookId);
                  });
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: download.thumbUrl != null && download.thumbUrl!.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: download.thumbUrl!,
                                  fit: BoxFit.cover,
                                  cacheManager: BookCoverCacheManager.instance,
                                  placeholder: (context, url) => Container(color: AppTheme.primaryLight),
                                  errorWidget: (context, url, error) => Container(
                                    color: AppTheme.primaryLight,
                                    child: const Icon(Icons.book, size: 28, color: AppTheme.primaryColor),
                                  ),
                                )
                              : Container(
                                  color: AppTheme.primaryLight,
                                  child: const Icon(Icons.book, size: 28, color: AppTheme.primaryColor),
                                ),
                        ),
                        if (_isSelectionMode)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4),
                                ],
                              ),
                              child: Icon(
                                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                                size: 24,
                                color: isSelected ? AppTheme.primaryColor : Colors.grey,
                              ),
                            ),
                          ),
                        // 已下载格式标记
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              download.format,
                              style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    download.bookName,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${download.author} · ${download.formattedFileSize}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          },
        ),
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
            '已选 ${_selectedBookIds.length} 项',
            style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              setState(() {
                _isSelectionMode = false;
                _selectedBookIds.clear();
              });
            },
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: _selectedBookIds.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text(_currentSubTab == 1 ? '删除下载 (${_selectedBookIds.length})' : '移出书架 (${_selectedBookIds.length})'),
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
}
