import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/comment.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/download_service.dart';
import '../services/reading_history_service.dart';
import '../services/reader_system_service.dart';
import '../services/tts_service.dart';
import '../widgets/tts_player_panel.dart';
import '../widgets/paragraph_comment_sheet.dart';

/// 阅读器主题配置
class ReaderTheme {
  final String name;
  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final Color highlightColor; // 主题专属同色系温和高亮底色
  final Brightness systemBrightness;

  const ReaderTheme({
    required this.name,
    required this.backgroundColor,
    required this.textColor,
    required this.secondaryColor,
    required this.highlightColor,
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
  // 章节是否来自本地持久化离线/已下载存储
  final Map<int, bool> _chapterIsOffline = {};
  // 当前无限下拉中已渲染展示的章节索引列表
  final List<int> _displayedChapters = [];
  final Map<int, GlobalKey> _chapterKeys = {};
  final Map<String, GlobalKey> _paragraphKeys = {};

  // 章节段评统计缓存 (itemId -> stats)
  final Map<String, ChapterCommentStats> _chapterCommentStats = {};
  // 真实本章评论总数 (itemId -> count)
  final Map<String, int> _chapterCommentsCount = {};
  // 已触发静默预加载的章节索引集合
  final Set<int> _prefetchedIndices = {};
  // 定位原文时高亮提示的目标段落 key
  String? _highlightedParagraphKey;
  Timer? _highlightTimer;

  // 当前用户视觉所在的章节索引
  late int _currentActiveIndex;
  late final ValueNotifier<int> _activeChapterNotifier;
  double _lastDetectPixels = 0.0;
  final TtsService _ttsService = TtsService();
  bool _isLoadingHead = false;
  bool _isLoadingPrev = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  bool _showControls = false;
  bool _isInBookshelf = false;

  // 底部常驻微型状态信息（时间与电池电量）
  Timer? _statusTimer;
  String _currentTimeStr = '';
  int _batteryLevel = -1;

  // 用户偏好
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  int _themeIndex = 1; // 默认羊皮纸
  double _horizontalPadding = 20.0; // 页面边距：14 紧凑, 20 适中, 28 宽松
  bool _volumeKeyScroll = false; // 音量物理键翻页滚动
  bool _showCommentBubbles = true; // 是否显示段评气泡

  static const List<ReaderTheme> _themes = [
    ReaderTheme(
      name: '白昼',
      backgroundColor: Color(0xFFFAF9F6),
      textColor: Color(0xFF222222),
      secondaryColor: Color(0xFF757575),
      highlightColor: Color(0xFFE8E2D2), // 淡雅米暖底色，温润不刺眼
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '羊皮纸',
      backgroundColor: Color(0xFFF5EEDC),
      textColor: Color(0xFF3B2F2F),
      secondaryColor: Color(0xFF7E7265),
      highlightColor: Color(0xFFE5DAC4), // 羊皮纸同色系浅茶色，浑然一体
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '护眼绿',
      backgroundColor: Color(0xFFE2EED9),
      textColor: Color(0xFF233621),
      secondaryColor: Color(0xFF5D7058),
      highlightColor: Color(0xFFCEE0C3), // 护眼绿同色系浅春草色，清爽柔和
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '暗夜',
      backgroundColor: Color(0xFF18181A),
      textColor: Color(0xFFB8B8B8),
      secondaryColor: Color(0xFF5C5C60),
      highlightColor: Color(0xFF28282C), // 沉稳深碳灰，夜晚完全不眩光
      systemBrightness: Brightness.dark,
    ),
    ReaderTheme(
      name: '纯黑',
      backgroundColor: Color(0xFF000000),
      textColor: Color(0xFFC7C7CC),
      secondaryColor: Color(0xFF636366),
      highlightColor: Color(0xFF222224), // 哑光低对比深灰，OLED 省电柔和
      systemBrightness: Brightness.dark,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _currentActiveIndex = widget.initialChapterIndex.clamp(0, widget.chapters.length - 1);
    _activeChapterNotifier = ValueNotifier<int>(_currentActiveIndex);
    _checkBookshelfStatus();
    _loadPreferences().then((_) {
      _startFromChapter(_currentActiveIndex);
      ReaderSystemService.setVolumeKeyScrollEnabled(_volumeKeyScroll);
    });
    _scrollController.addListener(_onScroll);
    _ttsService.addListener(_onTtsStateChanged);
    
    // 启用阅读屏幕常亮与定时电量/时间更新
    ReaderSystemService.setKeepScreenOn(true);
    ReaderSystemService.registerVolumeKeyListener(_onVolumeScroll);
    _updateStatusInfo();
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _updateStatusInfo());
  }

  @override
  void dispose() {
    _ttsService.removeListener(_onTtsStateChanged);
    _ttsService.stop();
    _activeChapterNotifier.dispose();
    _statusTimer?.cancel();
    _highlightTimer?.cancel();
    ReaderSystemService.setKeepScreenOn(false);
    ReaderSystemService.setVolumeKeyScrollEnabled(false);
    ReaderSystemService.registerVolumeKeyListener(null);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _apiService.dispose();
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  void _onTtsStateChanged() {
    if (mounted) {
      setState(() {});
      if (_ttsService.isPlaying && _scrollController.hasClients) {
        _autoScrollFollowTts();
      }
    }
  }

  /// 智能字幕式自动平滑滚屏跟随朗读进度
  void _autoScrollFollowTts() {
    final chIdx = widget.chapters.indexWhere((c) => c.title == _ttsService.currentChapterTitle);
    if (chIdx == -1 || !_displayedChapters.contains(chIdx)) return;

    final key = _chapterKeys[chIdx];
    final box = key?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;

    final chapterPos = box.localToGlobal(Offset.zero);
    final chapterHeight = box.size.height;
    final totalChunks = _ttsService.chunks.length;
    final curChunk = _ttsService.currentIndex;

    if (totalChunks <= 0) return;

    // 计算当前朗读切片在屏幕上的绝对垂直坐标
    final progressInChapter = (curChunk / totalChunks).clamp(0.0, 1.0);
    final currentSentenceDy = chapterPos.dy + progressInChapter * chapterHeight;

    final screenHeight = MediaQuery.of(context).size.height;
    final desiredDy = screenHeight * 0.35; // 黄金视线停留区（屏幕上方 35% 处）

    final delta = currentSentenceDy - desiredDy;
    if (delta.abs() > 35.0) {
      final targetOffset = (_scrollController.offset + delta)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _updateStatusInfo() async {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final battery = await ReaderSystemService.getBatteryLevel();
    if (mounted) {
      setState(() {
        _currentTimeStr = '$hour:$minute';
        _batteryLevel = battery;
      });
    }
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
      _horizontalPadding = prefs.getDouble('reader_horizontal_padding') ?? 20.0;
      _volumeKeyScroll = prefs.getBool('reader_volume_key_scroll') ?? false;
      _showCommentBubbles = prefs.getBool('reader_show_comment_bubbles') ?? true;
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader_font_size', _fontSize);
    await prefs.setDouble('reader_line_height', _lineHeight);
    await prefs.setInt('reader_theme_index', _themeIndex);
    await prefs.setDouble('reader_horizontal_padding', _horizontalPadding);
    await prefs.setBool('reader_volume_key_scroll', _volumeKeyScroll);
    await prefs.setBool('reader_show_comment_bubbles', _showCommentBubbles);
  }

  void _onVolumeScroll(String direction) {
    if (!_volumeKeyScroll || !_scrollController.hasClients) return;
    final viewHeight = MediaQuery.of(context).size.height * 0.75;
    final target = direction == 'down'
        ? (_scrollController.offset + viewHeight).clamp(0.0, _scrollController.position.maxScrollExtent)
        : (_scrollController.offset - viewHeight).clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
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

      // 后台静默预加载后续 3~5 章，并提前在无限流中追加下一章
      _triggerSilentPrefetch(index);
      _autoAppendNextChapter();
    } else {
      setState(() {
        _isLoadingHead = false;
        _errorMessage = '本章内容加载失败，请检查网络后重试';
      });
    }
  }

  /// 滚动监听：节流局部检测活跃章节 + 双向无限滚动（极速丝滑不掉帧）
  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final currentPixels = _scrollController.position.pixels;

    // 1. 节流检测当前视口可见的章节（位移超过 50px 时才做轻量局部探测，极大提升长文滚屏流畅度）
    if ((currentPixels - _lastDetectPixels).abs() >= 50.0) {
      _lastDetectPixels = currentPixels;
      _detectCurrentVisibleChapterOptimized();
    }

    // 2. 距离顶部 300px 时自动预加载并追加上一章 (实现无缝双向无限滚动)
    if (currentPixels <= 300 &&
        _displayedChapters.isNotEmpty &&
        _displayedChapters.first > 0) {
      _autoPrependPreviousChapter();
    }

    // 3. 距离底部 800px 时自动预加载并追加下一章
    if (currentPixels >=
        _scrollController.position.maxScrollExtent - 800) {
      _autoAppendNextChapter();
    }
  }

  /// 高性能局部检测当前活跃章节（仅针对临近章节进行局部探测，避免全量 O(N) 全局矩阵坐标运算）
  void _detectCurrentVisibleChapterOptimized() {
    if (_displayedChapters.isEmpty) return;

    int active = _currentActiveIndex;
    final checkIndices = <int>{
      _currentActiveIndex,
      if (_displayedChapters.contains(_currentActiveIndex - 1)) _currentActiveIndex - 1,
      if (_displayedChapters.contains(_currentActiveIndex + 1)) _currentActiveIndex + 1,
      _displayedChapters.first,
      _displayedChapters.last,
    };

    for (final chIndex in checkIndices) {
      final key = _chapterKeys[chIndex];
      if (key?.currentContext != null) {
        final box = key!.currentContext!.findRenderObject() as RenderBox?;
        if (box != null && box.attached) {
          final pos = box.localToGlobal(Offset.zero);
          // 章节顶部接近视口上方 250 像素以内即判定为当前活动章节
          if (pos.dy <= 250 && pos.dy >= -300) {
            active = chIndex;
          }
        }
      }
    }

    if (active != _currentActiveIndex) {
      _currentActiveIndex = active;
      _activeChapterNotifier.value = active; // 仅通知微型小部件刷新，不触发全屏 Widget 树 Rebuild
      _persistReadingProgress(active);
      _triggerSilentPrefetch(active);
    }
  }

  /// 自动向上拉伸追加上一章（实现双向无缝连续阅读）
  Future<void> _autoPrependPreviousChapter() async {
    if (_isLoadingPrev || _displayedChapters.isEmpty) return;

    final prevIndex = _displayedChapters.first - 1;
    if (prevIndex < 0) return;

    _isLoadingPrev = true;

    // 确保内容在缓存中
    if (!_chapterCache.containsKey(prevIndex)) {
      await _fetchChapterContent(prevIndex);
    }

    if (!mounted) {
      _isLoadingPrev = false;
      return;
    }

    if (_chapterCache.containsKey(prevIndex)) {
      // 记录插入前的位置与最大滚动距离
      final oldMaxScroll = _scrollController.position.maxScrollExtent;
      final oldPixels = _scrollController.position.pixels;

      setState(() {
        if (!_displayedChapters.contains(prevIndex)) {
          _displayedChapters.insert(0, prevIndex);
          _chapterKeys[prevIndex] = GlobalKey();
        }
      });

      // 帧渲染完成后精确补偿滚动偏移量，确保当前读者视口内容纹丝不动
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          _isLoadingPrev = false;
          return;
        }
        final newMaxScroll = _scrollController.position.maxScrollExtent;
        final delta = newMaxScroll - oldMaxScroll;
        if (delta > 0) {
          _scrollController.jumpTo(oldPixels + delta);
        }
        _isLoadingPrev = false;
      });

      // 静默预加载更前面的章节
      if (prevIndex > 0) {
        _triggerSilentPrefetch(prevIndex - 1, count: 1);
      }
    } else {
      _isLoadingPrev = false;
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
      // 深度静默预加载后续章节
      _triggerSilentPrefetch(nextIndex);
    }

    _isLoadingMore = false;
  }

