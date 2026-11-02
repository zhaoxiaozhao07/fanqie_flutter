import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../models/discovery.dart';
import '../services/api_service.dart';
import '../widgets/book_card.dart';
import '../widgets/download_action_button.dart';
import 'search_results_screen.dart';
import 'book_detail_screen.dart';

/// Official library discovery. Categories and their IDs come from the server.
class SearchScreen extends StatefulWidget {
  final ApiService? apiService;
  const SearchScreen({super.key, this.apiService});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final ApiService _api = widget.apiService ?? ApiService();
  final _search = TextEditingController();
  final _scroll = ScrollController();
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
    _reload(refreshCatalog: true);
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    _scroll.dispose();
    if (widget.apiService == null) _api.dispose();
    super.dispose();
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

  void _performSearch() {
    final keyword = _search.text.trim();
    if (keyword.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入搜索关键词')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchResultsScreen(keyword: keyword)),
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
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: options.entries
                    .map(
                      (e) => ChoiceChip(
                        label: Text(e.value),
                        selected: e.key == selected,
                        onSelected: (_) => modalSetState(() => change(e.key)),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
          );
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    children: [
                      const Text(
                        '筛选条件',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
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
                    ],
                  ),
                  choices('排序方式', LibraryFilters.sorts, sort, (v) => sort = v),
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
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确定筛选'),
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

  Widget _optionMenu(
    String key,
    String label,
    Map<int, String> options,
    void Function(int) change,
  ) => PopupMenuButton<int>(
    key: ValueKey(key),
    tooltip: label,
    onSelected: (v) {
      setState(() => change(v));
      _reload();
    },
    itemBuilder: (_) => options.entries
        .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
        .toList(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text(label), const Icon(Icons.arrow_drop_down, size: 18)],
      ),
    ),
  );

  Widget _header() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '番茄Reader',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            const DownloadActionButton(),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '搜索书名、作者...',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _performSearch(),
              ),
            ),
            IconButton(
              onPressed: _performSearch,
              tooltip: '搜索',
              icon: const Icon(Icons.search_rounded),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...LibraryFilters.genders.entries.map(
                (e) => ChoiceChip(
                  label: Text(e.value),
                  selected: e.key == _gender,
                  onSelected: (_) => _switchGender(e.key),
                ),
              ),
              TextButton.icon(
                onPressed: _showFilters,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('高级筛选'),
              ),
            ],
          ),
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: 8),
            TextButton.icon(
              key: const ValueKey('category-picker'),
              onPressed: _catalogLoading && _categories.isEmpty
                  ? null
                  : _pickCategory,
              icon: const Icon(Icons.category_outlined, size: 18),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(_category.name, overflow: TextOverflow.ellipsis),
              ),
            ),
            _optionMenu(
              'sort-picker',
              '排序: ${LibraryFilters.sorts[_sort]}',
              LibraryFilters.sorts,
              (v) => _sort = v,
            ),
            _optionMenu(
              'status-picker',
              LibraryFilters.statuses[_status]!,
              LibraryFilters.statuses,
              (v) => _status = v,
            ),
            _optionMenu(
              'words-picker',
              LibraryFilters.wordCounts[_wordCount]!,
              LibraryFilters.wordCounts,
              (v) => _wordCount = v,
            ),
          ],
        ),
      ),
      if (_catalogError != null || _catalogCached)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                _catalogError ?? '分类使用上次缓存',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
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
  );

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
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
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
  );
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
