import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/comment.dart';
import '../models/bookmark.dart';
import '../models/reading_position.dart';
import '../models/reader_settings.dart';
import '../models/reader_theme.dart';
import '../services/reader_settings_repository.dart';
import '../services/reader_route_observer.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/reader_search_sheet.dart';
import '../services/reader_search_service.dart';
import '../services/reader_navigation_history.dart';

export '../models/reader_theme.dart';
import 'book_detail_screen.dart';
import '../services/api_service.dart';
import '../services/bookshelf_service.dart';
import '../services/bookmark_service.dart';
import '../services/download_service.dart';
import '../services/reading_history_service.dart';
import '../services/reader_system_service.dart';
import '../services/reader_pagination.dart';
import '../services/reader_position_service.dart';
import '../services/reader_font_service.dart';
import '../services/reader_cache_service.dart';
import '../services/reader_text.dart';
import '../services/tts_service.dart';
import '../widgets/tts_player_panel.dart';
import '../widgets/paragraph_comment_sheet.dart';
import '../widgets/reader_page_view.dart';
import '../widgets/reader_comment_bubble.dart';
import '../widgets/reader_cache_sheet.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final List<Chapter> chapters;
  final int initialChapterIndex;
  final bool resumeSavedPosition;
  final ReaderSettingsRecord? initialSettings;
  final Future<String?> Function(Chapter chapter)? chapterContentLoader;
  final Future<ChapterCommentStats?> Function(Chapter chapter)?
  chapterCommentStatsLoader;

  const ReaderScreen({
    super.key,
    required this.book,
    required this.chapters,
    this.initialChapterIndex = 0,
    this.resumeSavedPosition = true,
    this.initialSettings,
    this.chapterContentLoader,
    this.chapterCommentStatsLoader,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final ReaderSettingsRepository _settingsRepository = ReaderSettingsRepository();
  ReaderSettings _readerPreferences = const ReaderSettings();
  bool _bookSettingsOverride = false;
  PageRoute<dynamic>? _observedRoute;
  bool _readerRouteActive = true;
  bool _dependenciesReady = false;
  final ReaderNavigationHistory _jumpHistory = ReaderNavigationHistory();
  bool _navigationLoading = false;
  int _navigationGeneration = 0;
  ReaderSearchHit? _searchHighlight;
  final ApiService _apiService = ApiService();
  final BookshelfService _bookshelfService = BookshelfService();
  final ReadingHistoryService _readingHistoryService = ReadingHistoryService();
  final BookmarkService _bookmarkService = BookmarkService();
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  final ReaderPositionService _positionService = ReaderPositionService();
  final ReaderPaginationCache _pagination = ReaderPaginationCache();
  final Map<int, Future<void>> _chapterRequests = {};
  final Map<int, String> _chapterErrors = {};
  ReaderCachePolicy _cachePolicy = const ReaderCachePolicy();
  int _prefetchGeneration = 0;
  final LinkedHashSet<int> _prefetchQueue = LinkedHashSet();
  final Map<String, Future<void>> _commentRequests = {};
  final Map<int, ReaderChapterPages> _preparedPages = {};
  final Set<int> _warmingPages = {};
  final Map<int, Timer> _layoutWarmTimers = {};
  final GlobalKey<ReaderPageViewState> _pageViewKey = GlobalKey();
  final GlobalKey _verticalPaintKey = GlobalKey();
  final GlobalKey _pagePaintKey = GlobalKey();
  final ValueNotifier<bool> _controlsNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _autoRunningNotifier = ValueNotifier(false);
  final ValueNotifier<int> _autoControlsVersion = ValueNotifier(0);
  final ValueNotifier<int> _ttsHighlightNotifier = ValueNotifier(0);
  final ValueNotifier<int> _positionVersion = ValueNotifier(0);
  late final Listenable _paragraphSignals = Listenable.merge([
    _commentStatsVersionNotifier,
    _ttsHighlightNotifier,
  ]);
  ReaderLayout? _pageLayout;
  Object? _preparedLayoutKey;
  int _layoutGeneration = 0;
  int _notesVersion = 0;
  int _prefetchWorkers = 0;
  ReadingPosition? _readingPosition;
  _ReaderPageAddress? _chapterTransition;
  bool _positionNeedsReflow = true;
  bool _restoringPosition = false;
  bool _deferredPageRefresh = false;
  bool _deferredCommentRefresh = false;
  ui.Image? _restorationImage;
  Timer? _positionTimer;
  Timer? _preferencesTimer;
  Future<void> _preferencesWrites = Future.value();
  Future<void>? _notesRequest;
  Object? _ttsPaintKey;
  DateTime _manualScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastAutoElapsed = Duration.zero;
  bool _resumeAutoAfterLifecycle = false;
  bool _volumeAnimating = false;
  String? _queuedVolumeDirection;
  int _chapterOpenGeneration = 0;
  int? _requestedChapterIndex;
  Timer? _chapterWaitTimer;
  final ValueNotifier<bool> _chapterWaitingNotifier = ValueNotifier(false);
  final List<VoidCallback> _pendingSettings = [];
  bool _preferencesDirty = false;
  int _verticalRestoreGeneration = 0;
  final Map<String, double> _paragraphHeights = {};
  final Map<String, int> _chapterIndexById = {};
  final Map<Chapter, int> _chapterIndices = {};
  bool _windowRebaseScheduled = false;

  // 章节内容内存缓存
  final Map<int, String> _chapterCache = {};
  // 预分割章节段落缓存，避免 build 期间重复 split 造成卡顿
  final Map<int, List<String>> _chapterParagraphsCache = {};
  // 笔记划线 O(1) 索引缓存 ('${chapterIndex}_${paraIndex}' -> List<String>)
  final Map<String, List<String>> _notesByChapterPara = {};
  // 章节是否来自本地持久化离线/已下载存储
  final Map<int, bool> _chapterIsOffline = {};
  // 当前无限下拉中已渲染展示的章节索引列表
  final List<int> _displayedChapters = [];
  // 双向虚拟化滚动的中心锚点章节与 Sliver Key（向上追加章节零跳动）
  int _anchorChapterIndex = 0;
  Key _centerSliverKey = UniqueKey();
  final Map<int, GlobalKey> _chapterKeys = {};
  // 当前视口已挂载段落的轻量级上下文追踪表（仅保存视口附近 ~15-25 个段落）
  final Map<String, _MountedParagraphInfo> _mountedParagraphs = {};
  // 按需激活长按自由选词的段落 key（平时 100% 纯 Text.rich 零开销渲染）
  final ValueNotifier<String?> _activeSelectableParaNotifier = ValueNotifier<String?>(null);
  final GlobalKey _activeSelectableTextKey = GlobalKey();
  // 段评/章评统计异步更新局部通知器，避免滚动途中全屏 setState
  final ValueNotifier<int> _commentStatsVersionNotifier = ValueNotifier<int>(0);

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
  bool _isLoadingHead = true;
  bool _isLoadingPrev = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  bool get _showControls => _controlsNotifier.value;
  set _showControls(bool value) => _controlsNotifier.value = value;
  bool _isInBookshelf = false;
  bool _isCurrentChapterBookmarked = false;

  // 底部常驻微型状态信息（时间与电池电量）
  Timer? _statusTimer;
  String _currentTimeStr = '';
  int _batteryLevel = -1;
  late final ValueNotifier<String> _statusTextNotifier;

  // 用户偏好
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  int _themeIndex = 1; // 默认羊皮纸
  double _horizontalPadding = 20.0; // 页面边距：14 紧凑, 20 适中, 28 宽松
  bool _volumeKeyScroll = false; // 音量物理键翻页滚动
  bool get _canUseVolumeKeys =>
      _readerRouteActive && _volumeKeyScroll && !_ttsService.isActive && _readerPanels == 0;
  bool _showCommentBubbles = true; // 是否显示段评气泡
  bool _indentTwoChars = true; // 首行缩进两字符
  double _letterSpacing = 0.5; // 字间距
  double _paragraphSpacing = 14.0; // 段间距
  String _fontFamily = 'system'; // 字体设置
  bool _isPageMode = false; // 双模式切换：水平翻页 vs 连续滚屏
  String _pageTurnAnimation = 'cover'; // 左右翻页动画：cover(覆盖), simulation(仿真), slide(滑动), fade(渐变)
  int _currentHorizontalPageIndex = 0;
  DateTime _lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);
  List<ReadingNote> _cachedNotes = [];
  String _tapLayout = 'balanced';
  int _ttsStartGeneration = 0;
  int _readerPanels = 0;
  Completer<void>? _panelsClosed;
  final Map<String, List<Chapter>> _volumeGroups = {};

  // 沉浸式自动滚屏阅读
  bool _isAutoScrolling = false;
  double _autoScrollSpeed = 40.0; // px/s
  Ticker? _autoScrollTicker;

  String? _resolveFontFamily(String font) {
    switch (font) {
      case 'kaiti':
        return 'ReaderKaiTi';
      case 'serif':
        return 'ReaderSongTi';
      case 'sans-serif':
        return 'sans-serif';
      default:
        return null;
    }
  }

  static const List<ReaderTheme> _themes = ReaderTheme.presets;

  bool get _systemDark => _dependenciesReady
      ? MediaQuery.platformBrightnessOf(context) == Brightness.dark
      : WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dependenciesReady = true;
    final route = ModalRoute.of(context);
    if (route is PageRoute && !identical(route, _observedRoute)) {
      readerRouteObserver.unsubscribe(this);
      _observedRoute = route;
      readerRouteObserver.subscribe(this, route);
    }
    _refreshAutomaticTheme();
    _applyWindowBrightness();
  }

  @override
  void didPush() {
    _readerRouteActive = true;
    ReaderSystemService.setKeepScreenOn(true, owner: this);
    ReaderSystemService.registerVolumeKeyListener(_onVolumeScroll, owner: this);
    ReaderSystemService.setVolumeKeyScrollEnabled(_canUseVolumeKeys, owner: this);
    _applyWindowBrightness();
  }
  @override
  void didPushNext() {
    _readerRouteActive = false;
    ReaderSystemService.setKeepScreenOn(false, owner: this);
    _pauseAutoScroll();
    ReaderSystemService.setVolumeKeyScrollEnabled(false, owner: this);
    ReaderSystemService.restoreWindowBrightness(this);
  }
  @override
  void didPopNext() {
    didPush();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_readerRouteActive) return;
      _ttsPaintKey = null;
      _onTtsStateChanged();
    });
  }
  @override
  void didPop() {
    _readerRouteActive = false;
    ReaderSystemService.setKeepScreenOn(false, owner: this);
    _pauseAutoScroll();
    ReaderSystemService.setVolumeKeyScrollEnabled(false, owner: this);
    ReaderSystemService.restoreWindowBrightness(this);
  }
  @override
  void didChangePlatformBrightness() => _refreshAutomaticTheme();

  void _applyWindowBrightness() {
    if (!mounted || !_readerRouteActive) return;
    ReaderSystemService.setWindowBrightness(
      this, _readerPreferences.systemBrightness ? null : _readerPreferences.brightness,
    );
  }

  void _refreshAutomaticTheme() {
    if (!mounted) return;
    final next = _readerPreferences.effectiveTheme(systemDark: _systemDark, now: DateTime.now());
    if (next != _themeIndex) {
      _applyReaderSetting(() => _themeIndex = next, layoutChanged: false, persist: false);
    }
  }

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSettings;
    if (initial != null) {
      _bookSettingsOverride = initial.bookOverride;
      _assignReaderSettings(initial.settings);
    }
    _currentActiveIndex = widget.initialChapterIndex.clamp(
      0,
      widget.chapters.length - 1,
    );
    _anchorChapterIndex = _currentActiveIndex;
    _activeChapterNotifier = ValueNotifier<int>(_currentActiveIndex);
    _statusTextNotifier = ValueNotifier<String>('');
    var currentVolume = '正文';
    final volumePattern = RegExp(r'(第.+卷[^\s]*)');
    for (var index = 0; index < widget.chapters.length; index++) {
      final chapter = widget.chapters[index];
      _chapterIndexById[chapter.itemId] = index;
      _chapterIndices[chapter] = index;
      if (chapter.volumeTitle.isNotEmpty) {
        currentVolume = chapter.volumeTitle;
      } else if (chapter.title.contains('卷')) {
        currentVolume =
            volumePattern.firstMatch(chapter.title)?.group(1) ?? currentVolume;
      }
      _volumeGroups.putIfAbsent(currentVolume, () => []).add(chapter);
    }
    WidgetsBinding.instance.addObserver(this);
    ReaderCacheService.pinBook(widget.book.bookId);
    _autoScrollTicker = createTicker(_advanceAutoScroll);
    _checkBookshelfStatus();
    _checkBookmarkStatus();
    _bookmarkService.changeNotifier.addListener(_checkBookmarkStatus);
    _loadNotes();
    _bookmarkService.changeNotifier.addListener(_loadNotes);
    _activeSelectableParaNotifier.addListener(_onReaderSelectionChanged);
    _loadPreferences().then((_) async {
      final saved = widget.resumeSavedPosition
          ? await _positionService.loadSnapshot(widget.book.bookId)
          : null;
      if (!mounted) return;
      final target = saved?.resolve(widget.chapters);
      if (target != null) {
        _currentActiveIndex = target.chapterIndex;
        _activeChapterNotifier.value = target.chapterIndex;
        _anchorChapterIndex = target.chapterIndex;
        _readingPosition = target.position;
      }
      await _startFromChapter(_currentActiveIndex, preservePosition: true);
      if (mounted) {
        if (target?.notice != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(target!.notice!)),
          );
        }
        ReaderSystemService.setVolumeKeyScrollEnabled(_canUseVolumeKeys, owner: this);
      }
    });
    _scrollController.addListener(_onScroll);
    _ttsService.attachReader(widget.book.bookId);
    _ttsService.addListener(_onTtsStateChanged);

    // 启用阅读屏幕常亮与定时电量/时间更新
    ReaderSystemService.setKeepScreenOn(true, owner: this);
    ReaderSystemService.registerVolumeKeyListener(_onVolumeScroll, owner: this);
    _updateStatusInfo();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _updateStatusInfo(),
    );
  }

  @override
  void dispose() {
    _navigationGeneration++;
    readerRouteObserver.unsubscribe(this);
    ReaderSystemService.restoreWindowBrightness(this);
    _prefetchGeneration++;
    _prefetchQueue.clear();
    ReaderCacheService.unpinBook(widget.book.bookId);
    _apiService.engine.readerCache.trim(_cachePolicy.maxBytes).catchError(
      (_) => 0,
    );
    WidgetsBinding.instance.removeObserver(this);
    _positionTimer?.cancel();
    _preferencesTimer?.cancel();
    _chapterWaitTimer?.cancel();
    if (_panelsClosed != null && !_panelsClosed!.isCompleted) {
      _panelsClosed!.complete();
    }
    for (final timer in _layoutWarmTimers.values) {
      timer.cancel();
    }
    _savePositionNow(notify: false);
    _flushPreferences();
    _ttsService.removeListener(_onTtsStateChanged);
    _ttsService.detachReader(widget.book.bookId);
    _ttsStartGeneration++;
    // The service owns the playlist; leaving this route must not stop audio.
    _bookmarkService.changeNotifier.removeListener(_checkBookmarkStatus);
    _bookmarkService.changeNotifier.removeListener(_loadNotes);
    _activeSelectableParaNotifier.removeListener(_onReaderSelectionChanged);
    _activeChapterNotifier.dispose();
    _statusTextNotifier.dispose();
    _activeSelectableParaNotifier.dispose();
    _commentStatsVersionNotifier.dispose();
    _statusTimer?.cancel();
    _highlightTimer?.cancel();
    _autoScrollTicker?.dispose();
    _controlsNotifier.dispose();
    _autoRunningNotifier.dispose();
    _autoControlsVersion.dispose();
    _ttsHighlightNotifier.dispose();
    _positionVersion.dispose();
    _chapterWaitingNotifier.dispose();
    _restorationImage?.dispose();
    ReaderSystemService.setKeepScreenOn(false, owner: this);
    ReaderSystemService.setVolumeKeyScrollEnabled(false, owner: this);
    ReaderSystemService.registerVolumeKeyListener(null, owner: this);
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
    if (!mounted) return;
    final key = (
      _ttsService.isActive,
      _ttsService.isPlaying,
      _ttsService.currentChapterTitle,
      _ttsService.currentIndex,
      _ttsService.currentText,
    );
    if (key == _ttsPaintKey) return;
    _ttsPaintKey = key;
    ReaderSystemService.setVolumeKeyScrollEnabled(_canUseVolumeKeys, owner: this);
    _ttsHighlightNotifier.value++;
    if (_readerRouteActive && !_navigationLoading && _ttsService.isPlaying &&
        !_isAutoScrolling &&
        !_showControls &&
        !_restoringPosition &&
        _readerPanels == 0 &&
        _activeSelectableParaNotifier.value == null &&
        DateTime.now().isAfter(_manualScrollUntil) &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _autoScrollFollowTts();
    }
  }

  void _autoScrollFollowTts() {
    final position = _ttsService.currentPosition;
    if (position == null || _ttsService.currentBookId != widget.book.bookId) return;
    final chapterIndex = _chapterIndexById[position.chapterId];
    if (chapterIndex == null) return;
    if (_isPageMode || !_displayedChapters.contains(chapterIndex)) {
      unawaited(_startFromChapter(chapterIndex, position: position));
      return;
    }
    final paragraphs = _getChapterParagraphs(chapterIndex);
    if (position.paragraphIndex >= paragraphs.length) return;
    final paragraphIndex = position.paragraphIndex;
    final characterOffset = position.characterOffset;
    final chapter = widget.chapters[chapterIndex];
    final mounted = _mountedParagraphs['${chapter.itemId}_$paragraphIndex'];
    if (mounted == null || !mounted.context.mounted) {
      _readingPosition = ReadingPosition(
        chapterId: chapter.itemId,
        paragraphIndex: paragraphIndex,
        characterOffset: characterOffset,
        viewportFraction: 0.35,
      );
      _captureRestorationImage();
      _restoreVerticalPosition();
      return;
    }
    final render = mounted.context.findRenderObject() as RenderBox;
    final original = paragraphs[paragraphIndex].trim();
    final indent = _indentTwoChars ? '\u3000\u3000' : '';
    final painter = _paragraphPainter('$indent$original', render.size.width);
    final caret = painter
        .getOffsetForCaret(
          TextPosition(offset: characterOffset + indent.length),
          Rect.zero,
        )
        .dy;
    painter.dispose();
    final body = _verticalPaintKey.currentContext?.findRenderObject();
    if (body is! RenderBox || !body.hasSize) return;
    final delta =
        render.localToGlobal(Offset.zero).dy +
        caret -
        body.localToGlobal(Offset.zero).dy -
        body.size.height * 0.35;
    if (delta.abs() < 35) return;
    final scrollPosition = _scrollController.position;
    _scrollController.animateTo(
      (_scrollController.offset + delta).clamp(
        scrollPosition.minScrollExtent,
        scrollPosition.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _updateStatusInfo() async {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final battery = await ReaderSystemService.getBatteryLevel();
    if (mounted) {
      _currentTimeStr = '$hour:$minute';
      _batteryLevel = battery;
      _statusTextNotifier.value = '$_currentTimeStr|$_batteryLevel';
      _refreshAutomaticTheme();
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

  Future<void> _checkBookmarkStatus() async {
    await _bookmarkService.initialize();
    final bookmarked = await _bookmarkService.isChapterBookmarked(
      widget.book.bookId,
      _currentActiveIndex,
    );
    if (mounted && _isCurrentChapterBookmarked != bookmarked) {
      if (_showControls) {
        setState(() {
          _isCurrentChapterBookmarked = bookmarked;
        });
      } else {
        _isCurrentChapterBookmarked = bookmarked;
      }
    }
  }

  Future<void> _loadNotes() {
    final pending = _notesRequest;
    if (pending != null) return pending;
    final request = _readNotes().whenComplete(() => _notesRequest = null);
    _notesRequest = request;
    return request;
  }

  Future<void> _readNotes() async {
    await _bookmarkService.initialize();
    final notes = await _bookmarkService.getNotes(widget.book.bookId);
    if (!mounted) return;
    final old = Object.hashAll(
      _cachedNotes.map((note) => (note.id, note.text, note.note)),
    );
    final next = Object.hashAll(
      notes.map((note) => (note.id, note.text, note.note)),
    );
    if (old == next) return;
    setState(() {
      _cachedNotes = notes;
      _rebuildNotesIndex(notes);
      _notesVersion++;
    });
  }

  /// 构建笔记划线 O(1) 哈希索引，避免在每个段落 build 时遍历全书笔记
  void _rebuildNotesIndex(List<ReadingNote> notes) {
    _notesByChapterPara.clear();
    for (final n in notes) {
      final t = n.text.trim();
      if (t.isEmpty) continue;
      final key = '${n.chapterIndex}_${n.paragraphIndex}';
      final list = _notesByChapterPara.putIfAbsent(key, () => <String>[]);
      if (!list.contains(t)) {
        list.add(t);
      }
    }
  }

  /// O(1) 获取指定章节与段落的划线词句列表
  List<String> _getParaUnderlines(
    int chapterIndex,
    int paraIndex, {
    bool includeChapterWide = false,
  }) {
    final exact = _notesByChapterPara['${chapterIndex}_$paraIndex'];
    if (!includeChapterWide) {
      return exact ?? const [];
    }
    final wide = _notesByChapterPara['${chapterIndex}_-1'];
    if (exact == null && wide == null) return const [];
    if (wide == null) return exact!;
    if (exact == null) return wide;
    return {...exact, ...wide}.toList();
  }

  /// 获取预分割的章节段落列表（带内存缓存，杜绝 build 期重复 split）
  List<String> _getChapterParagraphs(int chapterIndex) {
    final cached = _chapterParagraphsCache[chapterIndex];
    if (cached != null) return cached;
    final content = _chapterCache[chapterIndex];
    if (content == null || content.isEmpty) return const [];
    final split = content.split('\n\n');
    _chapterParagraphsCache[chapterIndex] = split;
    return split;
  }

  Future<void> _toggleBookmark() async {
    final bookmarked = await _bookmarkService.isChapterBookmarked(
      widget.book.bookId,
      _currentActiveIndex,
    );
    if (bookmarked) {
      await _bookmarkService.removeBookmarkByChapter(
        widget.book.bookId,
        _currentActiveIndex,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已移除书签'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } else {
      final chapter = widget.chapters[_currentActiveIndex];
      final captured = _captureReadingPosition();
      final position = captured?.chapterId == chapter.itemId ? captured : null;
      final paragraphs = _getChapterParagraphs(_currentActiveIndex);
      final paragraphIndex = (position?.paragraphIndex ?? 0)
          .clamp(0, math.max(0, paragraphs.length - 1))
          .toInt();
      final preview =
          (paragraphs.isEmpty ? null : paragraphs[paragraphIndex].trim()) ??
          chapter.title;
      await _bookmarkService.addBookmark(
        bookId: widget.book.bookId,
        chapterIndex: _currentActiveIndex,
        chapterTitle: chapter.title,
        paragraphIndex: paragraphIndex,
        characterOffset: position?.characterOffset ?? 0,
        contentPreview: preview,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('书签添加成功'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
    _checkBookmarkStatus();
  }

  ReaderSettings _captureReaderSettings() => _readerPreferences.copyWith(
    fontSize: _fontSize, lineHeight: _lineHeight, letterSpacing: _letterSpacing,
    paragraphSpacing: _paragraphSpacing, horizontalPadding: _horizontalPadding,
    fontFamily: _fontFamily, indent: _indentTwoChars, pageMode: _isPageMode,
    pageAnimation: _pageTurnAnimation, commentBubbles: _showCommentBubbles,
    volumeKeys: _volumeKeyScroll, tapLayout: _tapLayout,
  );

  void _assignReaderSettings(ReaderSettings value) {
    _readerPreferences = value;
    _fontSize = value.fontSize;
    _lineHeight = value.lineHeight;
    _letterSpacing = value.letterSpacing;
    _paragraphSpacing = value.paragraphSpacing;
    _horizontalPadding = value.horizontalPadding;
    _fontFamily = value.fontFamily;
    _indentTwoChars = value.indent;
    _isPageMode = value.pageMode;
    _pageTurnAnimation = value.pageAnimation;
    _showCommentBubbles = value.commentBubbles;
    _volumeKeyScroll = value.volumeKeys;
    _tapLayout = value.tapLayout;
    _themeIndex = value.effectiveTheme(systemDark: _systemDark, now: DateTime.now());
  }

  Object _layoutPreferences(ReaderSettings value) => (
    value.fontSize, value.lineHeight, value.letterSpacing, value.paragraphSpacing,
    value.horizontalPadding, value.fontFamily, value.indent,
    value.pageMode, value.commentBubbles,
  );

  Future<void> _receiveSettings(ReaderSettings value, bool bookOverride) async {
    if (!mounted) return;
    final before = _captureReaderSettings();
    final changedLayout = _layoutPreferences(before) != _layoutPreferences(value);
    final changedPaint = _themeIndex != value.effectiveTheme(systemDark: _systemDark, now: DateTime.now()) ||
        before.pageAnimation != value.pageAnimation || before.tapLayout != value.tapLayout;
    void apply() {
      _assignReaderSettings(value);
      _bookSettingsOverride = bookOverride;
      _applyWindowBrightness();
      ReaderSystemService.setVolumeKeyScrollEnabled(_canUseVolumeKeys, owner: this);
    }
    if (changedLayout || changedPaint) {
      _applyReaderSetting(apply, layoutChanged: changedLayout, persist: false);
    } else {
      // Brightness slider previews must not rebuild or re-paginate the text.
      apply();
    }
  }

  Future<void> _loadPreferences() async {
    _cachePolicy = await ReaderCachePolicy.load();
    final record = widget.initialSettings ?? await _settingsRepository.load(widget.book.bookId);
    if (!mounted) return;
    _bookSettingsOverride = record.bookOverride;
    setState(() => _assignReaderSettings(record.settings));
    _applyWindowBrightness();
    try {
      await ReaderFontService.ensureLoaded(_fontFamily);
    } catch (_) {
      if (mounted) setState(() => _fontFamily = 'system');
    }
  }

  void _savePreferences() {
    _preferencesDirty = true;
    _preferencesTimer?.cancel();
    _preferencesTimer = Timer(
      const Duration(milliseconds: 250),
      _flushPreferences,
    );
  }

  Future<void> _flushPreferences() {
    _preferencesTimer?.cancel();
    if (!_preferencesDirty) return _preferencesWrites;
    _preferencesDirty = false;
    final settings = _captureReaderSettings();
    final scope = _bookSettingsOverride ? widget.book.bookId : null;
    _preferencesWrites = _preferencesWrites.catchError((_) {}).then((_) async {
      await _settingsRepository.save(settings, bookId: scope);
    }).catchError((_) {
      _preferencesDirty = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('阅读设置暂未保存，请检查存储空间')),
      );
      }
    });
    return _preferencesWrites;
  }

  void _onVolumeScroll(String direction) {
    if (!mounted ||
        !_canUseVolumeKeys ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    if (_navigationLoading) {
      _cancelNavigation();
      return;
    }
    if (_isPageMode) {
      if (direction == 'down') {
        _pageViewKey.currentState?.turnToNextPage();
      } else {
        _pageViewKey.currentState?.turnToPreviousPage();
      }
      return;
    }
    if (_activeSelectableParaNotifier.value != null) {
      _activeSelectableParaNotifier.value = null;
      return;
    }
    _pauseAutoScroll();
    if (_volumeAnimating) {
      _queuedVolumeDirection = direction;
      return;
    }
    _animateVolumeScroll(direction);
  }

  Future<void> _animateVolumeScroll(String direction) async {
    if (!_scrollController.hasClients) return;
    _volumeAnimating = true;
    _manualScrollUntil = DateTime.now().add(const Duration(seconds: 3));
    try {
      final height = MediaQuery.sizeOf(context).height * 0.75;
      final position = _scrollController.position;
      await _scrollController.animateTo(
        (_scrollController.offset + (direction == 'down' ? height : -height))
            .clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _volumeAnimating = false;
      if (mounted) {
        _schedulePositionSave();
        final queued = _queuedVolumeDirection;
        _queuedVolumeDirection = null;
        if (queued != null) _animateVolumeScroll(queued);
      }
    }
  }

  /// 保存当前章节进度到 SharedPreferences、书架和阅读历史
  Future<void> _persistReadingProgress(int index) async {
    if (index < 0 || index >= widget.chapters.length) return;
    final chapter = widget.chapters[index];

    try {
      await _writeReadingSnapshot(
        _readingPosition?.chapterId == chapter.itemId
            ? _readingPosition!
            : ReadingPosition(chapterId: chapter.itemId),
        updateSummary: true,
      );
    } catch (_) {}
  }

  Future<void> _writeReadingSnapshot(
    ReadingPosition position, {
    bool updateSummary = false,
  }) {
    final index = _chapterIndexById[position.chapterId];
    if (index == null) return Future.value();
    final chapter = widget.chapters[index];
    return _positionService.save(
      widget.book.bookId,
      position,
      chapterIndex: index,
      chapterTitle: chapter.title,
      previousChapterId: index > 0 ? widget.chapters[index - 1].itemId : null,
      nextChapterId: index + 1 < widget.chapters.length
          ? widget.chapters[index + 1].itemId
          : null,
      onCommitted: updateSummary
          ? () async {
              await _readingHistoryService.recordReading(
                book: widget.book,
                chapterIndex: index,
                chapterTitle: chapter.title,
              );
              if (_isInBookshelf) {
                await _bookshelfService.updateReadingProgress(
                  widget.book.bookId, index, chapter.title,
                );
              }
            }
          : null,
    );
  }

  ReadingPosition? _captureReadingPosition() {
    if (_restoringPosition) return _readingPosition;
    if (_isPageMode) {
      if (_pageViewKey.currentState?.isBusy == true) return _readingPosition;
      final id = _pageViewKey.currentState?.currentPageId;
      if (id is _ReaderPageAddress) {
        final anchor = _readingPosition;
        if (anchor?.chapterId == id.layout.chapterId &&
            id.layout.pageFor(anchor!) == id.pageIndex) {
          return anchor;
        }
        return id.page.position(id.layout.chapterId);
      }
      return _readingPosition;
    }
    final boundary = _verticalPaintKey.currentContext?.findRenderObject();
    if (boundary is! RenderBox || !boundary.hasSize) return _readingPosition;
    final top = boundary.localToGlobal(Offset.zero).dy;
    final target = top + 24;
    _MountedParagraphInfo? nearest;
    var distance = double.infinity;
    for (final info in _mountedParagraphs.values) {
      final render = info.context.mounted
          ? info.context.findRenderObject()
          : null;
      if (render is! RenderBox || !render.attached || !render.hasSize) continue;
      final y = render.localToGlobal(Offset.zero).dy;
      final d = y <= target && y + render.size.height >= target
          ? 0.0
          : (y - target).abs();
      if (d < distance) {
        nearest = info;
        distance = d;
      }
    }
    if (nearest == null) return _readingPosition;
    final render = nearest.context.findRenderObject() as RenderBox;
    final y = render.localToGlobal(Offset.zero).dy;
    final original = _getChapterParagraphs(
      nearest.chapterIndex,
    )[nearest.paraIndex].trim();
    final prefix = _indentTwoChars ? '\u3000\u3000' : '';
    final painter = _paragraphPainter('$prefix$original', render.size.width);
    try {
      final position = painter.getPositionForOffset(
        Offset(0, (target - y).clamp(0.0, painter.height)),
      );
      final offset = (painter.getLineBoundary(position).start - prefix.length)
          .clamp(0, original.length);
      final caret = painter.getOffsetForCaret(
        TextPosition(offset: offset + prefix.length),
        Rect.zero,
      );
      return ReadingPosition(
        chapterId: widget.chapters[nearest.chapterIndex].itemId,
        paragraphIndex: nearest.paraIndex,
        characterOffset: offset,
        viewportFraction: ((y + caret.dy - top) / boundary.size.height).clamp(
          0.0,
          1.0,
        ),
      );
    } finally {
      painter.dispose();
    }
  }

  TextPainter _paragraphPainter(String text, double width) => TextPainter(
    text: TextSpan(text: text, style: _readerBodyStyle()),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, width).toDouble());

  TextStyle _readerBodyStyle({Color? color}) => TextStyle(
    inherit: false,
    color: color,
    fontSize: _fontSize,
    height: _lineHeight,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: FontWeight.normal,
    textBaseline: TextBaseline.alphabetic,
    letterSpacing: _letterSpacing,
    wordSpacing: 0,
    fontFamily: _resolveFontFamily(_fontFamily) ?? 'Roboto',
  );

  double _estimatedParagraphHeight(int chapterIndex, int paragraphIndex) {
    final key = '${widget.chapters[chapterIndex].itemId}_$paragraphIndex';
    final cached = _paragraphHeights[key];
    if (cached != null) return cached;
    final original = _getChapterParagraphs(chapterIndex)[paragraphIndex].trim();
    final painter = _paragraphPainter(
      '${_indentTwoChars ? '\u3000\u3000' : ''}$original',
      MediaQuery.sizeOf(context).width - _horizontalPadding * 2,
    );
    final height = painter.height + _paragraphSpacing;
    painter.dispose();
    return height;
  }

  void _schedulePositionSave() {
    if (_positionTimer?.isActive == true) return;
    _positionTimer = Timer(const Duration(milliseconds: 500), _savePositionNow);
  }

  Future<void> _savePositionNow({bool notify = true}) {
    if (mounted) {
      _readingPosition = _captureReadingPosition() ?? _readingPosition;
    }
    if (mounted && notify) _positionVersion.value++;
    final position = _readingPosition;
    return position == null
        ? Future.value()
        : _writeReadingSnapshot(position).catchError((_) {
            if (mounted && notify) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('阅读位置暂未保存，请检查存储空间')),
              );
            }
          });
  }

  void _captureRestorationImage({bool fromPage = false}) {
    final boundary = (fromPage ? _pagePaintKey : _verticalPaintKey)
        .currentContext
        ?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.hasSize ||
        (kDebugMode && boundary.debugNeedsPaint)) {
      return;
    }
    final old = _restorationImage;
    _restorationImage = boundary.toImageSync(
      pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0),
    );
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  void _dropRestorationImage() {
    final image = _restorationImage;
    if (image == null || !mounted) return;
    setState(() => _restorationImage = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  Future<void> _restoreVerticalPosition() async {
    final generation = ++_verticalRestoreGeneration;
    final position = _readingPosition;
    if (_isPageMode || position == null) {
      _dropRestorationImage();
      return;
    }
    final targetChapterIndex =
        _chapterIndexById[position.chapterId] ?? _currentActiveIndex;
    _restoringPosition = true;
    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted ||
            generation != _verticalRestoreGeneration ||
            _isPageMode) {
          return;
        }
        if (!_scrollController.hasClients) continue;
        final paragraphs = _getChapterParagraphs(targetChapterIndex);
        if (paragraphs.isEmpty) break;
        final targetIndex = position.paragraphIndex.clamp(
          0,
          paragraphs.length - 1,
        );
        if (targetIndex == 0 &&
            position.characterOffset == 0 &&
            position.viewportFraction == 0) {
          _scrollController.jumpTo(0);
          break;
        }
        final body = _verticalPaintKey.currentContext?.findRenderObject();
        if (body is! RenderBox || !body.hasSize) continue;
        final line =
            body.localToGlobal(Offset.zero).dy +
            (position.viewportFraction > 0
                ? body.size.height * position.viewportFraction
                : 24);
        final original = paragraphs[targetIndex].trim();
        final prefix = _indentTwoChars ? '\u3000\u3000' : '';
        final painter = _paragraphPainter(
          '$prefix$original',
          body.size.width - _horizontalPadding * 2,
        );
        final caret = painter
            .getOffsetForCaret(
              TextPosition(
                offset:
                    position.characterOffset.clamp(0, original.length) +
                    prefix.length,
              ),
              Rect.zero,
            )
            .dy;
        painter.dispose();
        final key =
            '${widget.chapters[targetChapterIndex].itemId}_$targetIndex';
        final target = _mountedParagraphs[key];
        double delta;
        if (target != null && target.context.mounted) {
          final box = target.context.findRenderObject() as RenderBox;
          delta = box.localToGlobal(Offset.zero).dy + caret - line;
        } else {
          final candidates =
              _mountedParagraphs.values
                  .where(
                    (info) =>
                        info.chapterIndex == targetChapterIndex &&
                        info.context.mounted,
                  )
                  .toList()
                ..sort(
                  (a, b) => (a.paraIndex - targetIndex).abs().compareTo(
                    (b.paraIndex - targetIndex).abs(),
                  ),
                );
          if (candidates.isEmpty) {
            SchedulerBinding.instance.scheduleFrame();
            continue;
          }
          final nearest = candidates.first;
          final nearestContext = nearest.context;
          if (!nearestContext.mounted) continue;
          final box = nearestContext.findRenderObject() as RenderBox;
          delta = box.localToGlobal(Offset.zero).dy + caret - line;
          if (nearest.paraIndex < targetIndex) {
            for (var index = nearest.paraIndex; index < targetIndex; index++) {
              delta += _estimatedParagraphHeight(targetChapterIndex, index);
            }
          } else {
            for (var index = targetIndex; index < nearest.paraIndex; index++) {
              delta -= _estimatedParagraphHeight(targetChapterIndex, index);
            }
          }
        }
        final scroll = _scrollController.position;
        final offset = (_scrollController.offset + delta).clamp(
          scroll.minScrollExtent,
          scroll.maxScrollExtent,
        );
        _scrollController.jumpTo(offset);
        if (target != null) break;
      }
    } finally {
      if (mounted && generation == _verticalRestoreGeneration) {
        _restoringPosition = false;
        _lastDetectPixels = _scrollController.hasClients
            ? _scrollController.offset
            : 0;
        _dropRestorationImage();
      }
    }
  }

  void _applyReaderSetting(VoidCallback action, {bool layoutChanged = true, bool persist = true}) {
    if (!mounted) return;
    if (_pageViewKey.currentState?.isBusy == true) {
      _pendingSettings.add(
        () => _applyReaderSetting(action, layoutChanged: layoutChanged, persist: persist),
      );
      return;
    }
    if (layoutChanged) {
      _readingPosition = _captureReadingPosition() ?? _readingPosition;
      if (!_isPageMode) _captureRestorationImage();
    }
    final previousMode = _isPageMode;
    setState(() {
      action();
      if (layoutChanged) {
        _positionNeedsReflow = true;
        _paragraphHeights.clear();
      }
      if (previousMode != _isPageMode) {
        if (_isPageMode) {
          _isAutoScrolling = false;
          _pauseAutoScroll();
        }
        _chapterOpenGeneration++;
        _requestedChapterIndex = null;
        _chapterTransition = null;
        _chapterWaitTimer?.cancel();
        _chapterWaitingNotifier.value = false;
        _anchorChapterIndex = _currentActiveIndex;
        _centerSliverKey = UniqueKey();
        _displayedChapters.clear();
        _displayedChapters.add(_currentActiveIndex);
        _chapterKeys[_currentActiveIndex] = GlobalKey();
      }
    });
    if (previousMode && !_isPageMode) {
      _captureRestorationImage(fromPage: true);
    }
    if (persist) _savePreferences();
    if (layoutChanged && !_isPageMode) _restoreVerticalPosition();
    if (_isPageMode) _dropRestorationImage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_readerRouteActive) ReaderSystemService.setKeepScreenOn(true, owner: this);
      _refreshAutomaticTheme();
      _applyWindowBrightness();
      _ttsPaintKey = null;
      _onTtsStateChanged();
      if (_readerRouteActive && _resumeAutoAfterLifecycle && _isAutoScrolling) _startAutoScroll();
      _resumeAutoAfterLifecycle = false;
    } else {
      _savePositionNow();
      _flushPreferences();
      _resumeAutoAfterLifecycle = _autoScrollTicker?.isActive ?? false;
      _pauseAutoScroll();
    }
  }

  void _cancelNavigation() {
    _navigationGeneration++;
    if (!_navigationLoading || !mounted) return;
    _chapterOpenGeneration++;
    _requestedChapterIndex = null;
    if (_pageViewKey.currentState?.isBusy != true) _chapterTransition = null;
    _readingPosition = _captureReadingPosition() ?? _readingPosition;
    setState(() {
      _navigationLoading = false;
      _positionNeedsReflow = true;
    });
  }

  Future<bool> _navigateTo(
    ReadingPosition target, {
    bool remember = true,
    String? locateText,
    ReaderSearchHit? searchHit,
  }) async {
    if (!mounted) return false;
    final index = _chapterIndexById[target.chapterId];
    if (index == null) return false;
    final generation = ++_navigationGeneration;
    final origin = _captureReadingPosition() ?? _readingPosition;
    _stopAutoScroll();
    _chapterOpenGeneration++;
    _requestedChapterIndex = index;
    _chapterWaitTimer?.cancel();
    _chapterWaitingNotifier.value = false;
    _pageViewKey.currentState?.clearQueuedTurns();
    setState(() {
      _readingPosition = origin;
      _searchHighlight = null;
      _navigationLoading = true;
      _positionNeedsReflow = true;
    });
    try {
      // Explicit jumps stop this book's speech rather than letting a later
      // spoken chunk pull the reader back. The next play starts at the new view.
      if (_ttsService.isActive && _ttsService.currentBookId == widget.book.bookId) {
        await _ttsService.stop();
      }
      await _fetchChapterContent(index);
      if (!mounted || generation != _navigationGeneration) return false;
      if (!_chapterCache.containsKey(index)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_chapterErrors[index] ?? '章节暂未就绪，原阅读位置已保留'),
        ));
        return false;
      }
      if (searchHit != null) {
        final paragraphs = _getChapterParagraphs(index);
        final paragraph = target.paragraphIndex < paragraphs.length
            ? paragraphs[target.paragraphIndex].trim() : '';
        if (target.characterOffset > paragraph.length ||
            searchHit.endOffset > paragraph.length ||
            paragraph.substring(target.characterOffset, searchHit.endOffset) != searchHit.quote) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('正文已有变化，请重新搜索；原阅读位置已保留')),
          );
          return false;
        }
      }
      // The return toolbar has a stable place in layout, never covers text.
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted || generation != _navigationGeneration) return false;
      _requestedChapterIndex = null;
      await _startFromChapter(index, position: target, locateText: locateText);
      if (!mounted || generation != _navigationGeneration) return false;
      if (remember && origin != null) {
        setState(() => _jumpHistory.record(origin, target));
      }
      _showControls = false;
      if (searchHit != null) _searchHighlight = searchHit;
      if (locateText == null) _highlightPosition(target);
      return true;
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _requestedChapterIndex = null;
        setState(() => _navigationLoading = false);
      }
    }
  }

  Future<void> _returnFromJump() async {
    final target = _jumpHistory.previous;
    if (target == null) return;
    if (await _navigateTo(target, remember: false) && mounted) {
      setState(() {
        _jumpHistory.returnedTo(target);
        _readingPosition = target;
        _positionNeedsReflow = true;
      });
      if (!_isPageMode) _restoreVerticalPosition();
    }
  }

  Widget _buildJumpBar(ReaderTheme theme) => SizedBox(
    height: math.max(48, MediaQuery.textScalerOf(context).scale(13) * 1.5 + 12),
    child: Material(color: theme.backgroundColor, child: Row(children: [
      Expanded(child: _navigationLoading
        ? Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Expanded(child: Text('正在准备章节，点击正文可取消',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: theme.secondaryColor))),
            ]))
        : TextButton.icon(
            key: const ValueKey('reader_jump_back'),
            onPressed: _returnFromJump, icon: Icon(Icons.undo, color: theme.textColor),
            label: Text('返回原阅读位置', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textColor, fontSize: 13)),
          )),
      IconButton(
        tooltip: _navigationLoading ? '取消跳转' : '清空跳转记录',
        icon: Icon(Icons.close, color: theme.secondaryColor),
        onPressed: _navigationLoading ? _cancelNavigation : () {
          _readingPosition = _captureReadingPosition() ?? _readingPosition;
          setState(() { _jumpHistory.clear(); _positionNeedsReflow = true; });
        },
      ),
    ])),
  );

  Future<void> _showReaderSearch() async {
    if (_readerPanels > 0) return;
    _beginReaderPanel();
    ReaderSearchHit? hit;
    try {
      final position = _captureReadingPosition();
      hit = await showModalBottomSheet<ReaderSearchHit>(
        context: context, isScrollControlled: true,
        backgroundColor: _themes[_themeIndex].backgroundColor,
        builder: (context) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: FractionallySizedBox(heightFactor: .9, child: ReaderSearchSheet(
            bookId: widget.book.bookId, chapters: widget.chapters,
            chapterIndex: _chapterIndexById[position?.chapterId] ?? _currentActiveIndex,
            canonicalMemory: {
              for (final entry in _chapterCache.entries)
                widget.chapters[entry.key].itemId: entry.value,
            },
            theme: _themes[_themeIndex],
          )),
        ),
      );
    } finally {
      _endReaderPanel();
    }
    if (mounted && hit != null) await _navigateTo(hit.position, searchHit: hit);
  }

  /// 从指定章节重新开始连续阅读（重置滚动列表）
  Future<void> _startFromChapter(
    int index, {
    bool toLastPage = false,
    bool preservePosition = false,
    ReadingPosition? position,
    String? locateText,
  }) async {
    if (index < 0 ||
        index >= widget.chapters.length ||
        _requestedChapterIndex == index) {
      return;
    }
    final generation = ++_chapterOpenGeneration;
    _pageViewKey.currentState?.clearQueuedTurns();
    _requestedChapterIndex = index;
    final hasVisibleContent = _chapterCache.containsKey(_currentActiveIndex);
    if (!hasVisibleContent) setState(() => _isLoadingHead = true);
    _chapterWaitTimer?.cancel();
    _chapterWaitTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted && generation == _chapterOpenGeneration) {
        _chapterWaitingNotifier.value = true;
      }
    });
    try {
      await _fetchChapterContent(index);
      if (!mounted || generation != _chapterOpenGeneration) return;
      if (!_chapterCache.containsKey(index)) {
        if (hasVisibleContent) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(
            content: Text(
              '${_chapterErrors[index] ?? '章节暂未就绪'}；当前阅读位置已保留',
            ),
            action: SnackBarAction(
              label: '重试',
              onPressed: () => _startFromChapter(
                index, position: position, toLastPage: toLastPage,
              ),
            ),
          ));
        } else {
          setState(() {
            _isLoadingHead = false;
            _errorMessage = _chapterErrors[index] ?? '本章内容加载失败，请重试';
          });
        }
        return;
      }
      var requestedPosition =
          position ??
          (preservePosition ? _readingPosition : null) ??
          ReadingPosition(chapterId: widget.chapters[index].itemId);
      if (locateText != null) {
        final paragraphs = _getChapterParagraphs(index);
        var paragraph = requestedPosition.paragraphIndex
            .clamp(0, math.max(0, paragraphs.length - 1))
            .toInt();
        var character = paragraphs.isEmpty
            ? -1
            : paragraphs[paragraph].trim().indexOf(locateText.trim());
        if (character < 0) {
          for (var candidate = 0; candidate < paragraphs.length; candidate++) {
            final match = paragraphs[candidate].trim().indexOf(
              locateText.trim(),
            );
            if (match >= 0) {
              paragraph = candidate;
              character = match;
              break;
            }
          }
        }
        requestedPosition = ReadingPosition(
          chapterId: widget.chapters[index].itemId,
          paragraphIndex: paragraph,
          characterOffset: math.max(0, character),
        );
        _highlightPosition(requestedPosition);
      }
      final layout = _pageLayout;
      if (_isPageMode && hasVisibleContent && layout != null) {
        await SchedulerBinding.instance.endOfFrame;
        if (_readerPanels > 0) await _panelsClosed?.future;
        if (!mounted || generation != _chapterOpenGeneration) return;
        final pages = _preparePages(index, _pageLayout ?? layout);
        while (mounted &&
            (_readerPanels > 0 || _pageViewKey.currentState?.isBusy == true)) {
          if (_readerPanels > 0) {
            await _panelsClosed?.future;
          } else {
            await SchedulerBinding.instance.endOfFrame;
          }
        }
        if (!mounted || generation != _chapterOpenGeneration) return;
        final target = _ReaderPageAddress(
          index,
          toLastPage
              ? pages.pages.length - 1
              : pages.pageFor(requestedPosition),
          pages,
          anchor: toLastPage ? null : requestedPosition,
        );
        final currentId = _pageViewKey.currentState?.currentPageId;
        if (currentId == target) {
          _readingPosition = requestedPosition;
          _schedulePositionSave();
          return;
        }
        final source = currentId is _ReaderPageAddress
            ? currentId
            : _ReaderPageAddress(
                _currentActiveIndex,
                _currentHorizontalPageIndex,
                _preparePages(_currentActiveIndex, _pageLayout ?? layout),
              );
        setState(() => _chapterTransition = target);
        // 数据准备完再加入真实目标页；等待视图对齐后，沿用普通翻页动画。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              generation != _chapterOpenGeneration ||
              _chapterTransition == null) {
            return;
          }
          final actualSource = _pageViewKey.currentState?.currentPageId;
          if (_chapterTransition!.isBefore(
            actualSource is _ReaderPageAddress ? actualSource : source,
          )) {
            _pageViewKey.currentState?.turnToPreviousPage();
          } else {
            _pageViewKey.currentState?.turnToNextPage();
          }
        });
      } else {
        if (hasVisibleContent && !_isPageMode) _captureRestorationImage();
        setState(() {
          _currentActiveIndex = index;
          _activeChapterNotifier.value = index;
          _anchorChapterIndex = index;
          _centerSliverKey = UniqueKey();
          _currentHorizontalPageIndex = 0;
          _readingPosition = requestedPosition;
          _positionNeedsReflow = true;
          _displayedChapters.clear();
          _displayedChapters.add(index);
          _mountedParagraphs.clear();
          _chapterKeys[index] = GlobalKey();
          _activeSelectableParaNotifier.value = null;
          _isLoadingHead = false;
          _errorMessage = null;
        });
        _persistReadingProgress(index);
        if (!_isPageMode) _restoreVerticalPosition();
        _triggerSilentPrefetch(index);
        if (!_isPageMode) _autoAppendNextChapter();
      }
    } finally {
      if (mounted && generation == _chapterOpenGeneration) {
        _requestedChapterIndex = null;
        _chapterWaitTimer?.cancel();
        _chapterWaitingNotifier.value = false;
      }
    }
  }

  /// 滚动监听：节流局部检测活跃章节 + 双向无限滚动（极速丝滑不掉帧）
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_restoringPosition) return;
    _schedulePositionSave();

    // 滚动开始时自动收起已激活的段落选词句柄，保持 100% 轻量绘制
    if (_activeSelectableParaNotifier.value != null) {
      _activeSelectableParaNotifier.value = null;
    }

    final pos = _scrollController.position;
    final currentPixels = pos.pixels;

    // 1. 节流检测当前视口可见的章节（位移超过 50px 时才做轻量局部探测，极大提升长文滚屏流畅度）
    if ((currentPixels - _lastDetectPixels).abs() >= 50.0) {
      _lastDetectPixels = currentPixels;
      _detectCurrentVisibleChapterOptimized();
    }

    // 2. 距离顶部 300px 时自动预加载并追加上一章 (实现无缝双向无限滚动)
    if (currentPixels - pos.minScrollExtent <= 300 &&
        _displayedChapters.isNotEmpty &&
        _displayedChapters.first > 0) {
      _autoPrependPreviousChapter();
    }

    // 3. 距离底部 800px 时自动预加载并追加下一章
    if (currentPixels >= pos.maxScrollExtent - 800) {
      _autoAppendNextChapter();
    }
  }

  bool _onVerticalScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        _restoringPosition) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _manualScrollUntil = DateTime.now().add(const Duration(seconds: 3));
      _pauseAutoScroll();
    } else if (notification is ScrollEndNotification) {
      if (_deferredCommentRefresh) {
        _deferredCommentRefresh = false;
        _commentStatsVersionNotifier.value++;
      }
      _maintainReadingWindow();
    }
    return false;
  }

  void _maintainReadingWindow() {
    if (_isPageMode ||
        _displayedChapters.length <= 9 ||
        _windowRebaseScheduled ||
        _restoringPosition) {
      return;
    }
    _windowRebaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _isPageMode) {
        _windowRebaseScheduled = false;
        return;
      }
      final resume = _autoScrollTicker?.isActive ?? false;
      _pauseAutoScroll();
      final position = _captureReadingPosition();
      if (position == null) {
        _windowRebaseScheduled = false;
        return;
      }
      final anchor =
          _chapterIndexById[position.chapterId] ?? _currentActiveIndex;
      _captureRestorationImage();
      setState(() {
        _readingPosition = position;
        _anchorChapterIndex = anchor;
        _centerSliverKey = UniqueKey();
        _displayedChapters.removeWhere((index) => (index - anchor).abs() > 3);
      });
      await _restoreVerticalPosition();
      _windowRebaseScheduled = false;
      if (!mounted) return;
      _trimChapterCaches();
      _paragraphHeights.removeWhere((key, _) {
        final chapterId = key.substring(0, key.lastIndexOf('_'));
        return !_chapterCache.containsKey(_chapterIndexById[chapterId]);
      });
      if (resume && _isAutoScrolling) _startAutoScroll();
    });
  }

  /// 高性能局部检测当前活跃章节（仅针对临近章节进行局部探测，避免全量 O(N) 全局矩阵坐标运算）
  void _detectCurrentVisibleChapterOptimized() {
    if (_displayedChapters.isEmpty) return;

    int active = _currentActiveIndex;

    // 优先通过当前视口已挂载的 ~15 个轻量段落探测读者视线处所在的真实章节
    double bestDistance = double.infinity;
    const targetReadingLineDy = 140.0;
    for (final info in _mountedParagraphs.values) {
      if (!info.context.mounted) continue;
      final renderObj = info.context.findRenderObject();
      if (renderObj is RenderBox && renderObj.attached) {
        final dy = renderObj.localToGlobal(Offset.zero).dy;
        final bottomDy = dy + renderObj.size.height;
        if (dy <= 280 && bottomDy >= 40) {
          final dist = (dy - targetReadingLineDy).abs();
          if (dist < bestDistance) {
            bestDistance = dist;
            active = info.chapterIndex;
          }
        }
      }
    }

    // 兜底检查章节标题 Key
    if (bestDistance == double.infinity) {
      final checkIndices = <int>{
        _currentActiveIndex,
        if (_displayedChapters.contains(_currentActiveIndex - 1))
          _currentActiveIndex - 1,
        if (_displayedChapters.contains(_currentActiveIndex + 1))
          _currentActiveIndex + 1,
      };
      for (final chIndex in checkIndices) {
        final key = _chapterKeys[chIndex];
        final renderObj = key?.currentContext?.findRenderObject();
        if (renderObj is RenderBox && renderObj.attached) {
          final pos = renderObj.localToGlobal(Offset.zero);
          if (pos.dy <= 250 && pos.dy >= -300) {
            active = chIndex;
          }
        }
      }
    }

    if (active != _currentActiveIndex) {
      _currentActiveIndex = active;
      _activeChapterNotifier.value =
          active; // 仅通知微型小部件刷新，不触发全屏 Widget 树 Rebuild
      _persistReadingProgress(active);
      _fetchCommentStats(widget.chapters[active].itemId);
      _fetchChapterCommentsCount(widget.chapters[active].itemId);
      _triggerSilentPrefetch(active);
      _checkBookmarkStatus();
    }
  }

  /// 自动向上拉伸追加上一章（实现双向无缝连续阅读）
  Future<bool> _mayAutoLoad(int index) async {
    if (_chapterCache.containsKey(index) ||
        widget.chapters[index].content != null) {
      return true;
    }
    if (await _apiService.isChapterOffline(
      widget.book.bookId, widget.chapters[index].itemId,
    )) {
      return true;
    }
    return _cachePolicy.allowsPrefetch(await ReaderSystemService.getNetworkType());
  }

  Future<void> _autoPrependPreviousChapter({bool retry = false}) async {
    if (_isLoadingPrev || _displayedChapters.isEmpty) return;

    final prevIndex = _displayedChapters.first - 1;
    if (!retry && _chapterErrors.containsKey(prevIndex)) return;
    if (prevIndex < 0) return;

    _isLoadingPrev = true;
    if (!retry && !await _mayAutoLoad(prevIndex)) {
      if (mounted) setState(() => _isLoadingPrev = false);
      return;
    }
    if (!mounted) return;

    // 确保内容在缓存中
    if (!_chapterCache.containsKey(prevIndex)) {
      await _fetchChapterContent(prevIndex);
    }

    if (!mounted) {
      _isLoadingPrev = false;
      return;
    }

    if (_chapterCache.containsKey(prevIndex)) {
      // 基于 CustomScrollView(center: _centerSliverKey) 反向生长槽位，向上插入章节天然零位移、零跳动
      setState(() {
        if (!_displayedChapters.contains(prevIndex)) {
          _displayedChapters.insert(0, prevIndex);
          _chapterKeys[prevIndex] = GlobalKey();
        }
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
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
  Future<void> _autoAppendNextChapter({bool retry = false}) async {
    if (_isLoadingMore || _displayedChapters.isEmpty) return;

    final nextIndex = _displayedChapters.last + 1;
    if (!retry && _chapterErrors.containsKey(nextIndex)) return;
    if (nextIndex >= widget.chapters.length) return; // 已到全书最后一章

    _isLoadingMore = true;
    if (!retry && !await _mayAutoLoad(nextIndex)) {
      if (mounted) setState(() => _isLoadingMore = false);
      return;
    }
    if (!mounted) return;

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

    if (mounted) {
      setState(() => _isLoadingMore = false);
    } else {
      _isLoadingMore = false;
    }
  }

  /// 获取章节内容并缓存
  Future<void> _fetchChapterContent(int index) {
    if (_chapterCache.containsKey(index) ||
        index < 0 ||
        index >= widget.chapters.length) {
      return Future.value();
    }
    final existing = _chapterRequests[index];
    if (existing != null) return existing;
    _prefetchQueue.remove(index); // Foreground promotes a queued chapter.
    _chapterErrors.remove(index);
    final request = _loadChapterContent(index).whenComplete(() {
      _chapterRequests.remove(index);
    });
    _chapterRequests[index] = request;
    return request;
  }

  Future<void> _loadChapterContent(int index) async {
    final chapter = widget.chapters[index];
    try {
      String? content = chapter.content;
      if (content == null && widget.chapterContentLoader != null) {
        content = await widget.chapterContentLoader!(chapter).timeout(
          const Duration(seconds: 30),
        );
      } else if (content == null) {
        _chapterIsOffline[index] = await _apiService.isChapterOffline(
          widget.book.bookId,
          chapter.itemId,
        );
        content = await _apiService.getChapterContent(
          chapter.itemId,
          bookId: widget.book.bookId,
        ).timeout(const Duration(seconds: 30));
      }
      if (!mounted) return;
      if (!ReaderCacheService.isReadable(content)) {
        throw const FormatException('章节为空、未完整提供或本地文件已缺失');
      }
      if ((index - _currentActiveIndex).abs() > 5 &&
          _requestedChapterIndex != index &&
          !_displayedChapters.contains(index)) {
        return;
      }
      final formatted = _formatContent(content!, chapterTitle: chapter.title);
      _chapterCache[index] = formatted;
      _chapterParagraphsCache[index] = formatted.split('\n\n');
      _chapterIsOffline[index] = chapter.content != null ||
          (widget.chapterContentLoader == null &&
           await _apiService.isChapterOffline(widget.book.bookId, chapter.itemId));
      if (!mounted) return;
      _preparedPages.remove(index);
      if ((index - _currentActiveIndex).abs() <= 1 ||
          _displayedChapters.contains(index)) {
        _fetchCommentStats(chapter.itemId);
        _fetchChapterCommentsCount(chapter.itemId);
      }
      _warmAdjacentPages();
    } catch (error) {
      if (mounted) {
        _chapterErrors[index] = switch (error) {
          TimeoutException() => '加载超时，请检查网络后重试',
          FormatException() => '章节内容不可用或本地文件缺失，请重试或重新导入',
          _ => '加载失败，请检查网络与存储后重试',
        };
      }
      _prefetchedIndices.remove(index);
    }
  }

  void _notifyComments() {
    if (!mounted) return;
    if (_pageViewKey.currentState?.isBusy == true ||
        (_scrollController.hasClients &&
            _scrollController.position.isScrollingNotifier.value)) {
      _deferredCommentRefresh = true;
    } else {
      _commentStatsVersionNotifier.value++;
    }
  }

  void _fetchCommentStats(String itemId) {
    if (!_showCommentBubbles || widget.book.bookId.startsWith('local_')) return;
    final key = 'stats:$itemId';
    if (_chapterCommentStats.containsKey(itemId) ||
        _commentRequests.containsKey(key)) {
      return;
    }
    final request = () async {
      try {
        final loader = widget.chapterCommentStatsLoader;
        final stats = loader == null
            ? await _apiService.getChapterCommentStats(
                itemId,
                bookId: widget.book.bookId,
              )
            : await loader(widget.chapters[_chapterIndexById[itemId]!]);
        if (stats != null && mounted) {
          _chapterCommentStats[itemId] = stats;
          _notifyComments();
        }
      } catch (_) {}
    }();
    _commentRequests[key] = request.whenComplete(
      () => _commentRequests.remove(key),
    );
  }

  void _fetchChapterCommentsCount(String itemId) {
    if (widget.book.bookId.startsWith('local_')) return;
    final key = 'count:$itemId';
    if (_chapterCommentsCount.containsKey(itemId) ||
        _commentRequests.containsKey(key)) {
      return;
    }
    final request = () async {
      try {
        final data = await _apiService.getChapterComments(
          widget.book.bookId,
          itemId,
          count: 1,
        );
        if (data != null && mounted) {
          _chapterCommentsCount[itemId] = data.total;
          _notifyComments();
        }
      } catch (_) {}
    }();
    _commentRequests[key] = request.whenComplete(
      () => _commentRequests.remove(key),
    );
  }

  void _triggerSilentPrefetch(int currentIndex, {int? count}) {
    final generation = ++_prefetchGeneration;
    final limit = count ?? _cachePolicy.ahead;
    _prefetchQueue.removeWhere((index) {
      final stale = (index - currentIndex).abs() > limit;
      if (stale) _prefetchedIndices.remove(index);
      return stale;
    });
    ReaderSystemService.getNetworkType().then((network) {
      if (!mounted || generation != _prefetchGeneration ||
          !_cachePolicy.allowsPrefetch(network)) {
        return;
      }
      _queueSilentPrefetch(currentIndex, limit);
    });
  }

  void _queueSilentPrefetch(int currentIndex, int count) {
    // 近邻优先，正文最多两个后台请求；评论不占用正文调度队列。
    for (final index in [
      currentIndex + 1,
      currentIndex - 1,
      for (var offset = 2; offset <= count; offset++) currentIndex + offset,
    ]) {
      if (index >= 0 &&
          index < widget.chapters.length &&
          !_chapterErrors.containsKey(index) &&
          !_chapterCache.containsKey(index) &&
          !_prefetchedIndices.contains(index)) {
        _prefetchQueue.add(index);
        _prefetchedIndices.add(index);
      }
    }
    _pumpPrefetch();
  }

  void _pumpPrefetch() {
    if (!mounted) return;
    while (_prefetchWorkers < 2 && _prefetchQueue.isNotEmpty) {
      final index = _prefetchQueue.first;
      _prefetchQueue.remove(index);
      _prefetchWorkers++;
      () async {
        if (!_cachePolicy.allowsPrefetch(
          await ReaderSystemService.getNetworkType(),
        ) || !mounted) {
          _prefetchedIndices.removeAll(_prefetchQueue);
          _prefetchQueue.clear();
          return;
        }
        await _fetchChapterContent(index);
      }().whenComplete(() {
        _prefetchWorkers--;
        if (!_chapterCache.containsKey(index)) _prefetchedIndices.remove(index);
        _pumpPrefetch();
      });
    }
  }

  void _trimChapterCaches() {
    final pinned = <int>{
      ..._displayedChapters,
      _currentActiveIndex,
      if (_requestedChapterIndex != null) _requestedChapterIndex!,
      if (_chapterTransition != null) _chapterTransition!.chapterIndex,
    };
    bool stale(int index) =>
        (index - _currentActiveIndex).abs() > 3 && !pinned.contains(index);
    final removed = _chapterCache.keys.where(stale).toList();
    for (final index in removed) {
      _chapterCache.remove(index);
      _chapterParagraphsCache.remove(index);
      _chapterIsOffline.remove(index);
      _preparedPages.remove(index);
      _chapterKeys.remove(index);
      _chapterErrors.remove(index);
      _prefetchedIndices.remove(index);
      final id = widget.chapters[index].itemId;
      _chapterCommentStats.remove(id);
      _chapterCommentsCount.remove(id);
    }
    _chapterCommentStats.removeWhere(
      (id, _) => stale(_chapterIndexById[id] ?? -100),
    );
    _chapterCommentsCount.removeWhere(
      (id, _) => stale(_chapterIndexById[id] ?? -100),
    );
    _chapterKeys.removeWhere((index, _) => stale(index));
    _prefetchedIndices.removeWhere(stale);
  }

  /// 文本段落格式化与首行重复章节名智能去重
  String _formatContent(String raw, {String? chapterTitle}) =>
      ReaderText.display(raw, chapterTitle: chapterTitle);

  void _toggleControls() {
    if (DateTime.now().difference(_lastBubbleTapTime) <
        const Duration(milliseconds: 400)) {
      return;
    }
    if (_isAutoScrolling && _autoScrollTicker?.isActive == true) {
      _pauseAutoScroll();
      return;
    }
    _showControls = !_showControls;
  }

  void _beginReaderPanel() {
    _pageViewKey.currentState?.clearQueuedTurns();
    if (_readerPanels++ == 0) _panelsClosed = Completer<void>();
    ReaderSystemService.setVolumeKeyScrollEnabled(false, owner: this);
  }

  void _endReaderPanel() {
    if (_readerPanels > 0) _readerPanels--;
    if (_readerPanels == 0) {
      if (_panelsClosed != null && !_panelsClosed!.isCompleted) {
        _panelsClosed!.complete();
      }
      if (mounted) {
        ReaderSystemService.setVolumeKeyScrollEnabled(_canUseVolumeKeys, owner: this);
      }
    }
  }

  void _onReaderSelectionChanged() {
    if (_activeSelectableParaNotifier.value != null) {
      _manualScrollUntil = DateTime.now().add(const Duration(seconds: 3));
      _pauseAutoScroll();
    }
  }

  void _toggleAutoScroll() =>
      _isAutoScrolling ? _stopAutoScroll() : _startAutoScroll();

  void _startAutoScroll() {
    if (_isPageMode) _applyReaderSetting(() => _isPageMode = false);
    if (!_isAutoScrolling) setState(() => _isAutoScrolling = true);
    _autoScrollTicker?.stop();
    _lastAutoElapsed = Duration.zero;
    _autoScrollTicker?.start();
    _autoRunningNotifier.value = true;
  }

  void _pauseAutoScroll() {
    _autoScrollTicker?.stop();
    _autoRunningNotifier.value = false;
  }

  void _changeAutoSpeed(double delta) {
    _autoScrollSpeed = (_autoScrollSpeed + delta).clamp(15.0, 100.0);
    _autoControlsVersion.value++;
  }

  void _advanceAutoScroll(Duration elapsed) {
    final delta = (elapsed - _lastAutoElapsed).inMicroseconds / 1000000.0;
    _lastAutoElapsed = elapsed;
    if (!_isAutoScrolling ||
        _restoringPosition ||
        !_scrollController.hasClients ||
        !_scrollController.position.haveDimensions) {
      return;
    }
    final position = _scrollController.position;
    final offset =
        _scrollController.offset + _autoScrollSpeed * delta.clamp(0.0, 0.1);
    if (offset >= position.maxScrollExtent) {
      if (_displayedChapters.isNotEmpty &&
          _displayedChapters.last < widget.chapters.length - 1) {
        _autoAppendNextChapter();
      } else {
        _stopAutoScroll();
      }
    } else {
      _scrollController.jumpTo(offset);
    }
  }

  void _stopAutoScroll() {
    _pauseAutoScroll();
    if (mounted) setState(() => _isAutoScrolling = false);
    _schedulePositionSave();
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
    _activeSelectableParaNotifier.value = null;
    _beginReaderPanel();
    final theme = _themes[_themeIndex];
    final search = TextEditingController();
    Timer? searchTimer;
    var reverse = false;
    var volumeMode = false;
    var activeTab = 0;
    var located = false;
    final expanded = <String>{
      for (final entry in _volumeGroups.entries)
        if (entry.value.contains(widget.chapters[_currentActiveIndex]))
          entry.key,
    };
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => theme.wrap(_ReaderSheetLifetime(
        onDispose: () { searchTimer?.cancel(); search.dispose(); _endReaderPanel(); },
        child: StatefulBuilder(
        builder: (context, update) {
          final filter = search.text.trim();
          final all = reverse
              ? widget.chapters.reversed.toList()
              : widget.chapters;
          final filtered = filter.isEmpty
              ? all
              : all.where((chapter) => chapter.title.contains(filter)).toList();
          final rows = <Object>[];
          if (volumeMode && filter.isEmpty) {
            final groups = reverse
                ? _volumeGroups.entries.toList().reversed
                : _volumeGroups.entries;
            for (final group in groups) {
              rows.add(group.key);
              if (expanded.contains(group.key)) {
                rows.addAll(reverse ? group.value.reversed : group.value);
              }
            }
          }
          final rowHeight =
              48.0 *
              math.max(1.0, MediaQuery.textScalerOf(context).scale(14) / 14);
          Widget chapterTile(Chapter chapter) {
            final index = _chapterIndices[chapter]!;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: volumeMode ? 28 : 16,
              ),
              title: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: index == _currentActiveIndex
                      ? Theme.of(context).primaryColor
                      : theme.textColor,
                  fontWeight: index == _currentActiveIndex
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
              trailing: index == _currentActiveIndex
                  ? Icon(Icons.bookmark, size: 16, color: theme.secondaryColor)
                  : null,
              onTap: () {
                _showControls = false;
                Navigator.pop(sheetContext);
                _navigateTo(ReadingPosition(chapterId: chapter.itemId));
              },
            );
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, controller) {
              if (!located && activeTab == 0 && filter.isEmpty && !volumeMode) {
                located = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!controller.hasClients) return;
                  final index = reverse
                      ? widget.chapters.length - 1 - _currentActiveIndex
                      : _currentActiveIndex;
                  controller.jumpTo(
                    (index * rowHeight - rowHeight * 2).clamp(
                      0.0,
                      controller.position.maxScrollExtent,
                    ),
                  );
                });
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: _settingChoices<int>(
                      {0: '目录', 1: '书签', 2: '笔记'},
                      activeTab,
                      (value) => update(() => activeTab = value),
                    ),
                  ),
                  if (activeTab == 0) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '目录（${widget.chapters.length}章）',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: volumeMode ? '列表平铺' : '按卷折叠',
                            icon: Icon(
                              volumeMode
                                  ? Icons.view_headline
                                  : Icons.folder_outlined,
                              color: theme.secondaryColor,
                            ),
                            onPressed: () => update(() {
                              volumeMode = !volumeMode;
                              located = false;
                            }),
                          ),
                          IconButton(
                            tooltip: reverse ? '正序' : '倒序',
                            icon: Icon(
                              reverse
                                  ? Icons.vertical_align_top
                                  : Icons.vertical_align_bottom,
                              color: theme.secondaryColor,
                            ),
                            onPressed: () => update(() {
                              reverse = !reverse;
                              located = false;
                            }),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: TextField(
                        controller: search,
                        style: TextStyle(color: theme.textColor, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '搜索章节名称...',
                          hintStyle: TextStyle(color: theme.secondaryColor),
                          prefixIcon: Icon(
                            Icons.search,
                            color: theme.secondaryColor,
                          ),
                          isDense: true,
                        ),
                        onChanged: (_) {
                          searchTimer?.cancel();
                          searchTimer = Timer(
                            const Duration(milliseconds: 120),
                            () {
                              if (sheetContext.mounted) update(() {});
                            },
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        key: ValueKey((volumeMode, reverse, filter)),
                        controller: controller,
                        itemExtent: rowHeight,
                        itemCount: volumeMode && filter.isEmpty
                            ? rows.length
                            : filtered.length,
                        itemBuilder: (context, index) {
                          if (!volumeMode || filter.isNotEmpty) {
                            return chapterTile(filtered[index]);
                          }
                          final row = rows[index];
                          if (row is Chapter) return chapterTile(row);
                          final title = row as String;
                          return ListTile(
                            title: Text(
                              '$title（${_volumeGroups[title]!.length}章）',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: Icon(
                              expanded.contains(title)
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              color: theme.secondaryColor,
                            ),
                            onTap: () => update(() {
                              expanded.contains(title)
                                  ? expanded.remove(title)
                                  : expanded.add(title);
                            }),
                          );
                        },
                      ),
                    ),
                  ] else if (activeTab == 1)
                    Expanded(
                      child: FutureBuilder<List<Bookmark>>(
                        future: _bookmarkService.getBookmarks(
                          widget.book.bookId,
                        ),
                        builder: (context, snapshot) {
                          final bookmarks = snapshot.data ?? [];
                          if (bookmarks.isEmpty) {
                            return Center(
                              child: Text(
                                '暂无书签',
                                style: TextStyle(color: theme.secondaryColor),
                              ),
                            );
                          }
                          return ListView.builder(
                            key: const ValueKey('bookmarks'),
                            controller: controller,
                            itemCount: bookmarks.length,
                            itemBuilder: (context, index) {
                              final bookmark = bookmarks[index];
                              return ListTile(
                                title: Text(
                                  bookmark.chapterTitle,
                                  style: TextStyle(color: theme.textColor),
                                ),
                                subtitle: Text(
                                  bookmark.contentPreview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: theme.secondaryColor),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: theme.secondaryColor,
                                  ),
                                  onPressed: () async {
                                    await _bookmarkService.removeBookmark(
                                      bookmark.id,
                                      widget.book.bookId,
                                    );
                                    if (sheetContext.mounted) update(() {});
                                  },
                                ),
                                onTap: () {
                                  if (bookmark.chapterIndex < 0 ||
                                      bookmark.chapterIndex >=
                                          widget.chapters.length) {
                                    return;
                                  }
                                  _showControls = false;
                                  Navigator.pop(sheetContext);
                                  _navigateTo(
                                    ReadingPosition(
                                      chapterId: widget
                                          .chapters[bookmark.chapterIndex]
                                          .itemId,
                                      paragraphIndex: bookmark.paragraphIndex,
                                      characterOffset: bookmark.characterOffset,
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        key: const ValueKey('reading_notes'),
                        controller: controller,
                        itemCount: _cachedNotes.length,
                        itemBuilder: (context, index) {
                          final note = _cachedNotes[index];
                          return ListTile(
                            title: Text(
                              note.chapterTitle,
                              style: TextStyle(color: theme.textColor),
                            ),
                            subtitle: Text(
                              note.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: theme.secondaryColor),
                            ),
                            onTap: () {
                              if (note.chapterIndex < 0 ||
                                  note.chapterIndex >= widget.chapters.length) {
                                return;
                              }
                              _showControls = false;
                              Navigator.pop(sheetContext);
                              _navigateTo(
                                ReadingPosition(
                                  chapterId:
                                      widget.chapters[note.chapterIndex].itemId,
                                  paragraphIndex: math.max(
                                    0,
                                    note.paragraphIndex,
                                  ),
                                ),
                                locateText: note.text,
                              );
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
        ),
      ),
      ),
    );
  }

  Widget _settingChoices<T>(
    Map<T, String> choices,
    T selected,
    ValueChanged<T> changed,
  ) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final entry in choices.entries)
        ChoiceChip(
          label: Text(
            entry.value,
            style: TextStyle(
              fontSize: 12,
              color: _themes[_themeIndex].textColor,
            ),
          ),
          backgroundColor: _themes[_themeIndex].highlightColor,
          selectedColor: _themes[_themeIndex].highlightColor,
          selected: entry.key == selected,
          onSelected: (value) {
            if (value) changed(entry.key);
          },
        ),
    ],
  );

  Future<void> _showSettingsModal() async {
    if (_readerPanels > 0) return;
    _activeSelectableParaNotifier.value = null;
    _beginReaderPanel();
    try {
      await _flushPreferences();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context, isScrollControlled: true,
        barrierColor: Colors.black.withValues(alpha: .12),
        backgroundColor: _themes[_themeIndex].backgroundColor,
        builder: (context) => FractionallySizedBox(
          heightFactor: .85,
          child: ReaderSettingsSheet(
            bookId: widget.book.bookId,
            settings: _captureReaderSettings(), bookOverride: _bookSettingsOverride,
            onChanged: _receiveSettings,
          ),
        ),
      );
      if (mounted) {
        final saved = await _settingsRepository.load(widget.book.bookId);
        await _receiveSettings(saved.settings, saved.bookOverride);
      }
    } finally {
      _endReaderPanel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = _themes[_themeIndex];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: theme.systemUiStyle,
      child: PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _savePositionNow();
      },
      child: Scaffold(
        backgroundColor: theme.backgroundColor,
        body: Stack(
          children: [
            // 阅读主要连续内容区域
            GestureDetector(
              // 翻页模式自己处理热区点击，不能再由祖先重复切换控制栏。
              onTap: _isPageMode ? null : _toggleControls,
              behavior: HitTestBehavior.translucent,
              child: SafeArea(
                child: Column(
                  children: [
                    // 顶部微型信息栏（局部响应式刷新，跨章滑动无需全屏 setState）
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _activeChapterNotifier,
                        builder: (context, activeIdx, _) {
                          final safeIdx = activeIdx.clamp(
                            0,
                            widget.chapters.length - 1,
                          );
                          final currentChapter = widget.chapters[safeIdx];
                          return Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    if (_chapterIsOffline[safeIdx] == true) ...[
                                      Container(
                                        margin: const EdgeInsets.only(right: 6),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: theme.secondaryColor
                                              .withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
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
                                '${safeIdx + 1}/${widget.chapters.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.secondaryColor,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    // 正文滚屏（支持无限下拉追加后续章节）
                    Expanded(child: Stack(fit: StackFit.expand, children: [
                      _buildReaderBody(theme),
                      if (_navigationLoading) Positioned.fill(child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _cancelNavigation,
                        onPanStart: (_) => _cancelNavigation(),
                      )),
                    ])),
                    if (_navigationLoading || _jumpHistory.canGoBack)
                      _buildJumpBar(theme),
                    // 底部常驻微型状态栏（时间、电量、总进度）
                    _buildBottomStatusBar(theme),
                  ],
                ),
              ),
            ),

            Positioned.fill(
              child: ValueListenableBuilder<bool>(
                valueListenable: _controlsNotifier,
                builder: (context, visible, _) => IgnorePointer(
                  ignoring: !visible,
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    child: visible
                        ? Stack(
                            key: const ValueKey('reader_controls'),
                            children: [
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _showControls = false,
                                ),
                              ),
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: _buildTopBar(theme),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: _buildBottomBar(theme),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
            ),

            // 听书浮动控制面板 (听书开启时常驻底部)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: TtsPlayerPanel(
                backgroundColor: theme.backgroundColor,
                textColor: theme.textColor,
                secondaryColor: theme.secondaryColor,
                onModalChanged: (opened) =>
                    opened ? _beginReaderPanel() : _endReaderPanel(),
                onClose: () => _ttsStartGeneration++,
              ),
            ),

            // 沉浸式自动阅读浮动控制条
            if (_isAutoScrolling) _buildAutoScrollControlBar(theme),
          ],
        ),
      ),
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
              Icon(
                Icons.cloud_off_outlined,
                size: 48,
                color: theme.secondaryColor,
              ),
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

    // 双模式切换：左右单屏翻页模式 (无垂直滑动，仅水平翻页)
    if (_isPageMode) {
      return _buildPageModeBody(theme);
    }

    // 双向虚拟化段落级懒加载滚动容器（CustomScrollView + center 锚点 + SliverList）
    // 仅挂载视口及 cacheExtent 内的 15~25 个段落，每个段落独立小型 RepaintBoundary，120fps 满帧丝滑
    final hasCenterChapter = _displayedChapters.contains(_anchorChapterIndex);
    final effectiveAnchor = hasCenterChapter
        ? _anchorChapterIndex
        : (_displayedChapters.isNotEmpty ? _displayedChapters.first : 0);
    final beforeChapters = _displayedChapters
        .where((c) => c < effectiveAnchor)
        .toList();
    final afterAndCenterChapters = _displayedChapters
        .where((c) => c >= effectiveAnchor)
        .toList();

    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          key: _verticalPaintKey,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onVerticalScrollNotification,
            child: Scrollbar(
              controller: _scrollController,
              child: CustomScrollView(
                controller: _scrollController,
                center: afterAndCenterChapters.isNotEmpty
                    ? _centerSliverKey
                    : null,
                // ignore: deprecated_member_use
                cacheExtent: 650.0,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  // 顶部上一章指示器/触发器（位于反向增长区最顶端）
                  if (beforeChapters.isNotEmpty)
                    _buildTopPrevIndicatorSliver(theme),

                  // 锚点之前的章节（向上无缝生长，零位移跳动）
                  for (int i = 0; i < beforeChapters.length; i++)
                    _buildChapterSliver(
                      beforeChapters[i],
                      theme,
                      isFirst: i == 0,
                      isCenter: false,
                      isBeforeCenter: true,
                    ),

                  // 锚点章节及之后的章节（向下无限延伸）
                  for (int i = 0; i < afterAndCenterChapters.length; i++)
                    _buildChapterSliver(
                      afterAndCenterChapters[i],
                      theme,
                      isFirst: beforeChapters.isEmpty && i == 0,
                      isCenter: i == 0,
                      isBeforeCenter: false,
                      includeTopIndicator: beforeChapters.isEmpty && i == 0,
                    ),

                  // 底部下拉预加载指示器
                  _buildBottomNextIndicatorSliver(theme),
                ],
              ),
            ),
          ),
        ),
        if (_restorationImage != null)
          Positioned.fill(
            child: AbsorbPointer(
              child: RawImage(image: _restorationImage, fit: BoxFit.fill),
            ),
          ),
      ],
    );
  }

  Widget _buildTopPrevIndicatorSliver(ReaderTheme theme) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
        child: _buildTopPrevIndicatorBox(theme),
      ),
    );
  }

  Widget _buildTopPrevIndicatorBox(ReaderTheme theme) {
    if (_displayedChapters.isNotEmpty && _displayedChapters.first > 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: TextButton.icon(
            onPressed: _isLoadingPrev
                ? null : () => _autoPrependPreviousChapter(retry: true),
            icon: _isLoadingPrev
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.secondaryColor,
                      ),
                    ),
                  )
                : Icon(
                    Icons.arrow_upward_rounded,
                    size: 16,
                    color: theme.secondaryColor,
                  ),
            label: Text(
              _isLoadingPrev
                  ? '正在加载上一章...'
                  : '上滑或点击加载：${widget.chapters[_displayedChapters.first - 1].title}',
              style: TextStyle(fontSize: 12, color: theme.secondaryColor),
            ),
          ),
        ),
      );
    } else if (_displayedChapters.isNotEmpty && _displayedChapters.first == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '— 已是第一章 —',
            style: TextStyle(
              fontSize: 12,
              color: theme.secondaryColor,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: 12);
  }

  Widget _buildBottomNextIndicatorSliver(ReaderTheme theme) {
    final next = _displayedChapters.isEmpty ? 0 : _displayedChapters.last + 1;
    final error = _chapterErrors[next];
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: _horizontalPadding, vertical: 32),
        child: Center(
          child: next >= widget.chapters.length
              ? Text('— 已到最后一章 —', style: TextStyle(color: theme.secondaryColor))
              : TextButton.icon(
                  onPressed: _isLoadingMore ? null
                      : () => _autoAppendNextChapter(retry: true),
                  icon: _isLoadingMore
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(error == null ? Icons.arrow_downward : Icons.refresh),
                  label: Text(_isLoadingMore ? '正在加载下一章…'
                      : error == null ? '继续下一章' : '$error · 点击重试'),
                ),
        ),
      ),
    );
  }

  Widget _buildBottomStatusBar(ReaderTheme theme) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _activeChapterNotifier,
        _statusTextNotifier,
        _positionVersion,
      ]),
      builder: (context, _) {
        final activeIdx = _activeChapterNotifier.value;
        final ch = (activeIdx >= 0 && activeIdx < widget.chapters.length)
            ? widget.chapters[activeIdx]
            : widget.chapters.first;
        final anchor = _readingPosition;
        var withinChapter = 0.0;
        if (anchor?.chapterId == ch.itemId) {
          final paragraphs = _getChapterParagraphs(activeIdx);
          final total = paragraphs.fold<int>(
            0,
            (sum, paragraph) => sum + paragraph.trim().length,
          );
          var read = anchor!.characterOffset;
          for (
            var index = 0;
            index < math.min(anchor.paragraphIndex, paragraphs.length);
            index++
          ) {
            read += paragraphs[index].trim().length;
          }
          if (total > 0) withinChapter = (read / total).clamp(0.0, 1.0);
        }
        final progress = widget.chapters.isNotEmpty
            ? ((activeIdx + withinChapter) / widget.chapters.length).clamp(
                0.0,
                1.0,
              )
            : 0.0;
        final percentStr = (progress * 100).toStringAsFixed(1);

        return Container(
          height: math.max(
            22,
            MediaQuery.textScalerOf(context).scale(10) * 1.4 + 4,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: theme.backgroundColor,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  ch.title,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.secondaryColor,
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
                  color: theme.secondaryColor,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 构建单章虚拟化 SliverList（按段落懒加载 + 独立微型 RepaintBoundary，彻底消除巨型纹理与卡顿）
  Widget _buildChapterSliver(
    int chapterIndex,
    ReaderTheme theme, {
    bool isFirst = false,
    bool isCenter = false,
    bool isBeforeCenter = false,
    bool includeTopIndicator = false,
  }) {
    final chapter = widget.chapters[chapterIndex];
    final paragraphs = _getChapterParagraphs(chapterIndex);
    final key = _chapterKeys[chapterIndex];
    final isDark =
        theme.backgroundColor == const Color(0xFF000000) ||
        theme.backgroundColor == const Color(0xFF18181A);

    // 逻辑项：0 为章节标题头，1..paragraphs.length 为各正文段落，paragraphs.length + 1 为章节尾（本章完+章评）
    final totalItems = paragraphs.length + 2;

    return SliverPadding(
      key: isCenter
          ? _centerSliverKey
          : ValueKey('chapter_sliver_$chapterIndex'),
      padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final logicalIdx = isBeforeCenter
                ? (totalItems - 1 - index)
                : index;

            if (logicalIdx == 0) {
              return Container(
                key: key,
                padding: EdgeInsets.only(
                  top: isFirst ? 8.0 : 24.0,
                  bottom: 20.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (includeTopIndicator) _buildTopPrevIndicatorBox(theme),
                    Text(
                      chapter.title,
                      style: TextStyle(
                        fontSize: _fontSize + 4,
                        fontWeight: FontWeight.bold,
                        color: theme.textColor,
                        height: 1.4,
                        fontFamily: _resolveFontFamily(_fontFamily),
                      ),
                    ),
                  ],
                ),
              );
            }

            if (logicalIdx == totalItems - 1) {
              return Padding(
                padding: const EdgeInsets.only(top: 28.0, bottom: 36.0),
                child: ValueListenableBuilder<int>(
                  valueListenable: _commentStatsVersionNotifier,
                  builder: (context, _, _) =>
                      _buildChapterEndComments(chapter, theme),
                ),
              );
            }

            final pIdx = logicalIdx - 1;
            final paraText = paragraphs[pIdx];
            final paraKeyStr = '${chapter.itemId}_$pIdx';

            return _ViewportParagraphTracker(
              key: ValueKey(paraKeyStr),
              paraKey: paraKeyStr,
              chapterIndex: chapterIndex,
              paraIndex: pIdx,
              onMount: (k, cIdx, pIndex, ctx) {
                _mountedParagraphs[k] = _MountedParagraphInfo(
                  chapterIndex: cIdx,
                  paraIndex: pIndex,
                  context: ctx,
                );
                final render = ctx.findRenderObject();
                if (render is RenderBox && render.hasSize) {
                  _paragraphHeights[k] = render.size.height;
                }
              },
              onUnmount: (k) {
                _mountedParagraphs.remove(k);
              },
              child: Padding(
                padding: EdgeInsets.only(bottom: _paragraphSpacing),
                child: AnimatedBuilder(
                  animation: _paragraphSignals,
                  builder: (context, _) {
                    final stats = _chapterCommentStats[chapter.itemId];
                    return _buildSingleParagraph(
                      paraText,
                      theme,
                      _ttsService.isActive &&
                              _ttsService.currentChapterTitle == chapter.title
                          ? _ttsService.currentText.trim()
                          : '',
                      isDark,
                      chapter: chapter,
                      chapterIndex: chapterIndex,
                      paraIndex: pIdx,
                      commentCount: stats?.getCount(pIdx) ?? 0,
                    );
                  },
                ),
              ),
            );
          },
          childCount: totalItems,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          addSemanticIndexes: false,
        ),
      ),
    );
  }

  Widget _buildSingleParagraph(
    String paragraph,
    ReaderTheme theme,
    String currentTtsText,
    bool isDark, {
    required Chapter chapter,
    required int chapterIndex,
    required int paraIndex,
    required int commentCount,
  }) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    var textToShow = paragraph;
    if (_indentTwoChars) {
      if (!textToShow.startsWith('\u3000\u3000') &&
          !textToShow.startsWith('    ')) {
        textToShow = '\u3000\u3000$trimmed';
      }
    } else {
      textToShow = trimmed;
    }

    final paraKeyStr = '${chapter.itemId}_$paraIndex';
    final isLocateTarget = _highlightedParagraphKey == paraKeyStr;
    final showBubble = _showCommentBubbles && commentCount > 0;

    // O(1) 哈希索引获取本章节、本段落特定的划线记录
    final validChapIdx = chapterIndex;
    final paraUnderlines = _getParaUnderlines(validChapIdx, paraIndex);

    final inlineSpans = _withSpokenHighlight(
      _buildSpansWithUnderline(textToShow, paraUnderlines, theme, validChapIdx, paraIndex),
      textToShow, theme, chapter.itemId, paraIndex,
      sourceStart: 0, sourceEnd: trimmed.length,
    );

    return DecoratedBox(
      decoration: isLocateTarget
          ? BoxDecoration(
              color: theme.highlightColor.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).primaryColor,
                width: 1.2,
              ),
            )
          : const BoxDecoration(),
      child: _buildOnDemandSelectableParagraph(
        paraKeyStr: paraKeyStr,
        inlineSpans: inlineSpans,
        theme: theme,
        chapterIndex: validChapIdx,
        paraIndex: paraIndex,
        onTap: _toggleControls,
        commentBubble: showBubble
            ? _buildCommentBubble(chapter, paraIndex, trimmed, theme)
            : null,
        commentBubbleSize: showBubble
            ? ReaderCommentBubble.sizeFor(
                MediaQuery.textScalerOf(context),
                count: commentCount,
              )
            : null,
      ),
    );
  }

  /// 按需激活的长按自由选词段落组件：默认零开销 Text.rich，长按当帧无缝切换为 SelectableText.rich 并呼出气泡菜单
  Widget _buildOnDemandSelectableParagraph({
    required String paraKeyStr,
    required List<InlineSpan> inlineSpans,
    required ReaderTheme theme,
    required int chapterIndex,
    required int paraIndex,
    required VoidCallback? onTap,
    Widget? commentBubble,
    Size? commentBubbleSize,
  }) {
    final baseStyle = _readerBodyStyle(color: theme.textColor);
    final commentChild = commentBubble == null
        ? null
        : SizedBox.fromSize(size: commentBubbleSize, child: commentBubble);
    final spanScale =
        MediaQuery.textScalerOf(context).scale(_fontSize) / _fontSize;
    final commentSpan = commentBubble == null
        ? null
        : WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox.fromSize(
              // WidgetSpan 会再按正文字号缩放整个控件，先抵消该倍率；
              // 数字已按系统 TextScaler 排版，不能二次放大并挤出分页。
              size: commentBubbleSize! / spanScale,
              child: FittedBox(fit: BoxFit.fill, child: commentChild),
            ),
          );
    final textSpan = TextSpan(
      children: [...inlineSpans, if (commentSpan != null) commentSpan],
    );

    return ValueListenableBuilder<String?>(
      valueListenable: _activeSelectableParaNotifier,
      builder: (context, activeParaKey, _) {
        final isSelectedPara = activeParaKey == paraKeyStr;
        if (isSelectedPara) {
          final selectable = SelectableText.rich(
            key: _activeSelectableTextKey,
            TextSpan(children: inlineSpans),
            style: baseStyle,
            onTap: () {
              _activeSelectableParaNotifier.value = null;
              onTap?.call();
            },
            contextMenuBuilder: (context, editableTextState) {
              final textVal = editableTextState.textEditingValue;
              final selected = textVal.selection.textInside(textVal.text);
              if (selected.trim().isEmpty) return const SizedBox.shrink();
              return _buildDarkBubbleMenu(
                context: context,
                anchors: editableTextState.contextMenuAnchors,
                selectedText: selected,
                onDismiss: () {
                  editableTextState.hideToolbar();
                  _activeSelectableParaNotifier.value = null;
                },
                chapterIndex: chapterIndex,
                paraIndex: paraIndex,
              );
            },
          );
          if (commentSpan == null) return selectable;
          // EditableText 不支持内联控件。保持原排版高度并覆盖同一段尾位置，
          // 选词/复制只包含原文，不带气泡占位符或计数，也不让后续段落跳动。
          return LayoutBuilder(
            builder: (context, constraints) {
              final painter =
                  TextPainter(
                    text: TextSpan(
                      style: baseStyle,
                      children: textSpan.children,
                    ),
                    textDirection: TextDirection.ltr,
                    textScaler: MediaQuery.textScalerOf(context),
                  )..setPlaceholderDimensions([
                    PlaceholderDimensions(
                      size: commentBubbleSize!,
                      alignment: PlaceholderAlignment.middle,
                    ),
                  ]);
              painter.layout(maxWidth: constraints.maxWidth);
              final height = painter.height;
              final rect = painter.inlinePlaceholderBoxes!.single.toRect();
              painter.dispose();
              return SizedBox(
                width: constraints.maxWidth,
                height: height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    selectable,
                    Positioned.fromRect(rect: rect, child: commentChild!),
                  ],
                ),
              );
            },
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onTap,
          onLongPressStart: (details) => _activateParagraphSelection(
            paraKeyStr: paraKeyStr,
            globalPosition: details.globalPosition,
          ),
          onLongPressMoveUpdate: (details) => _updateParagraphSelectionDrag(
            paraKeyStr: paraKeyStr,
            globalPosition: details.globalPosition,
            offsetFromOrigin: details.offsetFromOrigin,
          ),
          onLongPressEnd: (_) =>
              _endParagraphSelectionDrag(paraKeyStr: paraKeyStr),
          child: Text.rich(
            textSpan,
            key: ValueKey('reader-paragraph-$paraKeyStr'),
            style: baseStyle,
          ),
        );
      },
    );
  }

  void _activateParagraphSelection({
    required String paraKeyStr,
    required Offset globalPosition,
  }) {
    if (DateTime.now().difference(_lastBubbleTapTime) < const Duration(milliseconds: 400)) {
      return;
    }
    _activeSelectableParaNotifier.value = paraKeyStr;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeSelectableParaNotifier.value != paraKeyStr) return;
      final Object? state = _activeSelectableTextKey.currentState;
      if (state is TextSelectionGestureDetectorBuilderDelegate) {
        final editable = state.editableTextKey.currentState;
        if (editable != null && editable.mounted) {
          editable.renderEditable.selectWordsInRange(
            from: globalPosition,
            cause: SelectionChangedCause.longPress,
          );
          final sel = editable.textEditingValue.selection;
          final fullText = editable.textEditingValue.text;
          if (sel.isCollapsed && fullText.isNotEmpty) {
            final base = sel.baseOffset.clamp(0, fullText.length - 1);
            final end = (base + 2).clamp(1, fullText.length);
            editable.userUpdateTextEditingValue(
              editable.textEditingValue.copyWith(
                selection: TextSelection(baseOffset: base, extentOffset: end),
              ),
              SelectionChangedCause.longPress,
            );
          }
          editable.showToolbar();
        }
      }
    });
  }

  void _updateParagraphSelectionDrag({
    required String paraKeyStr,
    required Offset globalPosition,
    required Offset offsetFromOrigin,
  }) {
    if (_activeSelectableParaNotifier.value != paraKeyStr) return;
    final Object? state = _activeSelectableTextKey.currentState;
    if (state is TextSelectionGestureDetectorBuilderDelegate) {
      final editable = state.editableTextKey.currentState;
      if (editable != null && editable.mounted) {
        editable.renderEditable.selectWordsInRange(
          from: globalPosition - offsetFromOrigin,
          to: globalPosition,
          cause: SelectionChangedCause.longPress,
        );
      }
    }
  }

  void _endParagraphSelectionDrag({required String paraKeyStr}) {
    if (_activeSelectableParaNotifier.value != paraKeyStr) return;
    final Object? state = _activeSelectableTextKey.currentState;
    if (state is TextSelectionGestureDetectorBuilderDelegate) {
      final editable = state.editableTextKey.currentState;
      if (editable != null && editable.mounted) {
        editable.showToolbar();
      }
    }
  }

  /// 打开指定段落评论抽屉
  void _openParagraphComments({
    required Chapter chapter,
    required int paraIndex,
    required String paraText,
  }) {
    final theme = _themes[_themeIndex];
    ReadingPosition? origin;
    final id = _pageViewKey.currentState?.currentPageId;
    if (_isPageMode &&
        id is _ReaderPageAddress &&
        id.layout.chapterId == chapter.itemId) {
      for (final fragment in id.page.fragments) {
        if (fragment.paragraphIndex == paraIndex) {
          origin = ReadingPosition(
            chapterId: chapter.itemId,
            paragraphIndex: paraIndex,
            characterOffset: fragment.startOffset,
          );
          break;
        }
      }
    }
    _beginReaderPanel();
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
      onLocateParagraph: () =>
          _locateParagraph(chapter, paraIndex, position: origin),
    ).whenComplete(_endReaderPanel);
  }

  void _locateParagraph(
    Chapter chapter,
    int paraIndex, {
    ReadingPosition? position,
  }) {
    final index = _chapterIndexById[chapter.itemId];
    if (index == null) return;
    final anchor =
        position ??
        ReadingPosition(
          chapterId: chapter.itemId,
          paragraphIndex: math.max(0, paraIndex),
        );
    _highlightPosition(anchor);
    _navigateTo(anchor);
  }

  void _highlightPosition(ReadingPosition position) {
    if (!mounted) return;
    setState(
      () => _highlightedParagraphKey =
          '${position.chapterId}_${position.paragraphIndex}',
    );
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        setState(() {
        _highlightedParagraphKey = null;
        _searchHighlight = null;
      });
      }
    });
  }

  /// 显示本章段评概览
  void _openChapterComments(Chapter chapter) {
    final theme = _themes[_themeIndex];
    _beginReaderPanel();
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
    ).whenComplete(_endReaderPanel);
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
                  color: theme.secondaryColor,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
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
                icon: Icon(
                  Icons.arrow_back_ios_new,
                  size: 20,
                  color: theme.textColor,
                ),
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
              // 听书快捷入口
              IconButton(
                icon: Icon(
                  _ttsService.isActive
                      ? Icons.headphones
                      : Icons.headphones_outlined,
                  size: 22,
                  color: _ttsService.isActive
                      ? Theme.of(context).primaryColor
                      : theme.textColor,
                ),
                tooltip: '听书',
                onPressed: _startTtsReading,
              ),
              // 右上角折叠更多选项 (PopupMenuButton)
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert_rounded,
                  size: 22,
                  color: theme.textColor,
                ),
                tooltip: '更多选项',
                color: theme.backgroundColor,
                onSelected: (val) {
                  switch (val) {
                    case 'search':
                      _showReaderSearch();
                      break;
                    case 'bookshelf':
                      _toggleBookshelf();
                      break;
                    case 'bookmark':
                      _toggleBookmark();
                      break;
                    case 'cache':
                      _showQuickCacheModal();
                      break;
                    case 'detail':
                      _openBookDetail();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'search', child: Row(children: [
                    Icon(Icons.search, size: 18, color: theme.textColor),
                    const SizedBox(width: 12),
                    Text('正文搜索', style: TextStyle(color: theme.textColor)),
                  ])),
                  PopupMenuItem(
                    value: 'bookshelf',
                    child: Row(
                      children: [
                        Icon(
                          _isInBookshelf
                              ? Icons.bookmark_added
                              : Icons.bookmark_add_outlined,
                          size: 18,
                          color: _isInBookshelf
                              ? Theme.of(context).primaryColor
                              : theme.textColor,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _isInBookshelf ? '移出书架' : '加入书架',
                          style: TextStyle(color: theme.textColor),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'bookmark',
                    child: Row(
                      children: [
                        Icon(
                          _isCurrentChapterBookmarked
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          size: 18,
                          color: _isCurrentChapterBookmarked
                              ? Theme.of(context).primaryColor
                              : theme.textColor,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _isCurrentChapterBookmarked ? '取消书签' : '添加书签',
                          style: TextStyle(color: theme.textColor),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'cache',
                    child: Row(
                      children: [
                        Icon(
                          Icons.download_for_offline_outlined,
                          size: 18,
                          color: theme.textColor,
                        ),
                        const SizedBox(width: 12),
                        Text('批量离线', style: TextStyle(color: theme.textColor)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'detail',
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: theme.textColor,
                        ),
                        const SizedBox(width: 12),
                        Text('书籍详情', style: TextStyle(color: theme.textColor)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openBookDetail() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailScreen(book: widget.book)),
    );
  }

  Future<void> _startTtsReading({int? chapterIndex}) async {
    final tts = _ttsService;
    if (chapterIndex == null && tts.isActive &&
        tts.currentBookId == widget.book.bookId) {
      tts.isPaused ? await tts.resume() : await tts.pause();
      return;
    }
    _ttsStartGeneration++;
    final index = chapterIndex ?? _currentActiveIndex;
    if (index < 0 || index >= widget.chapters.length) return;
    final position = chapterIndex == null ? _captureReadingPosition() : null;
    _showControls = false;
    await tts.startBook(widget.book, widget.chapters, index, position: position);
  }

  void _showQuickCacheModal() {
    final currentTheme = _themes[_themeIndex];
    _beginReaderPanel();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: currentTheme.backgroundColor,
      builder: (context) => currentTheme.wrap(
        FractionallySizedBox(
          heightFactor: .85,
          child: ReaderCacheSheet(
            bookId: widget.book.bookId,
            chapters: widget.chapters,
            currentIndex: _currentActiveIndex,
            warning: _apiService.engine.cacheWarning.value,
            onDownload: _triggerBatchDownload,
            onPolicyChanged: (policy) {
              _cachePolicy = policy;
              _prefetchedIndices.removeAll(_prefetchQueue);
              _prefetchQueue.clear();
              _triggerSilentPrefetch(_currentActiveIndex);
            },
          ),
        ),
      ),
    ).whenComplete(_endReaderPanel);
  }

  void _triggerBatchDownload(int count) {
    if (count <= 0) return;
    final startIndex = _currentActiveIndex + 1;
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
    Widget item(String label, IconData icon, VoidCallback action) => Expanded(
      child: TextButton(
        onPressed: action,
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: theme.textColor, size: 22),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, style: TextStyle(color: theme.textColor, fontSize: 13)),
        ]),
      ),
    );
    return Material(
      color: theme.backgroundColor,
      elevation: 6,
      child: SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          item('目录', Icons.menu_book_outlined, _showDirectoryDrawer),
          item(_isAutoScrolling ? '停止' : '自动阅读',
            _isAutoScrolling ? Icons.pause_circle_outline : Icons.play_circle_outline,
            () { _showControls = false; _toggleAutoScroll(); }),
          item('排版设置', Icons.text_format, _showSettingsModal),
        ]),
      )),
    );
  }

  ReaderLayout _layoutFor(Size size) => ReaderLayout(
    size: size,
    bodyStyle: _readerBodyStyle(),
    titleStyle: TextStyle(
      fontSize: _fontSize + 4,
      height: 1.4,
      fontWeight: FontWeight.bold,
      fontFamily: _resolveFontFamily(_fontFamily),
    ),
    textScaler: MediaQuery.textScalerOf(context),
    horizontalPadding: _horizontalPadding,
    paragraphSpacing: _paragraphSpacing,
    inlineCommentSize: _showCommentBubbles
        ? ReaderCommentBubble.sizeFor(MediaQuery.textScalerOf(context))
        : Size.zero,
  );

  ReaderChapterPages _preparePages(int index, ReaderLayout layout) {
    final chapter = widget.chapters[index];
    final result = _pagination.paginate(
      chapterId: chapter.itemId,
      title: chapter.title,
      content: _chapterCache[index] ?? '',
      layout: layout,
      indent: _indentTwoChars,
    );
    _preparedPages[index] = result;
    return result;
  }

  void _warmAdjacentPages() {
    final layout = _pageLayout;
    if (!_isPageMode || layout == null) return;
    final generation = _layoutGeneration;
    for (final index in [_currentActiveIndex + 1, _currentActiveIndex - 1]) {
      if (index < 0 ||
          index >= widget.chapters.length ||
          !_chapterCache.containsKey(index) ||
          _preparedPages.containsKey(index) ||
          !_warmingPages.add(index)) {
        continue;
      }
      _layoutWarmTimers[index] = Timer(const Duration(milliseconds: 32), () {
        _layoutWarmTimers.remove(index);
        _warmingPages.remove(index);
        if (!mounted ||
            !_isPageMode ||
            generation != _layoutGeneration ||
            _preparedPages.containsKey(index)) {
          return;
        }
        if (_pageViewKey.currentState?.isBusy == true) {
          _deferredPageRefresh = true;
          return;
        }
        _preparePages(index, layout);
        _refreshPageWindow();
      });
    }
  }

  void _refreshPageWindow() {
    if (!mounted || !_isPageMode) return;
    if (_pageViewKey.currentState?.isBusy == true) {
      _deferredPageRefresh = true;
    } else {
      setState(() {});
    }
  }

  void _onPageInteractionEnded() {
    if (!mounted) return;
    if (_pendingSettings.isNotEmpty) {
      _pageViewKey.currentState?.clearQueuedTurns();
      final actions = List<VoidCallback>.of(_pendingSettings);
      _pendingSettings.clear();
      for (final action in actions) {
        action();
      }
    }
    if (_deferredCommentRefresh) {
      _deferredCommentRefresh = false;
      _commentStatsVersionNotifier.value++;
    }
    if (_deferredPageRefresh) {
      _deferredPageRefresh = false;
      setState(() {});
    }
    _warmAdjacentPages();
  }

  Widget _buildPageModeBody(ReaderTheme theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = _layoutFor(constraints.biggest);
        final layoutKey = (layout.key, _indentTwoChars);
        if (_preparedLayoutKey != layoutKey) {
          _preparedLayoutKey = layoutKey;
          _pageLayout = layout;
          _preparedPages.clear();
          for (final timer in _layoutWarmTimers.values) {
            timer.cancel();
          }
          _layoutWarmTimers.clear();
          _warmingPages.clear();
          _layoutGeneration++;
          _positionNeedsReflow = true;
        }
        final current = _preparePages(_currentActiveIndex, layout);
        if (_positionNeedsReflow) {
          final anchor = _readingPosition;
          _currentHorizontalPageIndex = anchor?.chapterId == current.chapterId
              ? current.pageFor(anchor!)
              : 0;
          _positionNeedsReflow = false;
        }
        _currentHorizontalPageIndex = _currentHorizontalPageIndex.clamp(
          0,
          current.pages.length - 1,
        );
        final source = _ReaderPageAddress(
          _currentActiveIndex,
          _currentHorizontalPageIndex,
          current,
        );
        final addresses = <_ReaderPageAddress>[];
        var transition = _chapterTransition;
        if (transition != null) {
          final ready = _preparePages(transition.chapterIndex, layout);
          if (ready.key != transition.layout.key) {
            transition = _ReaderPageAddress(
              transition.chapterIndex,
              transition.anchor == null
                  ? ready.pages.length - 1
                  : ready.pageFor(transition.anchor!),
              ready,
              anchor: transition.anchor,
            );
            _chapterTransition = transition;
          }
          if (transition == source) {
            _readingPosition =
                transition.anchor ?? source.page.position(current.chapterId);
            _chapterTransition = null;
            transition = null;
          }
        }
        if (transition != null) {
          if (transition.isBefore(source)) addresses.add(transition);
          addresses.add(source);
          if (!transition.isBefore(source)) addresses.add(transition);
        } else {
          final previous = _preparedPages[_currentActiveIndex - 1];
          if (previous != null) {
            addresses.add(
              _ReaderPageAddress(
                _currentActiveIndex - 1,
                previous.pages.length - 1,
                previous,
              ),
            );
          }
          for (var index = 0; index < current.pages.length; index++) {
            addresses.add(
              _ReaderPageAddress(_currentActiveIndex, index, current),
            );
          }
          final next = _preparedPages[_currentActiveIndex + 1];
          if (next != null) {
            addresses.add(_ReaderPageAddress(_currentActiveIndex + 1, 0, next));
          }
        }
        _warmAdjacentPages();
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              key: _pagePaintKey,
              child: ReaderPageView(
                key: _pageViewKey,
                pages: [
                  for (final address in addresses)
                    ReaderPageItem(
                      id: address,
                      builder: (context) =>
                          _buildSinglePageCard(address, theme, constraints),
                    ),
                ],
                currentPageId: source,
                contentVersion: (
                  _notesVersion,
                  _themeIndex,
                  layoutKey,
                  _highlightedParagraphKey,
                  _searchHighlight?.position.characterOffset,
                  _searchHighlight?.endOffset,
                ),
                mode: MediaQuery.disableAnimationsOf(context)
                    ? 'none'
                    : _pageTurnAnimation,
                backgroundColor: theme.backgroundColor,
                isDark: theme.systemBrightness == Brightness.dark,
                selection: _activeSelectableParaNotifier,
                pageContentChanges: _paragraphSignals,
                onDismissSelection: () =>
                    _activeSelectableParaNotifier.value = null,
                lastBubbleTap: () => _lastBubbleTapTime,
                previousTapFraction: _tapLayout == 'right_hand' ? 0.18 : 0.28,
                nextTapFraction: _tapLayout == 'right_hand' ? 0.55 : 0.72,
                onCenterTap: _toggleControls,
                onPreviousBoundary: () => _startFromChapter(
                  _currentActiveIndex - 1,
                  toLastPage: true,
                ),
                onNextBoundary: () =>
                    _startFromChapter(_currentActiveIndex + 1),
                onPageSettled: _onPageSettled,
                onInteractionEnded: _onPageInteractionEnded,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _chapterWaitingNotifier,
                builder: (context, waiting, _) => waiting
                    ? LinearProgressIndicator(
                        minHeight: 1.5,
                        color: theme.secondaryColor,
                        backgroundColor: theme.backgroundColor,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onPageSettled(ReaderPageItem item) {
    final address = item.id as _ReaderPageAddress;
    final changedChapter = address.chapterIndex != _currentActiveIndex;
    setState(() {
      _currentActiveIndex = address.chapterIndex;
      _currentHorizontalPageIndex = address.pageIndex;
      _activeChapterNotifier.value = address.chapterIndex;
      _readingPosition =
          address.anchor ?? address.page.position(address.layout.chapterId);
      _positionNeedsReflow = false;
      _chapterTransition = null;
      _activeSelectableParaNotifier.value = null;
      if (changedChapter) {
        _anchorChapterIndex = _currentActiveIndex;
        _displayedChapters.clear();
        _displayedChapters.add(_currentActiveIndex);
        _chapterKeys[_currentActiveIndex] = GlobalKey();
      }
    });
    _schedulePositionSave();
    if (changedChapter) {
      final chapterId = widget.chapters[_currentActiveIndex].itemId;
      _fetchCommentStats(chapterId);
      _fetchChapterCommentsCount(chapterId);
      _persistReadingProgress(_currentActiveIndex);
      _checkBookmarkStatus();
      _triggerSilentPrefetch(_currentActiveIndex);
      _trimChapterCaches();
    }
  }

  Widget _buildSinglePageCard(
    _ReaderPageAddress address,
    ReaderTheme theme,
    BoxConstraints constraints,
  ) {
    final chapter = widget.chapters[address.chapterIndex];
    final page = address.page;
    final paragraphs = address.layout.sourceParagraphs;
    return ColoredBox(
      color: theme.backgroundColor,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: _horizontalPadding,
          vertical: 8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (address.pageIndex == 0) ...[
              SizedBox(
                height: page.titleHeight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: constraints.maxWidth - _horizontalPadding * 2,
                    child: Text(
                      chapter.title,
                      style: TextStyle(
                        fontSize: _fontSize + 4,
                        height: 1.4,
                        fontWeight: FontWeight.bold,
                        color: theme.textColor,
                        fontFamily: _resolveFontFamily(_fontFamily),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: ClipRect(
                child: SingleChildScrollView(
                  physics: page.oversized
                      ? const ClampingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: AnimatedBuilder(
                    animation: _paragraphSignals,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (
                          var index = 0;
                          index < page.fragments.length;
                          index++
                        ) ...[
                          if (index > 0)
                            SizedBox(
                              height: _paragraphSpacing,
                            ),
                          _buildParagraphWithUnderlines(
                            page.fragments[index].text,
                            theme,
                            chapter,
                            page.fragments[index].paragraphIndex,
                            chapterIndex: address.chapterIndex,
                            pageIdx: address.pageIndex,
                            sourceParagraph:
                                paragraphs[page.fragments[index].paragraphIndex]
                                    .trim(),
                            startOffset: page.fragments[index].startOffset,
                            endOffset: page.fragments[index].endOffset,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '第 ${address.pageIndex + 1} / ${address.layout.pages.length} 页',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1,
                      letterSpacing: 1,
                      color: theme.secondaryColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentBubble(
    Chapter chapter,
    int paragraphIndex,
    String originalText,
    ReaderTheme theme,
  ) {
    final count =
        _chapterCommentStats[chapter.itemId]?.getCount(paragraphIndex) ?? 0;
    return ReaderCommentBubble(
      key: ValueKey('paragraph-comment-${chapter.itemId}-$paragraphIndex'),
      count: count,
      backgroundColor: theme.highlightColor,
      foregroundColor: theme.secondaryColor,
      onTapDown: () => _lastBubbleTapTime = DateTime.now(),
      onTap: () {
        _lastBubbleTapTime = DateTime.now();
        _openParagraphComments(
          chapter: chapter,
          paraIndex: paragraphIndex,
          paraText: originalText,
        );
      },
    );
  }

  /// 单屏段落构建（带自由长按选词、纯正虚线下划线，支持段评气泡与点击取消划线）
  Widget _buildParagraphWithUnderlines(
    String paragraph,
    ReaderTheme theme,
    Chapter chapter,
    int pIdx, {
    required int chapterIndex,
    int pageIdx = 0,
    required String sourceParagraph,
    required int startOffset,
    required int endOffset,
  }) {
    final trimmed = paragraph.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    // 缩进只在原段落开头加入；续页保持分页器的文本，不重新缩进。
    final textToShow = paragraph;
    final validChapIdx = chapterIndex;
    final effectiveParaIdx = pIdx;

    final paraUnderlines = _getParaUnderlines(
      validChapIdx,
      effectiveParaIdx,
      includeChapterWide: true,
    );

    final visibleUnderlines = <String>[];
    for (final phrase in paraUnderlines) {
      var offset = sourceParagraph.indexOf(phrase);
      while (offset >= 0) {
        final begin = math.max(startOffset, offset);
        final end = math.min(endOffset, offset + phrase.length);
        if (begin < end) {
          visibleUnderlines.add(sourceParagraph.substring(begin, end));
        }
        offset = sourceParagraph.indexOf(phrase, offset + 1);
      }
    }
    final spans = _withSpokenHighlight(
      _buildSpansWithUnderline(textToShow, visibleUnderlines, theme, validChapIdx, effectiveParaIdx),
      textToShow, theme, chapter.itemId, effectiveParaIdx,
      sourceStart: startOffset, sourceEnd: endOffset,
    );

    final paraKeyStr = 'page_${chapter.itemId}_${pageIdx}_$pIdx';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _highlightedParagraphKey == '${chapter.itemId}_$pIdx'
            ? theme.highlightColor
            : Colors.transparent,
      ),
      child: _buildOnDemandSelectableParagraph(
        paraKeyStr: paraKeyStr,
        inlineSpans: spans,
        theme: theme,
        chapterIndex: validChapIdx,
        paraIndex: effectiveParaIdx,
        onTap: null,
        // 续页中段不重复显示段评。只在原段落的真正结尾预留内联气泡；
        // 统计异步到达时可原位显示，不缩窄正文，也不改变既有分页。
        commentBubble:
            _showCommentBubbles && endOffset == sourceParagraph.length
            ? _buildCommentBubble(
                chapter,
                effectiveParaIdx,
                sourceParagraph,
                theme,
              )
            : null,
        commentBubbleSize: _showCommentBubbles
            ? ReaderCommentBubble.sizeFor(MediaQuery.textScalerOf(context))
            : null,
      ),
    );
  }

  List<InlineSpan> _withSpokenHighlight(
    List<InlineSpan> spans, String text, ReaderTheme theme,
    String chapterId, int paragraphIndex, {
    required int sourceStart, required int sourceEnd,
  }) {
    final spoken = _ttsService.spokenRange(widget.book.bookId, chapterId, paragraphIndex);
    var result = spans;
    final prefix = math.max(0, text.length - (sourceEnd - sourceStart));
    if (spoken != null) {
      result = _paintSpanRange(result,
        (spoken.start - sourceStart + prefix).clamp(prefix, text.length),
        (spoken.end - sourceStart + prefix).clamp(prefix, text.length),
        TextStyle(backgroundColor: theme.highlightColor));
    }
    final hit = _searchHighlight;
    if (hit != null && hit.position.chapterId == chapterId &&
        hit.position.paragraphIndex == paragraphIndex) {
      result = _paintSpanRange(result,
        (hit.position.characterOffset - sourceStart + prefix).clamp(prefix, text.length),
        (hit.endOffset - sourceStart + prefix).clamp(prefix, text.length),
        TextStyle(backgroundColor: theme.highlightColor, decoration: TextDecoration.underline,
          decorationColor: theme.textColor, decorationThickness: 2,
          decorationStyle: TextDecorationStyle.solid));
    }
    return result;
  }

  List<InlineSpan> _paintSpanRange(List<InlineSpan> spans, int start, int end, TextStyle paint) {
    if (start >= end) return spans;
    var cursor = 0;
    final result = <InlineSpan>[];
    for (final span in spans) {
      if (span is! TextSpan || span.text == null) {
        result.add(span);
        cursor += span.toPlainText().length;
        continue;
      }
      final value = span.text!;
      final left = (start - cursor).clamp(0, value.length);
      final right = (end - cursor).clamp(0, value.length);
      if (left >= right) {
        result.add(span);
      } else {
        if (left > 0) result.add(TextSpan(text: value.substring(0, left), style: span.style));
        result.add(TextSpan(text: value.substring(left, right),
          style: (span.style ?? const TextStyle()).merge(paint)));
        if (right < value.length) result.add(TextSpan(text: value.substring(right), style: span.style));
      }
      cursor += value.length;
    }
    return result;
  }

  /// 纯正虚线下划线构建（字体平整不跳起，仅在文字下方展示优雅虚线）
  List<InlineSpan> _buildSpansWithUnderline(
    String text,
    List<String> underlinedPhrases,
    ReaderTheme theme,
    int chapterIndex,
    int paraIndex,
  ) {
    if (underlinedPhrases.isEmpty) {
      return [
        TextSpan(
          text: text,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: theme.textColor,
            letterSpacing: _letterSpacing,
            fontFamily: _resolveFontFamily(_fontFamily),
          ),
        ),
      ];
    }

    final matchedPhrases = underlinedPhrases
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty && text.contains(p))
        .toList();

    if (matchedPhrases.isEmpty) {
      return [
        TextSpan(
          text: text,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: theme.textColor,
            letterSpacing: _letterSpacing,
            fontFamily: _resolveFontFamily(_fontFamily),
          ),
        ),
      ];
    }

    matchedPhrases.sort((a, b) => b.length.compareTo(a.length));
    final spans = <InlineSpan>[];
    int currentPos = 0;

    while (currentPos < text.length) {
      int nextMatchStart = -1;
      String? matchedPhrase;

      for (final phrase in matchedPhrases) {
        final idx = text.indexOf(phrase, currentPos);
        if (idx != -1 && (nextMatchStart == -1 || idx < nextMatchStart)) {
          nextMatchStart = idx;
          matchedPhrase = phrase;
        }
      }

      if (nextMatchStart != -1 && matchedPhrase != null) {
        if (nextMatchStart > currentPos) {
          spans.add(
            TextSpan(
              text: text.substring(currentPos, nextMatchStart),
              style: TextStyle(
                fontSize: _fontSize,
                height: _lineHeight,
                color: theme.textColor,
                letterSpacing: _letterSpacing,
                fontFamily: _resolveFontFamily(_fontFamily),
              ),
            ),
          );
        }
        // 虚线下划线：文字基线绝对平齐，绝不抬高文字，文字下方展现优雅虚线
        spans.add(
          TextSpan(
            text: matchedPhrase,
            style: TextStyle(
              fontSize: _fontSize,
              height: _lineHeight,
              fontFamily: _resolveFontFamily(_fontFamily),
              letterSpacing: _letterSpacing,
              color: theme.textColor,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dashed,
              decorationColor: theme.textColor.withValues(alpha: 0.85),
              decorationThickness: 1.5,
            ),
          ),
        );
        currentPos = nextMatchStart + matchedPhrase.length;
      } else {
        spans.add(
          TextSpan(
            text: text.substring(currentPos),
            style: TextStyle(
              fontSize: _fontSize,
              height: _lineHeight,
              color: theme.textColor,
              letterSpacing: _letterSpacing,
              fontFamily: _resolveFontFamily(_fontFamily),
            ),
          ),
        );
        break;
      }
    }

    return spans;
  }

  /// 专属暗色半透明圆角气泡浮动菜单（支持自由选择文字、复制、划线/取消划线，紧贴选区）
  Widget _buildDarkBubbleMenu({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required String selectedText,
    required VoidCallback onDismiss,
    required int chapterIndex,
    required int paraIndex,
  }) {
    final cleanSelected = selectedText.trim();
    if (cleanSelected.isEmpty) return const SizedBox.shrink();

    // 智能判断选中文本是否已在划线中
    final isAlreadyUnderlined = _cachedNotes.any((n) {
      if (n.chapterIndex != chapterIndex) return false;
      if (paraIndex >= 0 &&
          n.paragraphIndex >= 0 &&
          n.paragraphIndex != paraIndex) {
        return false;
      }
      final noteText = n.text.trim();
      if (noteText.isEmpty) return false;
      return noteText == cleanSelected ||
          noteText.contains(cleanSelected) ||
          cleanSelected.contains(noteText);
    });

    final messenger = ScaffoldMessenger.of(context);

    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF232326),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: cleanSelected));
                  onDismiss();
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('已复制文本'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 15,
                  color: Colors.white,
                ),
                label: const Text(
                  '复制',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Container(width: 1, height: 16, color: Colors.white24),
              if (isAlreadyUnderlined)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    onDismiss();
                    await _bookmarkService.removeNoteByParagraph(
                      bookId: widget.book.bookId,
                      chapterIndex: chapterIndex,
                      paragraphIndex: paraIndex,
                      text: cleanSelected,
                    );
                    await _bookmarkService.removeNoteByText(
                      cleanSelected,
                      widget.book.bookId,
                    );
                    await _loadNotes();
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('已取消划线'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: const Icon(
                    Icons.format_clear_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                  label: const Text(
                    '取消划线',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    onDismiss();
                    await _bookmarkService.addNote(
                      bookId: widget.book.bookId,
                      chapterIndex: chapterIndex,
                      chapterTitle: widget.chapters[chapterIndex].title,
                      paragraphIndex: paraIndex >= 0 ? paraIndex : 0,
                      text: cleanSelected,
                      note: '',
                    );
                    await _loadNotes();
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('已添加虚线划线'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 15,
                    color: Colors.white,
                  ),
                  label: const Text(
                    '划线',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAutoScrollControlBar(ReaderTheme theme) {
    return Positioned(
      bottom: 24,
      left: 20,
      right: 20,
      child: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _autoRunningNotifier,
            _autoControlsVersion,
          ]),
          builder: (context, _) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: theme.backgroundColor.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: theme.secondaryColor.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '自动阅读',
                  style: TextStyle(
                    color: theme.textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.remove_circle_outline,
                    color: theme.secondaryColor,
                    size: 20,
                  ),
                  tooltip: '减速',
                  onPressed: _autoScrollSpeed > 15
                      ? () => _changeAutoSpeed(-5)
                      : null,
                ),
                Text(
                  '${_autoScrollSpeed.toInt()} px/s',
                  style: TextStyle(color: theme.textColor, fontSize: 12),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: theme.secondaryColor,
                    size: 20,
                  ),
                  tooltip: '加速',
                  onPressed: _autoScrollSpeed < 100
                      ? () => _changeAutoSpeed(5)
                      : null,
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _autoScrollTicker?.isActive == true
                        ? Icons.pause_circle
                        : Icons.play_circle,
                    color: Theme.of(context).primaryColor,
                    size: 24,
                  ),
                  tooltip: _autoScrollTicker?.isActive == true ? '暂停' : '继续',
                  onPressed: () {
                    if (_autoScrollTicker?.isActive == true) {
                      _pauseAutoScroll();
                    } else {
                      _startAutoScroll();
                    }
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close,
                    color: theme.secondaryColor,
                    size: 20,
                  ),
                  tooltip: '退出自动阅读',
                  onPressed: _stopAutoScroll,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderPageAddress {
  final int chapterIndex;
  final int pageIndex;
  final ReaderChapterPages layout;
  final ReadingPosition? anchor;

  const _ReaderPageAddress(
    this.chapterIndex,
    this.pageIndex,
    this.layout, {
    this.anchor,
  });

  ReaderPage get page => layout.pages[pageIndex];

  bool isBefore(_ReaderPageAddress other) =>
      chapterIndex < other.chapterIndex ||
      (chapterIndex == other.chapterIndex && pageIndex < other.pageIndex);

  @override
  bool operator ==(Object other) =>
      other is _ReaderPageAddress &&
      chapterIndex == other.chapterIndex &&
      pageIndex == other.pageIndex &&
      layout.key == other.layout.key;

  @override
  int get hashCode => Object.hash(chapterIndex, pageIndex, layout.key);
}

/// 记录视口内已挂载段落的轻量元信息
class _MountedParagraphInfo {
  final int chapterIndex;
  final int paraIndex;
  final BuildContext context;

  const _MountedParagraphInfo({
    required this.chapterIndex,
    required this.paraIndex,
    required this.context,
  });
}

/// 视口内段落挂载生命周期追踪器（零布局/零绘制开销，仅在 SliverList 挂载/卸载段落时登记上下文）
class _ViewportParagraphTracker extends StatefulWidget {
  final String paraKey;
  final int chapterIndex;
  final int paraIndex;
  final void Function(
    String key,
    int chapterIndex,
    int paraIndex,
    BuildContext context,
  )
  onMount;
  final void Function(String key) onUnmount;
  final Widget child;

  const _ViewportParagraphTracker({
    super.key,
    required this.paraKey,
    required this.chapterIndex,
    required this.paraIndex,
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });

  @override
  State<_ViewportParagraphTracker> createState() => _ViewportParagraphTrackerState();
}

class _ViewportParagraphTrackerState extends State<_ViewportParagraphTracker> {
  @override
  void initState() {
    super.initState();
    widget.onMount(
      widget.paraKey,
      widget.chapterIndex,
      widget.paraIndex,
      context,
    );
  }

  @override
  void didUpdateWidget(covariant _ViewportParagraphTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paraKey != widget.paraKey) {
      widget.onUnmount(oldWidget.paraKey);
    }
    widget.onMount(
      widget.paraKey,
      widget.chapterIndex,
      widget.paraIndex,
      context,
    );
  }

  @override
  void dispose() {
    widget.onUnmount(widget.paraKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}


class _ReaderSheetLifetime extends StatefulWidget {
  final Widget child;
  final VoidCallback onDispose;
  const _ReaderSheetLifetime({required this.child, required this.onDispose});
  @override
  State<_ReaderSheetLifetime> createState() => _ReaderSheetLifetimeState();
}
class _ReaderSheetLifetimeState extends State<_ReaderSheetLifetime> {
  @override
  void dispose() { widget.onDispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => widget.child;
}
