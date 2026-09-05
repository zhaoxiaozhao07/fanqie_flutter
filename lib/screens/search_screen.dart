import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../services/api_service.dart';
import '../widgets/book_card.dart';
import '../widgets/loading_widget.dart';
import 'search_results_screen.dart';
import 'book_detail_screen.dart';
import 'source_management_screen.dart';

/// 搜索与发现主页面
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
    '科幻': 9,
    '游戏': 6,
    '历史': 4,
    '悬疑': 8,
  };

  // 排序选项
  static const Map<int, String> _sortOptions = {
    0: '最热',
    1: '最新',
    2: '字数',
  };

  // 连载状态选项
  static const Map<int, String> _statusOptions = {
    -1: '全部状态',
    1: '连载中',
    0: '已完结',
  };

  // 字数选项
  static const Map<int, String> _wordCountOptions = {
    -1: '全部字数',
    1: '30万以下',
    2: '30-50万',
    3: '50-100万',
    4: '100-200万',
    5: '200万以上',
  };

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  List<Book> _discoverBooks = [];

  int _currentPage = 1;
  bool _isRankingMode = true;
  String _currentRankingType = '巅峰榜';
  String _currentCategoryName = '玄幻';
  int _currentCategoryType = 7;

  // 多维筛选状态
  int _currentGender = 1; // 1=男频, 2=女频, 0=全部
  int _currentSort = 0; // 0=最热, 1=最新, 2=字数
  int _currentStatus = -1; // -1=全部, 1=连载, 0=完结
  int _currentWordCount = -1; // -1=全部

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
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
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
      final books = await _apiService.discoverBooks(
        bdtype: _isRankingMode ? _currentRankingType : null,
        type: !_isRankingMode ? _currentCategoryType : null,
        gender: _currentGender,
        isRanking: _isRankingMode,
        creationStatus: _currentStatus,
        wordCount: _currentWordCount,
        sort: _currentSort,
        page: 1,
      );

      if (mounted) {
        setState(() {
          _discoverBooks = books;
          _isLoading = false;
          _hasMore = books.isNotEmpty;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _discoverBooks = [];
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadMoreBooks() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() => _isLoadingMore = true);

    try {
      final nextPage = _currentPage + 1;
      final books = await _apiService.discoverBooks(
        bdtype: _isRankingMode ? _currentRankingType : null,
        type: !_isRankingMode ? _currentCategoryType : null,
        gender: _currentGender,
        isRanking: _isRankingMode,
        creationStatus: _currentStatus,
        wordCount: _currentWordCount,
        sort: _currentSort,
        page: nextPage,
      );

      if (mounted) {
        setState(() {
          _discoverBooks.addAll(books);
          _currentPage = nextPage;
          _isLoadingMore = false;
          _hasMore = books.isNotEmpty;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
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

  void _performSearch() {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入搜索关键词')),
      );
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

  /// 打开多维高级筛选底部弹窗
  void _showFilterBottomSheet() {
    var tempSort = _currentSort;
    var tempStatus = _currentStatus;
    var tempWordCount = _currentWordCount;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.85,
                ),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    MediaQuery.of(context).viewInsets.bottom + 24,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '筛选条件',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setModalState(() {
                            tempSort = 0;
                            tempStatus = -1;
                            tempWordCount = -1;
                          });
                        },
                        child: const Text('重置'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // 排序方式
                  const Text('排序方式', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _sortOptions.entries.map((entry) {
                      final isSelected = tempSort == entry.key;
                      return ChoiceChip(
                        label: Text(entry.value),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            setModalState(() => tempSort = entry.key);
                          }
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // 完结状态
                  const Text('书籍状态', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _statusOptions.entries.map((entry) {
                      final isSelected = tempStatus == entry.key;
                      return ChoiceChip(
                        label: Text(entry.value),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            setModalState(() => tempStatus = entry.key);
                          }
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // 字数区间
                  const Text('字数区间', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _wordCountOptions.entries.map((entry) {
                      final isSelected = tempWordCount == entry.key;
                      return ChoiceChip(
                        label: Text(entry.value),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            setModalState(() => tempWordCount = entry.key);
                          }
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // 确定按钮
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        setState(() {
                          _currentSort = tempSort;
                          _currentStatus = tempStatus;
                          _currentWordCount = tempWordCount;
                        });
                        _loadDiscoverBooks();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text('确定筛选', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  },
);
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // 顶部渐变导航与搜索栏
          Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFFFE8E8),
                  Colors.white,
                ],
                stops: [0.0, 1.0],
              ),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 44,
                  width: double.infinity,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        '番茄Reader',
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
                          tooltip: 'API 源设置',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const SourceManagementScreen(),
                              ),
                            ).then((_) => _loadDiscoverBooks());
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF2F4F7),
                borderRadius: BorderRadius.circular(19),
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
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _performSearch,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              minimumSize: const Size(0, 38),
              fixedSize: const Size.fromHeight(38),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(19),
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
        _buildSubFilterBar(),
        Expanded(child: _buildBookList()),
      ],
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _buildRankingPopupMenu(),
          const SizedBox(width: 8),
          _buildCategoryPopupMenu(),
          const Spacer(),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('全部')),
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
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 次级筛选条：排序、状态与更多筛选
  Widget _buildSubFilterBar() {
    final hasActiveFilter = _currentStatus != -1 || _currentWordCount != -1 || _currentSort != 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Row(
        children: [
          // 快捷排序选择
          GestureDetector(
            onTap: () {
              setState(() {
                _currentSort = (_currentSort + 1) % 3;
              });
              _loadDiscoverBooks();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    '排序: ${_sortOptions[_currentSort]}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 快捷状态切换
          GestureDetector(
            onTap: () {
              setState(() {
                if (_currentStatus == -1) {
                  _currentStatus = 1;
                } else if (_currentStatus == 1) {
                  _currentStatus = 0;
                } else {
                  _currentStatus = -1;
                }
              });
              _loadDiscoverBooks();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _currentStatus == -1
                    ? '状态: 全部'
                    : (_currentStatus == 1 ? '状态: 连载' : '状态: 完结'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
          ),
          const Spacer(),

          // 更多筛选按钮
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showFilterBottomSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: hasActiveFilter
                    ? AppTheme.primaryColor.withValues(alpha: 0.1)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(12),
                border: hasActiveFilter
                    ? Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.4))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.filter_list_rounded,
                    size: 14,
                    color: hasActiveFilter ? AppTheme.primaryColor : AppTheme.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    hasActiveFilter ? '已筛选' : '更多筛选',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: hasActiveFilter ? FontWeight.bold : FontWeight.normal,
                      color: hasActiveFilter ? AppTheme.primaryColor : AppTheme.textSecondary,
                    ),
                  ),
                ],
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
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
                colors: [activeColor, activeColor.withValues(alpha: 0.7)],
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
                  color: activeColor.withValues(alpha: 0.3),
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
    final currentLabel = _isRankingMode ? _currentRankingType : _currentCategoryName;

    if (_isLoading) {
      return LoadingWidget(message: '加载$currentLabel...');
    }

    if (_discoverBooks.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.book_outlined,
        title: '暂无符合条件的内容',
        subtitle: '尝试更改筛选或分类条件',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDiscoverBooks,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 0, bottom: 16),
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
            showAbstract: false,
            onTap: () => _navigateToDetail(book),
          );
        },
      ),
    );
  }
}
