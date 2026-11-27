import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../models/reading_position.dart';
import '../../services/api_service.dart';
import '../../services/app_storage.dart';
import '../../services/bookshelf_service.dart';
import '../../services/cover_cache_service.dart';
import '../../services/reader_library_service.dart';
import '../../services/reader_platform.dart';
import '../../services/reader_position_service.dart';
import '../../services/reader_system_service.dart';
import '../../services/reading_history_service.dart';
import '../../services/tts_service.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import 'audio_cache_manager.dart';
import 'chunk_planner.dart';
import 'context_builder.dart';
import 'identity_coordinator.dart';
import 'immersive_audio_player_bridge.dart';
import 'immersive_database.dart';
import 'immersive_job_scheduler.dart';
import 'immersive_config_service.dart';
import 'source_normalizer.dart';
import 'manifest_builder.dart';
import 'text_model_adapter.dart';
import 'tts_provider_adapter.dart';

/// 沉浸式播放器运行状态
enum ImmersivePlayState { stopped, preparingPrefix, buffering, playing, paused, blocked }

/// 原生音频通道调用函数签名（便于测试注入桩）
typedef PlatformAudioInvoker =
    Future<Object?> Function(String method, Map<String, Object?>? args);

/// 沉浸式多角色听书总控协调器与顺序播放器（全局唯一权威实例）
class ImmersivePlaybackCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  static final ImmersivePlaybackCoordinator _instance =
      ImmersivePlaybackCoordinator._internal();
  factory ImmersivePlaybackCoordinator() => _instance;

  static const _tokenPrefix = 'immersive:';

  ImmersivePlaybackCoordinator._internal()
    : _isTestInstance = false,
      _invoke = _defaultPlatformInvoke,
      _httpClient = http.Client(),
      _configService = ImmersiveConfigService(),
      _storeOverride = null,
      _testAudioCacheDir = null,
      _testTempDir = null,
      _freeDiskProbe = null,
      _platformAudioProbe = null,
      _now = DateTime.now {
    _textAdapter = OpenAiChatTextModelAdapter(_httpClient);
    _ttsAdapter = OpenAiSpeechTtsAdapter(_httpClient);
    WidgetsBinding.instance.addObserver(this);
    _bindPlatformListeners();
  }

  /// 测试专用构造器：允许注入可控模拟器、内存状态库与自定义时钟
  @visibleForTesting
  ImmersivePlaybackCoordinator.forTesting({
    required ImmersiveConfigService configService,
    required ImmersiveStateStore stateStore,
    required TextModelAdapter textAdapter,
    required TtsProviderAdapter ttsAdapter,
    required PlatformAudioInvoker invoke,
    required String audioCacheDir,
    required String tempDir,
    DateTime Function()? now,
    Future<int?> Function(String path)? freeDiskProbe,
    Future<({bool valid, int durationMs})> Function(String, int)?
    platformAudioProbe,
  }) : _isTestInstance = true,
       _invoke = invoke,
       _httpClient = http.Client(),
       _configService = configService,
       _storeOverride = stateStore,
       _textAdapter = textAdapter,
       _ttsAdapter = ttsAdapter,
       _testAudioCacheDir = audioCacheDir,
       _testTempDir = tempDir,
       _freeDiskProbe = freeDiskProbe,
       _platformAudioProbe = platformAudioProbe,
       _now = now ?? DateTime.now;

  static Future<Object?> _defaultPlatformInvoke(
    String method,
    Map<String, Object?>? args,
  ) async {
    if (ReaderPlatform.isDesktop && !ReaderPlatform.capabilities.tts) {
      return null;
    }
    return ReaderPlatform.invoke<Object?>(method, args);
  }

  final bool _isTestInstance;
  final PlatformAudioInvoker _invoke;
  final http.Client _httpClient;
  final ImmersiveConfigService _configService;
  final ImmersiveStateStore? _storeOverride;
  late final TextModelAdapter _textAdapter;
  late final TtsProviderAdapter _ttsAdapter;
  final String? _testAudioCacheDir;
  final String? _testTempDir;
  final Future<int?> Function(String path)? _freeDiskProbe;
  final Future<({bool valid, int durationMs})> Function(String, int)?
  _platformAudioProbe;
  final DateTime Function() _now;
  final ApiService _api = ApiService();

  ImmersiveStateStore? _store;
  AudioCacheManager? _cacheManager;
  IdentityCoordinator? _identityCoordinator;
  ImmersiveJobScheduler? _scheduler;

  bool _initialized = false;
  bool _closed = false;
  bool _listenersBound = false;
  bool _appForeground = true;

  // 当前播放会话状态
  ImmersivePlayState _state = ImmersivePlayState.stopped;
  int _playbackEpoch = 0;
  int _playSerial = 0;
  String? _activePlayToken;
  String? _activePlayingSegmentId;
  PinnedAudioHandle? _currentPinnedAudio;
  PinnedAudioHandle? _preloadedPinnedAudio;
  String? _preloadedPlayToken;
  String? _preloadedSegmentId;
  int? _preloadedSegmentIndex;
  String? _preloadingSegmentId;
  PinnedAudioHandle? _previewPinnedHandle;
  String? _previewPlayToken;
  String? _previewingVoiceProfileId;

  Book? _book;
  List<Chapter> _chapters = const [];
  Future<String?> Function(Chapter)? _contentLoader;
  bool _offlineOnly = false;
  BookRevision? _currentRevision;
  BookAudioConfig? _currentBookAudioConfig;
  final Map<int, bool> _loadedChapters = {};
  final Map<String, String> _chapterRawTexts = {};

  List<SourceUnit> _units = const [];
  Map<String, SourceUnit> _unitById = const {};
  List<AnalysisChunk> _chunks = const [];
  List<AudioSegment> _manifestSegments = const [];
  int _currentSegmentIndex = 0;
  int _targetGlobalOrder = 0;
  int _minWindowChunkOrder = 0;
  int _currentChapterIndex = 0;
  int _pendingResumePositionMs = 0;
  double _playbackRate = 1.0;
  final Set<String> _runtimeFailedVoiceProfileIds = {};

  bool _startupSatisfied = false;
  bool _checkingPlayback = false;
  bool _pendingCheckPlayback = false;
  int? _firstReadyObservedAtMs;
  Timer? _startupGraceTimer;
  Timer? _cursorSaveTimer;
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  bool _stopAfterCurrentChapter = false;
  int? _sessionStartedAtMs;
  int? _firstAudioLatencyMs;
  int _stallCount = 0;
  int _cachedUsedBytes = 0;
  String? _notice;
  String? _errorMessage;

  // 通勤离线预合成任务状态
  bool _isPreSynthesizing = false;
  bool _preSynthCancelled = false;
  int _preSynthCompletedChapters = 0;
  int _preSynthTotalChapters = 0;
  String _preSynthProgressText = '';

  // 只读 getter
  bool get isInitialized => _initialized;
  ImmersiveConfig? get config => _configService.currentConfig;
  ImmersiveStateStore? get activeStateStore => _store;
  List<ConfigValidationIssue> get configIssues => _configService.lastIssues;
  ImmersivePlayState get state => _state;
  bool get isActive => _state != ImmersivePlayState.stopped;
  bool get isPlaying => _state == ImmersivePlayState.playing;
  bool get isPaused => _state == ImmersivePlayState.paused;
  bool get isBuffering =>
      _state == ImmersivePlayState.buffering ||
      _state == ImmersivePlayState.preparingPrefix;
  Book? get currentBook => _book;
  String? get currentBookId => _book?.bookId;
  String get currentBookTitle => _book?.bookName ?? '';
  String get currentChapterTitle =>
      _currentChapterIndex >= 0 && _currentChapterIndex < _chapters.length
          ? _chapters[_currentChapterIndex].title
          : '';
  int get currentChapterIndex => _currentChapterIndex;
  int get playbackEpoch => _playbackEpoch;
  double get playbackRate => _playbackRate;
  List<AudioSegment> get manifestSegments => List.unmodifiable(_manifestSegments);
  int get currentSegmentIndex => _currentSegmentIndex;
  AudioSegment? get currentSegment =>
      _currentSegmentIndex >= 0 && _currentSegmentIndex < _manifestSegments.length
          ? _manifestSegments[_currentSegmentIndex]
          : null;
  String? get notice => _notice;
  String? get errorMessage => _errorMessage;
  bool get isPreSynthesizing => _isPreSynthesizing;
  int get preSynthCompletedChapters => _preSynthCompletedChapters;
  int get preSynthTotalChapters => _preSynthTotalChapters;
  String get preSynthProgressText => _preSynthProgressText;
  String? get previewingVoiceProfileId => _previewingVoiceProfileId;
  ImmersiveStateStore? get stateStore => _store;
  AudioCacheManager? get cacheManager => _cacheManager;
  ImmersiveJobScheduler? get scheduler => _scheduler;
  TextAnalysisConfig? get activeTextModelConfig =>
      _scheduler?.activeTextModel ?? config?.primaryTextModel;
  String get activeTextModelLabel {
    final model = activeTextModelConfig;
    if (model == null) return '';
    return model.displayName.trim().isNotEmpty
        ? model.displayName.trim()
        : model.modelId;
  }

  String get activeTextModelId => activeTextModelConfig?.modelId ?? '';
  bool get isUsingFallbackTextModel =>
      _scheduler?.isUsingFallbackTextModel ?? false;

  /// 手动关闭播放器上的错误/提示横幅（清空内存报错与阻塞横幅显示）
  void dismissIssue() {
    _errorMessage = null;
    _notice = null;
    _scheduler?.clearErrorState();
    _notify();
  }
  bool get stopAfterCurrentChapter => _stopAfterCurrentChapter;
  DateTime? get sleepDeadline => _sleepDeadline;
  bool get hasSleepSchedule =>
      _stopAfterCurrentChapter || _sleepDeadline != null;
  int get timerRemainingMinutes => _sleepDeadline == null
      ? 0
      : (_sleepDeadline!.difference(_now()).inMilliseconds / 60000)
            .ceil()
            .clamp(0, 1440);

  /// 当前正在播放的阅读位置（供阅读页自动滚动跟随）
  ReadingPosition? get currentPosition {
    final seg = currentSegment;
    if (seg != null) {
      return ReadingPosition(
        chapterId: seg.chapterId,
        paragraphIndex: seg.startParagraphIndex,
        characterOffset: seg.startCharOffset,
      );
    }
    if (_chapters.isNotEmpty && _currentChapterIndex < _chapters.length) {
      return ReadingPosition(chapterId: _chapters[_currentChapterIndex].itemId);
    }
    return null;
  }

  /// 提供给 ReaderScreen 的段级高亮范围（audio_segment 粒度，绝不伪造逐字时间戳）
  ({int start, int end})? spokenRange(
    String bookId,
    String chapterId,
    int paragraphIndex,
  ) {
    if (!isActive || currentBookId != bookId) return null;
    final seg = currentSegment;
    if (seg == null || seg.chapterId != chapterId) return null;
    if (paragraphIndex < seg.startParagraphIndex ||
        paragraphIndex > seg.endParagraphIndex) {
      return null;
    }
    // 查找该段落在当前 AudioSegment 中覆盖的真实原文起止偏移
    var minStart = 1 << 30;
    var maxEnd = -1;
    for (final uid in seg.sourceUnitIds) {
      final u = _unitById[uid];
      if (u != null &&
          u.chapterId == chapterId &&
          u.paragraphIndex == paragraphIndex) {
        if (u.startOffset < minStart) minStart = u.startOffset;
        if (u.endOffset > maxEnd) maxEnd = u.endOffset;
      }
    }
    if (maxEnd > minStart) {
      return (start: minStart, end: maxEnd);
    }
    return null;
  }

  /// 初始化并加载配置、状态库、缓存与统一调度器（应用启动调用，失败不阻断普通阅读）
  Future<ConfigServiceStatus> loadAndValidateConfig({
    File? configFile,
    bool autoInitPreset = true,
  }) async {
    final status = await _configService.loadAndValidateConfig(
      configFile: configFile,
      autoInitPreset: autoInitPreset,
    );
    if (status.config != null) {
      await _setupRuntimeServices(status.config!, status.paths);
      _playbackRate = status.config!.playback.defaultRate;
    }
    _initialized = true;
    _notify();
    return status;
  }

  static bool _hasTextModelConfigChanged(
    ImmersiveConfig? prev,
    ImmersiveConfig next,
  ) {
    if (prev == null) return true;
    if (prev.primaryTextModel.effectiveId != next.primaryTextModel.effectiveId ||
        prev.fallbackTextModel?.effectiveId !=
            next.fallbackTextModel?.effectiveId ||
        prev.textAnalysisModels.length != next.textAnalysisModels.length) {
      return true;
    }
    for (var i = 0; i < prev.textAnalysisModels.length; i++) {
      final a = prev.textAnalysisModels[i];
      final b = next.textAnalysisModels[i];
      if (a.effectiveId != b.effectiveId ||
          a.enabled != b.enabled ||
          a.modelId != b.modelId ||
          a.baseUrl != b.baseUrl ||
          a.endpoint != b.endpoint ||
          a.apiKey != b.apiKey ||
          a.thinkingLevel != b.thinkingLevel ||
          a.contextWindowTokens != b.contextWindowTokens ||
          a.maxOutputTokens != b.maxOutputTokens ||
          a.outputLimitParameter != b.outputLimitParameter ||
          a.structuredOutput.mode != b.structuredOutput.mode ||
          a.structuredOutput.strict != b.structuredOutput.strict) {
        return true;
      }
    }
    return false;
  }

  /// 复活指定书籍中全部阻塞、失败或处于退避等待的任务（立即清零退避时间并重新入队）
  Future<int> _reviveStuckJobsForBook(
    String bookId, {
    String? jobType,
  }) async {
    final store = _store;
    if (store == null) return 0;
    final jobs = await store.listJobs(
      bookId: bookId,
      statuses: const {
        ImmersiveJobStatus.blocked,
        ImmersiveJobStatus.failed,
        ImmersiveJobStatus.retryWait,
      },
    );
    final nowMs = _now().millisecondsSinceEpoch;
    var revivedCount = 0;
    for (final j in jobs) {
      if (jobType != null && j.jobType != jobType) continue;
      await store.enqueueOrReviveJob(
        j.copyWith(updatedAtMs: nowMs),
        reviveTerminal: true,
      );
      revivedCount++;
    }
    return revivedCount;
  }

  /// 保存并热应用配置修改（校验失败不破坏运行快照）
  Future<ConfigServiceStatus> saveConfig(
    ImmersiveConfig newConfig, {
    File? configFile,
  }) async {
    final prevConfig = _configService.currentConfig;
    final status = await _configService.saveConfig(
      newConfig,
      configFile: configFile,
    );
    if (status.config != null) {
      final textChanged = _hasTextModelConfigChanged(prevConfig, status.config!);
      await _setupRuntimeServices(status.config!, status.paths);
      _runtimeFailedVoiceProfileIds.clear();
      if (textChanged) {
        _textAdapter.cancelAll();
        _errorMessage = null;
        _notice = null;
      }
      _scheduler?.updateConfig(status.config!);
      if (textChanged && _book != null) {
        await _reviveStuckJobsForBook(
          _book!.bookId,
          jobType: ImmersiveJobType.chunkAnalysis,
        );
        if (_state == ImmersivePlayState.blocked) {
          _state = ImmersivePlayState.buffering;
        }
      }
      // 若当前有打开的书籍，检查配置变更对当前清单的影响（停用/删除音色将自动按同性别兜底）
      if (_book != null && _currentRevision != null) {
        await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
        await _pushDemandToScheduler();
        if (textChanged && isActive && !isPaused) {
          unawaited(_scheduler?.tick());
        }
      }
    }
    _notify();
    return status;
  }

  Future<void> _setupRuntimeServices(
    ImmersiveConfig cfg,
    ResolvedStoragePaths? paths,
  ) async {
    if (_store == null) {
      if (_storeOverride != null) {
        _store = _storeOverride;
      } else {
        final dbPath =
            paths?.databasePath ??
            p.join((await AppStorage.documents()).path, 'immersive-audio', 'state.sqlite3');
        _store = SqliteImmersiveStateStore(dbPath);
      }
      await _store!.initialize();
    }

    final cacheDir =
        _testAudioCacheDir ??
        paths?.audioCacheDir ??
        p.join((await AppStorage.documents()).path, 'immersive-audio', 'audio');
    final tmpDir =
        _testTempDir ??
        paths?.tempDir ??
        p.join(cacheDir, 'tmp');

    _cacheManager ??= AudioCacheManager(
      store: _store!,
      audioCacheDir: cacheDir,
      tempDir: tmpDir,
      cacheConfig: cfg.cache,
      now: _now,
      freeDiskProbe: _freeDiskProbe,
      platformAudioProbe: _platformAudioProbe,
    );
    await _cacheManager!.ensureDirectories();

    _identityCoordinator ??= IdentityCoordinator(_store!, now: _now);

    if (_scheduler == null) {
      _scheduler = ImmersiveJobScheduler(
        store: _store!,
        identityCoordinator: _identityCoordinator!,
        textAdapter: _textAdapter,
        ttsAdapter: _ttsAdapter,
        cacheManager: _cacheManager!,
        config: cfg,
        now: _now,
      );
      _scheduler!.onProgressChanged = () {
        unawaited(_refreshCacheBytes());
        _notify();
      };
      _scheduler!.onAllocationsCommitted = (bookId, revId) async {
        if (_book?.bookId != bookId || _currentRevision?.revisionId != revId) {
          return;
        }
        await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
        await _pushDemandToScheduler();
        await _checkBufferAndAdvancePlayback();
      };
      _scheduler!.onAudioAssetReady = (requestKey) async {
        // ready 事件只通知重新检查需求与连续缓冲，绝不无条件 enqueue（满足 A01）
        await _syncManifestReadyStates();
        await _checkBufferAndAdvancePlayback();
        await _pushDemandToScheduler();
        if (_state == ImmersivePlayState.playing) {
          unawaited(_tryPreloadNextSegment());
        }
      };
      _scheduler!.onFailoverNotice = (msg) {
        _notice = msg;
        _notify();
      };
      _scheduler!.onVoiceFailedNeedsFallback = (failedVpid, reason) async {
        if (_runtimeFailedVoiceProfileIds.add(failedVpid)) {
          _notice = '音色 $failedVpid 暂不可用（$reason），已自动尝试同性别兜底音色';
          if (_book != null && _currentRevision != null) {
            await _rebuildManifestFromAllocations(
              preservePlayingBoundary: isPlaying,
            );
            await _pushDemandToScheduler();
            await _checkBufferAndAdvancePlayback();
          }
          _notify();
        }
      };
      await _scheduler!.recoverOnStartup();
    }
  }

  /// 测试指定文本分析模型（或当前主模型）的真实 JSON 结构化返回能力
  Future<AnalysisProviderTestResult> testAnalysisProvider({
    TextAnalysisConfig? override,
    String? modelEntryId,
  }) async {
    final cfg = _configService.currentConfig;
    final target =
        override ??
        (modelEntryId != null ? cfg?.findTextModel(modelEntryId) : null) ??
        cfg?.primaryTextModel;
    if (target == null) {
      return const AnalysisProviderTestResult(
        success: false,
        message: '尚未加载有效配置或未找到对应文本模型',
        latencyMs: 0,
        modeUsed: 'none',
      );
    }
    try {
      final key = _configService.resolveTextModelApiKey(target);
      return await _textAdapter.testProvider(config: target, apiKey: key);
    } catch (e) {
      return AnalysisProviderTestResult(
        success: false,
        message: '$e',
        latencyMs: 0,
        modeUsed: target.structuredOutput.mode,
      );
    }
  }

  /// 对指定音色配置发起精确路由短文本在线合成测试，并在本地验证可解码与可选播放
  Future<VoiceProfileTestResult> testVoiceProfile(
    String voiceProfileId, {
    bool playResult = true,
  }) async {
    final cfg = _configService.currentConfig;
    if (cfg == null) {
      return const VoiceProfileTestResult(
        success: false,
        message: '尚未加载有效配置',
        latencyMs: 0,
      );
    }
    final res = cfg.resolveVoiceProfile(voiceProfileId);
    if (res == null) {
      return VoiceProfileTestResult(
        success: false,
        message: '未找到音色配置：$voiceProfileId',
        latencyMs: 0,
      );
    }
    try {
      final key = res.provider.adapter == 'native_tts'
          ? ''
          : _configService.resolveTtsApiKey(res.provider);
      final result = await _ttsAdapter.testVoiceProfile(
        resolution: res,
        apiKey: key,
      );
      if (result.success && playResult && result.audioBytes != null) {
        await _playPreviewBytes(
          voiceProfileId: voiceProfileId,
          bytes: result.audioBytes!,
          ext: result.audioFormat ?? 'mp3',
        );
      }
      return result;
    } catch (e) {
      return VoiceProfileTestResult(
        success: false,
        message: '$e',
        latencyMs: 0,
      );
    }
  }

  /// 直接播放内置 assets/TTS-Example 本地试听样本（零网络延迟）
  Future<bool> playLocalVoiceSample({
    required String voiceProfileId,
    required String assetPath,
  }) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final ext = p.extension(assetPath).replaceFirst('.', '');
      return await _playPreviewBytes(
        voiceProfileId: voiceProfileId,
        bytes: bytes,
        ext: ext.isEmpty ? 'wav' : ext,
      );
    } catch (e) {
      _errorMessage = '本地试听样本播放失败：$e';
      _notify();
      return false;
    }
  }

  Future<bool> _playPreviewBytes({
    required String voiceProfileId,
    required Uint8List bytes,
    required String ext,
  }) async {
    if (isPlaying) await pause();
    final tmpRoot = await getTemporaryDirectory();
    final file = File(
      p.join(tmpRoot.path, 'immersive_preview_${voiceProfileId.hashCode}.$ext'),
    );
    await file.writeAsBytes(bytes, flush: true);
    final token = '${_tokenPrefix}preview:${++_playSerial}';
    _previewPlayToken = token;
    _previewingVoiceProfileId = voiceProfileId;
    _notify();
    final ok = await _safeInvoke('playAudioFile', {
      'id': token,
      'filePath': file.path,
      'rate': 1.0,
      'preservePitch': true,
    });
    if (ok != true) {
      _previewPlayToken = null;
      _previewingVoiceProfileId = null;
      _notify();
      return false;
    }
    return true;
  }

  /// 准备书籍状态：建立或恢复 BookRevision、BookAudioConfig（仅新书由 book_defaults 初始化）与历史检查点
  Future<BookRevision> prepareBook({
    required Book book,
    required List<Chapter> chapters,
    required int anchorChapterIndex,
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
  }) async {
    if (!_initialized) {
      await loadAndValidateConfig();
    }
    final cfg = _configService.currentConfig;
    if (cfg == null) {
      throw StateError('沉浸式听书配置无效或未就绪，请先检查设置');
    }
    if (!cfg.featureEnabled) {
      throw StateError('沉浸式听书功能当前已关闭，请在设置中开启');
    }

    _book = book;
    _chapters = List.unmodifiable(chapters);
    _contentLoader = contentLoader;
    _offlineOnly = offlineOnly;

    // 1. 仅新书由全局 book_defaults 初始化，已有书籍保留独立快照不被全局修改覆盖
    var bookCfg = await _store!.getBookAudioConfig(book.bookId);
    if (bookCfg == null) {
      bookCfg = BookAudioConfig(
        bookId: book.bookId,
        selectedVoiceProfileIds: List.of(cfg.bookDefaults.selectedVoiceProfileIds),
        narratorVoiceProfileId: cfg.bookDefaults.narratorVoiceProfileId,
        allowVoiceReuse: cfg.bookDefaults.allowVoiceReuse,
        reserveNarratorForNonDialogue:
            cfg.bookDefaults.reserveNarratorForNonDialogue,
        updatedAtMs: _now().millisecondsSinceEpoch,
      );
      await _store!.saveBookAudioConfig(bookCfg);
    }
    _currentBookAudioConfig = bookCfg;

    // 2. 确定需要载入正文的章节范围：
    //    空降任意章节时，最多向前自动回溯 max_prefix_backtrack_chapters（默认 5 章）建档，
    //    绝不拉取千章长书更早的无关章节。
    final maxBacktrack = cfg.analysisPipeline.maxPrefixBacktrackChapters;
    final windowStartChapter = math.max(0, anchorChapterIndex - maxBacktrack);
    final endChapterToLoad = (anchorChapterIndex + cfg.analysisPipeline.aheadChapters)
        .clamp(0, chapters.isEmpty ? 0 : chapters.length - 1);

    final stableRevId = SourceNormalizer.stableRevisionIdForBook(book.bookId);
    final existingRev =
        await _store!.getBookRevision(stableRevId) ??
        await _store!.getLatestBookRevision(book.bookId);

    _loadedChapters.clear();
    _chapterRawTexts.clear();

    final sysCatalogTokens = ContextBuilder.buildSystemMessage(
      config: cfg,
      bookConfig: bookCfg,
    ).estimatedTokens;

    if (existingRev != null && existingRev.revisionId == stableRevId) {
      // 稳定版本已存在：复用历史已载入章节，仅对当前窗口内尚未入库的新章节做增量加载与追加
      final storedUnits = await _store!.getSourceUnits(stableRevId);
      final storedChapterIndices = {for (final u in storedUnits) u.chapterIndex};
      for (final idx in storedChapterIndices) {
        _loadedChapters[idx] = true;
      }

      final newUnits = <SourceUnit>[];
      for (var i = windowStartChapter; i <= endChapterToLoad; i++) {
        if (storedChapterIndices.contains(i)) continue;
        final text = await _loadChapterText(book, chapters[i]);
        if (text == null) continue;
        _chapterRawTexts[chapters[i].itemId] = text;
        _loadedChapters[i] = true;
        newUnits.addAll(
          SourceNormalizer.normalizeSingleChapter(
            bookId: book.bookId,
            bookRevisionId: stableRevId,
            chapterIndex: i,
            chapter: chapters[i],
            rawText: text,
            startingGlobalOrder: SourceNormalizer.chapterScopedGlobalOrder(i, 0),
          ),
        );
      }

      final mergedUnits = [...storedUnits, ...newUnits]
        ..sort((a, b) => a.globalOrder.compareTo(b.globalOrder));
      final existingChunks = await _store!.getAnalysisChunks(stableRevId);

      if (newUnits.isNotEmpty || existingChunks.isEmpty) {
        final replannedChunks = ChunkPlanner.planChunks(
          bookId: book.bookId,
          bookRevisionId: stableRevId,
          allOrderedUnits: mergedUnits,
          pipelineConfig: cfg.analysisPipeline,
          textConfig: cfg.primaryTextModel,
          systemVoiceCatalogTokens: sysCatalogTokens,
          useChapterScopedChunkOrder: true,
          fastStartChapterIndex: anchorChapterIndex,
        );
        await _store!.appendChapterUnitsAndChunks(
          bookRevisionId: stableRevId,
          units: newUnits,
          chunks: replannedChunks,
        );
        _chunks = replannedChunks;
      } else {
        _chunks = existingChunks;
      }
      _currentRevision = existingRev;
      _units = mergedUnits;
    } else {
      // 首次初始化本书稳定版本：仅加载 [windowStartChapter .. endChapterToLoad]
      final windowUnits = <SourceUnit>[];
      for (var i = windowStartChapter; i <= endChapterToLoad; i++) {
        final text = await _loadChapterText(book, chapters[i]);
        if (text == null) continue;
        _chapterRawTexts[chapters[i].itemId] = text;
        _loadedChapters[i] = true;
        windowUnits.addAll(
          SourceNormalizer.normalizeSingleChapter(
            bookId: book.bookId,
            bookRevisionId: stableRevId,
            chapterIndex: i,
            chapter: chapters[i],
            rawText: text,
            startingGlobalOrder: SourceNormalizer.chapterScopedGlobalOrder(i, 0),
          ),
        );
      }

      final rev = BookRevision(
        revisionId: stableRevId,
        bookId: book.bookId,
        sourceFileHash: stableRevId,
        normalizedTextHash: stableRevId,
        parserVersion: SourceNormalizer.parserVersion,
        chapterCount: chapters.length,
        createdAtMs: _now().millisecondsSinceEpoch,
      );
      final chunks = ChunkPlanner.planChunks(
        bookId: book.bookId,
        bookRevisionId: stableRevId,
        allOrderedUnits: windowUnits,
        pipelineConfig: cfg.analysisPipeline,
        textConfig: cfg.primaryTextModel,
        systemVoiceCatalogTokens: sysCatalogTokens,
        useChapterScopedChunkOrder: true,
        fastStartChapterIndex: anchorChapterIndex,
      );
      await _store!.saveBookRevisionWithUnits(
        revision: rev,
        units: windowUnits,
        chunks: chunks,
      );
      _currentRevision = rev;
      _units = windowUnits;
      _chunks = chunks;
    }

    _unitById = {for (final u in _units) u.unitId: u};
    // 记录本次窗口起点分块号，确保空降第 1000 章时有序提交最多从第 995 章起步
    final windowChunk = _chunks.where((c) => c.chapterIndex >= windowStartChapter);
    _minWindowChunkOrder = windowChunk.isEmpty ? 0 : windowChunk.first.chunkOrder;
    return _currentRevision!;
  }

  /// 重建当前书籍的编排数据：从当前阅读章节开始（最多回溯往前 5 章）清除旧编排并重新分析配音
  Future<void> rebuildArrangementFromCurrentChapter({
    Book? book,
    List<Chapter>? chapters,
    int? chapterIndex,
    ReadingPosition? position,
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
    bool restartPlayback = true,
  }) async {
    if (!_initialized) {
      await loadAndValidateConfig();
    }
    final targetBook = book ?? _book;
    final targetChapters = chapters ?? _chapters;
    final targetIdx = chapterIndex ?? _currentChapterIndex;
    final targetLoader = contentLoader ?? _contentLoader;
    final targetOffline = chapters != null ? offlineOnly : _offlineOnly;

    if (targetBook == null || _store == null) {
      throw StateError('当前未打开有效书籍，无法重建编排');
    }

    await stop();
    await _store!.resetBookArrangement(
      targetBook.bookId,
      nowMs: _now().millisecondsSinceEpoch,
    );
    _runtimeFailedVoiceProfileIds.clear();
    _loadedChapters.clear();
    _chapterRawTexts.clear();
    _units = const [];
    _unitById = const {};
    _chunks = const [];
    _manifestSegments = const [];
    _currentRevision = null;
    _scheduler?.resetTextModelFailover();
    _notice = '已清空旧编排数据，正在从当前章节（最多回溯 5 章）重新建档编排…';
    _notify();

    if (restartPlayback && targetChapters.isNotEmpty) {
      await startImmersivePlayback(
        book: targetBook,
        chapters: targetChapters,
        chapterIndex: targetIdx.clamp(0, targetChapters.length - 1),
        position: position,
        contentLoader: targetLoader,
        offlineOnly: targetOffline,
      );
    }
  }

  /// 从指定章节与原文位置启动沉浸式多角色听书
  Future<void> startImmersivePlayback({
    required Book book,
    required List<Chapter> chapters,
    required int chapterIndex,
    ReadingPosition? position,
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
  }) async {
    if (!_isTestInstance) {
      unawaited(TtsService.ensureAndroidNotificationPermission());
      // 互斥：停掉普通单声听书，确保只有一个音频所有者
      if (TtsService().isActive) {
        await TtsService().stop();
      }
    }
    _errorMessage = null;
    _notice = null;
    _scheduler?.clearErrorState(resetFailover: true);
    _sessionStartedAtMs = _now().millisecondsSinceEpoch;
    _firstAudioLatencyMs = null;
    _stallCount = 0;

    final safeIdx = chapterIndex.clamp(0, chapters.length - 1);
    _currentChapterIndex = safeIdx;
    final startEpoch = ++_playbackEpoch;
    _startupSatisfied = false;
    _firstReadyObservedAtMs = null;
    _startupGraceTimer?.cancel();
    _releaseCurrentPin();
    await _stopNativeAudioOnly();
    if (_playbackEpoch != startEpoch) return;

    _state = ImmersivePlayState.buffering;
    _notify();

    try {
      await prepareBook(
        book: book,
        chapters: chapters,
        anchorChapterIndex: safeIdx,
        contentLoader: contentLoader,
        offlineOnly: offlineOnly,
      );
    } catch (e) {
      if (_playbackEpoch != startEpoch) return;
      _state = ImmersivePlayState.blocked;
      _errorMessage = '$e';
      _notify();
      return;
    }
    if (_playbackEpoch != startEpoch || _state == ImmersivePlayState.stopped) {
      return;
    }

    // 启动会话时复活本书历史遗留的阻塞/失败/退避任务，保证切换模型重开立刻用新模型重跑
    await _reviveStuckJobsForBook(book.bookId);
    if (_playbackEpoch != startEpoch || _state == ImmersivePlayState.stopped) {
      return;
    }

    // 定位目标原文单元
    final targetPos =
        position ?? ReadingPosition(chapterId: chapters[safeIdx].itemId);
    final anchorUnit =
        SourceNormalizer.unitForPosition(_units, targetPos) ??
        _units.firstWhere(
          (u) => u.chapterIndex >= safeIdx,
          orElse: () => _units.first,
        );
    _targetGlobalOrder = anchorUnit.globalOrder;

    // 尝试恢复上次光标的倍速与同资产片内时间（若资产未变化）
    final savedCursor = await _store!.getPlaybackCursor(book.bookId);
    if (savedCursor != null) {
      _playbackRate = savedCursor.playbackRate.clamp(0.5, 2.0);
    }

    await _rebuildManifestFromAllocations(preservePlayingBoundary: false);
    _alignSegmentIndexToGlobalOrder(_targetGlobalOrder);

    if (savedCursor != null &&
        currentSegment != null &&
        savedCursor.audioRequestKey == currentSegment!.requestKey &&
        savedCursor.positionInSegmentMs > 0) {
      final asset = await _cacheManager!.peekValidAssetMetadata(
        currentSegment!.requestKey,
      );
      if (asset != null &&
          asset.contentSha256 == savedCursor.audioContentSha256) {
        _pendingResumePositionMs = savedCursor.positionInSegmentMs;
      }
    }

    // 检查是否需要前缀人物补齐（从中间章节首次起听且无前缀检查点）
    final latestCp = await _store!.getLatestCheckpoint(
      book.bookId,
      _currentRevision!.revisionId,
    );
    final confirmedThrough = latestCp?.confirmedThroughGlobalOrder ?? -1;
    if (confirmedThrough < _targetGlobalOrder && safeIdx > 0) {
      _state = ImmersivePlayState.preparingPrefix;
    } else {
      _state = ImmersivePlayState.buffering;
    }

    _syncMediaNotification();
    _startCursorSaveTimer();
    await _pushDemandToScheduler(isSeek: true);
    await _checkBufferAndAdvancePlayback();
    _notify();
  }

  /// 暂停播放：立即停播放器、保存位置与暂停状态、停止新增分析/TTS 预取（在途可完成缓存 A08）
  Future<void> pause() async {
    if (!isActive || isPaused) return;
    _startupGraceTimer?.cancel();
    _releasePreloadedPin(notifyNative: true);
    _state = ImmersivePlayState.paused;
    await _persistCursor(userPaused: true);
    await _safeInvoke('pauseAudio', {'id': _activePlayToken});
    await _pushDemandToScheduler();
    _syncMediaNotification();
    _notify();
  }

  /// 恢复播放：重算连续缓冲与需求，恢复或重新起播当前段
  Future<void> resume() async {
    if (!isPaused || _book == null || _currentRevision == null) return;
    _errorMessage = null;
    if (_activePlayToken != null && _currentPinnedAudio != null) {
      final resumed = await _safeInvoke('resumeAudio', {'id': _activePlayToken});
      if (resumed == true) {
        _state = ImmersivePlayState.playing;
        await _persistCursor(userPaused: false);
        await _pushDemandToScheduler();
        unawaited(_tryPreloadNextSegment());
        _syncMediaNotification();
        _notify();
        return;
      }
    }
    _state = ImmersivePlayState.buffering;
    _startupSatisfied = false;
    await _persistCursor(userPaused: false);
    await _pushDemandToScheduler();
    await _checkBufferAndAdvancePlayback();
    _syncMediaNotification();
    _notify();
  }

  /// 停止当前播放会话（保留角色档案、已确认分配和音频缓存）
  Future<void> stop() async {
    _playbackEpoch++;
    _activePlayToken = null;
    _activePlayingSegmentId = null;
    _startupGraceTimer?.cancel();
    _cursorSaveTimer?.cancel();
    _clearSleepSchedule(notifyNative: true);
    _startupSatisfied = false;
    _firstReadyObservedAtMs = null;
    _pendingResumePositionMs = 0;
    _releaseCurrentPin();
    _state = ImmersivePlayState.stopped;
    _errorMessage = null;
    _notice = null;
    _textAdapter.cancelAll();
    _scheduler?.stop();
    // 第一时间通知界面关闭播放面板，避免被后续持久化或原生音频释放阻塞
    _notify();

    if (_book != null && _currentRevision != null) {
      try {
        await _persistCursor(userPaused: false);
      } catch (_) {}
    }
    await _safeInvoke('stopPlayback');
    await _safeInvoke('releasePlaybackService');
    _notify();
  }

  /// 跳转到新章节/原文位置（递增 playback_epoch，保留角色库和通用音频缓存 A07）
  Future<void> seekToSource({
    required int chapterIndex,
    required ReadingPosition position,
  }) async {
    if (_book == null || _currentRevision == null) return;
    _playbackEpoch++;
    _activePlayToken = null;
    _activePlayingSegmentId = null;
    _pendingResumePositionMs = 0;
    _startupSatisfied = false;
    _firstReadyObservedAtMs = null;
    _startupGraceTimer?.cancel();
    _releaseCurrentPin();
    await _stopNativeAudioOnly();

    final safeIdx = chapterIndex.clamp(0, _chapters.length - 1);
    _currentChapterIndex = safeIdx;
    await _ensureWindowChaptersLoaded(safeIdx);

    final targetUnit =
        SourceNormalizer.unitForPosition(_units, position) ??
        _units.firstWhere(
          (u) => u.chapterIndex >= safeIdx,
          orElse: () => _units.first,
        );
    _targetGlobalOrder = targetUnit.globalOrder;
    await _rebuildManifestFromAllocations(preservePlayingBoundary: false);
    _alignSegmentIndexToGlobalOrder(_targetGlobalOrder);

    // 若目标段已被 LRU 淘汰导致历史上 succeeded 但文件缺失，重检需求时调度器会自动原子重建（A21）
    await _syncManifestReadyStates();

    final latestCp = await _store!.getLatestCheckpoint(
      _book!.bookId,
      _currentRevision!.revisionId,
    );
    _state = (latestCp?.confirmedThroughGlobalOrder ?? -1) < _targetGlobalOrder &&
            safeIdx > 0
        ? ImmersivePlayState.preparingPrefix
        : ImmersivePlayState.buffering;

    await _persistCursor(userPaused: false);
    await _pushDemandToScheduler(isSeek: true);
    await _checkBufferAndAdvancePlayback();
    _syncMediaNotification();
    _notify();
  }

  Future<void> nextSegment() async {
    if (_currentSegmentIndex + 1 >= _manifestSegments.length) return;
    final next = _manifestSegments[_currentSegmentIndex + 1];
    await seekToSource(
      chapterIndex: next.chapterIndex,
      position: ReadingPosition(
        chapterId: next.chapterId,
        paragraphIndex: next.startParagraphIndex,
        characterOffset: next.startCharOffset,
      ),
    );
  }

  Future<void> previousSegment() async {
    if (_currentSegmentIndex <= 0 || _manifestSegments.isEmpty) return;
    final prev = _manifestSegments[_currentSegmentIndex - 1];
    await seekToSource(
      chapterIndex: prev.chapterIndex,
      position: ReadingPosition(
        chapterId: prev.chapterId,
        paragraphIndex: prev.startParagraphIndex,
        characterOffset: prev.startCharOffset,
      ),
    );
  }

  /// 切换到下一章开头继续沉浸式播放
  Future<void> nextChapter() async {
    if (_book == null || _currentChapterIndex + 1 >= _chapters.length) return;
    final targetIdx = _currentChapterIndex + 1;
    await seekToSource(
      chapterIndex: targetIdx,
      position: ReadingPosition(chapterId: _chapters[targetIdx].itemId),
    );
  }

  /// 切换到上一章开头继续沉浸式播放
  Future<void> previousChapter() async {
    if (_book == null || _currentChapterIndex <= 0) return;
    final targetIdx = _currentChapterIndex - 1;
    await seekToSource(
      chapterIndex: targetIdx,
      position: ReadingPosition(chapterId: _chapters[targetIdx].itemId),
    );
  }

  /// 取消正在进行的通勤离线预合成任务
  void cancelPreSynthesis() {
    if (!_isPreSynthesizing) return;
    _preSynthCancelled = true;
    _preSynthProgressText = '正在停止预合成任务…';
    _notify();
  }

  /// 通勤离线预合成：批量对后续 N 章执行角色分析与语音合成并写入本地缓存，地铁/无网可直接秒播
  Future<void> preSynthesizeUpcomingChapters({
    required Book book,
    required List<Chapter> chapters,
    required int startChapterIndex,
    required int chapterCount,
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
  }) async {
    if (_isPreSynthesizing || chapters.isEmpty) return;
    final safeStart = startChapterIndex.clamp(0, chapters.length - 1);
    final safeCount = chapterCount.clamp(1, 15);
    final endIndex = math.min(chapters.length - 1, safeStart + safeCount - 1);
    final total = endIndex - safeStart + 1;

    _isPreSynthesizing = true;
    _preSynthCancelled = false;
    _preSynthCompletedChapters = 0;
    _preSynthTotalChapters = total;
    _preSynthProgressText = '正在初始化书籍编排状态（共 $total 章）…';
    _notify();

    final wasActive = isActive;
    try {
      await prepareBook(
        book: book,
        chapters: chapters,
        anchorChapterIndex: safeStart,
        contentLoader: contentLoader,
        offlineOnly: offlineOnly,
      );
      final cfg = _configService.currentConfig;
      final rev = _currentRevision;
      final store = _store;
      if (cfg == null || rev == null || store == null) {
        throw StateError('沉浸式听书配置未就绪');
      }

      for (var chIdx = safeStart; chIdx <= endIndex; chIdx++) {
        if (_preSynthCancelled || _closed) break;
        final chapter = chapters[chIdx];
        final step = chIdx - safeStart + 1;
        _preSynthProgressText =
            '预合成第 $step/$total 章：${chapter.title}（载入正文与分析）';
        _notify();

        await _ensureWindowChaptersLoaded(chIdx);
        final chapterUnits = _units
            .where((u) => u.chapterIndex == chIdx)
            .toList();
        if (chapterUnits.isEmpty) {
          _preSynthCompletedChapters = step;
          _notify();
          continue;
        }
        final chapterChunks = _chunks
            .where((c) => c.chapterIndex == chIdx)
            .toList();
        final firstOrder = chapterUnits.first.globalOrder;
        final minChunkOrder = chapterChunks.isEmpty
            ? 0
            : chapterChunks
                  .map((c) => c.chunkOrder)
                  .reduce((a, b) => a < b ? a : b);

        // 驱动调度器为目标章节执行文本分析与并发语音合成
        final scheduler = _scheduler;
        if (scheduler != null) {
          final deadline = _now().add(const Duration(seconds: 120));
          while (!_preSynthCancelled && !_closed && _now().isBefore(deadline)) {
            await _rebuildManifestFromAllocations(
              preservePlayingBoundary: true,
            );
            final chSegs = _manifestSegments
                .where((s) => s.chapterIndex == chIdx)
                .toList();
            final readySegs = <AudioSegment>[];
            for (final seg in chSegs) {
              final asset = await _cacheManager?.peekValidAssetMetadata(
                seg.requestKey,
              );
              if (asset != null) readySegs.add(seg);
            }
            final latestCp = await store.getLatestCheckpoint(
              book.bookId,
              rev.revisionId,
            );
            final allAnalyzed =
                latestCp != null &&
                latestCp.confirmedThroughGlobalOrder >=
                    chapterUnits.last.globalOrder;
            if (allAnalyzed &&
                chSegs.isNotEmpty &&
                readySegs.length >= chSegs.length) {
              break;
            }
            _preSynthProgressText = chSegs.isEmpty
                ? '预合成第 $step/$total 章：${chapter.title}（角色脚本分析中）'
                : '预合成第 $step/$total 章：${chapter.title}（语音 ${readySegs.length}/${chSegs.length}）';
            _notify();

            final firstSegIdx = _manifestSegments.indexWhere(
              (s) => s.chapterIndex == chIdx,
            );
            await scheduler.updateDemand(
              SchedulerDemandSnapshot(
                bookId: book.bookId,
                bookRevisionId: rev.revisionId,
                currentChapterIndex: chIdx,
                targetGlobalOrder: firstOrder,
                minWindowChunkOrder: minChunkOrder,
                playbackRate: _playbackRate,
                continuousReadySeconds: 0,
                paused: false,
                currentManifestSegments: List.unmodifiable(_manifestSegments),
                currentSegmentIndex: firstSegIdx >= 0 ? firstSegIdx : 0,
                limitPrefetchToCurrentChapter: true,
                resolveTtsApiKey: (provider) =>
                    _configService.resolveTtsApiKey(provider),
                resolveTextApiKey: () => _configService.resolveTextApiKey(cfg),
                resolveTextModelApiKey: (model) =>
                    _configService.resolveTextModelApiKey(model),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 900));
          }
        }
        _preSynthCompletedChapters = step;
        _notify();
      }

      await _refreshCacheBytes();
      _preSynthProgressText = _preSynthCancelled
          ? '已停止预合成（已完成 $_preSynthCompletedChapters/$total 章）'
          : '通勤预合成完成：已离线就绪 $_preSynthCompletedChapters/$total 章';
    } catch (e) {
      _preSynthProgressText = '预合成中断：$e';
    } finally {
      _isPreSynthesizing = false;
      _preSynthCancelled = false;
      if (wasActive && isActive) {
        unawaited(_pushDemandToScheduler());
      } else {
        unawaited(_scheduler?.updateDemand(null));
      }
      _notify();
    }
  }

  /// 调整本地播放器倍速（绝不重新合成音频，只重算连续可播秒数 A06）
  Future<void> setPlaybackRate(double rate) async {
    final clamped = rate.clamp(0.5, 2.0);
    if ((_playbackRate - clamped).abs() < 0.01) return;
    _playbackRate = clamped;
    await _safeInvoke('setPlaybackRate', {
      'rate': _playbackRate,
      'preservePitch': _configService.currentConfig?.playback.preservePitch ?? true,
    });
    if (_state == ImmersivePlayState.playing) {
      _releasePreloadedPin(notifyNative: true);
      unawaited(_tryPreloadNextSegment());
    }
    await _persistCursor(userPaused: isPaused);
    await _pushDemandToScheduler();
    _notify();
  }

  /// 设置“播完本章停止”开关，开启后禁止跨章预装与超前拉取下一章
  void setStopAfterCurrentChapter(bool value) {
    if (_stopAfterCurrentChapter == value) return;
    _stopAfterCurrentChapter = value;
    if (value) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepDeadline = null;
      unawaited(_safeInvoke('setSleepDeadline', {'milliseconds': 0}));
      if (_preloadedSegmentIndex != null &&
          _preloadedSegmentIndex! < _manifestSegments.length) {
        final nextSeg = _manifestSegments[_preloadedSegmentIndex!];
        if (nextSeg.chapterIndex != _currentChapterIndex) {
          _releasePreloadedPin(notifyNative: true);
        }
      }
    }
    if (isActive) {
      unawaited(_pushDemandToScheduler());
    }
    _notify();
  }

  /// 切换“播完本章停止”开关
  void toggleStopAfterCurrentChapter() =>
      setStopAfterCurrentChapter(!_stopAfterCurrentChapter);

  /// 设置睡眠定时关闭（minutes <= 0 表示取消定时）
  void setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes <= 0) {
      _sleepDeadline = null;
      _stopAfterCurrentChapter = false;
      unawaited(_safeInvoke('setSleepDeadline', {'milliseconds': 0}));
      if (isActive) {
        unawaited(_pushDemandToScheduler());
      }
      _notify();
      return;
    }
    final clamped = minutes.clamp(1, 1440);
    _stopAfterCurrentChapter = false;
    _sleepDeadline = _now().add(Duration(minutes: clamped));
    final deadlineMs = _sleepDeadline!.millisecondsSinceEpoch;
    unawaited(_safeInvoke('setSleepDeadline', {'milliseconds': deadlineMs}));
    _sleepTimer = Timer(Duration(minutes: clamped), () {
      if (_sleepDeadline?.millisecondsSinceEpoch == deadlineMs) {
        unawaited(_handleSleepTimerExpired());
      }
    });
    if (isActive) {
      unawaited(_pushDemandToScheduler());
    }
    _notify();
  }

  void _clearSleepSchedule({bool notifyNative = false}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _stopAfterCurrentChapter = false;
    if (notifyNative) {
      unawaited(_safeInvoke('setSleepDeadline', {'milliseconds': 0}));
    }
  }

  Future<void> _handleSleepTimerExpired({String? reason}) async {
    _clearSleepSchedule(notifyNative: true);
    if (!isActive) {
      _notify();
      return;
    }
    _notice = reason ?? '定时听书时间已到，已自动暂停';
    if (!isPaused) {
      await pause();
    } else {
      _notify();
    }
  }

  /// 更新本书配音方案（人物候选池或固定旁白），不影响其他书，播放中在下一片段原文边界平滑切换
  Future<void> updateBookVoicePool({
    required String bookId,
    List<String>? selectedVoiceProfileIds,
    String? narratorVoiceProfileId,
  }) async {
    final cfg = _configService.currentConfig;
    if (cfg == null || _store == null) return;
    final existing = await _store!.getBookAudioConfig(bookId);
    final base =
        existing ??
        BookAudioConfig(
          bookId: bookId,
          selectedVoiceProfileIds: cfg.bookDefaults.selectedVoiceProfileIds,
          narratorVoiceProfileId: cfg.bookDefaults.narratorVoiceProfileId,
          updatedAtMs: _now().millisecondsSinceEpoch,
        );

    final newNarrator = narratorVoiceProfileId ?? base.narratorVoiceProfileId;
    final newSelected = selectedVoiceProfileIds ?? base.selectedVoiceProfileIds;
    if (cfg.resolveVoiceProfile(newNarrator) == null) {
      throw FormatException('所选旁白音色不存在：$newNarrator');
    }
    for (final id in newSelected) {
      if (cfg.resolveVoiceProfile(id) == null) {
        throw FormatException('所选候选音色不存在：$id');
      }
    }

    final updated = base.copyWith(
      selectedVoiceProfileIds: newSelected,
      narratorVoiceProfileId: newNarrator,
      castRevision: base.castRevision + 1,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    await _store!.saveBookAudioConfig(updated);
    if (_book?.bookId == bookId) {
      _currentBookAudioConfig = updated;
    }

    // 若旁白更换，更新所有旁白及未确定兜底 Allocation
    if (narratorVoiceProfileId != null &&
        narratorVoiceProfileId != base.narratorVoiceProfileId) {
      final rev = await _store!.getLatestBookRevision(bookId);
      if (rev != null) {
        final allocs = await _store!.getAllocations(bookId, rev.revisionId);
        final changed = <Allocation>[];
        for (final a in allocs) {
          if (a.speakerRef == 'narrator' ||
              a.speakerResolution == SpeakerResolution.unresolved) {
            changed.add(
              a.copyWith(
                allocationStatus: AllocationStatus.accepted,
                effectiveVoiceProfileId: newNarrator,
                fallbackVoiceProfileId:
                    a.speakerResolution == SpeakerResolution.unresolved
                        ? newNarrator
                        : null,
                allocationVersion: a.allocationVersion + 1,
              ),
            );
          }
        }
        if (changed.isNotEmpty) {
          await _store!.saveAllocations(changed);
        }
      }
    }

    if (_book?.bookId == bookId && _currentRevision != null) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
      await _pushDemandToScheduler();
    }
    _notify();
  }

  /// 修改指定角色固定音色（仅受影响角色与局部合并单元失效，无关缓存继续命中 A15；播放中下一片段切换 A22）
  Future<void> setCharacterVoice({
    required String bookId,
    required String characterId,
    required String voiceProfileId,
    bool manualLocked = true,
  }) async {
    if (_identityCoordinator == null) return;
    await _identityCoordinator!.setCharacterVoice(
      bookId: bookId,
      characterId: characterId,
      voiceProfileId: voiceProfileId,
      manualLocked: manualLocked,
    );
    if (_book?.bookId == bookId && _currentRevision != null) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
      await _pushDemandToScheduler();
    }
    _notify();
  }

  /// 合并两个角色并明确音色（可逆审计）
  Future<IdentityChange> resolveIdentityMerge({
    required String bookId,
    required String sourceCharacterId,
    required String targetCharacterId,
    required String resolvedVoiceProfileId,
  }) async {
    final change = await _identityCoordinator!.mergeCharacters(
      bookId: bookId,
      sourceCharacterId: sourceCharacterId,
      targetCharacterId: targetCharacterId,
      resolvedVoiceProfileId: resolvedVoiceProfileId,
    );
    if (_book?.bookId == bookId && _currentRevision != null) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
      await _pushDemandToScheduler();
    }
    _notify();
    return change;
  }

  /// 撤销一次身份合并（拆分还原）
  Future<bool> undoIdentityChange({
    required String bookId,
    required String changeId,
  }) async {
    final ok = await _identityCoordinator!.undoIdentityChange(
      bookId: bookId,
      changeId: changeId,
    );
    if (ok && _book?.bookId == bookId && _currentRevision != null) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
      await _pushDemandToScheduler();
      _notify();
    }
    return ok;
  }

  /// 纠正单句说话人（如解决待确认对白）
  Future<void> correctAllocationSpeaker({
    required String bookId,
    required String allocationId,
    required String newSpeakerRef,
  }) async {
    final cfg = _configService.currentConfig;
    final rev = await _store?.getLatestBookRevision(bookId);
    if (cfg == null || rev == null || _identityCoordinator == null) return;
    await _identityCoordinator!.correctAllocationSpeaker(
      bookId: bookId,
      bookRevisionId: rev.revisionId,
      allocationId: allocationId,
      newSpeakerRef: newSpeakerRef,
      config: cfg,
    );
    if (_book?.bookId == bookId) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
      await _pushDemandToScheduler();
    }
    _notify();
  }

  /// 重试所有阻塞、失败或处于退避冷却的区间任务
  Future<void> retryBlockedRange() async {
    _errorMessage = null;
    _notice = null;
    _scheduler?.clearErrorState(resetFailover: true);
    if (_state == ImmersivePlayState.blocked) {
      _state = ImmersivePlayState.buffering;
    }
    // 立即通知 UI 清空旧报错，避免用户点击重试后看似无反应
    _notify();

    if (_book == null || _store == null) return;
    await _reviveStuckJobsForBook(_book!.bookId);
    if (_currentRevision != null) {
      await _rebuildManifestFromAllocations(preservePlayingBoundary: isPlaying);
    }
    await _pushDemandToScheduler();
    await _scheduler?.tick();
    _notify();
  }

  /// 计算当前真实多阶段管线状态与本地指标（严格区分候选、确认、音频与连续可播秒数）
  Future<PipelineStatus> getPipelineStatus() async {
    if (_book == null || _currentRevision == null || _store == null) {
      return PipelineStatus(
        phaseLabel: '未启动沉浸式听书',
        cacheUsedBytes: _cachedUsedBytes,
        cacheHits: _cacheManager?.cacheHits ?? 0,
        cacheMisses: _cacheManager?.cacheMisses ?? 0,
      );
    }

    final bookId = _book!.bookId;
    final revId = _currentRevision!.revisionId;
    final latestCp = await _store!.getLatestCheckpoint(bookId, revId);
    final confirmedOrder = latestCp?.confirmedChunkOrder ?? -1;
    final validDrafts = await _store!.getValidDrafts(bookId, revId);
    final allocs = await _store!.getAllocations(bookId, revId);
    final unresolvedCount = allocs
        .where((a) => a.speakerResolution == SpeakerResolution.unresolved)
        .length;
    final conflictCount = allocs
        .where((a) => a.allocationStatus == AllocationStatus.blockedConflict)
        .length;

    final targetChunk = _chunks.isEmpty
        ? null
        : _chunks.firstWhere(
            (c) =>
                _targetGlobalOrder >= c.startGlobalOrder &&
                _targetGlobalOrder <= c.endGlobalOrder,
            orElse: () => _chunks.last,
          );
    final windowChunks = _chunks
        .where((c) => c.chunkOrder >= _minWindowChunkOrder)
        .toList();
    final prefixWindowChunks = targetChunk == null
        ? const <AnalysisChunk>[]
        : windowChunks
              .where((c) => c.chunkOrder < targetChunk.chunkOrder)
              .toList();
    final prefixDone = prefixWindowChunks
        .where((c) => c.chunkOrder <= confirmedOrder)
        .length;
    final isPrefix =
        prefixWindowChunks.isNotEmpty && prefixDone < prefixWindowChunks.length;
    final confirmedInWindow = windowChunks
        .where((c) => c.chunkOrder <= confirmedOrder)
        .length;

    final continuousSec = await computeContinuousReadySeconds();
    final estPending =
        _scheduler?.estimatePendingSeconds(
          _manifestSegments,
          _currentSegmentIndex,
          _playbackRate,
        ) ??
        0.0;
    final readyCount = _manifestSegments
        .where((s) => s.status == AudioSegmentStatus.ready)
        .length;

    final pendingTts = (await _store!.listJobs(
      bookId: bookId,
      statuses: const {
        ImmersiveJobStatus.queued,
        ImmersiveJobStatus.running,
        ImmersiveJobStatus.retryWait,
      },
    )).where((j) => j.jobType == ImmersiveJobType.ttsSynthesize).length;

    final String phaseLabel;
    if (_errorMessage != null || _scheduler?.blockingReason != null) {
      phaseLabel = '等待问题修复';
    } else if (_state == ImmersivePlayState.paused) {
      phaseLabel = '已暂停';
    } else if (isPrefix) {
      phaseLabel = '正在补齐前文人物档案';
    } else if (_state == ImmersivePlayState.playing) {
      phaseLabel = continuousSec < (_configService.currentConfig?.prefetch.lowWaterSeconds ?? 90)
          ? '正在播放 · 加速生成后续音频'
          : '正在播放 · 缓冲充足';
    } else if (_manifestSegments.isEmpty || _currentSegmentIndex >= _manifestSegments.length) {
      phaseLabel = '正在识别人物与分配角色';
    } else {
      phaseLabel = '正在生成当前段落音频';
    }

    return PipelineStatus(
      phaseLabel: phaseLabel,
      isPreparingPrefix: isPrefix,
      prefixCompletedChunks: isPrefix ? prefixDone : 0,
      prefixTotalChunks: isPrefix ? prefixWindowChunks.length : 0,
      candidateAnalyzedChunks: confirmedInWindow + validDrafts.length,
      confirmedChunks: confirmedInWindow,
      totalPlannedChunks: windowChunks.length,
      readyAudioSegments: readyCount,
      totalManifestSegments: _manifestSegments.length,
      continuousReadySeconds: continuousSec,
      estimatedPendingSeconds: estPending,
      activeTextRequests: _scheduler?.activeTextRequests ?? 0,
      activeTtsRequests: _scheduler?.activeTtsRequests ?? 0,
      pendingTtsJobs: pendingTts,
      unresolvedDialogueCount: unresolvedCount,
      blockedConflictCount: conflictCount,
      cacheUsedBytes: _cachedUsedBytes,
      cacheHits: _cacheManager?.cacheHits ?? 0,
      cacheMisses: _cacheManager?.cacheMisses ?? 0,
      firstAudioLatencyMs: _firstAudioLatencyMs,
      stallCount: _stallCount,
      blockingReason: _scheduler?.blockingReason,
      lastError: _errorMessage ?? _scheduler?.lastError,
    );
  }

  /// 计算从当前播放光标起连续可播真实秒数：(d0 + d1 + ... + dk) / r
  /// 遇到第一个缺失/损坏/未生成/阻塞段立即停止累计（绝不计入缺口后面的音频或在途估计 A02）
  Future<double> computeContinuousReadySeconds() async {
    if (_manifestSegments.isEmpty ||
        _currentSegmentIndex >= _manifestSegments.length ||
        _cacheManager == null) {
      return 0.0;
    }
    var mediaMs = 0.0;
    for (var i = _currentSegmentIndex; i < _manifestSegments.length; i++) {
      final seg = _manifestSegments[i];
      if (seg.status == AudioSegmentStatus.blocked ||
          seg.status == AudioSegmentStatus.failed) {
        break;
      }
      final asset = await _cacheManager!.peekValidAssetMetadata(seg.requestKey);
      if (asset == null || asset.durationMs <= 0) {
        break;
      }
      var segDurMs = asset.durationMs.toDouble();
      if (i == _currentSegmentIndex && isPlaying && _activePlayToken != null) {
        final pos = await _queryNativePositionMs();
        segDurMs = (segDurMs - pos).clamp(0.0, segDurMs);
      }
      mediaMs += segDurMs;
    }
    return (mediaMs / 1000.0) / _playbackRate;
  }

  /// 处理来自 Android 原生层的音频与锁屏媒体回调（由 playback_epoch 与 token 严格保护）
  void handlePlatformEvent(String method, dynamic args) {
    if (_closed) return;
    final id = args is Map ? args['id']?.toString() : args?.toString();

    // 试听样本完成或错误
    if (id != null && id == _previewPlayToken) {
      if (method == 'onAudioComplete' || method == 'onAudioError') {
        _previewPlayToken = null;
        _previewingVoiceProfileId = null;
        _notify();
      }
      return;
    }

    if (method == 'onSleepTimerExpired' || method == 'onAudioSleepTimer') {
      final rawExpired = args is Map
          ? (args['deadline'] ?? args['milliseconds'])
          : null;
      final expired = rawExpired is num ? rawExpired.toInt() : null;
      if (_sleepDeadline != null &&
          (expired == null ||
              expired == _sleepDeadline!.millisecondsSinceEpoch)) {
        if (isActive) {
          unawaited(_handleSleepTimerExpired());
        } else {
          _clearSleepSchedule(notifyNative: false);
          _notify();
        }
      }
      return;
    }

    // 仅处理属于沉浸式听书的 token
    if (id != null && !id.startsWith(_tokenPrefix)) {
      return;
    }

    if (method == 'onAudioTransientPause') {
      if (isPlaying) {
        _notice = '系统短暂中断，结束后自动续播';
        _notify();
      }
      return;
    }
    if (method == 'onAudioTransientResume') {
      if (_notice == '系统短暂中断，结束后自动续播') {
        _notice = null;
        _notify();
      }
      return;
    }

    if (method == 'onAudioFocusLost' || method == 'onAudioBecomingNoisy') {
      if (!isActive || isPaused) return;
      _notice = method == 'onAudioFocusLost' ? '音频焦点被占用，已暂停听书' : '音频输出设备变化，已暂停听书';
      unawaited(pause());
      return;
    }

    if (method == 'onAudioTransition' && args is Map) {
      final completedId = args['completedId']?.toString();
      final startedId = args['startedId']?.toString();
      if (completedId == _activePlayToken &&
          startedId != null &&
          startedId == _preloadedPlayToken &&
          _preloadedSegmentIndex != null &&
          _preloadedSegmentIndex! < _manifestSegments.length) {
        final prevSeg = currentSegment;
        if (prevSeg != null) {
          _cacheManager?.protectRecentPlayback(prevSeg.requestKey);
        }
        _currentPinnedAudio?.release();
        _currentPinnedAudio = _preloadedPinnedAudio;
        _preloadedPinnedAudio = null;

        final nextIdx = _preloadedSegmentIndex!;
        final nextSeg = _manifestSegments[nextIdx];
        _preloadedPlayToken = null;
        _preloadedSegmentId = null;
        _preloadedSegmentIndex = null;

        _currentSegmentIndex = nextIdx;
        _activePlayToken = startedId;
        _activePlayingSegmentId = nextSeg.segmentId;
        _pendingResumePositionMs = 0;
        _currentChapterIndex = nextSeg.chapterIndex;
        _state = ImmersivePlayState.playing;
        _syncMediaNotification();
        unawaited(_persistCursor(userPaused: false));
        unawaited(_pushDemandToScheduler());
        unawaited(_tryPreloadNextSegment());
        _notify();
      }
      return;
    }

    if (id == null || id != _activePlayToken) {
      // 过期的旧 playback_epoch 回调或重复回调，直接丢弃（满足 A07）
      return;
    }

    if (method == 'onAudioError') {
      _activePlayToken = null;
      _activePlayingSegmentId = null;
      _releaseCurrentPin();
      _stallCount++;
      final seg = currentSegment;
      if (seg != null && _store != null) {
        // 损坏资产自动失效并触发重建
        unawaited(_store!.deleteAudioAsset(seg.requestKey));
        unawaited(
          _store!.updateAudioSegmentStatus(
            segmentId: seg.segmentId,
            status: AudioSegmentStatus.pending,
          ),
        );
      }
      _state = ImmersivePlayState.buffering;
      _notice = '当前音频解码异常，正在重新生成本段，不会跳过正文';
      unawaited(_pushDemandToScheduler());
      _notify();
      return;
    }

    if (method == 'onAudioComplete') {
      // 先消费 token 并切出 playing 状态，防止重复完成事件跳段或阻塞下一段启播
      final completedSegId = _activePlayingSegmentId;
      _activePlayToken = null;
      _activePlayingSegmentId = null;
      _pendingResumePositionMs = 0;
      _state = ImmersivePlayState.buffering;
      _releaseCurrentPin();
      if (completedSegId != null && currentSegment != null) {
        _cacheManager?.protectRecentPlayback(currentSegment!.requestKey);
      }
      unawaited(_onCurrentSegmentFinished());
    }
  }

  void _handleMediaAction(String method) {
    if (!isActive) return;
    switch (method) {
      case 'onMediaPlay':
        unawaited(resume());
        break;
      case 'onMediaPause':
        unawaited(pause());
        break;
      case 'onMediaNext':
        unawaited(_handleMediaSkip(forward: true));
        break;
      case 'onMediaPrev':
        unawaited(_handleMediaSkip(forward: false));
        break;
      case 'onMediaStop':
        unawaited(stop());
        break;
    }
  }

  Future<void> _handleMediaSkip({required bool forward}) async {
    await ReaderSystemService.loadMediaButtonBehavior();
    switch (ReaderSystemService.mediaButtonBehavior) {
      case MediaButtonBehavior.segment:
        if (forward) {
          await nextSegment();
        } else {
          await previousSegment();
        }
        break;
      case MediaButtonBehavior.seek15s:
        final ok = await ReaderSystemService.seekAudio(
          deltaMs: forward ? 15000 : -15000,
        );
        if (!ok) {
          if (forward) {
            await nextSegment();
          } else {
            await previousSegment();
          }
        }
        break;
      case MediaButtonBehavior.chapter:
        if (forward) {
          await nextChapter();
        } else {
          await previousChapter();
        }
        break;
    }
  }

  Future<void> _onCurrentSegmentFinished() async {
    if (!isActive || isPaused || _book == null || _currentRevision == null) {
      return;
    }
    if (_sleepDeadline != null && !_sleepDeadline!.isAfter(_now())) {
      await _handleSleepTimerExpired();
      return;
    }
    final prevSeg = currentSegment;
    final nextIdx = _currentSegmentIndex + 1;

    if (nextIdx < _manifestSegments.length) {
      final nextSeg = _manifestSegments[nextIdx];
      if (_stopAfterCurrentChapter &&
          nextSeg.chapterIndex != _currentChapterIndex) {
        _currentSegmentIndex = nextIdx;
        _currentChapterIndex = nextSeg.chapterIndex;
        _targetGlobalOrder = nextSeg.startGlobalOrder;
        await _persistCursor(userPaused: true);
        await _handleSleepTimerExpired(reason: '本章已播完，已按定时暂停');
        return;
      }
      _currentSegmentIndex = nextIdx;
      _targetGlobalOrder = nextSeg.startGlobalOrder;
      if (nextSeg.chapterIndex != _currentChapterIndex) {
        _currentChapterIndex = nextSeg.chapterIndex;
        unawaited(_ensureWindowChaptersLoaded(_currentChapterIndex));
      }
      await _persistCursor(userPaused: false);
      await _checkBufferAndAdvancePlayback();
      await _pushDemandToScheduler();
      _notify();
      return;
    }

    // 已经到达当前已规划清单的末尾：检查是否还有后续章节或未确认分块，绝不误判为结束（A18）
    final latestCp = await _store!.getLatestCheckpoint(
      _book!.bookId,
      _currentRevision!.revisionId,
    );
    final hasUnconfirmedChunksInCurrentChapter = _chunks.any(
      (c) =>
          c.chapterIndex == _currentChapterIndex &&
          c.chunkOrder > (latestCp?.confirmedChunkOrder ?? -1),
    );
    if (_stopAfterCurrentChapter && !hasUnconfirmedChunksInCurrentChapter) {
      await _handleSleepTimerExpired(reason: '本章已播完，已按定时暂停');
      return;
    }
    final hasUnconfirmedChunks =
        _chunks.isNotEmpty &&
        (latestCp?.confirmedChunkOrder ?? -1) < _chunks.last.chunkOrder;
    final hasNextChapter =
        (_configService.currentConfig?.playback.chapterAutoAdvance ?? true) &&
        _currentChapterIndex + 1 < _chapters.length;

    if (hasUnconfirmedChunks || hasNextChapter) {
      _currentSegmentIndex = nextIdx; // 光标推进到下一待生成位，绝不重复上一章最后一段
      if (prevSeg != null) {
        _targetGlobalOrder = prevSeg.endGlobalOrder + 1;
      }
      if (hasNextChapter && !hasUnconfirmedChunks) {
        await _ensureWindowChaptersLoaded(_currentChapterIndex + 1);
      }
      _stallCount++;
      _state = ImmersivePlayState.buffering;
      _notice = '正在准备下一段音频…';
      await _pushDemandToScheduler();
      _notify();
      return;
    }

    // 全书真正朗读结束
    await stop();
  }

  /// 检查当前光标段是否满足启播/续播条件，并严格按顺序播放当前光标项（单飞串行防异步竞态）
  Future<void> _checkBufferAndAdvancePlayback() async {
    if (_checkingPlayback) {
      _pendingCheckPlayback = true;
      return;
    }
    _checkingPlayback = true;
    try {
      await _checkBufferAndAdvancePlaybackCore();
    } finally {
      _checkingPlayback = false;
      if (_pendingCheckPlayback) {
        _pendingCheckPlayback = false;
        unawaited(_checkBufferAndAdvancePlayback());
      }
    }
  }

  Future<void> _checkBufferAndAdvancePlaybackCore() async {
    if (!isActive || isPaused || isPlaying) return;
    if (_book == null || _currentRevision == null || _cacheManager == null) {
      return;
    }
    if (_manifestSegments.isEmpty ||
        _currentSegmentIndex >= _manifestSegments.length) {
      return;
    }

    final seg = _manifestSegments[_currentSegmentIndex];
    // 阻塞段：等待用户修复，绝不跳过
    if (seg.status == AudioSegmentStatus.blocked) {
      _state = ImmersivePlayState.blocked;
      _errorMessage = seg.errorMessage ?? '当前片段等待音色或角色冲突修复';
      _notify();
      return;
    }

    // 若当前段还未就绪，则保持缓冲状态等待，不跳到后面已完成的段（满足 A01 / A02）
    final firstAsset = await _cacheManager!.peekValidAssetMetadata(
      seg.requestKey,
    );
    if (!isActive || isPaused || isPlaying) return;
    if (firstAsset == null) {
      if (_state != ImmersivePlayState.preparingPrefix) {
        _state = ImmersivePlayState.buffering;
      }
      _notify();
      return;
    }

    final cfg = _configService.currentConfig!;
    final continuousSec = await computeContinuousReadySeconds();
    if (!isActive || isPaused || isPlaying) return;
    final isEndOfAvailableBook =
        _currentSegmentIndex == _manifestSegments.length - 1 &&
        _currentChapterIndex == _chapters.length - 1;

    // 首播门限：连续 >= startup_buffer_seconds(8s)，或书末不足，或首段就绪后等待 3 秒仍未达标可先播
    if (!_startupSatisfied && !isEndOfAvailableBook) {
      if (continuousSec >= cfg.prefetch.startupBufferSeconds) {
        _startupSatisfied = true;
        _startupGraceTimer?.cancel();
      } else {
        final nowMs = _now().millisecondsSinceEpoch;
        _firstReadyObservedAtMs ??= nowMs;
        final waitedMs = nowMs - _firstReadyObservedAtMs!;
        if (waitedMs >= cfg.prefetch.startupWaitAfterFirstReadyMs) {
          _startupSatisfied = true;
          _startupGraceTimer?.cancel();
        } else {
          final remainingMs =
              cfg.prefetch.startupWaitAfterFirstReadyMs - waitedMs;
          _startupGraceTimer ??= Timer(
            Duration(milliseconds: remainingMs.clamp(50, 10000)),
            () {
              _startupGraceTimer = null;
              unawaited(_checkBufferAndAdvancePlayback());
            },
          );
          _state = ImmersivePlayState.buffering;
          _notify();
          return;
        }
      }
    }

    await _playSegmentAtCurrentCursor(seg);
  }

  Future<void> _playSegmentAtCurrentCursor(AudioSegment seg) async {
    // 去重保护：同一段正在启动或已在播放时不重复入队
    if (_activePlayingSegmentId == seg.segmentId) return;
    final epoch = _playbackEpoch;
    _activePlayingSegmentId = seg.segmentId;

    // 原子钉住音频文件，覆盖校验与播放器打开全流程，消除与 LRU 清理器的竞态（A23）
    final pinned = await _cacheManager!.acquireAssetForPlayback(seg.requestKey);
    if (epoch != _playbackEpoch || !isActive || isPaused) {
      pinned?.release();
      if (_activePlayingSegmentId == seg.segmentId) {
        _activePlayingSegmentId = null;
      }
      return;
    }
    if (pinned == null) {
      if (_activePlayingSegmentId == seg.segmentId) {
        _activePlayingSegmentId = null;
      }
      // 文件被淘汰或损坏：标记回 pending 并让调度器原子开启重建代次（A21）
      await _store!.updateAudioSegmentStatus(
        segmentId: seg.segmentId,
        status: AudioSegmentStatus.pending,
      );
      _manifestSegments[_currentSegmentIndex] = seg.copyWith(
        status: AudioSegmentStatus.pending,
      );
      _state = ImmersivePlayState.buffering;
      await _pushDemandToScheduler();
      _notify();
      return;
    }

    _releaseCurrentPin();
    _currentPinnedAudio = pinned;

    final token =
        '$_tokenPrefix${_book!.bookId}:$epoch:${seg.segmentOrder}:${++_playSerial}';
    _activePlayToken = token;
    final resumePos = _pendingResumePositionMs;
    _pendingResumePositionMs = 0;

    final accepted = await _safeInvoke(
      'playAudioFile',
      ImmersiveAudioPlayerBridge.buildPlayArgs(
        token: token,
        filePath: pinned.asset.filePath,
        rate: _playbackRate,
        preservePitch:
            _configService.currentConfig?.playback.preservePitch ?? true,
        startPositionMs: resumePos,
      ),
    );

    if (epoch != _playbackEpoch || token != _activePlayToken || isPaused) {
      return;
    }

    if (accepted != true) {
      _activePlayToken = null;
      _activePlayingSegmentId = null;
      _releaseCurrentPin();
      _state = ImmersivePlayState.paused;
      _errorMessage = '音频播放器启动失败，请检查输出设备后重试';
      _notify();
      return;
    }

    if (_firstAudioLatencyMs == null && _sessionStartedAtMs != null) {
      _firstAudioLatencyMs = _now().millisecondsSinceEpoch - _sessionStartedAtMs!;
    }

    _state = ImmersivePlayState.playing;
    _notice = null;
    _errorMessage = null;
    _currentChapterIndex = seg.chapterIndex;
    _syncMediaNotification();
    await _persistCursor(userPaused: false);
    await _pushDemandToScheduler();
    unawaited(_tryPreloadNextSegment());
    _notify();
  }

  /// 尝试将下一段已就绪音频提前预热至 Android 原生双缓冲槽位，消除切段卡顿并注入自然呼吸停顿
  Future<void> _tryPreloadNextSegment() async {
    if (_closed ||
        _state != ImmersivePlayState.playing ||
        isPaused ||
        _book == null ||
        _cacheManager == null ||
        _activePlayToken == null) {
      return;
    }
    final nextIdx = _currentSegmentIndex + 1;
    if (nextIdx >= _manifestSegments.length) return;
    final curSeg = currentSegment;
    final nextSeg = _manifestSegments[nextIdx];
    if (curSeg == null || nextSeg.status != AudioSegmentStatus.ready) return;
    if (_stopAfterCurrentChapter &&
        nextSeg.chapterIndex != curSeg.chapterIndex) {
      // 开启“播完本章停止”时，禁止预装下一章音频，避免原生双缓冲越界切入下一章
      _releasePreloadedPin(notifyNative: true);
      return;
    }
    if (_preloadingSegmentId == nextSeg.segmentId) {
      return;
    }
    if (_preloadedSegmentId == nextSeg.segmentId &&
        _preloadedSegmentIndex == nextIdx &&
        _preloadedPlayToken != null) {
      return;
    }

    final epoch = _playbackEpoch;
    final curToken = _activePlayToken!;
    _preloadingSegmentId = nextSeg.segmentId;
    try {
      final pinnedNext = await _cacheManager!.acquireAssetForPlayback(
        nextSeg.requestKey,
      );
      if (pinnedNext == null) return;
      if (_closed ||
          epoch != _playbackEpoch ||
          curToken != _activePlayToken ||
          _state != ImmersivePlayState.playing ||
          isPaused) {
        pinnedNext.release();
        return;
      }

      final playbackCfg =
          _configService.currentConfig?.playback ?? const PlaybackConfig();
      final gapMs = ImmersiveAudioPlayerBridge.computeSegmentGapMs(
        playbackConfig: playbackCfg,
        current: curSeg,
        next: nextSeg,
      );
      final nextToken =
          '$_tokenPrefix${_book!.bookId}:$epoch:${nextSeg.segmentOrder}:${++_playSerial}';
      // 先记录预装状态再通知原生，消除原生极速触发 onAudioTransition 与 IPC 返回之间的竞态
      _preloadedPinnedAudio?.release();
      _preloadedPinnedAudio = pinnedNext;
      _preloadedPlayToken = nextToken;
      _preloadedSegmentId = nextSeg.segmentId;
      _preloadedSegmentIndex = nextIdx;

      final ok = await _safeInvoke(
        'preloadNextAudio',
        ImmersiveAudioPlayerBridge.buildPreloadArgs(
          currentToken: curToken,
          nextToken: nextToken,
          filePath: pinnedNext.asset.filePath,
          rate: _playbackRate,
          preservePitch: playbackCfg.preservePitch,
          gapMs: gapMs,
        ),
      );
      if (ok != true) {
        if (_preloadedPlayToken == nextToken) {
          _releasePreloadedPin(notifyNative: false);
        }
        return;
      }
      if (_closed ||
          epoch != _playbackEpoch ||
          _state != ImmersivePlayState.playing) {
        if (_preloadedPlayToken == nextToken) {
          _releasePreloadedPin(notifyNative: true);
        }
        return;
      }
    } finally {
      if (_preloadingSegmentId == nextSeg.segmentId) {
        _preloadingSegmentId = null;
      }
    }
  }

  void _releasePreloadedPin({bool notifyNative = false}) {
    _preloadingSegmentId = null;
    _preloadedPinnedAudio?.release();
    _preloadedPinnedAudio = null;
    _preloadedPlayToken = null;
    _preloadedSegmentId = null;
    _preloadedSegmentIndex = null;
    if (notifyNative) {
      unawaited(_safeInvoke('clearPreloadedAudio', null));
    }
  }

  /// 从最新已确认 Allocation 重建当前书播放清单（支持播放中“下一片段原文切换点生效” A22）
  Future<void> _rebuildManifestFromAllocations({
    required bool preservePlayingBoundary,
  }) async {
    final cfg = _configService.currentConfig;
    if (cfg == null ||
        _book == null ||
        _currentRevision == null ||
        _store == null) {
      return;
    }

    final bookId = _book!.bookId;
    final revId = _currentRevision!.revisionId;
    final bookCfg = await _store!.getBookAudioConfig(bookId);
    if (bookCfg == null) return;

    final allocs = await _store!.getAllocations(bookId, revId);
    if (allocs.isEmpty) return;

    final chars = await _store!.getCharacters(bookId);
    final charById = {for (final c in chars) c.characterId: c};
    final bindings = await _store!.getVoiceBindings(bookId);
    final bindingByChar = {for (final b in bindings) b.characterId: b};

    final allAssets = await _store!.listAllAudioAssets();
    final assetMap = <String, AudioAsset>{};
    for (final a in allAssets) {
      if (a.verifyStatus == 'valid' && await File(a.filePath).exists()) {
        assetMap[a.requestKey] = a;
      }
    }

    final newManifestRev = bookCfg.manifestRevision + 1;

    // 播放中修改音色：固定保护当前正在播放的旧段及之前前缀，新清单从旧段结束后的原文位置切分（满足 A22）
    List<AudioSegment> lockedPrefix = const [];
    if (preservePlayingBoundary &&
        _manifestSegments.isNotEmpty &&
        _currentSegmentIndex < _manifestSegments.length) {
      lockedPrefix = _manifestSegments
          .sublist(0, _currentSegmentIndex + 1)
          .map((s) => s.copyWith(manifestRevision: newManifestRev))
          .toList();
    }

    final built = ManifestBuilder.buildSegments(
      bookId: bookId,
      bookRevisionId: revId,
      manifestRevision: newManifestRev,
      config: cfg,
      orderedAllocations: allocs,
      unitById: _unitById,
      characterById: charById,
      bindingByCharId: bindingByChar,
      existingAssetsByRequestKey: assetMap,
      startupAnchorGlobalOrder: _targetGlobalOrder,
      lockedPrefixSegments: lockedPrefix,
      preferredPoolIds: bookCfg.selectedVoiceProfileIds,
      failedVoiceProfileIds: _runtimeFailedVoiceProfileIds,
      onVoiceFallback: (msg) {
        _notice = msg;
      },
    );

    final updatedBookCfg = bookCfg.copyWith(
      manifestRevision: newManifestRev,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    await _store!.saveBookAudioConfig(updatedBookCfg);
    _currentBookAudioConfig = updatedBookCfg;
    await _store!.saveAudioSegments(bookId, revId, newManifestRev, built);
    _manifestSegments = built;

    if (!preservePlayingBoundary) {
      _alignSegmentIndexToGlobalOrder(_targetGlobalOrder);
    }
  }

  Future<void> _syncManifestReadyStates() async {
    if (_cacheManager == null || _manifestSegments.isEmpty) return;
    for (var i = 0; i < _manifestSegments.length; i++) {
      final seg = _manifestSegments[i];
      if (seg.status == AudioSegmentStatus.blocked) continue;
      final asset = await _cacheManager!.peekValidAssetMetadata(seg.requestKey);
      if (asset != null && seg.status != AudioSegmentStatus.ready) {
        _manifestSegments[i] = seg.copyWith(status: AudioSegmentStatus.ready);
      } else if (asset == null && seg.status == AudioSegmentStatus.ready) {
        _manifestSegments[i] = seg.copyWith(status: AudioSegmentStatus.pending);
      }
    }
  }

  void _alignSegmentIndexToGlobalOrder(int globalOrder) {
    if (_manifestSegments.isEmpty) {
      _currentSegmentIndex = 0;
      return;
    }
    for (var i = 0; i < _manifestSegments.length; i++) {
      final seg = _manifestSegments[i];
      if (globalOrder <= seg.endGlobalOrder) {
        _currentSegmentIndex = i;
        return;
      }
    }
    _currentSegmentIndex = _manifestSegments.length;
  }

  Future<void> _ensureWindowChaptersLoaded(int anchorChapter) async {
    final cfg = _configService.currentConfig;
    if (cfg == null || _book == null || _currentRevision == null) return;
    final start = math.max(
      0,
      anchorChapter - cfg.analysisPipeline.maxPrefixBacktrackChapters,
    );
    final end = (anchorChapter + cfg.analysisPipeline.aheadChapters)
        .clamp(0, _chapters.length - 1);
    var addedAny = false;
    final newUnits = <SourceUnit>[];

    for (var i = start; i <= end; i++) {
      if (_loadedChapters[i] == true) continue;
      final raw = await _loadChapterText(_book!, _chapters[i]);
      if (raw == null) continue;
      _chapterRawTexts[_chapters[i].itemId] = raw;
      _loadedChapters[i] = true;
      final chUnits = SourceNormalizer.normalizeSingleChapter(
        bookId: _book!.bookId,
        bookRevisionId: _currentRevision!.revisionId,
        chapterIndex: i,
        chapter: _chapters[i],
        rawText: raw,
        startingGlobalOrder: SourceNormalizer.chapterScopedGlobalOrder(i, 0),
      );
      newUnits.addAll(chUnits);
      addedAny = true;
    }

    if (addedAny && newUnits.isNotEmpty) {
      _units = [..._units, ...newUnits]
        ..sort((a, b) => a.globalOrder.compareTo(b.globalOrder));
      _unitById = {for (final u in _units) u.unitId: u};
      final sysCatalogTokens = ContextBuilder.buildSystemMessage(
        config: cfg,
        bookConfig: _currentBookAudioConfig!,
      ).estimatedTokens;
      _chunks = ChunkPlanner.planChunks(
        bookId: _book!.bookId,
        bookRevisionId: _currentRevision!.revisionId,
        allOrderedUnits: _units,
        pipelineConfig: cfg.analysisPipeline,
        textConfig: cfg.primaryTextModel,
        systemVoiceCatalogTokens: sysCatalogTokens,
        useChapterScopedChunkOrder: true,
      );
      await _store!.appendChapterUnitsAndChunks(
        bookRevisionId: _currentRevision!.revisionId,
        units: newUnits,
        chunks: _chunks,
      );
    }
  }

  Future<String?> _loadChapterText(Book book, Chapter chapter) async {
    try {
      final raw =
          chapter.content ??
          (_contentLoader != null
              ? await _contentLoader!(chapter)
              : _offlineOnly
                  ? await _api.engine.readerCache.read(book.bookId, chapter.itemId)
                  : await _api
                        .getChapterContent(chapter.itemId, bookId: book.bookId)
                        .timeout(const Duration(seconds: 30)));
      if (raw == null || raw.trim().isEmpty || raw.contains('APP端专享/锁章章节')) {
        return null;
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pushDemandToScheduler({bool isSeek = false}) async {
    if (_scheduler == null) return;
    if (!isActive || _book == null || _currentRevision == null) {
      await _scheduler!.updateDemand(null);
      return;
    }
    final cfg = _configService.currentConfig!;
    final continuous = await computeContinuousReadySeconds();
    final limitToCurrentChapter =
        _stopAfterCurrentChapter ||
        (_sleepDeadline != null &&
            _sleepDeadline!.difference(_now()).inSeconds <=
                (continuous.isFinite ? continuous.round() + 60 : 60));
    await _scheduler!.updateDemand(
      SchedulerDemandSnapshot(
        bookId: _book!.bookId,
        bookRevisionId: _currentRevision!.revisionId,
        currentChapterIndex: _currentChapterIndex,
        targetGlobalOrder: _targetGlobalOrder,
        minWindowChunkOrder: _minWindowChunkOrder,
        playbackRate: _playbackRate,
        continuousReadySeconds: continuous,
        paused: isPaused,
        currentManifestSegments: List.unmodifiable(_manifestSegments),
        currentSegmentIndex: _currentSegmentIndex,
        limitPrefetchToCurrentChapter: limitToCurrentChapter,
        resolveTtsApiKey: (provider) => _configService.resolveTtsApiKey(provider),
        resolveTextApiKey: () => _configService.resolveTextApiKey(cfg),
        resolveTextModelApiKey: (model) =>
            _configService.resolveTextModelApiKey(model),
      ),
      isSeek: isSeek,
    );
  }

  void _startCursorSaveTimer() {
    _cursorSaveTimer?.cancel();
    final ms =
        _configService.currentConfig?.playback.cursorSaveIntervalMs ?? 1000;
    _cursorSaveTimer = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (isPlaying) {
        unawaited(_persistCursor(userPaused: false));
      }
    });
  }

  Future<void> _persistCursor({required bool userPaused}) async {
    if (_store == null || _book == null || _currentRevision == null) return;
    final seg = currentSegment;
    final posMs = isPlaying ? await _queryNativePositionMs() : 0;
    final asset = seg != null
        ? await _cacheManager?.peekValidAssetMetadata(seg.requestKey)
        : null;
    final chapterId = seg?.chapterId ??
        (_currentChapterIndex < _chapters.length
            ? _chapters[_currentChapterIndex].itemId
            : '');
    final cursor = PlaybackCursor(
      bookId: _book!.bookId,
      bookRevisionId: _currentRevision!.revisionId,
      chapterIndex: _currentChapterIndex,
      chapterId: chapterId,
      paragraphIndex: seg?.startParagraphIndex ?? 0,
      characterOffset: seg?.startCharOffset ?? 0,
      segmentId: seg?.segmentId,
      audioRequestKey: seg?.requestKey,
      audioContentSha256: asset?.contentSha256,
      positionInSegmentMs: posMs,
      playbackRate: _playbackRate,
      userPaused: userPaused,
      updatedAtMs: _now().millisecondsSinceEpoch,
    );
    await _store!.savePlaybackCursor(cursor);

    // 同步保存阅读器通用阅读进度（便于书架与阅读历史一致）
    if (!_isTestInstance && chapterId.isNotEmpty) {
      final readingPos = ReadingPosition(
        chapterId: chapterId,
        paragraphIndex: cursor.paragraphIndex,
        characterOffset: cursor.characterOffset,
      );
      unawaited(
        ReaderPositionService()
            .save(
              _book!.bookId,
              readingPos,
              chapterIndex: _currentChapterIndex,
              chapterTitle: currentChapterTitle,
              onCommitted: () async {
                await ReaderLibraryService().markReading(_book!.bookId);
                await ReadingHistoryService().recordReading(
                  book: _book!,
                  chapterIndex: _currentChapterIndex,
                  chapterTitle: currentChapterTitle,
                  preview: seg?.spokenText ?? '',
                );
                final shelf = BookshelfService();
                await shelf.initialize();
                if (shelf.isInBookshelf(_book!.bookId)) {
                  await shelf.updateReadingProgress(
                    _book!.bookId,
                    _currentChapterIndex,
                    currentChapterTitle,
                  );
                }
              },
            )
            .catchError((_) {}),
      );
    }
  }

  Future<int> _queryNativePositionMs() async {
    final res = await _safeInvoke('getAudioPosition');
    if (res is Map && res['id'] == _activePlayToken) {
      return (res['positionMs'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  Future<void> _refreshCacheBytes() async {
    if (_closed || _cacheManager == null) return;
    try {
      final stats = await _cacheManager!.computeStats();
      if (!_closed) {
        _cachedUsedBytes = stats.committedBytes;
      }
    } catch (_) {
      // 忽略目录已被销毁或瞬时 I/O 竞态
    }
  }

  void _syncMediaNotification() {
    final seg = currentSegment;
    final subtitle = seg != null
        ? '${seg.speakerDisplayName} · $currentChapterTitle'
        : currentChapterTitle;
    final bookId = _book?.bookId;
    final cachedCoverPath = bookId == null
        ? null
        : CoverCacheService().peekCover(bookId)?.path;
    final durationMs = seg != null
        ? (seg.spokenText.length * 220).clamp(1000, 60000)
        : null;
    if (bookId != null && cachedCoverPath == null) {
      unawaited(
        CoverCacheService().hasLocalCover(bookId).then((has) {
          if (has && !_closed && isActive && _book?.bookId == bookId) {
            final path = CoverCacheService().peekCover(bookId)?.path;
            if (path != null) {
              unawaited(
                _safeInvoke('updateMediaPlaybackState', {
                  'title': currentBookTitle.isEmpty ? '沉浸式听书' : currentBookTitle,
                  'subtitle': subtitle,
                  'isPlaying': isPlaying,
                  'isActive': isActive,
                  'coverPath': path,
                  if (durationMs != null && durationMs > 0)
                    'durationMs': durationMs,
                }),
              );
            }
          }
        }),
      );
    }
    unawaited(
      _safeInvoke('updateMediaPlaybackState', {
        'title': currentBookTitle.isEmpty ? '沉浸式听书' : currentBookTitle,
        'subtitle': subtitle,
        'isPlaying': isPlaying,
        'isActive': isActive,
        if (cachedCoverPath != null) 'coverPath': cachedCoverPath,
        if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
      }),
    );
  }

  Future<void> _stopNativeAudioOnly() async {
    await _safeInvoke('stopAudio');
  }

  void _releaseCurrentPin() {
    _currentPinnedAudio?.release();
    _currentPinnedAudio = null;
    _previewPinnedHandle?.release();
    _previewPinnedHandle = null;
    _releasePreloadedPin(notifyNative: false);
  }

  Future<Object?> _safeInvoke(String method, [Map<String, Object?>? args]) async {
    try {
      return await _invoke(method, args);
    } catch (_) {
      return null;
    }
  }

  void _bindPlatformListeners() {
    if (_listenersBound) return;
    _listenersBound = true;
    ReaderSystemService.addTtsListener(handlePlatformEvent);
    ReaderSystemService.addMediaListener(_handleMediaAction);
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (!_appForeground && isActive) {
      unawaited(_persistCursor(userPaused: isPaused));
    }
    // 平台恢复时绝不自动把用户主动暂停改为播放（满足 12.5 节）
  }

  @override
  void dispose() {
    _closed = true;
    _startupGraceTimer?.cancel();
    _cursorSaveTimer?.cancel();
    _releaseCurrentPin();
    _scheduler?.dispose();
    if (!_isTestInstance) {
      WidgetsBinding.instance.removeObserver(this);
      if (_listenersBound) {
        ReaderSystemService.removeTtsListener(handlePlatformEvent);
        ReaderSystemService.removeMediaListener(_handleMediaAction);
      }
    }
    _httpClient.close();
    _api.dispose();
    super.dispose();
  }
}