  /// 获取章节内容并缓存
  Future<void> _fetchChapterContent(int index) async {
    if (_chapterCache.containsKey(index)) return;
    if (index < 0 || index >= widget.chapters.length) return;

    final chapter = widget.chapters[index];
    
    // 1. 优先检查本地离线/已下载资源
    final isOffline = await _apiService.isChapterOffline(widget.book.bookId, chapter.itemId);
    _chapterIsOffline[index] = isOffline;

    // 2. 获取正文（传入 bookId，内部优先读取 offline_books，若未下载则拉取并自动持久化缓存）
    final content = await _apiService.getChapterContent(
      chapter.itemId,
      bookId: widget.book.bookId,
    );

    if (content != null && content.isNotEmpty) {
      _chapterCache[index] = _formatContent(content, chapterTitle: chapter.title);
      _chapterIsOffline[index] = true;
      _fetchCommentStats(chapter.itemId);
      _fetchChapterCommentsCount(chapter.itemId);
    }
  }

  /// 异步拉取章节段评数量统计
  void _fetchCommentStats(String itemId) async {
    if (_chapterCommentStats.containsKey(itemId)) return;
    try {
      final stats = await _apiService.getChapterCommentStats(
        itemId,
        bookId: widget.book.bookId,
      );
      if (stats != null && mounted) {
        setState(() {
          _chapterCommentStats[itemId] = stats;
        });
      }
    } catch (_) {}
  }

