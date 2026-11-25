import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import 'audio_cache_manager.dart';
import 'context_builder.dart';
import 'identity_coordinator.dart';
import 'immersive_database.dart';
import 'text_model_adapter.dart';
import 'tts_provider_adapter.dart';

/// 调度器并发与限流原子配额池
/// 保证：仅当全部必要额度同时可用时才分配，绝不先占全局槽再等待满额供应商
class SchedulerQuotaPool {
  final DateTime Function() _now;

  // 按文本模型 ID 独立统计并发、保留席位、RPM 与冷却（支持不同文本模型独立设置并发）
  final Map<String, int> _textTotalInFlightByModel = {};
  final Map<String, int> _textNormalInFlightByModel = {};
  final Map<String, List<int>> _textReqTimestampsByModel = {};
  final Map<String, int> _textCooldownUntilByModel = {};

  int _ttsGlobalInFlight = 0;
  final Map<String, int> _ttsProviderTotalInFlight = {};
  final Map<String, int> _ttsProviderBackgroundInFlight = {};
  final Map<String, int> _ttsModelInFlight = {}; // '$providerId\u0000$modelKey'
  final Map<String, List<int>> _ttsProviderReqTimestamps = {};
  final Map<String, int> _ttsProviderCooldownUntilMs = {};

  SchedulerQuotaPool({DateTime Function()? now}) : _now = now ?? DateTime.now;

  int get activeTextRequests =>
      _textTotalInFlightByModel.values.fold(0, (a, b) => a + b);
  int activeTextRequestsFor(String modelEntryId) =>
      _textTotalInFlightByModel[modelEntryId] ?? 0;
  int get activeTtsRequests => _ttsGlobalInFlight;

  /// 尝试原子申请指定文本模型的并发槽位；isReconciliation=true 可使用保留复核席位
  bool tryAcquireText({
    required TextAnalysisConfig config,
    required bool isReconciliation,
  }) {
    final modelKey = config.effectiveId;
    final nowMs = _now().millisecondsSinceEpoch;
    if (nowMs < (_textCooldownUntilByModel[modelKey] ?? 0)) return false;
    final totalInFlight = _textTotalInFlightByModel[modelKey] ?? 0;
    if (totalInFlight >= config.maxConcurrency) return false;

    final reserved = config.maxConcurrency <= 1
        ? 0
        : config.reservedReconciliationSlots.clamp(0, config.maxConcurrency - 1);
    final normalLimit = config.maxConcurrency - reserved;
    final normalInFlight = _textNormalInFlightByModel[modelKey] ?? 0;
    if (!isReconciliation && normalInFlight >= normalLimit) {
      return false;
    }

    if (config.requestsPerMinute != null) {
      final list = _textReqTimestampsByModel.putIfAbsent(modelKey, () => []);
      _pruneWindow(list, nowMs);
      if (list.length >= config.requestsPerMinute!) {
        return false;
      }
    }

    _textTotalInFlightByModel[modelKey] = totalInFlight + 1;
    if (!isReconciliation) {
      _textNormalInFlightByModel[modelKey] = normalInFlight + 1;
    }
    _textReqTimestampsByModel.putIfAbsent(modelKey, () => []).add(nowMs);
    return true;
  }

  void releaseText({
    required bool isReconciliation,
    String? modelEntryId,
  }) {
    final key =
        modelEntryId ??
        (_textTotalInFlightByModel.keys.isNotEmpty
            ? _textTotalInFlightByModel.keys.first
            : null);
    if (key == null) return;
    final total = _textTotalInFlightByModel[key] ?? 0;
    if (total > 0) _textTotalInFlightByModel[key] = total - 1;
    if (!isReconciliation) {
      final normal = _textNormalInFlightByModel[key] ?? 0;
      if (normal > 0) _textNormalInFlightByModel[key] = normal - 1;
    }
  }

  void applyTextCooldown(Duration duration, {String? modelEntryId}) {
    final key = modelEntryId ?? '_default';
    final target = _now().millisecondsSinceEpoch + duration.inMilliseconds;
    final cur = _textCooldownUntilByModel[key] ?? 0;
    if (target > cur) _textCooldownUntilByModel[key] = target;
  }

  /// 尝试一次性原子申请 TTS 全局、供应商（含前台保留席位）、模型子限额及 RPM 额度
  bool tryAcquireTts({
    required TtsConfig ttsConfig,
    required VoiceProfileResolution resolution,
    required bool isForegroundPriority,
  }) {
    final nowMs = _now().millisecondsSinceEpoch;
    final pid = resolution.provider.providerId;
    final modelKey = '$pid\u0000${resolution.model.modelKey}';

    // 1. 冷却检查（供应商所有模型共享冷却，如 X 和 x）
    if (nowMs < (_ttsProviderCooldownUntilMs[pid] ?? 0)) return false;

    // 2. 全局并发检查
    if (_ttsGlobalInFlight >= ttsConfig.globalMaxConcurrency) return false;

    // 3. 供应商并发及前台保留席位检查
    final pTotal = _ttsProviderTotalInFlight[pid] ?? 0;
    if (pTotal >= resolution.provider.maxConcurrency) return false;

    final reservedFg = resolution.provider.maxConcurrency <= 1
        ? 0
        : resolution.provider.reservedForegroundSlots.clamp(
            0,
            resolution.provider.maxConcurrency - 1,
          );
    final bgLimit = resolution.provider.maxConcurrency - reservedFg;
    final pBg = _ttsProviderBackgroundInFlight[pid] ?? 0;
    if (!isForegroundPriority && pBg >= bgLimit) return false;

    // 4. 模型子上限检查
    final mInFlight = _ttsModelInFlight[modelKey] ?? 0;
    if (mInFlight >= resolution.model.maxConcurrency) return false;

    // 5. 供应商共享 RPM 检查
    if (resolution.provider.requestsPerMinute != null) {
      final list = _ttsProviderReqTimestamps.putIfAbsent(pid, () => []);
      _pruneWindow(list, nowMs);
      if (list.length >= resolution.provider.requestsPerMinute!) return false;
    }

    // 全部条件满足，原子扣减所有维度额度
    _ttsGlobalInFlight++;
    _ttsProviderTotalInFlight[pid] = pTotal + 1;
    if (!isForegroundPriority) {
      _ttsProviderBackgroundInFlight[pid] = pBg + 1;
    }
    _ttsModelInFlight[modelKey] = mInFlight + 1;
    _ttsProviderReqTimestamps.putIfAbsent(pid, () => []).add(nowMs);
    return true;
  }

