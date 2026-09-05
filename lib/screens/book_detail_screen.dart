import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/reading_history_service.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import '../widgets/download_dialog.dart';
import '../widgets/loading_widget.dart';
import 'reader_screen.dart';

/// 书籍详情页面
class BookDetailScreen extends StatefulWidget {
  final Book book;

  const BookDetailScreen({super.key, required this.book});

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  final ApiService _apiService = ApiService();
  final HistoryService _historyService = HistoryService();
  final BookshelfService _bookshelfService = BookshelfService();
  final ReadingHistoryService _readingHistoryService = ReadingHistoryService();
  late DownloadService _downloadService;

  Book? _bookDetail;
  List<Chapter>? _chapters;
  bool _isLoading = true;
  bool _isDownloading = false;
  int _downloadProgress = 0;
  int _downloadTotal = 0;
  String _downloadMessage = '';
  bool _abstractExpanded = false;
  bool _isInBookshelf = false;

  int? _lastReadIndex;
  String? _lastReadTitle;

  @override
  void initState() {
    super.initState();
    _downloadService = DownloadService(_apiService, _historyService);
    _loadBookDetail();
  }

  @override
  void dispose() {
    _apiService.dispose();
    super.dispose();
  }

  /// 加载书籍详情与章节
  Future<void> _loadBookDetail() async {
    setState(() => _isLoading = true);

    try {
      final detail = await _apiService.getBookDetail(widget.book.bookId);
      final chapters = await _apiService.getBookChapters(widget.book.bookId);

      if (mounted) {
        setState(() {
          _bookDetail = detail ?? widget.book;
          _chapters = chapters;
          _isLoading = false;
        });
      }
      await _loadReadingProgress();
    } catch (e) {
      if (mounted) {
        setState(() {
          _bookDetail = widget.book;
          _isLoading = false;
        });
      }
      await _loadReadingProgress();
    }
  }

  /// 加载上次阅读记录
  Future<void> _loadReadingProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getInt('read_progress_index_${widget.book.bookId}');
      final title = prefs.getString('read_progress_title_${widget.book.bookId}');
      await _bookshelfService.initialize();
      final inShelf = _bookshelfService.isInBookshelf(widget.book.bookId);

      if (mounted) {
        setState(() {
          _lastReadIndex = index;
          _lastReadTitle = title;
          _isInBookshelf = inShelf;
        });
      }

