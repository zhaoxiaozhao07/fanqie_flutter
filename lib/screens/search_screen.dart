import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../services/api_service.dart';
import '../widgets/book_card.dart';
import '../widgets/loading_widget.dart';
import 'search_results_screen.dart';
import 'book_detail_screen.dart';
import 'source_management_screen.dart';

/// 搜索页面
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  // 榜单类型列表
  static const List<String> _rankingTypes = [
    '巅峰榜',
    '出版榜',
    '热搜榜',
    '黑马榜',
    '爆更榜',
    '推荐榜',
    '完结榜',
  ];

  // 分类标签列表
  static const Map<String, int> _categoryTypes = {
    '玄幻': 7,
    '传统玄幻': 258,
    '修仙': 517,
    '东方仙侠': 1140,
    '洪荒': 66,
    '系统': 19,
    '重生': 36,
    '穿越': 37,
    '无后宫': 838,
    '无女主': 391,
    '单女主': 389,
    '多女主': 91,
    '都市': 1,
  };

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  List<Book> _discoverBooks = [];
  int _currentGender = 1;
  int _currentPage = 1;

  bool _isRankingMode = true;
  String _currentRankingType = '巅峰榜';
  String _currentCategoryName = '玄幻';
  int _currentCategoryType = 7;

  @override
  void initState() {
    super.initState();
    _loadDiscoverBooks();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _apiService.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreBooks();
    }
  }

  Future<void> _loadDiscoverBooks() async {
    setState(() {
      _isLoading = true;
      _currentPage = 1;
      _hasMore = true;
    });

    try {
      List<Book> books;
      if (_isRankingMode) {
        books = await _apiService.discoverBooks(
          bdtype: _currentRankingType,
          gender: _currentGender,
          page: _currentPage,
        );
      } else {
        books = await _apiService.discoverByType(
          type: _currentCategoryType,
          gender: _currentGender,
          page: _currentPage,
        );
      }
      setState(() {
        _discoverBooks = books;
        _isLoading = false;
        _hasMore = books.isNotEmpty;
      });
    } catch (e) {
      setState(() {
        _discoverBooks = [];
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreBooks() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      List<Book> books;
      if (_isRankingMode) {
        books = await _apiService.discoverBooks(
          bdtype: _currentRankingType,
          gender: _currentGender,
          page: nextPage,
        );
      } else {
        books = await _apiService.discoverByType(
          type: _currentCategoryType,
          gender: _currentGender,
          page: nextPage,
        );
      }
      setState(() {
        _discoverBooks.addAll(books);
        _currentPage = nextPage;
        _isLoadingMore = false;
        _hasMore = books.isNotEmpty;
      });
    } catch (e) {
      setState(() => _isLoadingMore = false);
    }
  }

  void _switchToRanking(String type) {
    setState(() {
      _isRankingMode = true;
      _currentRankingType = type;
    });
    _loadDiscoverBooks();
  }

  void _switchToCategory(String name, int type) {
    setState(() {
      _isRankingMode = false;
      _currentCategoryName = name;
      _currentCategoryType = type;
    });
    _loadDiscoverBooks();
  }

  void _switchGender(int gender) {
    if (_currentGender != gender) {
      setState(() => _currentGender = gender);
      _loadDiscoverBooks();
    }
  }

  Future<void> _performSearch() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入搜索关键词')));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SearchResultsScreen(keyword: keyword),
      ),
    );
  }

  void _navigateToDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => BookDetailScreen(book: book)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Gradient Header
          Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(
                    0xFFFFE0E0,
                  ), // Slightly stronger pale red for visibility
                  Colors.white,
                ],
                stops: [0.0, 1.0],
              ),
            ),
            child: Column(
              children: [
                // Custom Title Area
                Container(
                  height: 44,
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        '番茄小说',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Positioned(
                        right: 4,
                        child: IconButton(
                          icon: const Icon(
                            Icons.settings_outlined,
                            size: 24,
                            color: AppTheme.textPrimary,
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const SourceManagementScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                _buildSearchArea(),
              ],
            ),
          ),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildSearchArea() {
    return Container(
      // Background is handled by parent gradient container
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 36, // Fixed smaller height
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(18),
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: '搜索书名、作者...',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppTheme.textHint,
                    size: 18,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(
                            Icons.clear,
                            size: 18,
                            color: AppTheme.textHint,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        )
                      : null,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  isDense: true,
                ),
                textAlignVertical: TextAlignVertical.center,
                style: const TextStyle(fontSize: 14),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _performSearch(),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _performSearch,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(0, 36),
              fixedSize: const Size.fromHeight(36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: const Text(
              '搜索',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        _buildFilterBar(),
        Expanded(child: _buildBookList()),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 4,
      ), // Reduced vertical padding
      child: Row(
        children: [
          _buildRankingPopupMenu(),
          const SizedBox(width: 8),
          _buildCategoryPopupMenu(),
          const Spacer(), // 这里添加 Spacer 将性别切换推到右侧
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('男频')),
              ButtonSegment(value: 2, label: Text('女频')),
            ],
            selected: {_currentGender},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              _switchGender(selection.first);
            },
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: MaterialStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRankingPopupMenu() {
    return PopupMenuButton<String>(
      onSelected: _switchToRanking,
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (context) => _rankingTypes.map((type) {
        final isSelected = _isRankingMode && type == _currentRankingType;
        return PopupMenuItem<String>(
          value: type,
          height: 36,
          child: Row(
            children: [
              Icon(
                Icons.emoji_events,
                size: 20,
                color: isSelected ? AppTheme.primaryColor : Colors.grey,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  type,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected ? AppTheme.primaryColor : null,
                  ),
                ),
              ),
              if (isSelected)
                const Icon(Icons.check, size: 18, color: AppTheme.primaryColor),
            ],
          ),
        );
      }).toList(),
      child: _buildMenuButton(
        label: _isRankingMode ? _currentRankingType : '榜单',
        icon: Icons.emoji_events,
        isActive: _isRankingMode,
        activeColor: AppTheme.primaryColor,
      ),
    );
  }

  Widget _buildCategoryPopupMenu() {
    final items = <PopupMenuEntry<MapEntry<String, int>>>[];

    // 添加标题
    items.add(
      PopupMenuItem<MapEntry<String, int>>(
        enabled: false,
        height: 36,
        child: Row(
          children: [
            const Icon(Icons.category, size: 16, color: AppTheme.accentColor),
            const SizedBox(width: 8),
            const Text(
              '选择分类',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppTheme.accentColor,
              ),
            ),
            const Spacer(),
            Text(
              '可滚动 ↓',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
    items.add(const PopupMenuDivider(height: 1));

    // 添加分类选项
    for (final entry in _categoryTypes.entries) {
      final isSelected = !_isRankingMode && entry.key == _currentCategoryName;
      items.add(
        PopupMenuItem<MapEntry<String, int>>(
          value: entry,
          height: 32,
          child: Row(
            children: [
              Icon(
                Icons.label_outline,
                size: 18,
                color: isSelected ? AppTheme.accentColor : Colors.grey,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.key,
                  style: TextStyle(
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected ? AppTheme.accentColor : null,
                  ),
                ),
              ),
              if (isSelected)
                const Icon(Icons.check, size: 18, color: AppTheme.accentColor),
            ],
          ),
        ),
      );
    }

    return PopupMenuButton<MapEntry<String, int>>(
      onSelected: (entry) => _switchToCategory(entry.key, entry.value),
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      constraints: const BoxConstraints(maxHeight: 400),
      itemBuilder: (context) => items,
      child: _buildMenuButton(
        label: !_isRankingMode ? _currentCategoryName : '分类',
        icon: Icons.category,
        isActive: !_isRankingMode,
        activeColor: AppTheme.accentColor,
      ),
    );
  }

  Widget _buildMenuButton({
    required String label,
    required IconData icon,
    required bool isActive,
    required Color activeColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: isActive
            ? LinearGradient(
                colors: [activeColor, activeColor.withOpacity(0.7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isActive ? null : Colors.grey[100],
        borderRadius: BorderRadius.circular(20),
        border: isActive ? null : Border.all(color: Colors.grey[300]!),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: activeColor.withOpacity(0.3),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: isActive ? Colors.white : Colors.grey[600],
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.grey[600],
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: isActive ? Colors.white : Colors.grey[600],
          ),
        ],
      ),
    );
  }

  Widget _buildBookList() {
    final currentLabel = _isRankingMode
        ? _currentRankingType
        : _currentCategoryName;

    if (_isLoading) {
      return LoadingWidget(message: '加载$currentLabel...');
    }

    if (_discoverBooks.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.book_outlined,
        title: '暂无推荐内容',
        subtitle: '请稍后再试',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDiscoverBooks,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(
          top: 0,
          bottom: 16,
        ), // Explicitly remove top padding
        itemCount: _discoverBooks.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _discoverBooks.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final book = _discoverBooks[index];
          return BookCard(
            book: book,
            showAbstract: false, // Hide abstract on home screen
            onTap: () => _navigateToDetail(book),
          );
        },
      ),
    );
  }
}