  void releaseTts({
    required VoiceProfileResolution resolution,
    required bool isForegroundPriority,
  }) {
    final pid = resolution.provider.providerId;
    final modelKey = '$pid\u0000${resolution.model.modelKey}';
    if (_ttsGlobalInFlight > 0) _ttsGlobalInFlight--;
    final pTotal = _ttsProviderTotalInFlight[pid] ?? 0;
    if (pTotal > 0) _ttsProviderTotalInFlight[pid] = pTotal - 1;
    if (!isForegroundPriority) {
      final pBg = _ttsProviderBackgroundInFlight[pid] ?? 0;
      if (pBg > 0) _ttsProviderBackgroundInFlight[pid] = pBg - 1;
    }
    final mInFlight = _ttsModelInFlight[modelKey] ?? 0;
    if (mInFlight > 0) _ttsModelInFlight[modelKey] = mInFlight - 1;
  }

  void applyProviderCooldown(String providerId, Duration duration) {
    final target = _now().millisecondsSinceEpoch + duration.inMilliseconds;
    final cur = _ttsProviderCooldownUntilMs[providerId] ?? 0;
    if (target > cur) _ttsProviderCooldownUntilMs[providerId] = target;
  }

  void _pruneWindow(List<int> timestamps, int nowMs) {
    timestamps.removeWhere((ts) => nowMs - ts >= 60000);
  }
}

/// 调度器实时需求快照（由 PlaybackCoordinator 提供）
class SchedulerDemandSnapshot {
  final String bookId;
  final String bookRevisionId;
  final int currentChapterIndex;
  final int targetGlobalOrder;
  final int minWindowChunkOrder;
  final double playbackRate;
  final double continuousReadySeconds;
  final bool paused;
  final List<AudioSegment> currentManifestSegments;
  final int currentSegmentIndex;
  final String Function(TtsProviderConfig provider) resolveTtsApiKey;
  final String Function() resolveTextApiKey;
  final String Function(TextAnalysisConfig model)? resolveTextModelApiKey;

  const SchedulerDemandSnapshot({
    required this.bookId,
    required this.bookRevisionId,
    required this.currentChapterIndex,
    required this.targetGlobalOrder,
    this.minWindowChunkOrder = 0,
    required this.playbackRate,
    required this.continuousReadySeconds,
    required this.paused,
    required this.currentManifestSegments,
    required this.currentSegmentIndex,
    required this.resolveTtsApiKey,
    required this.resolveTextApiKey,
    this.resolveTextModelApiKey,
  });

  String resolveApiKeyForTextModel(TextAnalysisConfig model) {
    if (resolveTextModelApiKey != null) {
      return resolveTextModelApiKey!(model);
    }
    return resolveTextApiKey();
  }
}

/// 全局唯一权威异步任务调度器
/// 管理分析预取、前缀补齐、有序确认提交、主备文本模型自动切换、TTS 合成与同性兜底
class ImmersiveJobScheduler {
  final ImmersiveStateStore _store;
  final IdentityCoordinator _identityCoordinator;
  final TextModelAdapter _textAdapter;
  final TtsProviderAdapter _ttsAdapter;
  final AudioCacheManager _cacheManager;
  final DateTime Function() _now;
  final math.Random _rand = math.Random();
  final String workerId;

  late final SchedulerQuotaPool quotaPool = SchedulerQuotaPool(now: _now);

  ImmersiveConfig _config;
  SchedulerDemandSnapshot? _activeDemand;
  Timer? _pollTimer;
  bool _running = false;
  bool _tickBusy = false;
  bool _pendingRetick = false;
  int _generation = 0;
  String? _lastError;
  String? _blockingReason;

  // 多文本模型主备运行态
  String? _activeTextModelId;
  int _consecutivePrimaryFailures = 0;
  String? _failoverNotice;

  final Set<String> _inFlightJobKeys = {};
  final Map<String, Timer> _heartbeats = {};
  final Set<int> _cancelledGenerations = {};

  /// 按音色平滑估计“字符/秒”，初始值为 audio_generation.initial_estimated_characters_per_second
  final Map<String, double> _voiceCharsPerSec = {};

  void Function()? onProgressChanged;
  Future<void> Function(String bookId, String bookRevisionId)? onAllocationsCommitted;
  Future<void> Function(String requestKey)? onAudioAssetReady;
  void Function(String notice)? onFailoverNotice;
  Future<void> Function(String failedVoiceProfileId, String reason)?
      onVoiceFailedNeedsFallback;

  ImmersiveJobScheduler({
    required ImmersiveStateStore store,
    required IdentityCoordinator identityCoordinator,
    required TextModelAdapter textAdapter,
    required TtsProviderAdapter ttsAdapter,
    required AudioCacheManager cacheManager,
    required ImmersiveConfig config,
    DateTime Function()? now,
    String? workerId,
  }) : _store = store,
       _identityCoordinator = identityCoordinator,
       _textAdapter = textAdapter,
       _ttsAdapter = ttsAdapter,
       _cacheManager = cacheManager,
       _config = config,
       _now = now ?? DateTime.now,
       workerId = workerId ?? 'worker_${DateTime.now().microsecondsSinceEpoch}' {
    _activeTextModelId = _config.primaryTextModel.effectiveId;
  }

  String? get lastError => _lastError;
  String? get blockingReason => _blockingReason;
  String? get failoverNotice => _failoverNotice;
  int get activeTextRequests => quotaPool.activeTextRequests;
  int get activeTtsRequests => quotaPool.activeTtsRequests;
  bool get isRunning => _running;

  /// 当前实际执勤的文本分析模型（默认主模型，主模型多次失败后自动切换至兜底模型）
  TextAnalysisConfig get activeTextModel {
    final cur = _config.findTextModel(_activeTextModelId);
    if (cur != null && cur.enabled) return cur;
    return _config.primaryTextModel;
  }

  bool get isUsingFallbackTextModel {
    final fb = _config.fallbackTextModel;
    return fb != null && activeTextModel.effectiveId == fb.effectiveId;
  }