  /// 异步拉取真实章节评论数量 (章评，非段落评论)
  void _fetchChapterCommentsCount(String itemId) async {
    if (_chapterCommentsCount.containsKey(itemId)) return;
    try {
      final data = await _apiService.getChapterComments(
        widget.book.bookId,
        itemId,
        count: 1,
      );
      if (data != null && mounted) {
        setState(() {
          _chapterCommentsCount[itemId] = data.total;
        });
      }
    } catch (_) {}
  }

  /// 静默预加载流水线：后台并发异步预取后续 3~5 章正文与段评，实现完全无缝零等待
  void _triggerSilentPrefetch(int currentIndex, {int count = 4}) {
    final targets = <int>[];
    for (int offset = 1; offset <= count; offset++) {
      final targetIdx = currentIndex + offset;
      if (targetIdx < widget.chapters.length &&
          !_chapterCache.containsKey(targetIdx) &&
          !_prefetchedIndices.contains(targetIdx)) {
        targets.add(targetIdx);
        _prefetchedIndices.add(targetIdx);
      }
    }
    // 同时预热前 1 章
    final prevIdx = currentIndex - 1;
    if (prevIdx >= 0 &&
        !_chapterCache.containsKey(prevIdx) &&
        !_prefetchedIndices.contains(prevIdx)) {
      targets.add(prevIdx);
      _prefetchedIndices.add(prevIdx);
    }

    if (targets.isEmpty) return;

    // 低优先级并发请求，静默缓存
    for (final idx in targets) {
      _fetchChapterContent(idx).catchError((_) {});
    }
  }

