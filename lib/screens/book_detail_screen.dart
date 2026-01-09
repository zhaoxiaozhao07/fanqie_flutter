import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import '../widgets/download_dialog.dart';
import '../widgets/loading_widget.dart';

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
  late DownloadService _downloadService;

  Book? _bookDetail;
  List<Chapter>? _chapters;
  bool _isLoading = true;
  bool _isDownloading = false;
  int _downloadProgress = 0;
  int _downloadTotal = 0;
  String _downloadMessage = '';
  bool _abstractExpanded = false;

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

  /// 加载书籍详情
  Future<void> _loadBookDetail() async {
    setState(() => _isLoading = true);

    try {
      // 获取详细信息
      final detail = await _apiService.getBookDetail(widget.book.bookId);

      // 获取章节目录
      final chapters = await _apiService.getBookChapters(widget.book.bookId);

      setState(() {
        _bookDetail = detail ?? widget.book;
        _chapters = chapters;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _bookDetail = widget.book;
        _isLoading = false;
      });
    }
  }

  /// 开始下载
  Future<void> _startDownload(String format) async {
    if (_chapters == null || _chapters!.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法获取章节目录')));
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
          setState(() {
            _downloadProgress = current;
            _downloadTotal = total;
            _downloadMessage = message;
          });
        },
      );
    } else {
      filePath = await _downloadService.downloadAsEpub(
        _bookDetail ?? widget.book,
        _chapters!,
        onProgress: (current, total, message) {
          setState(() {
            _downloadProgress = current;
            _downloadTotal = total;
            _downloadMessage = message;
          });
        },
      );
    }

    setState(() => _isDownloading = false);

    if (filePath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('下载完成: $filePath'),
          duration: const Duration(seconds: 5),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('下载失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? const LoadingWidget(message: '加载中...')
          : _buildContent(),
      floatingActionButton: _isLoading || _isDownloading
          ? null
          : FloatingActionButton.extended(
              onPressed: _showDownloadDialog,
              icon: const Icon(Icons.download),
              label: const Text('下载'),
            ),
    );
  }

  Widget _buildContent() {
    final book = _bookDetail ?? widget.book;

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // AppBar with cover background
            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                background: _buildHeaderBackground(book),
              ),
            ),
            // Book info
            SliverToBoxAdapter(child: _buildBookInfo(book)),
            // Chapter list header
            if (_chapters != null && _chapters!.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
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
                ),
              ),
            // Chapter list
            if (_chapters != null && _chapters!.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index >= 20) return null; // 只显示前 20 章
                  final chapter = _chapters![index];
                  return ListTile(
                    leading: Text(
                      '${index + 1}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    title: Text(
                      chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }, childCount: _chapters!.length > 20 ? 21 : _chapters!.length),
              ),
            // Show more chapters hint
            if (_chapters != null && _chapters!.length > 20)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      '还有 ${_chapters!.length - 20} 章...',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            // Bottom padding for FAB
            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        ),
        // Download progress overlay
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
      decoration: BoxDecoration(
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
              // Cover
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
              // Book title and author
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
          // Tags
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // 评分标签（金色）
              if (book.score != null && book.score!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
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
            ],
          ),
          const SizedBox(height: 16),

          // Abstract
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

  /// 构建标签
  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
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

  /// 显示下载对话框
  void _showDownloadDialog() async {
    final format = await DownloadDialog.show(
      context,
      (_bookDetail ?? widget.book).bookName,
    );

    if (format != null) {
      _startDownload(format);
    }
  }
}