  /// 手动复位主备状态，重新切回主文本模型
  void resetTextModelFailover() {
    _activeTextModelId = _config.primaryTextModel.effectiveId;
    _consecutivePrimaryFailures = 0;
    _failoverNotice = null;
  }

  void updateConfig(ImmersiveConfig config) {
    final prevPrimaryId = _config.primaryTextModel.effectiveId;
    _config = config;
    final curActive = _config.findTextModel(_activeTextModelId);
    if (curActive == null ||
        !curActive.enabled ||
        prevPrimaryId != _config.primaryTextModel.effectiveId) {
      resetTextModelFailover();
    }
  }

  /// 更新活动书籍的需求（换书、seek、暂停或水位变化时调用）
  Future<void> updateDemand(
    SchedulerDemandSnapshot? demand, {
    bool isSeek = false,
  }) async {
    final prevBookId = _activeDemand?.bookId;
    _activeDemand = demand;

    if (demand == null || demand.paused) {
      // 暂停：停止新增派发，允许在途请求完成并缓存
      _stopTimer();
      onProgressChanged?.call();
      return;
    }

    if (prevBookId != null && prevBookId != demand.bookId) {
      // 换书：停止旧书排队任务
      await _store.cancelQueuedJobsForBook(prevBookId);
    }

    if (isSeek) {
      _generation++;
      await _store.cancelQueuedJobsForBook(
        demand.bookId,
        jobType: ImmersiveJobType.ttsSynthesize,
      );
      if (_config.jobs.cancelUnneededRequestsOnSeek) {
        _cancelledGenerations.add(_generation - 1);
      }
    }

    _startLoopIfNeeded();
    unawaited(tick());
  }

  /// 启动时恢复过期租约并清理孤立临时文件
  Future<int> recoverOnStartup() async {
    final recovered = await _store.recoverExpiredLeases(
      _now().millisecondsSinceEpoch,
    );
    await _cacheManager.cleanupStaleAndOrphanFiles();
    return recovered;
  }

  /// 停止调度器轮询（在途任务保留自身 fence 校验）
  void stop() {
    _activeDemand = null;
    _stopTimer();
  }

  void dispose() {
    stop();
    for (final t in _heartbeats.values) {
      t.cancel();
    }
    _heartbeats.clear();
    _textAdapter.cancelAll();
    _ttsAdapter.cancelAll();
  }

