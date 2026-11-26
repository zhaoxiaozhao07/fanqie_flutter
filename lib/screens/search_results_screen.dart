import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/book.dart';
import '../services/api_service.dart';
import '../services/search_history_service.dart';
import '../widgets/book_card.dart';
import '../widgets/loading_widget.dart';
import 'book_detail_screen.dart';

/// 搜索结果页面（支持站内二次搜索、作者作品精准穿透与同类书筛选）
class SearchResultsScreen extends StatefulWidget {
  final String keyword;
  final String? authorOnly;
  final String? titlePrefix;
  final ApiService? apiService;

  const SearchResultsScreen({
    super.key,
    required this.keyword,
    this.authorOnly,
    this.titlePrefix,
    this.apiService,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  late final ApiService _apiService = widget.apiService ?? ApiService();
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _keywordController = TextEditingController(
    text: widget.keyword,
  );

  late String _activeKeyword = widget.keyword;
  late String? _authorOnly = widget.authorOnly;
  final List<Book> _books = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 10;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (_authorOnly == null) {
      SearchHistoryService().addKeyword(_activeKeyword);
    }
    _loadBooks();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _keywordController.dispose();
    if (widget.apiService == null) {
      _apiService.dispose();
    }
    super.dispose();
  }

  /// 监听滚动，实现无限加载
  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200) {
      _loadMoreBooks();
    }
  }

  void _submitNewSearch() {
    final next = _keywordController.text.trim();
    if (next.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _activeKeyword = next;
      _authorOnly = null;
      _books.clear();
      _offset = 0;
      _hasMore = true;
      _errorMessage = null;
    });
    SearchHistoryService().addKeyword(next);
    _loadBooks();
  }

  /// 加载书籍列表
  Future<void> _loadBooks() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final books = await _apiService.searchBooks(
        _activeKeyword,
        offset: _offset,
      );

      if (!mounted) return;
      setState(() {
        final seen = _books.map((b) => b.bookId).toSet();
        var added = books.where((b) => seen.add(b.bookId)).toList();
        if (_authorOnly != null && _authorOnly!.trim().isNotEmpty) {
          final targetAuthor = _authorOnly!.trim().toLowerCase();
          final exact = added
              .where((b) => b.author.trim().toLowerCase() == targetAuthor)
              .toList();
          if (exact.isNotEmpty) {
            added = exact;
          } else {
            added = added
                .where(
                  (b) => b.author.trim().toLowerCase().contains(targetAuthor),
                )
                .toList();
          }
        }
        _books.addAll(added);
        _hasMore = books.length >= _pageSize && books.isNotEmpty;
        _offset += books.length;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '搜索失败: $e';
        _isLoading = false;
      });
    }
  }

  /// 加载更多
  Future<void> _loadMoreBooks() async {
    if (_isLoading || !_hasMore) return;
    await _loadBooks();
  }

  /// 刷新列表
  Future<void> _refreshBooks() async {
    setState(() {
      _books.clear();
      _offset = 0;
      _hasMore = true;
    });
    await _loadBooks();
  }

  @override
  Widget build(BuildContext context) {
    final isAuthorMode = _authorOnly != null && _authorOnly!.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: isAuthorMode ? null : 0,
        title: isAuthorMode
            ? Text(widget.titlePrefix ?? '作者作品：$_authorOnly')
            : Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextField(
                  controller: _keywordController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _submitNewSearch(),
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textPrimaryOf(context),
                  ),
                  decoration: InputDecoration(
                    hintText: '搜索书名、作者...',
                    filled: true,
                    fillColor: AppTheme.inputFillOf(context),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    suffixIcon: IconButton(
                      tooltip: '搜索',
                      icon: const Icon(Icons.search_rounded, size: 18),
                      onPressed: _submitNewSearch,
                    ),
                  ),
                ),
              ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_books.isEmpty && _isLoading) {
      return const LoadingWidget(message: '正在搜索...');
    }

    if (_books.isEmpty && _errorMessage != null) {
      return ErrorStateWidget(message: _errorMessage!, onRetry: _refreshBooks);
    }

    if (_books.isEmpty) {
      return EmptyStateWidget(
        icon: Icons.search_off,
        title: _authorOnly != null ? '未找到该作者的其他作品' : '未找到相关小说',
        subtitle: '换个关键词试试吧',
        action: ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshBooks,
      child: ListView.builder(
        controller: _scrollController,
        itemCount: _books.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _books.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final book = _books[index];

          return BookCard(
            book: book,
            showWordCount: true,
            onTap: () => _navigateToDetail(book),
          );
        },
      ),
    );
  }

  /// 跳转到详情页
  void _navigateToDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => BookDetailScreen(book: book)),
    );
  }
}