  /// 文本段落格式化与首行重复章节名智能去重
  String _formatContent(String raw, {String? chapterTitle}) {
    final lines = raw.split(RegExp(r'\r?\n'));
    final formatted = <String>[];
    bool isFirstLine = true;

    final normalizedTitle = chapterTitle
        ?.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
        .toLowerCase();

    for (var line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (isFirstLine) {
        isFirstLine = false;
        // 智能去重：若正文第一行与识别出的章节名重复，剔除该行
        final normalizedLine = trimmed.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '').toLowerCase();
        if (normalizedTitle != null && normalizedTitle.isNotEmpty) {
          if (normalizedLine == normalizedTitle ||
              (normalizedLine.length < 35 && (normalizedTitle.contains(normalizedLine) || normalizedLine.contains(normalizedTitle)))) {
            continue;
          }
        }
        if (trimmed.length < 30 && RegExp(r'^第[0-9一二三四五六七八九十百千万]+[章卷回节集]').hasMatch(trimmed)) {
          continue;
        }
      }

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
    var isVolumeMode = false;

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

            // 构造分卷分组
            final volumeMap = <String, List<Chapter>>{};
            String currentVol = '正文';
            for (final chap in allChapters) {
              if (chap.volumeTitle.isNotEmpty) {
                currentVol = chap.volumeTitle;
              } else if (chap.title.contains(RegExp(r'第.+卷'))) {
                final match = RegExp(r'(第.+卷[^\s]*)').firstMatch(chap.title);
                if (match != null) {
                  currentVol = match.group(1)!;
                }
              }
              volumeMap.putIfAbsent(currentVol, () => []).add(chap);
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) {
                // 打开目录时，自动平滑滚动定位到当前章节
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (scrollController.hasClients && filter.isEmpty && !isVolumeMode) {
                    final targetIndex = isReverse
                        ? (allChapters.length - 1 - _currentActiveIndex)
                        : _currentActiveIndex;
                    // 每个 dense ListTile 约 48px，目标定在视口第 3 项处，让读者一眼看清当前阅读位置
                    final targetOffset = (targetIndex * 48.0 - 120.0)
                        .clamp(0.0, scrollController.position.maxScrollExtent);
                    if ((scrollController.offset - targetOffset).abs() > 30) {
                      scrollController.jumpTo(targetOffset);
                    }
                  }
                });

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
                              isVolumeMode ? Icons.view_headline : Icons.folder_outlined,
                              color: currentTheme.secondaryColor,
                            ),
                            tooltip: isVolumeMode ? '列表平铺' : '按卷折叠',
                            onPressed: () {
                              setModalState(() {
                                isVolumeMode = !isVolumeMode;
                              });
                            },
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
                      child: isVolumeMode && filter.isEmpty
                          ? ListView(
                              controller: scrollController,
                              children: volumeMap.entries.map((entry) {
                                final volTitle = entry.key;
                                final volChapters = entry.value;
                                final containsActive = volChapters.any(
                                    (c) => widget.chapters.indexOf(c) == _currentActiveIndex);
                                return ExpansionTile(
                                  key: PageStorageKey('vol_$volTitle'),
                                  initiallyExpanded: containsActive || volumeMap.length == 1,
                                  iconColor: Theme.of(context).primaryColor,
                                  collapsedIconColor: currentTheme.secondaryColor,
                                  title: Text(
                                    '$volTitle (${volChapters.length}章)',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: containsActive
                                          ? Theme.of(context).primaryColor
                                          : currentTheme.textColor,
                                    ),
                                  ),
                                  children: volChapters.map((chap) {
                                    final originalIndex = widget.chapters.indexOf(chap);
                                    final isCurrent = originalIndex == _currentActiveIndex;
                                    return ListTile(
                                      dense: true,
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 32),
                                      title: Text(
                                        chap.title,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: isCurrent
                                              ? Theme.of(context).primaryColor
                                              : currentTheme.textColor,
                                          fontWeight:
                                              isCurrent ? FontWeight.bold : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: isCurrent
                                          ? Icon(Icons.bookmark,
                                              size: 16, color: Theme.of(context).primaryColor)
                                          : null,
                                      onTap: () {
                                        Navigator.pop(ctx);
                                        _startFromChapter(originalIndex);
                                      },
                                    );
                                  }).toList(),
                                );
                              }).toList(),
                            )
                          : ListView.builder(
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
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '页边距',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const Spacer(),
                      SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: 14.0, label: Text('窄边')),
                          ButtonSegment(value: 20.0, label: Text('适中')),
                          ButtonSegment(value: 28.0, label: Text('宽边')),
                        ],
                        selected: {_horizontalPadding},
                        showSelectedIcon: false,
                        onSelectionChanged: (val) {
                          setState(() => _horizontalPadding = val.first);
                          setModalState(() {});
                          _savePreferences();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '音量键翻页滚动',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const Spacer(),
                      Switch.adaptive(
                        value: _volumeKeyScroll,
                        activeTrackColor: Theme.of(context).primaryColor,
                        onChanged: (val) {
                          setState(() => _volumeKeyScroll = val);
                          setModalState(() {});
                          _savePreferences();
                          ReaderSystemService.setVolumeKeyScrollEnabled(val);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        '段评气泡',
                        style: TextStyle(color: currentTheme.secondaryColor, fontSize: 14),
                      ),
                      const Spacer(),
                      Switch.adaptive(
                        value: _showCommentBubbles,
                        activeTrackColor: Theme.of(context).primaryColor,
                        onChanged: (val) {
                          setState(() => _showCommentBubbles = val);
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
                          child: Row(
                            children: [
                              if (_chapterIsOffline[_currentActiveIndex] == true) ...[
                                Container(
                                  margin: const EdgeInsets.only(right: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: theme.secondaryColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    '已离线',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: theme.secondaryColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
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
                            ],
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
                  // 底部常驻微型状态栏（时间、电量、总进度）
                  _buildBottomStatusBar(theme),
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

          // 听书浮动控制面板 (听书开启时常驻底部)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: TtsPlayerPanel(
              onClose: () {
                setState(() {});
              },
            ),
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
        padding: EdgeInsets.symmetric(horizontal: _horizontalPadding, vertical: 12),
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部上一章指示器/触发器
            if (_displayedChapters.isNotEmpty && _displayedChapters.first > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: TextButton.icon(
                    onPressed: _isLoadingPrev ? null : _autoPrependPreviousChapter,
                    icon: _isLoadingPrev
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                theme.secondaryColor.withValues(alpha: 0.6),
                              ),
                            ),
                          )
                        : Icon(Icons.arrow_upward_rounded, size: 16, color: theme.secondaryColor),
                    label: Text(
                      _isLoadingPrev
                          ? '正在加载上一章...'
                          : '上滑或点击加载：${widget.chapters[_displayedChapters.first - 1].title}',
                      style: TextStyle(fontSize: 12, color: theme.secondaryColor),
                    ),
                  ),
                ),
              )
            else if (_displayedChapters.isNotEmpty && _displayedChapters.first == 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '— 已是第一章 —',
                    style: TextStyle(fontSize: 12, color: theme.secondaryColor.withValues(alpha: 0.6)),
                  ),
                ),
              ),

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

  Widget _buildBottomStatusBar(ReaderTheme theme) {
    return ValueListenableBuilder<int>(
      valueListenable: _activeChapterNotifier,
      builder: (context, activeIdx, _) {
        final ch = (activeIdx >= 0 && activeIdx < widget.chapters.length)
            ? widget.chapters[activeIdx]
            : widget.chapters.first;
        final progress = widget.chapters.isNotEmpty
            ? ((activeIdx + 1) / widget.chapters.length).clamp(0.0, 1.0)
            : 0.0;
        final percentStr = (progress * 100).toStringAsFixed(1);

        return Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: theme.backgroundColor,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  ch.title,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.secondaryColor.withValues(alpha: 0.75),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_currentTimeStr.isNotEmpty ? '$_currentTimeStr  |  ' : ''}${_batteryLevel >= 0 ? '$_batteryLevel%  |  ' : ''}$percentStr%',
                style: TextStyle(
                  fontSize: 10,
                  color: theme.secondaryColor.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建单章内容块（RepaintBoundary 独立绘制层隔离 + TTS 语句智能高亮）
  Widget _buildChapterBlock(int chapterIndex, ReaderTheme theme, {bool isFirst = false}) {
    final chapter = widget.chapters[chapterIndex];
    final content = _chapterCache[chapterIndex] ?? '';
    final key = _chapterKeys[chapterIndex];

    final isTtsThisChapter = _ttsService.isActive && _ttsService.currentChapterTitle == chapter.title;
    final currentTtsText = isTtsThisChapter ? _ttsService.currentText.trim() : '';

    return RepaintBoundary(
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isFirst) const SizedBox(height: 24),

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

          // 章节正文（段落级渲染 + TTS 正在播放语句实时高亮）
          _buildChapterParagraphs(chapterIndex, content, theme, currentTtsText),
          const SizedBox(height: 28),

          // 章节末尾段评入口与本章完
          _buildChapterEndComments(chapter, theme),
          const SizedBox(height: 36),
        ],
      ),
    );
  }

  Widget _buildChapterParagraphs(int chapterIndex, String content, ReaderTheme theme, String currentTtsText) {
    if (content.isEmpty) return const SizedBox.shrink();
    final chapter = widget.chapters[chapterIndex];
    final paragraphs = content.split('\n\n');
    final isDark = theme.backgroundColor == const Color(0xFF000000) || theme.backgroundColor == const Color(0xFF18181A);
    final stats = _chapterCommentStats[chapter.itemId];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int pIdx = 0; pIdx < paragraphs.length; pIdx++) ...[
          _buildSingleParagraph(
            paragraphs[pIdx],
            theme,
            currentTtsText,
            isDark,
            chapter: chapter,
            paraIndex: pIdx,
            commentCount: stats?.getCount(pIdx) ?? 0,
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildSingleParagraph(
    String paragraph,
    ReaderTheme theme,
    String currentTtsText,
    bool isDark, {
    required Chapter chapter,
    required int paraIndex,
    required int commentCount,
  }) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final paraKeyStr = '${chapter.itemId}_$paraIndex';
    final pKey = _paragraphKeys.putIfAbsent(paraKeyStr, () => GlobalKey());
    final isLocateTarget = _highlightedParagraphKey == paraKeyStr;
    final showBubble = _showCommentBubbles && commentCount > 0;

    final inlineSpans = <InlineSpan>[];
    if (currentTtsText.isEmpty) {
      inlineSpans.add(
        TextSpan(
          text: paragraph,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: theme.textColor,
            letterSpacing: 0.5,
          ),
        ),
      );
    } else {
      // 提取当前朗读块中的核心语句
      final cleanTts = currentTtsText.replaceAll(RegExp(r'[\s\r\n]'), '');
      final cleanParagraph = trimmed.replaceAll(RegExp(r'[\s\r\n]'), '');

      final isFullMatch = cleanTts.contains(cleanParagraph) || cleanParagraph.contains(cleanTts);

      // 按自然句切分进行富文本高亮（Word 荧光笔标记风格，无外围多余边框）
      final sentencePattern = RegExp(r'[^。！？；!?;]+[。！？；!?;]?');
      final matches = sentencePattern.allMatches(paragraph);

      if (matches.isEmpty) {
        inlineSpans.add(
          TextSpan(
            text: paragraph,
            style: TextStyle(
              fontSize: _fontSize,
              height: _lineHeight,
              color: theme.textColor,
              letterSpacing: 0.5,
            ),
          ),
        );
      } else {
        final spans = <TextSpan>[];
        final highlightMarkerBg = theme.highlightColor;
        bool hasAnyHighlight = false;

        for (final match in matches) {
          final sentence = match.group(0) ?? '';
          final cleanSent = sentence.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');

          final isSentHighlighted = cleanSent.isNotEmpty &&
              (cleanTts.contains(cleanSent) ||
                  (cleanSent.length > 4 && cleanTts.contains(cleanSent.substring(0, 4))) ||
                  isFullMatch);

          if (isSentHighlighted) hasAnyHighlight = true;

          spans.add(
            TextSpan(
              text: sentence,
              style: TextStyle(
                fontSize: _fontSize,
                height: _lineHeight,
                color: theme.textColor,
                backgroundColor: isSentHighlighted ? highlightMarkerBg : null,
                fontWeight: isSentHighlighted ? FontWeight.w500 : FontWeight.normal,
                letterSpacing: 0.5,
              ),
            ),
          );
        }

        if (!hasAnyHighlight) {
          inlineSpans.add(
            TextSpan(
              text: paragraph,
              style: TextStyle(
                fontSize: _fontSize,
                height: _lineHeight,
                color: theme.textColor,
                letterSpacing: 0.5,
              ),
            ),
          );
        } else {
          inlineSpans.addAll(spans);
        }
      }
    }

    // 紧跟在段落最后几个字/标点符号后面的内联气泡角标，不单独另起一行
    if (showBubble) {
      inlineSpans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 4.0),
            child: GestureDetector(
              onTap: () => _openParagraphComments(
                chapter: chapter,
                paraIndex: paraIndex,
                paraText: trimmed,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : theme.highlightColor.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.secondaryColor.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 10,
                      color: isDark ? Colors.white70 : theme.secondaryColor,
                    ),
                    const SizedBox(width: 2.5),
                    Text(
                      commentCount > 999 ? '999+' : '$commentCount',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white70 : theme.secondaryColor,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      key: pKey,
      padding: isLocateTarget ? const EdgeInsets.symmetric(vertical: 2, horizontal: 4) : EdgeInsets.zero,
      decoration: isLocateTarget
          ? BoxDecoration(
              color: theme.highlightColor.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).primaryColor, width: 1.2),
            )
          : null,
      child: Text.rich(
        TextSpan(children: inlineSpans),
      ),
    );
  }

  /// 打开指定段落评论抽屉
  void _openParagraphComments({
    required Chapter chapter,
    required int paraIndex,
    required String paraText,
  }) {
    final theme = _themes[_themeIndex];
    ParagraphCommentSheet.show(
      context: context,
      bookId: widget.book.bookId,
      chapterId: chapter.itemId,
      paraIndex: paraIndex,
      paraText: paraText,
      chapterTitle: chapter.title,
      backgroundColor: theme.backgroundColor,
      textColor: theme.textColor,
      secondaryColor: theme.secondaryColor,
      highlightColor: theme.highlightColor,
      onLocateParagraph: () => _locateParagraph(chapter, paraIndex),
    );
  }

  /// 定位并高亮原文段落
  void _locateParagraph(Chapter chapter, int paraIndex) {
    final key = '${chapter.itemId}_$paraIndex';
    final targetContext = _paragraphKeys[key]?.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.25,
      );
      setState(() {
        _highlightedParagraphKey = key;
      });
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) {
          setState(() {
            _highlightedParagraphKey = null;
          });
        }
      });
    }
  }

  /// 显示本章段评概览
  void _openChapterComments(Chapter chapter) {
    final theme = _themes[_themeIndex];
    ParagraphCommentSheet.show(
      context: context,
      bookId: widget.book.bookId,
      chapterId: chapter.itemId,
      isChapterComment: true, // 明确为真实本章评论
      paraText: '',
      chapterTitle: chapter.title,
      backgroundColor: theme.backgroundColor,
      textColor: theme.textColor,
      secondaryColor: theme.secondaryColor,
      highlightColor: theme.highlightColor,
    );
  }

  /// 构建章节末尾的“本章完”分割与真实本章评论入口
  Widget _buildChapterEndComments(Chapter chapter, ReaderTheme theme) {
    final total = _chapterCommentsCount[chapter.itemId] ?? 0;
    final isDark = theme.backgroundColor.computeLuminance() < 0.2;

    return Column(
      children: [
        // 本章完装饰分割线
        Row(
          children: [
            Expanded(
              child: Divider(
                color: theme.secondaryColor.withValues(alpha: 0.25),
                thickness: 0.8,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '本章完',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.secondaryColor.withValues(alpha: 0.75),
                  letterSpacing: 2.0,
                ),
              ),
            ),
            Expanded(
              child: Divider(
                color: theme.secondaryColor.withValues(alpha: 0.25),
                thickness: 0.8,
              ),
            ),
          ],
        ),

        // 仅当本章真实有评论 (total > 0) 时才展示本章评论卡片；无评论时保持页面干净清爽
        if (total > 0) ...[
          const SizedBox(height: 16),
          Center(
            child: InkWell(
              onTap: () => _openChapterComments(chapter),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : theme.highlightColor.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.secondaryColor.withValues(alpha: 0.25),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 16,
                      color: isDark ? Colors.white70 : theme.secondaryColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '本章评论 ($total条讨论)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : theme.textColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 11,
                      color: isDark ? Colors.white54 : theme.secondaryColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
              IconButton(
                icon: Icon(Icons.headphones_rounded, size: 22, color: theme.textColor),
                tooltip: '听书',
                onPressed: _startTtsReading,
              ),
              IconButton(
                icon: Icon(Icons.download_for_offline_outlined, size: 22, color: theme.textColor),
                tooltip: '批量离线',
                onPressed: _showQuickCacheModal,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startTtsReading() async {
    final tts = TtsService();
    if (tts.isActive) {
      if (tts.isPlaying) {
        tts.pause();
      } else {
        tts.resume();
      }
      return;
    }

    final chapter = widget.chapters[_currentActiveIndex];
    String? content = _chapterCache[_currentActiveIndex];
    if (content == null || content.isEmpty) {
      await _fetchChapterContent(_currentActiveIndex);
      content = _chapterCache[_currentActiveIndex];
    }

    if (content != null && content.isNotEmpty) {
      setState(() {
        _showControls = false;
      });

      // 精准计算当前屏幕视口正在展示的第一句完整的话
      int startChunk = 0;
      final key = _chapterKeys[_currentActiveIndex];
      final box = key?.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.attached) {
        final chapterPos = box.localToGlobal(Offset.zero);
        final chapterHeight = box.size.height;
        // 如果当前章节顶部已滚入视口上方（即已看了一部分）
        if (chapterPos.dy < 0 && chapterHeight > 0) {
          // 读者视线开始处（屏幕顶部约 40px 处）
          final visibleOffsetInChapter = -chapterPos.dy + 40.0;
          final fraction = (visibleOffsetInChapter / chapterHeight).clamp(0.0, 1.0);
          final chunks = tts.splitIntoChunks(content);
          if (chunks.isNotEmpty) {
            startChunk = (fraction * chunks.length).floor().clamp(0, chunks.length - 1);
          }
        }
      }

      tts.onChapterComplete = (lastChunkIdx) {
        if (_currentActiveIndex < widget.chapters.length - 1) {
          _startFromChapter(_currentActiveIndex + 1);
          _startTtsReading();
        }
      };
      await tts.startChapter(chapter.title, content, startChunk: startChunk);
    }
  }

  void _showQuickCacheModal() {
    final currentTheme = _themes[_themeIndex];
    final remainingCount = widget.chapters.length - _currentActiveIndex - 1;

    showModalBottomSheet(
      context: context,
      backgroundColor: currentTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
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
                '批量离线缓存',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: currentTheme.textColor,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '当前位置：第 ${_currentActiveIndex + 1} 章，后续未读 ${remainingCount > 0 ? remainingCount : 0} 章',
                style: TextStyle(fontSize: 12, color: currentTheme.secondaryColor),
              ),
              const SizedBox(height: 16),
              _buildCacheOptionTile(
                currentTheme,
                title: '缓存后续 20 章',
                subtitle: '适合通勤快速离线阅读',
                onTap: () => _triggerBatchDownload(20),
              ),
              _buildCacheOptionTile(
                currentTheme,
                title: '缓存后续 50 章',
                subtitle: '深度阅读推荐',
                onTap: () => _triggerBatchDownload(50),
              ),
              _buildCacheOptionTile(
                currentTheme,
                title: '缓存全书未读章节 (${remainingCount > 0 ? remainingCount : 0} 章)',
                subtitle: '离线保存整本剩余内容',
                onTap: () => _triggerBatchDownload(remainingCount),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCacheOptionTile(
    ReaderTheme theme, {
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: TextStyle(color: theme.textColor, fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(subtitle, style: TextStyle(color: theme.secondaryColor, fontSize: 12)),
      trailing: Icon(Icons.arrow_forward_ios, size: 14, color: theme.secondaryColor),
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
    );
  }

  void _triggerBatchDownload(int count) {
    if (count <= 0) return;
    final startIndex = _currentActiveIndex;
    final endIndex = (startIndex + count).clamp(0, widget.chapters.length);
    final targetChapters = widget.chapters.sublist(startIndex, endIndex);

    if (targetChapters.isEmpty) return;

    DownloadService().startBackgroundDownload(
      book: widget.book,
      chapters: targetChapters,
      format: 'TXT',
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已开始在后台离线 ${targetChapters.length} 章，可在顶栏下载管理查看进度'),
        duration: const Duration(seconds: 3),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              TextButton.icon(
                onPressed: _showDirectoryDrawer,
                icon: Icon(Icons.menu_book_outlined, color: theme.textColor, size: 20),
                label: Text('目录', style: TextStyle(color: theme.textColor)),
              ),
              TextButton.icon(
                onPressed: _startTtsReading,
                icon: Icon(Icons.headphones_outlined, color: theme.textColor, size: 20),
                label: Text('听书', style: TextStyle(color: theme.textColor)),
              ),
              TextButton.icon(
                onPressed: _showSettingsModal,
                icon: Icon(Icons.text_format, color: theme.textColor, size: 20),
                label: Text('排版设置', style: TextStyle(color: theme.textColor)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
