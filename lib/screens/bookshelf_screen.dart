import '../widgets/book_page_route.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import '../services/reader_route_observer.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import '../models/download_history.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/history_service.dart';
import '../services/local_book_service.dart';
import '../widgets/local_book_import_dialog.dart';
import '../widgets/reader_backup_dialog.dart';
import '../widgets/reading_activity_dialog.dart';
import '../widgets/book_cover_widget.dart';
import '../widgets/download_action_button.dart';
import 'book_detail_screen.dart';
import 'reader_screen.dart';
import '../services/reader_settings_repository.dart';
import '../services/reader_platform.dart';

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
  final bool isActive;
  final BookshelfService? bookshelfService;
  final HistoryService? historyService;
  final ApiService? apiService;

  const BookshelfScreen({
    super.key,
    this.onGoToDiscover,
    this.isActive = true,
    this.bookshelfService,
    this.historyService,
    this.apiService,
  });

  @override
  State<BookshelfScreen> createState() => BookshelfScreenState();
}

class BookshelfScreenState extends State<BookshelfScreen> with RouteAware {
  late final BookshelfService _bookshelfService =
      widget.bookshelfService ?? BookshelfService();
  late final HistoryService _downloadHistoryService =
      widget.historyService ?? HistoryService();
  late final ApiService _apiService = widget.apiService ?? ApiService();

  // 0: 全部收藏, 1: 已下载
  int _currentSubTab = 0;

  List<BookshelfBook> _books = [];
  List<DownloadHistory> _downloadedBooks = [];
  bool _isLoading = true;
  bool _loaded = false, _reloadRequested = false, _covered = false;
  Future<void>? _loadRequest, _coverRequest;
  String? _snapshot;
  final Map<String, DateTime> _coverAttempts = {};
  PageRoute<dynamic>? _route;
  String? _openingBookId;

  bool _isSelectionMode = false;
  final Set<String> _selectedBookIds = {};
  BookshelfSortType _sortType = BookshelfSortType.recentRead;
  BookshelfViewMode _viewMode = BookshelfViewMode.list;

  @override
  void initState() {
    super.initState();
    _loadPreferences().then((_) {
      if (!mounted) return;
      _loadData().then((_) => _startBackgroundMaintenance());
    });
    _bookshelfService.changeNotifier.addListener(_onBookshelfChanged);
    _downloadHistoryService.changeNotifier.addListener(_onBookshelfChanged);
  }

  @override
  void dispose() {
    _bookshelfService.changeNotifier.removeListener(_onBookshelfChanged);
    _downloadHistoryService.changeNotifier.removeListener(_onBookshelfChanged);
    readerRouteObserver.unsubscribe(this);
    _apiService.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && !identical(route, _route)) {
      readerRouteObserver.unsubscribe(this);
      _route = route;
      readerRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(covariant BookshelfScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _startBackgroundMaintenance();
    }
  }

  @override
  void didPushNext() => _covered = true;

  @override
  void didPopNext() {
    _covered = false;
    if (_reloadRequested) unawaited(_loadData());
  }

  void _onBookshelfChanged() {
    if (!mounted) return;
    _reloadRequested = true;
    if (!_covered) unawaited(_loadData());
  }

  /// Refresh the local snapshot without blanking content or starting network work.
  Future<void> refresh() => _loadData();

  void _startBackgroundMaintenance() {
    if (!mounted || !_loaded || !widget.isActive || _covered) return;
    unawaited(_backgroundMaintenance());
  }

  Future<void> _backgroundMaintenance() async {
    try {
      await Future.wait([
        _bookshelfService.checkBookshelfUpdates(),
        _fetchMissingCovers(),
      ]);
    } catch (_) {
      /* Preserve the visible local snapshot on storage/network failure. */
    }
  }