  void _startLoopIfNeeded() {
    if (_running) return;
    _running = true;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(milliseconds: _config.jobs.pollIntervalMs.clamp(100, 5000)),
      (_) => unawaited(tick()),
    );
  }

  void _stopTimer() {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 估算“已在队列/在途”的 TTS 任务预计可播秒数（严禁将尚未入队的普通 pending 片段计入在途水位）
  double estimatePendingSeconds(
    List<AudioSegment> segments,
    int fromIndex,
    double rate, {
    Set<String>? activeTtsRequestKeys,
  }) {
    var sec = 0.0;
    final defaultCps = _config.audioGeneration.initialEstimatedCharactersPerSecond;
    for (var i = fromIndex; i < segments.length; i++) {
      final seg = segments[i];
      final isInFlightOrQueued =
          seg.status == AudioSegmentStatus.synthesizing ||
          (activeTtsRequestKeys != null &&
              activeTtsRequestKeys.contains(seg.requestKey));
      if (isInFlightOrQueued) {
        final cps = _voiceCharsPerSec[seg.voiceProfileId] ?? defaultCps;
        sec += (seg.codePointLength / cps) / rate;
      }
    }
    return sec;
  }

  /// 执行一轮调度：检查租约、补充分析窗口任务、排空有序提交、补充 TTS 任务并派发
  Future<void> tick() async {
    if (_tickBusy) {
      _pendingRetick = true;
      return;
    }
    final demand = _activeDemand;
    if (demand == null || demand.paused) return;
    _tickBusy = true;
    try {
      final nowMs = _now().millisecondsSinceEpoch;
      await _store.recoverExpiredLeases(nowMs);
      await _planAnalysisJobs(demand, nowMs);
      await _dispatchAnalysisJobs(demand, nowMs);
      await _drainOrderedCommits(demand);
      final latestDemand = _activeDemand;
      if (latestDemand != null && !latestDemand.paused) {
        await _planTtsJobs(latestDemand, nowMs);
        await _dispatchTtsJobs(latestDemand, nowMs);
      }
      onProgressChanged?.call();
    } finally {
      _tickBusy = false;
      if (_pendingRetick) {
        _pendingRetick = false;
        unawaited(tick());
      }
    }
  }

  /// 规划文本分析任务：遵守 ahead_chapters、max_ahead_chunks、max_uncommitted_chunks
  /// 且前缀补齐严格从下一可提交块向前推进（避免后部前缀块堵死窗口，满足 A25）
  Future<void> _planAnalysisJobs(
    SchedulerDemandSnapshot demand,
    int nowMs,
  ) async {
    final bookCfg = await _store.getBookAudioConfig(demand.bookId);
    if (bookCfg == null) return;
    final chunks = await _store.getAnalysisChunks(demand.bookRevisionId);
    if (chunks.isEmpty) return;

    final latestCp = await _store.getLatestCheckpoint(
      demand.bookId,
      demand.bookRevisionId,
    );
    final confirmedOrder = latestCp?.confirmedChunkOrder ?? -1;
    final nextCommitOrder = math.max(
      confirmedOrder + 1,
      demand.minWindowChunkOrder,
    );

    // 判断当前是否处于“从中间章节首次起听的前缀补齐”阶段（最多回溯 5 章）
    final targetChunk = chunks.firstWhere(
      (c) =>
          demand.targetGlobalOrder >= c.startGlobalOrder &&
          demand.targetGlobalOrder <= c.endGlobalOrder,
      orElse: () => chunks.last,
    );
    final needsPrefix = nextCommitOrder < targetChunk.chunkOrder;

    final maxChapterAllowed =
        demand.currentChapterIndex + _config.analysisPipeline.aheadChapters;
    final maxAheadCount = _config.analysisPipeline.maxAheadChunks;

    final validDrafts = await _store.getValidDrafts(
      demand.bookId,
      demand.bookRevisionId,
    );
    final validDraftChunkIds = {for (final d in validDrafts) d.chunkId};

    final existingJobs = await _store.listJobs(
      bookId: demand.bookId,
      statuses: const {
        ImmersiveJobStatus.queued,
        ImmersiveJobStatus.running,
        ImmersiveJobStatus.retryWait,
      },
    );
    final analysisActiveJobs = existingJobs
        .where((j) => j.jobType == ImmersiveJobType.chunkAnalysis)
        .toList();
    final activeChunkIds = <String>{};
    for (final j in analysisActiveJobs) {
      final map = jsonDecode(j.payloadJson) as Map;
      final cid = map['chunk_id']?.toString();
      if (cid != null) activeChunkIds.add(cid);
    }

    // 未有序提交的数量 = 已就绪草稿数 + 活跃(queued/running/retry_wait)分析任务数
    // retry_wait 持续占用位置，防止下一可提交块在重试期间被后续块挤走
    var uncommittedCount =
        validDraftChunkIds.length +
        activeChunkIds.where((id) => !validDraftChunkIds.contains(id)).length;
    final maxUncommitted = _config.analysisPipeline.maxUncommittedChunks;
    var scannedAheadCount = 0;

    for (final chunk in chunks) {
      if (chunk.chunkOrder < nextCommitOrder) continue;
      if (scannedAheadCount >= maxAheadCount) break;
      final isFirstPendingChunk = scannedAheadCount == 0;
      scannedAheadCount++;
      if (!needsPrefix && chunk.chapterIndex > maxChapterAllowed) break;
      if (validDraftChunkIds.contains(chunk.chunkId)) continue;
      if (activeChunkIds.contains(chunk.chunkId)) continue;
      if (uncommittedCount >= maxUncommitted) break;

      // 计算优先级：前缀块和下一可提交块为 P0；当前章低水位为 P1；其余窗口块为 P3
      int priority;
      if (isFirstPendingChunk ||
          (needsPrefix && chunk.chunkOrder <= targetChunk.chunkOrder)) {
        priority = 0;
      } else if (chunk.chapterIndex == demand.currentChapterIndex &&
          demand.continuousReadySeconds < _config.prefetch.lowWaterSeconds) {
        priority = 1;
      } else {
        priority = 3;
      }

      final jobKey =
          'analyze:${demand.bookRevisionId}:${chunk.chunkId}:r${bookCfg.analysisRunRevision}';
      await _store.enqueueOrReviveJob(
        ImmersiveJob(
          jobKey: jobKey,
          jobType: ImmersiveJobType.chunkAnalysis,
          bookId: demand.bookId,
          bookRevisionId: demand.bookRevisionId,
          status: ImmersiveJobStatus.queued,
          priority: priority,
          inputVersion:
              '${demand.bookRevisionId}|r${bookCfg.analysisRunRevision}|c${bookCfg.castRevision}',
          payloadJson: jsonEncode({
            'chunk_id': chunk.chunkId,
            'chunk_order': chunk.chunkOrder,
            'is_prefix': needsPrefix && chunk.chunkOrder < targetChunk.chunkOrder,
          }),
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
      );
      activeChunkIds.add(chunk.chunkId);
      uncommittedCount++;
    }
  }

  Future<void> _dispatchAnalysisJobs(
    SchedulerDemandSnapshot demand,
    int nowMs,
  ) async {
    final candidates = await _store.listJobs(
      bookId: demand.bookId,
      statuses: const {ImmersiveJobStatus.queued, ImmersiveJobStatus.retryWait},
    );
    final analysisJobs = candidates
        .where(
          (j) =>
              j.jobType == ImmersiveJobType.chunkAnalysis &&
              !_inFlightJobKeys.contains(j.jobKey) &&
              (j.status == ImmersiveJobStatus.queued ||
                  (j.notBeforeMs ?? 0) <= nowMs),
        )
        .toList();

    // 同优先级优先最靠前的 chunk_order（保障前缀与下一可提交块永远最先推进）
    analysisJobs.sort((a, b) {
      final pCmp = a.priority.compareTo(b.priority);
      if (pCmp != 0) return pCmp;
      final aOrder = (jsonDecode(a.payloadJson) as Map)['chunk_order'] as int? ?? 0;
      final bOrder = (jsonDecode(b.payloadJson) as Map)['chunk_order'] as int? ?? 0;
      return aOrder.compareTo(bOrder);
    });

    for (final job in analysisJobs) {
      if (demand.paused) break;
      final textModel = activeTextModel;
      final acquired = quotaPool.tryAcquireText(
        config: textModel,
        isReconciliation: false,
      );
      if (!acquired) break;

      final claimed = await _store.claimJob(
        jobKey: job.jobKey,
        workerId: workerId,
        leaseSeconds: _config.jobs.leaseSeconds,
        nowMs: _now().millisecondsSinceEpoch,
      );
      if (claimed == null) {
        quotaPool.releaseText(
          isReconciliation: false,
          modelEntryId: textModel.effectiveId,
        );
        continue;
      }

      _inFlightJobKeys.add(claimed.jobKey);
      unawaited(_executeAnalysisJob(claimed, demand, textModel));
    }
  }

  Future<void> _executeAnalysisJob(
    ImmersiveJob job,
    SchedulerDemandSnapshot demand,
    TextAnalysisConfig textModel,
  ) async {
    _startHeartbeat(job);
    try {
      final payloadMap = jsonDecode(job.payloadJson) as Map;
      final chunkId = payloadMap['chunk_id'] as String;
      final bookCfg = await _store.getBookAudioConfig(job.bookId);
      if (bookCfg == null) {
        await _store.completeJob(
          jobKey: job.jobKey,
          workerId: workerId,
          fence: job.fence,
          newStatus: ImmersiveJobStatus.cancelled,
          nowMs: _now().millisecondsSinceEpoch,
        );
        return;
      }

      final chunks = await _store.getAnalysisChunks(job.bookRevisionId);
      final chunkIdx = chunks.indexWhere((c) => c.chunkId == chunkId);
      if (chunkIdx == -1) {
        await _store.completeJob(
          jobKey: job.jobKey,
          workerId: workerId,
          fence: job.fence,
          newStatus: ImmersiveJobStatus.cancelled,
          nowMs: _now().millisecondsSinceEpoch,
        );
        return;
      }
      final chunk = chunks[chunkIdx];
      final units = await _store.getSourceUnits(job.bookRevisionId);
      final unitById = {for (final u in units) u.unitId: u};
      final chars = await _store.getCharacters(job.bookId);
      final aliases = await _store.getAliasEvidences(job.bookId);
      final bindings = await _store.getVoiceBindings(job.bookId);
      final bindingByChar = {for (final b in bindings) b.characterId: b};
      final latestCp = await _store.getLatestCheckpoint(
        job.bookId,
        job.bookRevisionId,
      );

      final prompt = ContextBuilder.buildChunkAnalysisPrompt(
        config: _config,
        bookConfig: bookCfg,
        chunk: chunk,
        unitById: unitById,
        allCharacters: chars,
        allAliases: aliases,
        bindingByCharId: bindingByChar,
        latestCheckpoint: latestCp,
      );

      final apiKey = demand.resolveApiKeyForTextModel(textModel);
      // 分级思考策略：常规文本分块且模型设为 auto 时降档为 minimal 提速降耗；身份复核与测试保持原档位深度推理
      final effectiveAnalyzeModel =
          _config.analysisPipeline.tieredThinking &&
              textModel.thinkingLevel == TextThinkingLevel.auto
          ? textModel.copyWith(thinkingLevel: TextThinkingLevel.minimal)
          : textModel;
      final resp = await _textAdapter.analyzeChunk(
        config: effectiveAnalyzeModel,
        apiKey: apiKey,
        systemMessage: prompt.systemMessage,
        userMessage: prompt.userMessage,
      );

      // 保存草稿前做结构与原文覆盖校验
      IdentityCoordinator.validateDraftAgainstChunk(
        payload: resp.data,
        chunk: chunk,
        unitById: unitById,
        knownCharacterIds: {for (final c in chars) c.characterId},
      );

      if (textModel.effectiveId == _config.primaryTextModel.effectiveId) {
        _consecutivePrimaryFailures = 0;
      }

      final nowMs = _now().millisecondsSinceEpoch;
      final ok = await _store.completeJob(
        jobKey: job.jobKey,
        workerId: workerId,
        fence: job.fence,
        newStatus: ImmersiveJobStatus.succeeded,
        nowMs: nowMs,
      );
      if (ok) {
        await _store.saveDraft(
          AnalysisDraft(
            draftId: 'draft_${chunk.chunkId}_f${job.fence}_$nowMs',
            bookId: job.bookId,
            bookRevisionId: job.bookRevisionId,
            chunkId: chunk.chunkId,
            chunkOrder: chunk.chunkOrder,
            analysisRunRevision: bookCfg.analysisRunRevision,
            snapshotRegistryRevision: bookCfg.registryRevision,
            castRevision: bookCfg.castRevision,
            payloadJson: jsonEncode(resp.data),
            validationStatus: 'valid',
            createdAtMs: nowMs,
          ),
        );
        _lastError = null;
        _blockingReason = null;
      }
    } on TextModelException catch (e) {
      await _handleTextJobError(job, textModel, e);
    } on DraftSemanticValidationException catch (e) {
      final switched = await _maybeFailoverTextModel(
        job,
        textModel,
        '模型返回未覆盖全部目标原文（${e.message}）',
        immediate: false,
      );
      if (!switched) {
        await _handleRetryableJobFailure(
          job,
          '模型返回未覆盖全部目标原文（${e.message}）',
          isBlocking: false,
        );
      }
    } catch (e) {
      final switched = await _maybeFailoverTextModel(
        job,
        textModel,
        '文本分析执行异常：$e',
        immediate: false,
      );
      if (!switched) {
        await _handleRetryableJobFailure(
          job,
          '文本分析执行异常：$e',
          isBlocking: false,
        );
      }
    } finally {
      _stopHeartbeat(job.jobKey);
      _inFlightJobKeys.remove(job.jobKey);
      quotaPool.releaseText(
        isReconciliation: false,
        modelEntryId: textModel.effectiveId,
      );
      unawaited(tick());
    }
  }

  /// 判断是否满足主模型故障转移条件：主模型连续失败达到阈值或遇阻断错误时，自动切至兜底模型并立刻重试
  Future<bool> _maybeFailoverTextModel(
    ImmersiveJob job,
    TextAnalysisConfig failedModel,
    String errorMessage, {
    required bool immediate,
  }) async {
    final primary = _config.primaryTextModel;
    final fallback = _config.fallbackTextModel;
    if (fallback == null ||
        failedModel.effectiveId != primary.effectiveId ||
        activeTextModel.effectiveId == fallback.effectiveId) {
      return false;
    }

    _consecutivePrimaryFailures++;
    final shouldSwitch =
        immediate ||
        _consecutivePrimaryFailures >= _config.textFailoverThreshold;
    if (!shouldSwitch) return false;

    _activeTextModelId = fallback.effectiveId;
    _blockingReason = null;
    _failoverNotice =
        '主模型 ${primary.displayName} 连续失败（$errorMessage），已自动切换至兜底模型 ${fallback.displayName}';
    _lastError = _failoverNotice;
    onFailoverNotice?.call(_failoverNotice!);

    final nowMs = _now().millisecondsSinceEpoch;
    await _store.completeJob(
      jobKey: job.jobKey,
      workerId: workerId,
      fence: job.fence,
      newStatus: ImmersiveJobStatus.retryWait,
      nextNotBeforeMs: nowMs,
      errorMessage: _failoverNotice,
      nowMs: nowMs,
    );
    return true;
  }

  Future<void> _handleTextJobError(
    ImmersiveJob job,
    TextAnalysisConfig failedModel,
    TextModelException e,
  ) async {
    if (e.kind == TextModelErrorKind.rateLimited) {
      quotaPool.applyTextCooldown(
        e.retryAfter ?? const Duration(seconds: 3),
        modelEntryId: failedModel.effectiveId,
      );
    }
    final switched = await _maybeFailoverTextModel(
      job,
      failedModel,
      e.message,
      immediate:
          e.isBlockingConfigOrProtocol || e.kind == TextModelErrorKind.refusal,
    );
    if (switched) return;

    if (e.isBlockingConfigOrProtocol || e.kind == TextModelErrorKind.refusal) {
      _blockingReason = e.message;
      _lastError = e.message;
      await _store.completeJob(
        jobKey: job.jobKey,
        workerId: workerId,
        fence: job.fence,
        newStatus: ImmersiveJobStatus.blocked,
        errorMessage: e.message,
        nowMs: _now().millisecondsSinceEpoch,
      );
      return;
    }
    await _handleRetryableJobFailure(
      job,
      e.message,
      retryAfter: e.retryAfter,
      isBlocking: false,
    );
  }

  /// 在独立复核保留席位上运行局部身份复核并排空有序提交
  Future<void> _drainOrderedCommits(SchedulerDemandSnapshot demand) async {
    final outcomes = await _identityCoordinator.drainOrderedCommits(
      bookId: demand.bookId,
      bookRevisionId: demand.bookRevisionId,
      config: _config,
      minWindowChunkOrder: demand.minWindowChunkOrder,
      recheckInvoker: ({required systemMessage, required userMessage}) async {
        // 使用当前执勤文本模型的保留复核席位申请并发，防止被普通后台分析堵死（A05）
        final textModel = activeTextModel;
        final deadline = _now().millisecondsSinceEpoch + 30000;
        while (!quotaPool.tryAcquireText(
          config: textModel,
          isReconciliation: true,
        )) {
          if (_now().millisecondsSinceEpoch >= deadline) return null;
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        try {
          return await _textAdapter.recheckIdentity(
            config: textModel,
            apiKey: demand.resolveApiKeyForTextModel(textModel),
            systemMessage: systemMessage,
            userMessage: userMessage,
          );
        } catch (_) {
          return null;
        } finally {
          quotaPool.releaseText(
            isReconciliation: true,
            modelEntryId: textModel.effectiveId,
          );
        }
      },
    );

    var anyCommitted = false;
    for (final out in outcomes) {
      if (out.committed) anyCommitted = true;
      if (out.blockingReason != null) {
        _blockingReason = out.blockingReason;
      }
    }
    if (anyCommitted) {
      await onAllocationsCommitted?.call(demand.bookId, demand.bookRevisionId);
    }
  }

  /// 规划 TTS 任务：受目标/高水位、64 待处理上限、首个缺口后 8 个投机任务共同约束
  Future<void> _planTtsJobs(
    SchedulerDemandSnapshot demand,
    int nowMs,
  ) async {
    final segments = demand.currentManifestSegments;
    if (segments.isEmpty || demand.currentSegmentIndex >= segments.length) {
      // 目标播放位置尚未进入已确认清单前沿（例如仍在补齐前文人物档案）时，绝不提前合成前文音频
      return;
    }

    final startIdx = demand.currentSegmentIndex;
    final activeTtsJobs = await _store.listJobs(
      statuses: const {
        ImmersiveJobStatus.queued,
        ImmersiveJobStatus.running,
        ImmersiveJobStatus.retryWait,
      },
    );
    final activeTtsOnly = activeTtsJobs
        .where((j) => j.jobType == ImmersiveJobType.ttsSynthesize)
        .toList();
    final activeTtsRequestKeys = <String>{};
    for (final j in activeTtsOnly) {
      final map = jsonDecode(j.payloadJson) as Map;
      final rk = map['request_key']?.toString();
      if (rk != null) activeTtsRequestKeys.add(rk);
    }

    final estPending = estimatePendingSeconds(
      segments,
      startIdx,
      demand.playbackRate,
      activeTtsRequestKeys: activeTtsRequestKeys,
    );
    final totalProjected = demand.continuousReadySeconds + estPending;

    // 达到高水位或连续缓冲已满足目标缓冲则停止新增普通 TTS
    if (demand.continuousReadySeconds >= _config.prefetch.targetBufferSeconds ||
        totalProjected >= _config.prefetch.highWaterSeconds) {
      return;
    }

    var pendingTtsCount = activeTtsOnly.length;
    if (pendingTtsCount >= _config.tts.maxPendingJobs) return;

    var foundFirstGap = false;
    var speculativeBeyondGap = 0;
    var projectedSeconds = demand.continuousReadySeconds;
    final defaultCps =
        _config.audioGeneration.initialEstimatedCharactersPerSecond;

    for (var i = startIdx; i < segments.length; i++) {
      if (pendingTtsCount >= _config.tts.maxPendingJobs) break;
      if (projectedSeconds >= _config.prefetch.highWaterSeconds) break;

      final seg = segments[i];
      // 阻塞段不能发 TTS，并构成首个缺口
      if (seg.status == AudioSegmentStatus.blocked) {
        if (!foundFirstGap) foundFirstGap = true;
        break; // 身份/音色未确认边界之后不越过发投机 TTS
      }

      final cachedAsset = await _cacheManager.peekValidAssetMetadata(
        seg.requestKey,
      );
      if (cachedAsset != null) {
        if (!foundFirstGap) {
          // 已经在连续缓冲内
        }
        continue;
      }

      // 发现尚未就绪的音频段
      final isFirstGapSeg = !foundFirstGap;
      if (!foundFirstGap) {
        foundFirstGap = true;
      } else {
        if (speculativeBeyondGap >= _config.prefetch.maxJobsBeyondFirstGap) {
          break;
        }
        speculativeBeyondGap++;
      }

      // 分配优先级：首个缺口/第一段 P0；低水位内 P1；目标缓冲内 P2
      final int priority;
      if (isFirstGapSeg || i == startIdx) {
        priority = 0;
      } else if (projectedSeconds < _config.prefetch.lowWaterSeconds) {
        priority = 1;
      } else if (projectedSeconds < _config.prefetch.targetBufferSeconds) {
        priority = 2;
      } else {
        break;
      }

      final jobKey = 'tts:${seg.requestKey}';
      final existing = await _store.getJob(jobKey);
      final needRevive =
          existing != null &&
          (existing.status == ImmersiveJobStatus.succeeded ||
              existing.status == ImmersiveJobStatus.cancelled);

      final enqueued = await _store.enqueueOrReviveJob(
        ImmersiveJob(
          jobKey: jobKey,
          jobType: ImmersiveJobType.ttsSynthesize,
          bookId: demand.bookId,
          bookRevisionId: demand.bookRevisionId,
          status: ImmersiveJobStatus.queued,
          priority: priority,
          inputVersion: seg.renderSpecHash,
          payloadJson: jsonEncode({
            'segment_id': seg.segmentId,
            'request_key': seg.requestKey,
            'voice_profile_id': seg.voiceProfileId,
            'spoken_text': seg.spokenText,
            'segment_order': seg.segmentOrder,
            'generation': _generation,
          }),
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
        reviveTerminal: needRevive,
      );

      if (enqueued.status == ImmersiveJobStatus.queued &&
          existing == null) {
        pendingTtsCount++;
      }

      final cps = _voiceCharsPerSec[seg.voiceProfileId] ?? defaultCps;
      projectedSeconds += (seg.codePointLength / cps) / demand.playbackRate;
    }
  }

  Future<void> _dispatchTtsJobs(
    SchedulerDemandSnapshot demand,
    int nowMs,
  ) async {
    final candidates = await _store.listJobs(
      bookId: demand.bookId,
      statuses: const {ImmersiveJobStatus.queued, ImmersiveJobStatus.retryWait},
    );
    final ttsJobs = candidates
        .where(
          (j) =>
              j.jobType == ImmersiveJobType.ttsSynthesize &&
              !_inFlightJobKeys.contains(j.jobKey) &&
              (j.status == ImmersiveJobStatus.queued ||
                  (j.notBeforeMs ?? 0) <= nowMs),
        )
        .toList();

    ttsJobs.sort((a, b) {
      final pCmp = a.priority.compareTo(b.priority);
      if (pCmp != 0) return pCmp;
      final aOrd = (jsonDecode(a.payloadJson) as Map)['segment_order'] as int? ?? 0;
      final bOrd = (jsonDecode(b.payloadJson) as Map)['segment_order'] as int? ?? 0;
      return aOrd.compareTo(bOrd);
    });

    for (final job in ttsJobs) {
      if (demand.paused) break;
      final payload = jsonDecode(job.payloadJson) as Map;
      final vpid = payload['voice_profile_id'] as String;
      final resolution = _config.resolveVoiceProfile(vpid);
      if (resolution == null || !resolution.isEffectivelyEnabled) {
        // 供应商/模型/音色已被禁用或删除：取消该旧任务并触发同性别自动兜底重建清单
        await _store.completeJob(
          jobKey: job.jobKey,
          workerId: job.leaseOwner ?? workerId,
          fence: job.fence,
          newStatus: ImmersiveJobStatus.cancelled,
          errorMessage: '音色 $vpid 已停用或移除，切换同性别兜底音色',
          nowMs: nowMs,
        );
        if (onVoiceFailedNeedsFallback != null) {
          unawaited(
            onVoiceFailedNeedsFallback!(vpid, '音色 $vpid 已停用或移除'),
          );
        }
        continue;
      }

      final isForeground = job.priority <= 1;
      // 一次性原子申请全局 + 供应商 + 模型 + RPM 额度，不满足跳过，绝不阻塞其他可用供应商
      final acquired = quotaPool.tryAcquireTts(
        ttsConfig: _config.tts,
        resolution: resolution,
        isForegroundPriority: isForeground,
      );
      if (!acquired) continue;

      final claimed = await _store.claimJob(
        jobKey: job.jobKey,
        workerId: workerId,
        leaseSeconds: _config.jobs.leaseSeconds,
        nowMs: _now().millisecondsSinceEpoch,
      );
      if (claimed == null) {
        quotaPool.releaseTts(
          resolution: resolution,
          isForegroundPriority: isForeground,
        );
        continue;
      }

      _inFlightJobKeys.add(claimed.jobKey);
      unawaited(
        _executeTtsJob(
          claimed,
          resolution: resolution,
          isForeground: isForeground,
          demand: demand,
        ),
      );
    }
  }

  Future<void> _executeTtsJob(
    ImmersiveJob job, {
    required VoiceProfileResolution resolution,
    required bool isForeground,
    required SchedulerDemandSnapshot demand,
  }) async {
    _startHeartbeat(job);
    final payload = jsonDecode(job.payloadJson) as Map;
    final segmentId = payload['segment_id'] as String;
    final requestKey = payload['request_key'] as String;
    final spokenText = payload['spoken_text'] as String;
    final jobGen = payload['generation'] as int? ?? _generation;
    final reservationId = '${job.jobKey}_f${job.fence}';
    var reserved = false;

    try {
      // 若缓存已存在合法有效文件，直接复用并完成任务
      final existingAsset = await _cacheManager.peekValidAssetMetadata(
        requestKey,
      );
      if (existingAsset != null) {
        await _store.publishTtsAssetAtomically(
          jobKey: job.jobKey,
          workerId: workerId,
          fence: job.fence,
          asset: existingAsset,
          nowMs: _now().millisecondsSinceEpoch,
        );
        await onAudioAssetReady?.call(requestKey);
        return;
      }

      // 估算写入空间并原子预留
      final estBytes = math.max(16384, spokenText.runes.length * 1400);
      reserved = await _cacheManager.reserveInFlightSpace(
        reservationId,
        estBytes,
      );
      if (!reserved) {
        _blockingReason = '音频缓存空间或磁盘剩余空间不足，已暂停新预取';
        await _store.completeJob(
          jobKey: job.jobKey,
          workerId: workerId,
          fence: job.fence,
          newStatus: ImmersiveJobStatus.blocked,
          errorMessage: _blockingReason,
          nowMs: _now().millisecondsSinceEpoch,
        );
        return;
      }

      await _store.updateAudioSegmentStatus(
        segmentId: segmentId,
        status: AudioSegmentStatus.synthesizing,
      );

      final spec = RenderSpec.fromResolution(
        resolution: resolution,
        inputText: spokenText,
      );
      final apiKey = demand.resolveTtsApiKey(resolution.provider);

      final audio = await _ttsAdapter.synthesize(
        spec: spec,
        apiKey: apiKey,
        timeoutMs: resolution.provider.requestTimeoutMs,
        isCancelled: () => _cancelledGenerations.contains(jobGen),
      );

      final writeRes = await _cacheManager.writeAndPublishAtomically(
        jobKey: job.jobKey,
        workerId: workerId,
        attempt: job.attempt,
        fence: job.fence,
        requestKey: spec.requestKey,
        audio: audio,
      );

      if (writeRes.publishResult.published && writeRes.asset != null) {
        // 用真实音频时长平滑更新该音色的字符/秒估算
        final secs = writeRes.asset!.durationSeconds;
        if (secs > 0.1) {
          final observedCps = (spokenText.runes.length / secs).clamp(1.0, 15.0);
          final prev = _voiceCharsPerSec[resolution.voice.voiceProfileId] ??
              _config.audioGeneration.initialEstimatedCharactersPerSecond;
          _voiceCharsPerSec[resolution.voice.voiceProfileId] =
              prev * 0.7 + observedCps * 0.3;
        }
        _lastError = null;
        await onAudioAssetReady?.call(spec.requestKey);
      }
    } on TtsAdapterException catch (e) {
      if (e.kind == TtsAdapterErrorKind.cancelled) {
        await _store.completeJob(
          jobKey: job.jobKey,
          workerId: workerId,
          fence: job.fence,
          newStatus: ImmersiveJobStatus.cancelled,
          nowMs: _now().millisecondsSinceEpoch,
        );
      } else if (e.kind == TtsAdapterErrorKind.rateLimited) {
        quotaPool.applyProviderCooldown(
          resolution.provider.providerId,
          e.retryAfter ?? const Duration(seconds: 3),
        );
        await _handleRetryableJobFailure(
          job,
          e.message,
          retryAfter: e.retryAfter,
          isBlocking: false,
          segmentId: segmentId,
        );
      } else if (e.isBlocking) {
        // TTS 音色不可用或鉴权/参数被拒：若有同性别其他可用音色，通知协调器自动切换兜底
        final vpid = resolution.voice.voiceProfileId;
        final hasOther = _config.allEnabledVoiceProfiles
            .any((r) => r.voice.voiceProfileId != vpid);
        if (hasOther && onVoiceFailedNeedsFallback != null) {
          await _store.completeJob(
            jobKey: job.jobKey,
            workerId: workerId,
            fence: job.fence,
            newStatus: ImmersiveJobStatus.cancelled,
            errorMessage: '音色 $vpid 失效，自动切换同性别兜底',
            nowMs: _now().millisecondsSinceEpoch,
          );
          unawaited(onVoiceFailedNeedsFallback!(vpid, e.message));
        } else {
          _blockingReason = e.message;
          _lastError = e.message;
          await _store.completeJob(
            jobKey: job.jobKey,
            workerId: workerId,
            fence: job.fence,
            newStatus: ImmersiveJobStatus.blocked,
            errorMessage: e.message,
            nowMs: _now().millisecondsSinceEpoch,
          );
          await _store.updateAudioSegmentStatus(
            segmentId: segmentId,
            status: AudioSegmentStatus.blocked,
            errorMessage: e.message,
          );
        }
      } else {
        final vpid = resolution.voice.voiceProfileId;
        final reachedLimit = job.attempt >= _config.retry.maxAttempts;
        final hasOther = _config.allEnabledVoiceProfiles
            .any((r) => r.voice.voiceProfileId != vpid);
        if (reachedLimit && hasOther && onVoiceFailedNeedsFallback != null) {
          await _store.completeJob(
            jobKey: job.jobKey,
            workerId: workerId,
            fence: job.fence,
            newStatus: ImmersiveJobStatus.cancelled,
            errorMessage: '音色 $vpid 多次合成失败，自动切换同性别兜底',
            nowMs: _now().millisecondsSinceEpoch,
          );
          unawaited(onVoiceFailedNeedsFallback!(vpid, e.message));
        } else {
          await _handleRetryableJobFailure(
            job,
            e.message,
            isBlocking: false,
            segmentId: segmentId,
          );
        }
      }
    } catch (e) {
      await _handleRetryableJobFailure(
        job,
        'TTS 合成失败：$e',
        isBlocking: false,
        segmentId: segmentId,
      );
    } finally {
      if (reserved) _cacheManager.releaseInFlightSpace(reservationId);
      _stopHeartbeat(job.jobKey);
      _inFlightJobKeys.remove(job.jobKey);
      quotaPool.releaseTts(
        resolution: resolution,
        isForegroundPriority: isForeground,
      );
      unawaited(tick());
    }
  }

  Future<void> _handleRetryableJobFailure(
    ImmersiveJob job,
    String errorMessage, {
    Duration? retryAfter,
    required bool isBlocking,
    String? segmentId,
  }) async {
    _lastError = errorMessage;
    final nowMs = _now().millisecondsSinceEpoch;
    if (isBlocking || job.attempt >= _config.retry.maxAttempts) {
      final finalStatus = isBlocking
          ? ImmersiveJobStatus.blocked
          : ImmersiveJobStatus.failed;
      await _store.completeJob(
        jobKey: job.jobKey,
        workerId: workerId,
        fence: job.fence,
        newStatus: finalStatus,
        errorMessage: errorMessage,
        nowMs: nowMs,
      );
      if (segmentId != null) {
        await _store.updateAudioSegmentStatus(
          segmentId: segmentId,
          status: isBlocking
              ? AudioSegmentStatus.blocked
              : AudioSegmentStatus.failed,
          errorMessage: errorMessage,
        );
      }
      return;
    }

    // 指数退避 + 随机抖动 + Retry-After 尊重
    final expMs =
        _config.retry.initialBackoffMs * math.pow(2, math.max(0, job.attempt - 1));
    final cappedMs = math.min(expMs.toInt(), _config.retry.maxBackoffMs);
    final jitterFactor =
        1.0 + (_rand.nextDouble() * 2 - 1) * _config.retry.jitterRatio;
    var delayMs = (cappedMs * jitterFactor).round().clamp(50, _config.retry.maxBackoffMs);
    if (_config.retry.respectRetryAfter && retryAfter != null) {
      delayMs = math.max(delayMs, retryAfter.inMilliseconds);
    }

    await _store.completeJob(
      jobKey: job.jobKey,
      workerId: workerId,
      fence: job.fence,
      newStatus: ImmersiveJobStatus.retryWait,
      nextNotBeforeMs: nowMs + delayMs,
      errorMessage: errorMessage,
      nowMs: nowMs,
    );
  }

  void _startHeartbeat(ImmersiveJob job) {
    _stopHeartbeat(job.jobKey);
    _heartbeats[job.jobKey] = Timer.periodic(
      Duration(seconds: _config.jobs.heartbeatSeconds),
      (_) {
        unawaited(
          _store.heartbeatJob(
            jobKey: job.jobKey,
            workerId: workerId,
            fence: job.fence,
            leaseSeconds: _config.jobs.leaseSeconds,
            nowMs: _now().millisecondsSinceEpoch,
          ),
        );
      },
    );
  }

  void _stopHeartbeat(String jobKey) {
    _heartbeats.remove(jobKey)?.cancel();
  }
}