      // 只要打开详情页就记录到阅读历史中
      await _readingHistoryService.recordReading(
        book: _bookDetail ?? widget.book,
        chapterIndex: index ?? 0,
        chapterTitle: title ?? (_chapters?.isNotEmpty == true ? _chapters!.first.title : '开始阅读'),
      );
    } catch (_) {}
  }

  Future<void> _toggleBookshelf() async {
    final book = _bookDetail ?? widget.book;
    final added = await _bookshelfService.toggleBookshelf(
      book,
      chapterIndex: _lastReadIndex,
      chapterTitle: _lastReadTitle,
    );

    if (mounted) {
      setState(() {
        _isInBookshelf = added;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(added ? '已加入书架：《${book.bookName}》' : '已从书架移出：《${book.bookName}》'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _openReader(int chapterIndex) {
    if (_chapters == null || _chapters!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在加载章节目录，请稍候...')),
      );
      return;
    }

    final targetIndex = chapterIndex.clamp(0, _chapters!.length - 1);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(
          book: _bookDetail ?? widget.book,
          chapters: _chapters!,
          initialChapterIndex: targetIndex,
        ),
      ),
    ).then((_) {
      if (mounted) {
        _loadReadingProgress();
      }
    });
  }

  /// 显示完整章节目录弹窗
  void _showAllChaptersModal() {
    if (_chapters == null || _chapters!.isEmpty) return;

    final searchController = TextEditingController();
    var isReverse = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filter = searchController.text.trim();
            final allChapters = isReverse
                ? _chapters!.reversed.toList()
                : _chapters!;

            final displayChapters = filter.isEmpty
                ? allChapters
                : allChapters.where((c) => c.title.contains(filter)).toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.85,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '完整目录 (共 ${_chapters!.length} 章)',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isReverse
                                  ? Icons.vertical_align_top
                                  : Icons.vertical_align_bottom,
                              color: AppTheme.textSecondary,
                            ),
                            tooltip: isReverse ? '正序' : '倒序',
                            onPressed: () {
                              setModalState(() {
                                isReverse = !isReverse;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: TextField(
                        controller: searchController,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '搜索章节名...',
                          hintStyle: const TextStyle(color: AppTheme.textHint),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          filled: true,
                          fillColor: const Color(0xFFF2F4F7),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: (_) => setModalState(() {}),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: displayChapters.length,
                        itemBuilder: (context, idx) {
                          final chapter = displayChapters[idx];
                          final originalIndex = _chapters!.indexOf(chapter);
                          final isCurrent = originalIndex == _lastReadIndex;

                          return ListTile(
                            dense: true,
                            title: Text(
                              chapter.title,
                              style: TextStyle(
                                fontSize: 14,
                                color: isCurrent
                                    ? AppTheme.primaryColor
                                    : AppTheme.textPrimary,
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isCurrent
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      '已读到',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.primaryColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                : null,
                            onTap: () {
                              Navigator.pop(ctx);
                              _openReader(originalIndex);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  /// 开始下载
  Future<void> _startDownload(String format) async {
    if (_chapters == null || _chapters!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取章节目录')),
        );
      }
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadTotal = _chapters!.length;
      _downloadMessage = '准备下载...';
    });

    String? filePath;

    if (format == 'TXT') {
      filePath = await _downloadService.downloadAsTxt(
        _bookDetail ?? widget.book,
        _chapters!,
        onProgress: (current, total, message) {
          if (mounted) {
            setState(() {
              _downloadProgress = current;
              _downloadTotal = total;
              _downloadMessage = message;
            });
          }
        },
      );
    } else {
      filePath = await _downloadService.downloadAsEpub(
        _bookDetail ?? widget.book,
        _chapters!,
        onProgress: (current, total, message) {
          if (mounted) {
            setState(() {
              _downloadProgress = current;
              _downloadTotal = total;
              _downloadMessage = message;
            });
          }
        },
      );
    }

    if (!mounted) return;
    setState(() => _isDownloading = false);

    if (filePath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('下载完成: $filePath'),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载失败')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? const LoadingWidget(message: '加载中...')
          : _buildContent(),
      bottomNavigationBar: _isLoading || _isDownloading ? null : _buildBottomBar(),
    );
  }

  Widget _buildBottomBar() {
    final hasReadHistory = _lastReadIndex != null && _lastReadIndex! >= 0;
    final readText = hasReadHistory
        ? '继续阅读 (第${_lastReadIndex! + 1}章)'
        : '开始阅读';

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
          // 下载按钮
          OutlinedButton.icon(
            onPressed: _showDownloadDialog,
            icon: const Icon(Icons.download_rounded, size: 20),
            label: const Text('下载'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              side: const BorderSide(color: AppTheme.primaryColor),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 阅读按钮
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _openReader(_lastReadIndex ?? 0),
              icon: const Icon(Icons.menu_book_rounded, size: 20),
              label: Text(
                readText,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final book = _bookDetail ?? widget.book;

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              actions: [
                IconButton(
                  icon: Icon(
                    _isInBookshelf ? Icons.bookmark_added : Icons.bookmark_add_outlined,
                    color: Colors.white,
                  ),
                  tooltip: _isInBookshelf ? '已在书架（点击移出）' : '加入书架',
                  onPressed: _toggleBookshelf,
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: _buildHeaderBackground(book),
              ),
            ),
            SliverToBoxAdapter(child: _buildBookInfo(book)),
            // 目录标题与全部目录入口
            if (_chapters != null && _chapters!.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            '章节目录',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '共 ${_chapters!.length} 章',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: _showAllChaptersModal,
                        icon: const Icon(Icons.format_list_bulleted, size: 16),
                        label: const Text('完整目录', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
            // 前 20 章节列表
            if (_chapters != null && _chapters!.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final chapter = _chapters![index];
                  final isCurrent = index == _lastReadIndex;

                  return ListTile(
                    leading: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontSize: 13,
                        color: isCurrent ? AppTheme.primaryColor : AppTheme.textSecondary,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    title: Text(
                      chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: isCurrent ? AppTheme.primaryColor : AppTheme.textPrimary,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: isCurrent
                        ? const Icon(Icons.bookmark, size: 18, color: AppTheme.primaryColor)
                        : const Icon(Icons.arrow_forward_ios, size: 12, color: AppTheme.textHint),
                    onTap: () => _openReader(index),
                  );
                }, childCount: _chapters!.length > 20 ? 20 : _chapters!.length),
              ),
            // 查看更多提示
            if (_chapters != null && _chapters!.length > 20)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: OutlinedButton(
                      onPressed: _showAllChaptersModal,
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Text('查看剩余 ${_chapters!.length - 20} 章全部目录'),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 20)),
          ],
        ),
        // 下载进度遮罩
        if (_isDownloading)
          Container(
            color: Colors.black54,
            child: Center(
              child: Card(
                margin: const EdgeInsets.all(32),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        '$_downloadProgress / $_downloadTotal',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _downloadMessage,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: _downloadTotal > 0
                            ? _downloadProgress / _downloadTotal
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 构建头部背景
  Widget _buildHeaderBackground(Book book) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.primaryColor, AppTheme.primaryDark],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 120,
                  height: 160,
                  child: book.thumbUrl != null && book.thumbUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: book.thumbUrl!,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: Colors.white24,
                            child: const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: Colors.white24,
                            child: const Icon(
                              Icons.book,
                              size: 48,
                              color: Colors.white54,
                            ),
                          ),
                        )
                      : Container(
                          color: Colors.white24,
                          child: const Icon(
                            Icons.book,
                            size: 48,
                            color: Colors.white54,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.bookName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(
                          Icons.person_outline,
                          size: 16,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          book.author,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建书籍信息
  Widget _buildBookInfo(Book book) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (book.score != null && book.score!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 14, color: Colors.amber),
                      const SizedBox(width: 4),
                      Text(
                        book.score!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.amber,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              InkWell(
                onTap: _toggleBookshelf,
                borderRadius: BorderRadius.circular(16),
                child: _buildTag(
                  _isInBookshelf ? '已在书架' : '+ 加入书架',
                  _isInBookshelf ? AppTheme.primaryColor : AppTheme.tagCompleted,
                ),
              ),
              _buildTag(
                book.creationStatus,
                book.creationStatus == '完结'
                    ? AppTheme.tagCompleted
                    : AppTheme.tagSerializing,
              ),
              if (book.category != null && book.category!.isNotEmpty)
                _buildTag(book.category!, AppTheme.tagCategory),
              _buildTag(book.formattedWordCount, AppTheme.textSecondary),
              if (_chapters != null)
                _buildTag('${_chapters!.length}章', AppTheme.accentColor),
              if (_lastReadTitle != null)
                _buildTag('已读至: $_lastReadTitle', AppTheme.primaryColor),
            ],
          ),
          const SizedBox(height: 16),

          Text('简介', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              setState(() => _abstractExpanded = !_abstractExpanded);
            },
            child: Text(
              book.abstract ?? '暂无简介',
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: _abstractExpanded ? null : 4,
              overflow: _abstractExpanded ? null : TextOverflow.ellipsis,
            ),
          ),
          if (book.abstract != null && book.abstract!.length > 100)
            TextButton(
              onPressed: () {
                setState(() => _abstractExpanded = !_abstractExpanded);
              },
              child: Text(_abstractExpanded ? '收起' : '展开'),
            ),

          const Divider(height: 32),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _showDownloadDialog() async {
    final format = await DownloadDialog.show(
      context,
      (_bookDetail ?? widget.book).bookName,
    );

    if (format != null && mounted) {
      _startDownload(format);
    }
  }
}