  Future<void> _refreshFromNetwork() async {
    try {
      await Future.wait([
        _bookshelfService.checkBookshelfUpdates(force: true),
        _fetchMissingCovers(force: true),
      ]);
    } catch (_) {}
    if (mounted) await _loadData();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString('bookshelf_view_mode') ?? 'list';
    if (mounted) {
      setState(() {
        _viewMode = modeStr == 'grid3'
            ? BookshelfViewMode.grid3
            : BookshelfViewMode.list;
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
    await prefs.setString(
      'bookshelf_view_mode',
      nextMode == BookshelfViewMode.grid3 ? 'grid3' : 'list',
    );
  }

  Future<void> _showImportLocalBookDialog() async {
    final result = await showDialog<LocalImportResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const LocalBookImportDialog(),
    );
    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.alreadyExists
              ? '已保留《${result.book.bookName}》原阅读数据'
              : '已导入《${result.book.bookName}》共 ${result.chapterCount} 章',
        ),
      ),
    );
    _loadData(silent: true);
  }

  Future<void> _loadData({bool silent = false}) {
    if (!mounted) return Future.value();
    _reloadRequested = true;
    final pending = _loadRequest;
    if (pending != null) return pending;
    late final Future<void> request;
    request =
        () async {
          do {
            _reloadRequested = false;
            await _bookshelfService.initialize();
            List<DownloadHistory> downloads;
            try {
              downloads = await _downloadHistoryService.getHistoryList();
            } catch (_) {
              downloads = _downloadedBooks;
            }
            if (!mounted) return;
            if (_covered && _loaded) {
              _reloadRequested = true;
              return;
            }
            // Read the current shelf AFTER asynchronous work; never publish a stale
            // pre-await snapshot over a more recent reading-progress notification.
            final shelf = List<BookshelfBook>.of(_bookshelfService.books);
            _sortBooks(shelf);
            final snapshot = jsonEncode([
              shelf.map((b) => b.toJson()).toList(),
              downloads.map((b) => b.toJson()).toList(),
            ]);
            if (!_loaded || _snapshot != snapshot) {
              setState(() {
                _books = shelf;
                _downloadedBooks = downloads;
                _snapshot = snapshot;
                _isLoading = false;
                _loaded = true;
              });
            }
          } while (_reloadRequested && !_covered);
        }().whenComplete(() {
          if (identical(_loadRequest, request)) _loadRequest = null;
        });
    _loadRequest = request;
    return request;
  }

  /// 安全的 URL 清洗（升级协议为 https，保留完整有效链接）
  static String? cleanCoverUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    var clean = url.trim();
    if (clean.startsWith('http://')) {
      clean = clean.replaceFirst('http://', 'https://');
    }
    return clean.startsWith('https://') ? clean : null;
  }

  Future<void> _fetchMissingCovers({bool force = false}) {
    final pending = _coverRequest;
    if (pending != null) return pending;
    late final Future<void> request;
    request = _repairMissingCovers(force).whenComplete(() {
      if (identical(_coverRequest, request)) _coverRequest = null;
    });
    _coverRequest = request;
    return request;
  }

  Future<void> _repairMissingCovers(bool force) async {
    final shelf = _bookshelfService.books;
    final downloads = await _downloadHistoryService.getHistoryList();
    final covers = <String, String>{};
    final missing = <String, String>{};
    for (final b in [
      ...shelf.map((b) => b.toBook()),
      ...downloads.map((d) => d.toBook()),
    ]) {
      final cover = cleanCoverUrl(b.thumbUrl);
      if (cover != null) covers[b.bookId] = cover;
      if (cover == null) missing[b.bookId] = b.bookName;
    }
    for (final entry in missing.entries) {
      if (!mounted) return;
      final id = entry.key;
      var cover = covers[id];
      if (cover == null && !id.startsWith('local_')) {
        final now = DateTime.now();
        if (!force &&
            _coverAttempts[id] != null &&
            now.difference(_coverAttempts[id]!) <
                BookshelfService.updateInterval) {
          continue;
        }
        _coverAttempts[id] = now;
        try {
          final results = await _apiService.searchBooks(entry.value);
          for (final book in results) {
            if (book.bookId == id) {
              cover = cleanCoverUrl(book.thumbUrl);
              break;
            }
          }
          cover ??= cleanCoverUrl(
            (await _apiService.getBookDetail(id))?.thumbUrl,
          );
        } catch (_) {}
      }
      if (!mounted) return;
      if (cover != null) {
        await _bookshelfService.updateCover(id, cover);
        await _downloadHistoryService.updateCover(id, cover);
      }
    }
  }

  void _sortBooks(List<BookshelfBook> list) {
    switch (_sortType) {
      case BookshelfSortType.recentRead:
        list.sort((a, b) {
          final aTime = a.lastReadTime ?? a.addedTime;
          final bTime = b.lastReadTime ?? b.addedTime;
          final order = bTime.compareTo(aTime);
          return order != 0 ? order : a.bookId.compareTo(b.bookId);
        });
        break;
      case BookshelfSortType.recentAdded:
        list.sort((a, b) {
          final order = b.addedTime.compareTo(a.addedTime);
          return order != 0 ? order : a.bookId.compareTo(b.bookId);
        });
        break;
      case BookshelfSortType.bookName:
        list.sort((a, b) {
          final order = a.bookName.compareTo(b.bookName);
          return order != 0 ? order : a.bookId.compareTo(b.bookId);
        });
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
        await _downloadHistoryService.deleteHistories(
          _selectedBookIds.toList(),
        );
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
          SnackBar(
            content: Text(isDownloadedTab ? '已删除选中的下载记录' : '已将选中的书籍移出书架'),
          ),
        );
      }
    }
  }

  Future<void> _continueReading(BookshelfBook book) =>
      _openShelfReader(book.toBook(), book.lastReadChapterIndex ?? 0);

  void _openBookDetail(Book book) {
    Navigator.push(
      context,
      BookPageRoute(builder: (_) => BookDetailScreen(book: book)),
    ).then((_) {
      if (mounted) _loadData();
    });
  }

  Future<void> _readDownloadedBook(DownloadHistory download) async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    await _openShelfReader(
      download.toBook(),
      prefs.getInt('read_progress_index_${download.bookId}') ?? 0,
      filePath: download.filePath,
    );
  }

  Future<void> _openShelfReader(
    Book book,
    int index, {
    String? filePath,
  }) async {
    if (_openingBookId != null) return;
    setState(() => _openingBookId = book.bookId);
    try {
      List<Chapter> chapters = [];
      try {
        chapters = await _apiService.getBookChapters(book.bookId);
      } catch (_) {}
      if (chapters.isEmpty && filePath != null) {
        chapters = await _parseChaptersFromLocalFile(filePath);
      }
      if (!mounted) return;
      if (chapters.isEmpty) {
        _openBookDetail(book);
        return;
      }
      final settings = await ReaderSettingsRepository().load(book.bookId);
      if (!mounted) return;
      final route = Navigator.push(
        context,
        BookPageRoute(
          builder: (_) => ReaderScreen(
            book: book,
            chapters: chapters,
            initialChapterIndex: index.clamp(0, chapters.length - 1),
            initialSettings: settings,
          ),
        ),
      );
      unawaited(_bookshelfService.clearBookUpdateBadge(book.bookId));
      unawaited(
        route.then((_) {
          if (mounted) _loadData();
        }),
      );
    } finally {
      if (mounted) setState(() => _openingBookId = null);
    }
  }

  /// 从本地 TXT 文件解析章节
  Future<List<Chapter>> _parseChaptersFromLocalFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final content = await file.readAsString();
      final reg = RegExp(
        r'\n(?=(?:第[0-9一二三四五六七八九十百千]+[章回节卷集幕篇部]|[0-9]+[、\s]))',
      );
      final splits = content.split(reg);

      final chapters = <Chapter>[];
      for (int i = 0; i < splits.length; i++) {
        final part = splits[i].trim();
        if (part.isEmpty) continue;
        final lines = part.split('\n');
        final title = lines.first.trim();
        chapters.add(
          Chapter(
            itemId: 'local_$i',
            title: title.length > 40 ? title.substring(0, 40) : title,
            order: i + 1,
            content: part,
          ),
        );
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
              : MediaQuery.sizeOf(context).width < 400
              ? '书架'
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
            const DownloadActionButton(),
            // 导入本地 TXT / EPUB 小说
            PopupMenuButton<String>(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: '导入与备份',
              onSelected: (value) async {
                if (value == 'import') {
                  await _showImportLocalBookDialog();
                } else if (value == 'activity') {
                  await showDialog<void>(
                    context: context,
                    builder: (_) => const ReadingActivityDialog(),
                  );
                } else {
                  await showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const ReaderBackupDialog(),
                  );
                  if (mounted) _loadData(silent: true);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'import', child: Text('导入本地小说')),
                PopupMenuItem(value: 'backup', child: Text('备份与恢复')),
                PopupMenuItem(value: 'activity', child: Text('阅读统计')),
              ],
            ),
            // 切换 列表 / 三列 视图按钮
            IconButton(
              icon: Icon(
                _viewMode == BookshelfViewMode.list
                    ? Icons.grid_view_rounded
                    : Icons.view_list_rounded,
              ),
              tooltip: _viewMode == BookshelfViewMode.list
                  ? '切换为三列视图'
                  : '切换为列表视图',
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
              tooltip: _selectedBookIds.length == _currentTabTotalCount
                  ? '取消全选'
                  : '全选',
              onPressed: _selectAll,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildSubTabBar(),
          SizedBox(
            height: 2,
            child: _openingBookId == null
                ? null
                : const LinearProgressIndicator(key: ValueKey('shelf-opening')),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: _isSelectionMode ? _buildBatchBottomBar() : null,
    );
  }

  /// 顶部快捷子标签：全部收藏 vs 已下载
  Widget _buildSubTabBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _buildPillTab(
              0,
              '全部收藏 (${_books.length})',
              Icons.collections_bookmark_rounded,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildPillTab(
              1,
              '已下载 (${_downloadedBooks.length})',
              Icons.download_done_rounded,
            ),
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
              ? Border.all(
                  color: AppTheme.primaryColor.withValues(alpha: 0.5),
                  width: 1.5,
                )
              : Border.all(color: Colors.transparent, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected
                  ? AppTheme.primaryColor
                  : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? AppTheme.primaryColor
                      : AppTheme.textSecondary,
                ),
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
              Icon(
                Icons.collections_bookmark_outlined,
                size: 72,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 16),
              const Text(
                '书架空空如也',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshFromNetwork,
      child: _viewMode == BookshelfViewMode.grid3
          ? _buildFavoritesGrid()
          : _buildFavoritesList(),
    );
  }

  /// 单列列表呈现
  Widget _buildFavoritesList() {
    return ListView.builder(
      key: const PageStorageKey('favorites-list'),
      findChildIndexCallback: (key) {
        final index = _books.indexWhere((b) => ValueKey(b.bookId) == key);
        return index < 0 ? null : index;
      },
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final shelfBook = _books[index];
        final isSelected = _selectedBookIds.contains(shelfBook.bookId);

        return Container(
          key: ValueKey(shelfBook.bookId),
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
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
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
                  // 点击书封 -> 立即进入阅读！
                  GestureDetector(
                    onTap: () {
                      if (_isSelectionMode) {
                        _toggleSelection(shelfBook.bookId);
                      } else {
                        _continueReading(shelfBook);
                      }
                    },
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 52,
                            height: 74,
                            child: BookCoverWidget(
                              bookId: shelfBook.bookId,
                              bookName: shelfBook.bookName,
                              thumbUrl: shelfBook.thumbUrl,
                              iconSize: 22,
                            ),
                          ),
                        ),
                        if (shelfBook.hasUpdate)
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.only(
                                  topRight: Radius.circular(6),
                                  bottomLeft: Radius.circular(6),
                                ),
                              ),
                              child: const Text(
                                '更新',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // 点击书名 -> 进入书籍详情！
              title: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(shelfBook.bookId);
                  } else {
                    _openBookDetail(shelfBook.toBook());
                  }
                },
                child: Text(
                  shelfBook.bookName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(shelfBook.bookId);
                  } else {
                    _openBookDetail(shelfBook.toBook());
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      '作者: ${shelfBook.author}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
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
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textHint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              trailing: !_isSelectionMode
                  ? OutlinedButton(
                      onPressed: () => _continueReading(shelfBook),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        minimumSize: const Size(0, 32),
                        side: BorderSide(
                          color: AppTheme.primaryColor.withValues(alpha: 0.6),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        shelfBook.lastReadChapterIndex != null ? '续读' : '开读',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    )
                  : null,
              onTap: () {
                if (_isSelectionMode) {
                  _toggleSelection(shelfBook.bookId);
                } else {
                  Navigator.push(
                    context,
                    BookPageRoute(
                      builder: (_) =>
                          BookDetailScreen(book: shelfBook.toBook()),
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
          ),
        );
      },
    );
  }

  /// 三列宫格呈现
  Widget _buildFavoritesGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 900;
    final columns = ReaderPlatform.isMacOS
        ? ((math.min(screenWidth, 900) - 32) / 170).floor().clamp(2, 5)
        : 3;
    final width =
        ((isWide ? 900.0 : screenWidth) - 32 - 14 * (columns - 1)) / columns;
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = 36 * scaler.scale(13) / 13;
    final authorHeight = 16 * scaler.scale(11) / 11;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
        child: GridView.builder(
          key: const PageStorageKey('favorites-grid'),
          findChildIndexCallback: (key) {
            final index = _books.indexWhere((b) => ValueKey(b.bookId) == key);
            return index < 0 ? null : index;
          },
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: width * 1.42 + titleHeight + authorHeight + 12,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _books.length,
          itemBuilder: (context, index) {
            final shelfBook = _books[index];
            final isSelected = _selectedBookIds.contains(shelfBook.bookId);

            return Column(
              key: ValueKey(shelfBook.bookId),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 封面容器（严格固定 1 : 1.42 长方形比例，点击进入阅读）
                AspectRatio(
                  aspectRatio: 1 / 1.42,
                  child: GestureDetector(
                    onTap: () {
                      if (_isSelectionMode) {
                        _toggleSelection(shelfBook.bookId);
                      } else {
                        _continueReading(shelfBook); // 点击封面 -> 直接进入阅读！
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 6,
                                offset: const Offset(1, 3),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: BookCoverWidget(
                              bookId: shelfBook.bookId,
                              bookName: shelfBook.bookName,
                              thumbUrl: shelfBook.thumbUrl,
                              iconSize: 28,
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
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                size: 24,
                                color: isSelected
                                    ? AppTheme.primaryColor
                                    : Colors.grey,
                              ),
                            ),
                          ),
                        // 追更红点徽标
                        if (!_isSelectionMode && shelfBook.hasUpdate)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Text(
                                '更新',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        // 阅读进度标签浮层
                        if (!_isSelectionMode &&
                            shelfBook.lastReadChapterIndex != null)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(8),
                                ),
                              ),
                              child: Text(
                                '读至第${(shelfBook.lastReadChapterIndex ?? 0) + 1}章',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // 2. 书名与作者（严格固定高度，点击书名/作者 -> 进书籍详情！）
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (_isSelectionMode) {
                      _toggleSelection(shelfBook.bookId);
                    } else {
                      _openBookDetail(shelfBook.toBook()); // 点击名称 -> 进入书籍详情！
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
                      SizedBox(
                        height: titleHeight, // 严格固定两行高度，确保所有卡片对齐
                        child: Text(
                          shelfBook.bookName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SizedBox(
                        height: authorHeight,
                        child: Text(
                          shelfBook.author,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
              Icon(
                Icons.download_done_rounded,
                size: 72,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 16),
              const Text(
                '暂无已下载小说',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshFromNetwork,
      child: _viewMode == BookshelfViewMode.grid3
          ? _buildDownloadsGrid()
          : _buildDownloadsList(),
    );
  }

  /// 已下载书籍单列列表
  Widget _buildDownloadsList() {
    return ListView.builder(
      key: const PageStorageKey('downloads-list'),
      findChildIndexCallback: (key) {
        final index = _downloadedBooks.indexWhere(
          (b) => ValueKey(b.bookId) == key,
        );
        return index < 0 ? null : index;
      },
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _downloadedBooks.length,
      itemBuilder: (context, index) {
        final download = _downloadedBooks[index];
        final isSelected = _selectedBookIds.contains(download.bookId);

        return Container(
          key: ValueKey(download.bookId),
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
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
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
                  // 点击书封 -> 立即进入阅读！
                  GestureDetector(
                    onTap: () {
                      if (_isSelectionMode) {
                        _toggleSelection(download.bookId);
                      } else {
                        _readDownloadedBook(download);
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 52,
                        height: 74,
                        child: BookCoverWidget(
                          bookId: download.bookId,
                          bookName: download.bookName,
                          thumbUrl: download.thumbUrl,
                          epubPath: download.filePath,
                          iconSize: 22,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              // 点击书名 -> 进入书籍详情！
              title: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(download.bookId);
                  } else {
                    _openBookDetail(download.toBook());
                  }
                },
                child: Text(
                  download.bookName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleSelection(download.bookId);
                  } else {
                    _openBookDetail(download.toBook());
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      '作者: ${download.author}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 1,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            download.format,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppTheme.primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          download.formattedFileSize,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textHint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              trailing: !_isSelectionMode
                  ? ElevatedButton.icon(
                      onPressed: () => _readDownloadedBook(download),
                      icon: const Icon(Icons.menu_book_rounded, size: 16),
                      label: const Text('阅读', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 32),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    )
                  : null,
              onLongPress: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    _selectedBookIds.add(download.bookId);
                  });
                }
              },
            ),
          ),
        );
      },
    );
  }

  /// 已下载书籍三列宫格
  Widget _buildDownloadsGrid() {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 900;
    final columns = ReaderPlatform.isMacOS
        ? ((math.min(screenWidth, 900) - 32) / 170).floor().clamp(2, 5)
        : 3;
    final width =
        ((isWide ? 900.0 : screenWidth) - 32 - 14 * (columns - 1)) / columns;
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = 36 * scaler.scale(13) / 13;
    final authorHeight = 16 * scaler.scale(11) / 11;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isWide ? 900 : double.infinity),
        child: GridView.builder(
          key: const PageStorageKey('downloads-grid'),
          findChildIndexCallback: (key) {
            final index = _downloadedBooks.indexWhere(
              (b) => ValueKey(b.bookId) == key,
            );
            return index < 0 ? null : index;
          },
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: width * 1.42 + titleHeight + authorHeight + 12,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: _downloadedBooks.length,
          itemBuilder: (context, index) {
            final download = _downloadedBooks[index];
            final isSelected = _selectedBookIds.contains(download.bookId);

            return Column(
              key: ValueKey(download.bookId),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 封面容器（严格固定 1 : 1.42 比例，点击进入阅读）
                AspectRatio(
                  aspectRatio: 1 / 1.42,
                  child: GestureDetector(
                    onTap: () {
                      if (_isSelectionMode) {
                        _toggleSelection(download.bookId);
                      } else {
                        _readDownloadedBook(download); // 点击封面 -> 直接进入阅读！
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 6,
                                offset: const Offset(1, 3),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: BookCoverWidget(
                              bookId: download.bookId,
                              bookName: download.bookName,
                              thumbUrl: download.thumbUrl,
                              epubPath: download.filePath,
                              iconSize: 28,
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
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                              child: Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                size: 24,
                                color: isSelected
                                    ? AppTheme.primaryColor
                                    : Colors.grey,
                              ),
                            ),
                          ),
                        // 已下载格式标记
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              download.format,
                              style: const TextStyle(
                                fontSize: 9,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // 2. 书名与作者（严格固定高度，点击进入书籍详情）
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (_isSelectionMode) {
                      _toggleSelection(download.bookId);
                    } else {
                      _openBookDetail(download.toBook()); // 点击名称 -> 进书籍详情！
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
                      SizedBox(
                        height: titleHeight, // 严格固定两行高度
                        child: Text(
                          download.bookName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SizedBox(
                        height: authorHeight,
                        child: Text(
                          '${download.author} · ${download.formattedFileSize}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBatchBottomBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.of(context).padding.bottom + 8,
      ),
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
            label: Text(
              _currentSubTab == 1
                  ? '删除下载 (${_selectedBookIds.length})'
                  : '移出书架 (${_selectedBookIds.length})',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
