import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/reading_history_service.dart';

/// 阅读器主题配置
class ReaderTheme {
  final String name;
  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final Brightness systemBrightness;

  const ReaderTheme({
    required this.name,
    required this.backgroundColor,
    required this.textColor,
    required this.secondaryColor,
    required this.systemBrightness,
  });
}

class ReaderScreen extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final int initialChapterIndex;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.chapters,
    this.initialChapterIndex = 0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final ApiService _apiService = ApiService();
  final BookshelfService _bookshelfService = BookshelfService();
  final ReadingHistoryService _readingHistoryService = ReadingHistoryService();
  final ScrollController _scrollController = ScrollController();

  // 章节内容内存缓存
  final Map<int, String> _chapterCache = {};
  // 当前无限下拉中已渲染展示的章节索引列表
  final List<int> _displayedChapters = [];
  final Map<int, GlobalKey> _chapterKeys = {};

  // 当前用户视觉所在的章节索引
  late int _currentActiveIndex;
  bool _isLoadingHead = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  bool _showControls = false;
  bool _isInBookshelf = false;

  // 用户偏好
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  int _themeIndex = 1; // 默认羊皮纸

  static const List<ReaderTheme> _themes = [
    ReaderTheme(
      name: '白昼',
      backgroundColor: Color(0xFFFAF9F6),
      textColor: Color(0xFF222222),
      secondaryColor: Color(0xFF757575),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '羊皮纸',
      backgroundColor: Color(0xFFF5EEDC),
      textColor: Color(0xFF3B2F2F),
      secondaryColor: Color(0xFF7E7265),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '护眼绿',
      backgroundColor: Color(0xFFE2EED9),
      textColor: Color(0xFF233621),
      secondaryColor: Color(0xFF5D7058),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '暗夜',
      backgroundColor: Color(0xFF18181A),
      textColor: Color(0xFFB8B8B8),
      secondaryColor: Color(0xFF5C5C60),
      systemBrightness: Brightness.dark,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _currentActiveIndex = widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    _checkBookshelfStatus();
    _loadPreferences().then((_) {
      _startFromChapter(_currentActiveIndex);
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _apiService.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  Future<void> _checkBookshelfStatus() async {
    await _bookshelfService.initialize();
    if (mounted) {
      setState(() {
        _isInBookshelf = _bookshelfService.isInBookshelf(widget.book.bookId);
      });
    }
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _fontSize = prefs.getDouble('reader_font_size') ?? 18.0;
      _lineHeight = prefs.getDouble('reader_line_height') ?? 1.8;
      _themeIndex = (prefs.getInt('reader_theme_index') ?? 1).clamp(0, _themes.length - 1);
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader_font_size', _fontSize);
    await prefs.setDouble('reader_line_height', _lineHeight);
    await prefs.setInt('reader_theme_index', _themeIndex);
  }

  /// 保存当前章节进度到 SharedPreferences、书架和阅读历史
  Future<void> _persistReadingProgress(int index) async {
    if (index < 0 || index >= widget.chapters.length) return;
    final chapter = widget.chapters[index];

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('read_progress_index_${widget.book.bookId}', index);
      await prefs.setString('read_progress_title_${widget.book.bookId}', chapter.title);
      await prefs.setInt('read_progress_time_${widget.book.bookId}', DateTime.now().millisecondsSinceEpoch);

      // 同步到阅读历史（只要打开阅读就记录）
      await _readingHistoryService.recordReading(
        book: widget.book,
        chapterIndex: index,
        chapterTitle: chapter.title,
      );

      // 若在书架中，则同步书架进度并置顶
      if (_isInBookshelf) {
        await _bookshelfService.updateReadingProgress(
          widget.book.bookId,
          index,
          chapter.title,
        );
      }
    } catch (_) {}
  }

  /// 从指定章节重新开始连续阅读（重置滚动列表）
  Future<void> _startFromChapter(int index) async {
    if (index < 0 || index >= widget.chapters.length) return;

    setState(() {
      _currentActiveIndex = index;
      _displayedChapters.clear();
      _isLoadingHead = true;
      _errorMessage = null;
    });

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    await _fetchChapterContent(index);

    if (!mounted) return;

    if (_chapterCache.containsKey(index)) {
      setState(() {
        _displayedChapters.add(index);
        _chapterKeys[index] = GlobalKey();
        _isLoadingHead = false;
      });

      _persistReadingProgress(index);

      // 后台预加载后续 2 章，并提前在无限流中追加下一章
      _preloadNextChapters(index + 1, count: 2);
      _autoAppendNextChapter();
    } else {
      setState(() {
        _isLoadingHead = false;
        _errorMessage = '本章内容加载失败，请检查网络后重试';
      });
    }
  }

  /// 滚动监听：无限下拉加载后续章节 + 检测当前可见章节以同步进度
  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // 1. 检测当前视口可见的章节，更新标题和持久化阅读历史
    _detectCurrentVisibleChapter();

    // 2. 距离底部 800px 时自动预加载并追加下一章
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 800) {
      _autoAppendNextChapter();
    }
  }

  void _detectCurrentVisibleChapter() {
    if (_displayedChapters.isEmpty) return;

    int active = _displayedChapters.first;
    for (final chIndex in _displayedChapters) {
      final key = _chapterKeys[chIndex];
      if (key?.currentContext != null) {
        final box = key!.currentContext!.findRenderObject() as RenderBox?;
        if (box != null) {
          final pos = box.localToGlobal(Offset.zero);
          // 如果该章节标题已滚动到视口顶部 250 像素以内，则判定为当前活动章节
          if (pos.dy <= 250) {
            active = chIndex;
          }
        }
      }
    }

    if (active != _currentActiveIndex) {
      setState(() {
        _currentActiveIndex = active;
      });
      _persistReadingProgress(active);
    }
  }

  /// 自动向下拉伸追加下一章（实现连续无限下拉）
  Future<void> _autoAppendNextChapter() async {
    if (_isLoadingMore || _displayedChapters.isEmpty) return;

    final nextIndex = _displayedChapters.last + 1;
    if (nextIndex >= widget.chapters.length) return; // 已到全书最后一章

    _isLoadingMore = true;

    // 确保内容在缓存中
    if (!_chapterCache.containsKey(nextIndex)) {
      await _fetchChapterContent(nextIndex);
    }

    if (!mounted) {
      _isLoadingMore = false;
      return;
    }

    if (_chapterCache.containsKey(nextIndex)) {
      setState(() {
        if (!_displayedChapters.contains(nextIndex)) {
          _displayedChapters.add(nextIndex);
          _chapterKeys[nextIndex] = GlobalKey();
        }
      });
      // 深度预加载后续章节
      _preloadNextChapters(nextIndex + 1, count: 2);
    }

    _isLoadingMore = false;
  }

  /// 获取章节内容并缓存
  Future<void> _fetchChapterContent(int index) async {
    if (_chapterCache.containsKey(index)) return;
    if (index < 0 || index >= widget.chapters.length) return;

    final chapter = widget.chapters[index];
    final content = await _apiService.getChapterContent(chapter.itemId);

    if (content != null && content.isNotEmpty) {
      _chapterCache[index] = _formatContent(content);
    }
  }

  /// 后台静默预加载后续章节
  void _preloadNextChapters(int startIndex, {int count = 2}) async {
    for (int i = 0; i < count; i++) {
      final targetIndex = startIndex + i;
      if (targetIndex >= widget.chapters.length) break;
      if (!_chapterCache.containsKey(targetIndex)) {
        await _fetchChapterContent(targetIndex);
      }
    }
  }

  /// 文本段落格式化
  String _formatContent(String raw) {
    final lines = raw.split(RegExp(r'\r?\n'));
    final formatted = <String>[];
    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      formatted.add('\u3000\u3000$trimmed');
    }
    return formatted.join('\n\n');
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  Future<void> _toggleBookshelf() async {
    final added = await _bookshelfService.toggleBookshelf(
      widget.book,
      chapterIndex: _currentActiveIndex,
      chapterTitle: widget.chapters[_currentActiveIndex].title,
    );
    if (!mounted) return;
    setState(() {
      _isInBookshelf = added;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已加入书架' : '已从书架中移出'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showDirectoryDrawer() {
    final currentTheme = _themes[_themeIndex];
    final searchController = TextEditingController();
    var isReverse = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: currentTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final filter = searchController.text.trim();
            final allChapters = isReverse
                ? widget.chapters.reversed.toList()
                : widget.chapters;

            final displayChapters = filter.isEmpty
                ? allChapters
                : allChapters
                    .where((c) => c.title.contains(filter))
                    .toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '目录 (共 ${widget.chapters.length} 章)',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: currentTheme.textColor,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isReverse ? Icons.vertical_align_top : Icons.vertical_align_bottom,
                              color: currentTheme.secondaryColor,
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
                        style: TextStyle(color: currentTheme.textColor, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '搜索章节名称...',
                          hintStyle: TextStyle(color: currentTheme.secondaryColor),
                          prefixIcon: Icon(Icons.search, color: currentTheme.secondaryColor, size: 20),
                          filled: true,
                          fillColor: currentTheme.secondaryColor.withValues(alpha: 0.1),
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
                          final chap = displayChapters[idx];
                          final originalIndex = widget.chapters.indexOf(chap);
                          final isCurrent = originalIndex == _currentActiveIndex;

                          return ListTile(
                            dense: true,
                            title: Text(
                              chap.title,
                              style: TextStyle(
                                fontSize: 14,
                                color: isCurrent
                                    ? Theme.of(context).primaryColor
                                    : currentTheme.textColor,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isCurrent
                                ? Icon(
                                    Icons.bookmark,
                                    size: 18,
                                    color: Theme.of(context).primaryColor,
                                  )
                                : null,
                            onTap: () {
                              Navigator.pop(ctx);
                              _startFromChapter(originalIndex);
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

  void _showSettingsModal() {
    final currentTheme = _themes[_themeIndex];
    showModalBottomSheet(
      context: context,
      backgroundColor: currentTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: currentTheme.secondaryColor.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '阅读设置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTheme.textColor,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '字号',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: _fontSize > 13
                            ? () {
                                setState(() => _fontSize -= 1.0);
                                setModalState(() {});
                                _savePreferences();
                              }
                            : null,
                        child: const Text('A -'),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          '${_fontSize.toInt()}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: currentTheme.textColor,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _fontSize < 28
                            ? () {
                                setState(() => _fontSize += 1.0);
                                setModalState(() {});
                                _savePreferences();
                              }
                            : null,
                        child: const Text('A +'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '行距',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const Spacer(),
                      SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: 1.5, label: Text('紧凑')),
                          ButtonSegment(value: 1.8, label: Text('适中')),
                          ButtonSegment(value: 2.2, label: Text('宽松')),
                        ],
                        selected: {_lineHeight},
                        showSelectedIcon: false,
                        onSelectionChanged: (val) {
                          setState(() => _lineHeight = val.first);
                          setModalState(() {});
                          _savePreferences();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '背景',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: List.generate(_themes.length, (idx) {
                            final th = _themes[idx];
                            final isSelected = _themeIndex == idx;
                            return GestureDetector(
                              onTap: () {
                                setState(() => _themeIndex = idx);
                                setModalState(() {});
                                _savePreferences();
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: th.backgroundColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? Theme.of(context).primaryColor
                                        : Colors.grey.shade400,
                                    width: isSelected ? 2.5 : 1.0,
                                  ),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.15),
                                            blurRadius: 4,
                                            offset: const Offset(0, 2),
                                          )
                                        ]
                                      : null,
                                ),
                                child: Center(
                                  child: Text(
                                    th.name.substring(0, 1),
                                    style: TextStyle(
                                      color: th.textColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _themes[_themeIndex];
    final currentChapter = widget.chapters[_currentActiveIndex];

    return Scaffold(
      backgroundColor: theme.backgroundColor,
      body: Stack(
        children: [
          // 阅读主要连续内容区域
          GestureDetector(
            onTap: _toggleControls,
            behavior: HitTestBehavior.opaque,
            child: SafeArea(
              child: Column(
                children: [
                  // 顶部微型信息栏
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            currentChapter.title,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.secondaryColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${_currentActiveIndex + 1}/${widget.chapters.length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.secondaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 正文滚屏（支持无限下拉追加后续章节）
                  Expanded(
                    child: _buildReaderBody(theme),
                  ),
                ],
              ),
            ),
          ),

          // 顶部操作栏
          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _buildTopBar(theme),
            ),

          // 底部操作栏
          if (_showControls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomBar(theme),
            ),
        ],
      ),
    );
  }

  Widget _buildReaderBody(ReaderTheme theme) {
    if (_isLoadingHead) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(theme.secondaryColor),
            ),
            const SizedBox(height: 12),
            Text(
              '正在加载章节...',
              style: TextStyle(color: theme.secondaryColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48, color: theme.secondaryColor),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.secondaryColor, fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _startFromChapter(_currentActiveIndex),
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    return Scrollbar(
      controller: _scrollController,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 渲染所有已加载的章节
            for (int i = 0; i < _displayedChapters.length; i++)
              _buildChapterBlock(_displayedChapters[i], theme, isFirst: i == 0),

            // 下拉预加载指示器
            if (_displayedChapters.isNotEmpty &&
                _displayedChapters.last < widget.chapters.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            theme.secondaryColor.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '下拉自动加载下一章...',
                        style: TextStyle(fontSize: 13, color: theme.secondaryColor),
                      ),
                    ],
                  ),
                ),
              )
            else if (_displayedChapters.isNotEmpty &&
                _displayedChapters.last >= widget.chapters.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    '— 全书已完结 —',
                    style: TextStyle(fontSize: 13, color: theme.secondaryColor),
                  ),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  /// 构建单章内容块
  Widget _buildChapterBlock(int chapterIndex, ReaderTheme theme, {bool isFirst = false}) {
    final chapter = widget.chapters[chapterIndex];
    final content = _chapterCache[chapterIndex] ?? '';
    final key = _chapterKeys[chapterIndex];

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isFirst) ...[
          const SizedBox(height: 36),
          // 章节间优雅分割条
          Row(
            children: [
              Expanded(
                child: Divider(
                  color: theme.secondaryColor.withValues(alpha: 0.3),
                  thickness: 1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '本章完',
                  style: TextStyle(fontSize: 12, color: theme.secondaryColor),
                ),
              ),
              Expanded(
                child: Divider(
                  color: theme.secondaryColor.withValues(alpha: 0.3),
                  thickness: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 36),
        ],

        // 章节大标题
        Text(
          chapter.title,
          style: TextStyle(
            fontSize: _fontSize + 4,
            fontWeight: FontWeight.bold,
            color: theme.textColor,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),

        // 章节正文
        Text(
          content,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: theme.textColor,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(ReaderTheme theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.backgroundColor.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new, size: 20, color: theme.textColor),
                onPressed: () => Navigator.pop(context),
              ),
              Expanded(
                child: Text(
                  widget.book.bookName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: theme.textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 加入书架 / 已在书架按钮
              IconButton(
                icon: Icon(
                  _isInBookshelf ? Icons.bookmark_added : Icons.bookmark_add_outlined,
                  color: _isInBookshelf ? Theme.of(context).primaryColor : theme.textColor,
                ),
                tooltip: _isInBookshelf ? '已在书架' : '加入书架',
                onPressed: _toggleBookshelf,
              ),
              IconButton(
                icon: Icon(Icons.list_rounded, size: 24, color: theme.textColor),
                tooltip: '目录',
                onPressed: _showDirectoryDrawer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(ReaderTheme theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.backgroundColor.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.skip_previous_rounded, color: theme.textColor),
                    tooltip: '上一章',
                    onPressed: _currentActiveIndex > 0
                        ? () => _startFromChapter(_currentActiveIndex - 1)
                        : null,
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: _currentActiveIndex.toDouble(),
                        min: 0,
                        max: (widget.chapters.length - 1).toDouble().clamp(0.0, double.infinity),
                        divisions: widget.chapters.length > 1 ? widget.chapters.length - 1 : 1,
                        label: '第 ${_currentActiveIndex + 1} 章',
                        onChanged: (val) {
                          final target = val.round();
                          if (target != _currentActiveIndex) {
                            _startFromChapter(target);
                          }
                        },
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_next_rounded, color: theme.textColor),
                    tooltip: '下一章',
                    onPressed: _currentActiveIndex < widget.chapters.length - 1
                        ? () => _startFromChapter(_currentActiveIndex + 1)
                        : null,
                  ),
                ],
              ),
              const Divider(height: 1),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  TextButton.icon(
                    onPressed: _showDirectoryDrawer,
                    icon: Icon(Icons.menu_book_outlined, color: theme.textColor, size: 20),
                    label: Text('目录', style: TextStyle(color: theme.textColor)),
                  ),
                  TextButton.icon(
                    onPressed: _showSettingsModal,
                    icon: Icon(Icons.text_format, color: theme.textColor, size: 20),
                    label: Text('排版设置', style: TextStyle(color: theme.textColor)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
