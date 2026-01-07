import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../services/api_service.dart';
import '../widgets/book_card.dart';
import '../widgets/loading_widget.dart';
import 'book_detail_screen.dart';

/// 搜索结果页面
class SearchResultsScreen extends StatefulWidget {
  final String keyword;

  const SearchResultsScreen({super.key, required this.keyword});

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  final List<Book> _books = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _offset = 0;
  static const int _pageSize = 10;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadBooks();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _apiService.dispose();
    super.dispose();
  }

  /// 监听滚动，实现无限加载
  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreBooks();
    }
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
        widget.keyword,
        offset: _offset,
      );

      setState(() {
        _books.addAll(books);
        _hasMore = books.length >= _pageSize;
        _offset += books.length;
        _isLoading = false;
      });
    } catch (e) {
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
    return Scaffold(
      appBar: AppBar(title: Text('搜索: ${widget.keyword}')),
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
        title: '未找到相关小说',
        subtitle: '换个关键词试试吧',
        action: ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回搜索'),
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

          // List item animation
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutQuart,
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 20 * (1 - value)),
                  child: child,
                ),
              );
            },
            child: BookCard(
              book: book,
              showWordCount: true,
              onTap: () => _navigateToDetail(book),
            ),
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
