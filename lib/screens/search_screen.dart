import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../models/discovery.dart';
import '../services/api_service.dart';
import '../services/app_theme_service.dart';
import '../services/search_history_service.dart';
import '../widgets/book_card.dart';
import '../widgets/download_action_button.dart';
import '../webdav/widgets/webdav_sync_sheet.dart';
import 'search_results_screen.dart';
import 'book_detail_screen.dart';

/// Official library discovery. Categories and their IDs come from the server.
class SearchScreen extends StatefulWidget {
  final ApiService? apiService;
  final FocusNode? searchFocusNode;
  const SearchScreen({super.key, this.apiService, this.searchFocusNode});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _searchHistory = SearchHistoryService();
  FocusNode? _ownedSearchFocus;
  FocusNode get _effectiveSearchFocus =>
      widget.searchFocusNode ?? (_ownedSearchFocus ??= FocusNode());
  bool _searchFocused = false;
  Timer? _suggestDebounce;
  List<Book> _suggestions = const [];
  int _suggestGeneration = 0;
  List<LibraryCategory> _categories = const [];
  LibraryCategory _category = LibraryCategory.all;
  List<Book> _books = [];
  int _gender = 0, _sort = 0, _status = -1, _wordCount = -1;
  int _page = 1, _generation = 0;
  bool _loading = true, _loadingMore = false, _hasMore = false;
  bool _catalogCached = false;
  bool _catalogLoading = false;
  String? _error, _moreError, _catalogError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _effectiveSearchFocus.addListener(_onSearchFocusChanged);
    unawaited(_searchHistory.initialize());
    _reload(refreshCatalog: true);
  }

  @override
  void dispose() {
    _generation++;
    _suggestGeneration++;
    _suggestDebounce?.cancel();
    _effectiveSearchFocus.removeListener(_onSearchFocusChanged);
    _ownedSearchFocus?.dispose();
    _search.dispose();
    _scroll.dispose();
    if (widget.apiService == null) _api.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;
    final focused = _effectiveSearchFocus.hasFocus;
    if (focused != _searchFocused) {
      setState(() => _searchFocused = focused);
    }
  }

  void _onSearchTextChanged(String raw) {
    _suggestDebounce?.cancel();
    final q = raw.trim();
    if (q.isEmpty) {
      if (_suggestions.isNotEmpty) {
        setState(() => _suggestions = const []);
      }
      return;
    }
    final gen = ++_suggestGeneration;
    _suggestDebounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await _api.searchBooks(q, offset: 0);
        if (!mounted || gen != _suggestGeneration) return;
        setState(() => _suggestions = results.take(5).toList());
      } catch (_) {}
    });
  }

  void _onScroll() {
    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 200 &&
        _moreError == null) {
      _loadMore();
    }
  }

  Future<void> _reload({bool refreshCatalog = false}) async {
    refreshCatalog = refreshCatalog || _categories.isEmpty;
    final generation = ++_generation;
    final gender = _gender;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = false;
      _error = _moreError = null;
      _page = 1;
      _catalogLoading = refreshCatalog;
    });
    if (refreshCatalog) {
      try {
        final catalog = await _api.getCategories(gender: gender);
        if (!mounted || generation != _generation) return;
        setState(() {
          _categories = catalog.categories;
          _catalogCached = catalog.isCached;
          _catalogError = null;
          _catalogLoading = false;
          if (_category.id != -1) {
            final matches = _categories.where((c) => c.id == _category.id);
            _category = matches.isEmpty ? LibraryCategory.all : matches.first;
          }
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _catalogLoading = false;
          _catalogError = '分类加载失败，可浏览全部分类或重试';
        });
      }
    }
    try {
      final result = await _api.discoverBooks(
        categoryId: _category.id,
        gender: gender,
        sort: _sort,
        creationStatus: _status,
        wordCount: _wordCount,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _books = result.books;
        _hasMore = result.hasMore;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _books = [];
        _loading = false;
        _error = '书库加载失败，请稍后重试';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    final nextPage = _page + 1;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final result = await _api.discoverBooks(
        categoryId: _category.id,
        gender: _gender,
        sort: _sort,
        creationStatus: _status,
        wordCount: _wordCount,
        page: nextPage,
      );
      if (!mounted || generation != _generation) return;
      final seen = _books.map((b) => b.bookId).toSet();
      final added = result.books.where((b) => seen.add(b.bookId)).toList();
      setState(() {
        _books = [..._books, ...added];
        if (added.isNotEmpty || result.books.isEmpty) _page = nextPage;
        _hasMore = result.hasMore;
        if (result.books.isNotEmpty && added.isEmpty && result.hasMore) {
          _moreError = '接口未返回新的书籍，请重试或刷新';
        }
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _moreError = '加载更多失败，点击重试');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _switchGender(int value) {
    if (_gender == value) return;
    setState(() {
      _gender = value;
      _category = LibraryCategory.all;
      _categories = const [];
      _catalogCached = false;
      _catalogError = null;
    });
    _reload(refreshCatalog: true);
  }

  void _performSearch([String? explicitKeyword]) {
    final keyword = (explicitKeyword ?? _search.text).trim();
    if (keyword.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入搜索关键词')));
      return;
    }
    _search.text = keyword;
    _effectiveSearchFocus.unfocus();
    setState(() => _suggestions = const []);
    unawaited(_searchHistory.addKeyword(keyword));
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchResultsScreen(keyword: keyword)),
    );
  }

  Future<void> _cycleAppTheme() async {
    final service = AppThemeService();
    final next = AppTheme.isDark(context)
        ? AppThemePreference.light
        : AppThemePreference.dark;
    await service.setPreference(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已切换外围外观：${AppThemeService.labelOf(next)}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pickCategory() async {
    final selected = await showModalBottomSheet<LibraryCategory>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _CategoryPicker(
        categories: _categories,
        selectedId: _category.id,
        isCached: _catalogCached,
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.id != -1 && !_categories.any((c) => c.id == selected.id)) {
      return;
    }
    setState(() => _category = selected);
    _reload();
  }

  Future<void> _showFilters() async {
    var sort = _sort, status = _status, words = _wordCount;
    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, modalSetState) {
          Widget choices(
            String title,
            Map<int, String> options,
            int selected,
            void Function(int) change,
          ) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options.entries
                    .map(
                      (e) => ChoiceChip(
                        label: Text(e.value),
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        selected: e.key == selected,
                        showCheckmark: false,
                        backgroundColor: const Color(0xFFF5F6F8),
                        selectedColor: AppTheme.primaryLight,
                        side: BorderSide(
                          color: e.key == selected
                              ? AppTheme.primaryColor.withValues(alpha: .3)
                              : Colors.transparent,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        labelStyle: TextStyle(
                          fontSize: 13,
                          color: e.key == selected
                              ? AppTheme.primaryDark
                              : AppTheme.textSecondary,
                          fontWeight: e.key == selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        onSelected: (_) => modalSetState(() => change(e.key)),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 22),
            ],
          );
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10, bottom: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE4E6EB),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '筛选条件',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => modalSetState(() {
                            sort = 0;
                            status = -1;
                            words = -1;
                          }),
                          child: const Text('重置'),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          tooltip: '关闭',
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 20, color: AppTheme.dividerColor),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          choices(
                            '排序方式',
                            LibraryFilters.sorts,
                            sort,
                            (v) => sort = v,
                          ),
                          choices(
                            '书籍状态',
                            LibraryFilters.statuses,
                            status,
                            (v) => status = v,
                          ),
                          choices(
                            '字数区间',
                            LibraryFilters.wordCounts,
                            words,
                            (v) => words = v,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.primaryColor,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          '确定筛选',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || apply != true) return;
    setState(() {
      _sort = sort;
      _status = status;
      _wordCount = words;
    });
    _reload();
  }

  Widget _chipContent(String label, {IconData? icon, bool active = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.primarySoftOf(context)
              : AppTheme.inputFillOf(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: active
                    ? AppTheme.primaryColor
                    : AppTheme.textSecondaryOf(context),
              ),
              const SizedBox(width: 5),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color: active
                      ? AppTheme.primaryAccentTextOf(context)
                      : AppTheme.textSecondaryOf(context),
                ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: active
                  ? AppTheme.primaryColor
                  : AppTheme.textSecondaryOf(context),
            ),
          ],
        ),
      );

  Widget _optionMenu(
    String key,
    String label,
    Map<int, String> options,
    int selected,
    void Function(int) change, {
    IconData? icon,
    bool active = false,
  }) => PopupMenuButton<int>(
    key: ValueKey(key),
    tooltip: label,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    onSelected: (v) {
      setState(() => change(v));
      _reload();
    },
    itemBuilder: (_) => options.entries
        .map(
          (e) => PopupMenuItem(
            value: e.key,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    e.value,
                    style: TextStyle(
                      fontSize: 13,
                      color: e.key == selected
                          ? AppTheme.primaryDark
                          : AppTheme.textPrimary,
                    ),
                  ),
                ),
                if (e.key == selected)
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: AppTheme.primaryColor,
                  ),
              ],
            ),
          ),
        )
        .toList(),
    child: _chipContent(label, icon: icon, active: active),
  );

  Widget _genderSegment() => Material(
    color: AppTheme.inputFillOf(context),
    borderRadius: BorderRadius.circular(20),
    child: Padding(
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: LibraryFilters.genders.entries
            .map(
              (e) => Semantics(
                button: true,
                selected: e.key == _gender,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _switchGender(e.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: e.key == _gender
                          ? AppTheme.primaryColor
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      e.value,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: e.key == _gender
                            ? Colors.white
                            : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    ),
  );

  Widget _advancedFilterButton() {
    final count =
        (_sort == 0 ? 0 : 1) +
        (_status == -1 ? 0 : 1) +
        (_wordCount == -1 ? 0 : 1);
    return Material(
      color: count == 0
          ? AppTheme.inputFillOf(context)
          : AppTheme.primarySoftOf(context),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: const ValueKey('home-filter-button'),
        borderRadius: BorderRadius.circular(18),
        onTap: _showFilters,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.tune_rounded,
                size: 14,
                color: count == 0
                    ? AppTheme.textSecondary
                    : AppTheme.primaryColor,
              ),
              const SizedBox(width: 5),
              Text(
                '高级筛选',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: count == 0
                      ? AppTheme.textSecondary
                      : AppTheme.primaryDark,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBar() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _search,
                builder: (context, value, _) => TextField(
                  controller: _search,
                  focusNode: _effectiveSearchFocus,
                  textInputAction: TextInputAction.search,
                  textAlignVertical: TextAlignVertical.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppTheme.textPrimaryOf(context),
                  ),
                  onChanged: _onSearchTextChanged,
                  decoration: InputDecoration(
                    hintText: '搜索书名、作者...',
                    filled: true,
                    fillColor: AppTheme.inputFillOf(context),
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: AppTheme.textHintOf(context),
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: AppTheme.textHintOf(context),
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    suffixIcon: value.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空',
                            onPressed: () {
                              _search.clear();
                              setState(() => _suggestions = const []);
                            },
                            icon: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: AppTheme.textHintOf(context),
                            ),
                          ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide(
                        color: AppTheme.primaryColor.withValues(alpha: .35),
                      ),
                    ),
                  ),
                  onSubmitted: (_) => _performSearch(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const ValueKey('home-search-action'),
              onPressed: () => _performSearch(),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
              child: const Text(
                '搜索',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
      if (_searchFocused && _suggestions.isNotEmpty)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          decoration: BoxDecoration(
            color: AppTheme.surfaceOf(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.dividerOf(context)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final book in _suggestions)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: const Icon(Icons.menu_book_outlined, size: 16),
                  title: Text(
                    book.bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '${book.author}${book.category?.isNotEmpty == true ? ' · ${book.category}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () {
                    _effectiveSearchFocus.unfocus();
                    unawaited(_searchHistory.addKeyword(book.bookName));
                    setState(() => _suggestions = const []);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BookDetailScreen(book: book),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      AnimatedBuilder(
        animation: _searchHistory,
        builder: (context, _) {
          final history = _searchHistory.items;
          if (!_searchFocused || history.isEmpty || _suggestions.isNotEmpty) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '最近搜索',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondaryOf(context),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => unawaited(_searchHistory.clearAll()),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                      child: const Text('清空', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final item in history.take(10))
                      InputChip(
                        key: ValueKey('search-history-$item'),
                        label: Text(item, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _performSearch(item),
                        onDeleted: () =>
                            unawaited(_searchHistory.removeKeyword(item)),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ],
  );

  Widget _header() {
    final isDark = AppTheme.isDark(context);
    return Column(
    children: [
      Container(
        key: const ValueKey('home-red-header'),
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF28191B), AppTheme.darkSurfaceColor]
                : const [Color(0xFFFFE8E8), Colors.white],
          ),
        ),
        child: Column(
          children: [
            SizedBox(
              height: math.max(
                44,
                MediaQuery.textScalerOf(context).scale(18) * 1.3 + 8,
              ),
              width: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 8,
                    child: IconButton(
                      key: const ValueKey('home-theme-toggle-btn'),
                      tooltip: isDark ? '切换为浅色外观' : '切换为深色外观',
                      icon: Icon(
                        isDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 20,
                        color: AppTheme.textPrimaryOf(context),
                      ),
                      onPressed: _cycleAppTheme,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 56),
                    child: Text(
                      '番茄Reader',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimaryOf(context),
                      ),
                    ),
                  ),
                  const Positioned(
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WebDavSyncActionButton(),
                        DownloadActionButton(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _searchBar(),
          ],
        ),
      ),
      Container(
        color: AppTheme.surfaceOf(context),
        width: double.infinity,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [_genderSegment(), _advancedFilterButton()],
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey('category-picker'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: _catalogLoading && _categories.isEmpty
                          ? null
                          : _pickCategory,
                      child: _chipContent(
                        _category.name,
                        icon: Icons.category_outlined,
                        active: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _optionMenu(
                    'sort-picker',
                    LibraryFilters.sorts[_sort]!,
                    LibraryFilters.sorts,
                    _sort,
                    (v) => _sort = v,
                    icon: Icons.sort_rounded,
                    active: _sort != 0,
                  ),
                  const SizedBox(width: 8),
                  _optionMenu(
                    'status-picker',
                    LibraryFilters.statuses[_status]!,
                    LibraryFilters.statuses,
                    _status,
                    (v) => _status = v,
                    active: _status != -1,
                  ),
                  const SizedBox(width: 8),
                  _optionMenu(
                    'words-picker',
                    LibraryFilters.wordCounts[_wordCount]!,
                    LibraryFilters.wordCounts,
                    _wordCount,
                    (v) => _wordCount = v,
                    active: _wordCount != -1,
                  ),
                ],
              ),
            ),
            if (_catalogError != null || _catalogCached)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _catalogError ?? '分类使用上次缓存',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _reload(refreshCatalog: true),
                      child: const Text('更新分类'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
  }

  Widget _message(String text, {bool loading = false, VoidCallback? retry}) =>
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
              if (retry != null)
                TextButton(onPressed: retry, child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _bookList() {
    if (_loading) return _message('加载书库...', loading: true);
    if (_error != null) return _message(_error!, retry: _reload);
    if (_books.isEmpty) return _message('暂无符合条件的内容', retry: _reload);
    return RefreshIndicator(
      onRefresh: () => _reload(refreshCatalog: true),
      child: ListView.builder(
        key: const ValueKey('library-books'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _books.length + 1,
        itemBuilder: (context, index) {
          if (index == _books.length) {
            if (_moreError != null) {
              return TextButton(onPressed: _loadMore, child: Text(_moreError!));
            }
            if (_loadingMore) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _hasMore
                    ? TextButton(
                        onPressed: _loadMore,
                        child: const Text('加载更多'),
                      )
                    : const Text('已加载全部结果'),
              ),
            );
          }
          final book = _books[index];
          return BookCard(
            key: ValueKey('book-${book.bookId}'),
            book: book,
            showAbstract: false,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BookDetailScreen(book: book)),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, bounds) => Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: bounds.maxHeight * .55),
                  child: SingleChildScrollView(child: _header()),
                ),
                Expanded(child: _bookList()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPicker extends StatefulWidget {
  final List<LibraryCategory> categories;
  final int selectedId;
  final bool isCached;
  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.isCached,
  });

  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final groups = <String, List<LibraryCategory>>{};
    for (final c in widget.categories) {
      if (c.name.contains(_query) || c.description.contains(_query)) {
        groups.putIfAbsent(c.group, () => []).add(c);
      }
    }
    Widget tile(LibraryCategory c) => ListTile(
      key: ValueKey('category-${c.id}'),
      title: Text(c.name),
      selected: c.id == widget.selectedId,
      trailing: c.id == widget.selectedId ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, c),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height:
            (media.size.height - media.viewInsets.bottom - media.padding.top) *
            .85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.isCached ? '选择分类（缓存）' : '选择分类'} · ${widget.categories.length}项',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '查找分类',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  tile(LibraryCategory.all),
                  for (final group in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        group.key,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ...group.value.map(tile),
                  ],
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无分类，可选择全部分类'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
