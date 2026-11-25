import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../services/reader_platform.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import 'immersive_database.dart';
import 'tts_provider_adapter.dart';

/// 已被读者原子钉住保护的可播放音频句柄（释放前清理器禁止删除）
class PinnedAudioHandle {
  final AudioAsset asset;
  final void Function() _onRelease;
  bool _released = false;

  PinnedAudioHandle(this.asset, this._onRelease);

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

/// 缓存空间状态快照
class AudioCacheStats {
  final int committedBytes;
  final int tempBytes;
  final int reservedInFlightBytes;
  final int assetCount;
  final int? freeDiskBytes;

  const AudioCacheStats({
    required this.committedBytes,
    required this.tempBytes,
    required this.reservedInFlightBytes,
    required this.assetCount,
    this.freeDiskBytes,
  });

  int get totalBudgetBytes =>
      committedBytes + tempBytes + reservedInFlightBytes;
}

/// 音频缓存管理器：独占临时落盘、原子重命名、SHA-256 复用校验、读写互斥保护与 LRU 淘汰
class AudioCacheManager {
  final ImmersiveStateStore _store;
  final String audioCacheDir;
  final String tempDir;
  final CacheConfig cacheConfig;
  final DateTime Function() _now;
  final Future<int?> Function(String path)? _freeDiskProbe;
  final Future<({bool valid, int durationMs})> Function(
    String filePath,
    int fallbackDurationMs,
  )? _platformAudioProbe;

  final math.Random _rand = math.Random.secure();
  final Map<String, int> _pinCounts = {};
  final Set<String> _evictingKeys = {};
  final Map<String, int> _inFlightReservations = {};
  final Map<String, int> _recentPlayProtectedUntilMs = {};

  int cacheHits = 0;
  int cacheMisses = 0;

  AudioCacheManager({
    required ImmersiveStateStore store,
    required this.audioCacheDir,
    required this.tempDir,
    required this.cacheConfig,
    DateTime Function()? now,
    Future<int?> Function(String path)? freeDiskProbe,
    Future<({bool valid, int durationMs})> Function(
      String filePath,
      int fallbackDurationMs,
    )? platformAudioProbe,
  }) : _store = store,
       _now = now ?? DateTime.now,
       _freeDiskProbe = freeDiskProbe,
       _platformAudioProbe = platformAudioProbe;

  Future<void> ensureDirectories() async {
    await Directory(audioCacheDir).create(recursive: true);
    await Directory(tempDir).create(recursive: true);
  }

  /// 为即将发出的在途请求原子预留缓存空间，避免并发超限；不足时先尝试 LRU 淘汰
  Future<bool> reserveInFlightSpace(
    String reservationId,
    int estimatedBytes,
  ) async {
    await ensureDirectories();
    final safeEst = estimatedBytes.clamp(4096, 8 * 1024 * 1024);
    final hasRoom = await _ensureSpaceFor(safeEst);
    if (!hasRoom) return false;
    _inFlightReservations[reservationId] = safeEst;
    return true;
  }

  void releaseInFlightSpace(String reservationId) {
    _inFlightReservations.remove(reservationId);
  }

  /// 标记近期播放过的资产受保护（在 protect_recent_playback_seconds 内不被 LRU 淘汰）
  void protectRecentPlayback(String requestKey) {
    final until =
        _now().millisecondsSinceEpoch +
        cacheConfig.protectRecentPlaybackSeconds * 1000;
    _recentPlayProtectedUntilMs[requestKey] = until;
  }

  /// 原子取得资产保护句柄（覆盖存在检查、SHA-256 校验、打开、入队全过程，消除检查后被删竞态 A23）
  Future<PinnedAudioHandle?> acquireAssetForPlayback(
    String requestKey, {
    bool touchAccessTime = true,
  }) async {
    // 1. 原子互斥：若清理器正在淘汰该键，拒绝借出
    if (_evictingKeys.contains(requestKey)) {
      cacheMisses++;
      return null;
    }
    // 先递增引用计数，阻止任何并发清理器将此资产置为 evicting
    _pinCounts[requestKey] = (_pinCounts[requestKey] ?? 0) + 1;
    var releasedOnError = false;
    void releasePin() {
      final cur = (_pinCounts[requestKey] ?? 1) - 1;
      if (cur <= 0) {
        _pinCounts.remove(requestKey);
      } else {
        _pinCounts[requestKey] = cur;
      }
    }

    try {
      final asset = await _store.getAudioAsset(requestKey);
      if (asset == null || asset.verifyStatus != 'valid') {
        cacheMisses++;
        releasePin();
        releasedOnError = true;
        return null;
      }
      final file = File(asset.filePath);
      if (!await file.exists()) {
        await _store.deleteAudioAsset(requestKey);
        cacheMisses++;
        releasePin();
        releasedOnError = true;
        return null;
      }
      final actualLen = await file.length();
      if (actualLen != asset.byteSize || actualLen <= 0) {
        await _store.deleteAudioAsset(requestKey);
        cacheMisses++;
        releasePin();
        releasedOnError = true;
        return null;
      }
      if (cacheConfig.verifyChecksumOnReuse) {
        final bytes = await file.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest != asset.contentSha256) {
          await _store.deleteAudioAsset(requestKey);
          try {
            await file.delete();
          } catch (_) {}
          cacheMisses++;
          releasePin();
          releasedOnError = true;
          return null;
        }
      }
      cacheHits++;
      if (touchAccessTime) {
        await _store.touchAudioAsset(requestKey, _now().millisecondsSinceEpoch);
      }
      return PinnedAudioHandle(asset, releasePin);
    } catch (_) {
      if (!releasedOnError) releasePin();
      cacheMisses++;
      return null;
    }
  }

  /// 仅查询资产元数据是否可用（不刷新 LRU 最近使用时间，满足 11.4 节）
  Future<AudioAsset?> peekValidAssetMetadata(String requestKey) async {
    if (_evictingKeys.contains(requestKey)) return null;
    final asset = await _store.getAudioAsset(requestKey);
    if (asset == null || asset.verifyStatus != 'valid') return null;
    final file = File(asset.filePath);
    if (!await file.exists()) return null;
    return asset;
  }

  /// 完整原子写盘与事务发布流程（第 11.2 节）：
  /// 1. 独占临时文件 -> 2. 校验解码与平台时长 -> 3. 内容哈希不可变路径原子重命名 -> 4. 事务校验 owner/fence 后发布
  Future<({AudioAsset? asset, AssetPublishResult publishResult})>
  writeAndPublishAtomically({
    required String jobKey,
    required String workerId,
    required int attempt,
    required int fence,
    required String requestKey,
    required SynthesizedAudioPayload audio,
  }) async {
    await ensureDirectories();
    final randHex = _rand.nextInt(1 << 30).toRadixString(16);
    final safeJob = jobKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final tmpFile = File(
      p.join(tempDir, '${safeJob}_a${attempt}_f${fence}_$randHex.tmp'),
    );

    try {
      await tmpFile.writeAsBytes(audio.bytes, flush: true);

      // 平台原生二次校验可解码性与真实时长
      final probed = _platformAudioProbe != null
          ? await _platformAudioProbe(tmpFile.path, audio.durationMs)
          : await AudioFormatInspector.probeFileOnPlatform(
              tmpFile.path,
              fallbackDurationMs: audio.durationMs,
            );
      if (!probed.valid || probed.durationMs <= 0) {
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidAudioPayload,
          message: '平台音频解码器校验失败，音频文件损坏或不可播放',
        );
      }

      final contentHash = sha256.convert(audio.bytes).toString();
      // 使用内容哈希作为不可变文件名，同文件系统原子重命名，绝不覆盖不同内容
      final finalPath = p.join(
        audioCacheDir,
        '$contentHash.${audio.detectedFormat}',
      );
      final finalFile = File(finalPath);
      if (await finalFile.exists()) {
        // 已有相同内容哈希的不可变文件，直接删除本次临时文件即可复用
        await tmpFile.delete();
      } else {
        await tmpFile.rename(finalPath);
      }

      final nowMs = _now().millisecondsSinceEpoch;
      final asset = AudioAsset(
        requestKey: requestKey,
        contentSha256: contentHash,
        filePath: finalPath,
        format: audio.detectedFormat,
        durationMs: probed.durationMs,
        byteSize: audio.bytes.length,
        verifyStatus: 'valid',
        lastAccessedAtMs: nowMs,
        createdAtMs: nowMs,
      );

      final publishRes = await _store.publishTtsAssetAtomically(
        jobKey: jobKey,
        workerId: workerId,
        fence: fence,
        asset: asset,
        nowMs: nowMs,
      );

      // 若发布成功，顺便做一次非阻塞容量维护
      if (publishRes.published) {
        await evictIfNeeded();
      }
      return (asset: publishRes.published ? asset : null, publishResult: publishRes);
    } finally {
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
    }
  }

  /// 按 LRU 清理未保护资产，将总占用降至 max_bytes * evict_to_ratio 并保留 min_free_disk_bytes
  Future<int> evictIfNeeded({int incomingBytes = 0}) async {
    final stats = await computeStats();
    final needByCap = stats.totalBudgetBytes + incomingBytes > cacheConfig.maxBytes;
    final needByDisk =
        stats.freeDiskBytes != null &&
        stats.freeDiskBytes! - incomingBytes < cacheConfig.minFreeDiskBytes;
    if (!needByCap && !needByDisk) return 0;

    final targetBytes = (cacheConfig.maxBytes * cacheConfig.evictToRatio).floor();
    var currentTotal = stats.totalBudgetBytes + incomingBytes;
    var currentFree = stats.freeDiskBytes;
    var evictedCount = 0;
    final nowMs = _now().millisecondsSinceEpoch;

    final assets = await _store.listAllAudioAssets(); // 已按 last_accessed_at_ms ASC 排序
    // 统计同一内容文件是否被多个 request_key 引用（内容去重保护）
    final pathRefCounts = <String, int>{};
    for (final a in assets) {
      pathRefCounts[a.filePath] = (pathRefCounts[a.filePath] ?? 0) + 1;
    }

    for (final asset in assets) {
      final capOk = currentTotal <= targetBytes;
      final diskOk =
          currentFree == null ||
          currentFree - incomingBytes >= cacheConfig.minFreeDiskBytes;
      if (capOk && diskOk) break;

      // 跳过正在播放/入队钉住的、正在淘汰的、以及近期播放保护窗口内的资产
      if ((_pinCounts[asset.requestKey] ?? 0) > 0) continue;
      if (_evictingKeys.contains(asset.requestKey)) continue;
      final recentUntil = _recentPlayProtectedUntilMs[asset.requestKey] ?? 0;
      if (recentUntil > nowMs) continue;

      // 原子将资产切换为 evicting，阻止新读者竞态打开
      _evictingKeys.add(asset.requestKey);
      try {
        // 再次检查在进入 evicting 前是否刚好被读者钉住
        if ((_pinCounts[asset.requestKey] ?? 0) > 0) continue;
        final marked = await _store.markAssetEvictingIfValid(asset.requestKey);
        if (!marked) continue;

        await _store.deleteAudioAsset(asset.requestKey);
        final remainingRefs = (pathRefCounts[asset.filePath] ?? 1) - 1;
        pathRefCounts[asset.filePath] = remainingRefs;
        if (remainingRefs <= 0) {
          final file = File(asset.filePath);
          if (await file.exists()) {
            await file.delete();
          }
          currentTotal -= asset.byteSize;
          if (currentFree != null) currentFree += asset.byteSize;
        }
        evictedCount++;
      } finally {
        _evictingKeys.remove(asset.requestKey);
      }
    }

    return evictedCount;
  }

  /// 启动维护：清理超时未完成临时文件及无数据库引用的孤立内容文件
  Future<int> cleanupStaleAndOrphanFiles() async {
    await ensureDirectories();
    var cleaned = 0;
    final nowMs = _now().millisecondsSinceEpoch;
    final staleThresholdMs =
        cacheConfig.cleanupIncompleteFilesAfterSeconds * 1000;

    // 1. 清理 tempDir 中过期或无活跃租约的残留临时文件
    final tDir = Directory(tempDir);
    if (await tDir.exists()) {
      await for (final entity in tDir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (nowMs - stat.modified.millisecondsSinceEpoch >= staleThresholdMs ||
              _inFlightReservations.isEmpty) {
            await entity.delete();
            cleaned++;
          }
        } catch (_) {}
      }
    }

    // 2. 清理 audioCacheDir 中没有被任何有效 AudioAsset 引用的孤立文件
    final assets = await _store.listAllAudioAssets();
    final referencedPaths = {
      for (final a in assets) p.normalize(a.filePath),
    };
    final aDir = Directory(audioCacheDir);
    if (await aDir.exists()) {
      await for (final entity in aDir.list()) {
        if (entity is! File) continue;
        final norm = p.normalize(entity.path);
        if (!referencedPaths.contains(norm)) {
          try {
            await entity.delete();
            cleaned++;
          } catch (_) {}
        }
      }
    }
    return cleaned;
  }

  /// 统计当前缓存已用字节、临时文件字节、在途预留字节及真实可用磁盘空间
  Future<AudioCacheStats> computeStats() async {
    final assets = await _store.listAllAudioAssets();
    final uniqueFiles = <String, int>{};
    for (final a in assets) {
      uniqueFiles[a.filePath] = a.byteSize;
    }
    final committedBytes = uniqueFiles.values.fold<int>(0, (s, v) => s + v);

    var tempBytes = 0;
    final tDir = Directory(tempDir);
    if (await tDir.exists()) {
      await for (final entity in tDir.list()) {
        if (entity is File) {
          try {
            tempBytes += await entity.length();
          } catch (_) {}
        }
      }
    }
    final reserved = _inFlightReservations.values.fold<int>(0, (s, v) => s + v);
    final freeDisk = await _queryFreeDiskBytes();

    return AudioCacheStats(
      committedBytes: committedBytes,
      tempBytes: tempBytes,
      reservedInFlightBytes: reserved,
      assetCount: assets.length,
      freeDiskBytes: freeDisk,
    );
  }

  /// 清空所有未钉住的音频缓存（用于用户手动清理缓存按钮）
  Future<int> clearAllUnpinnedCache() async {
    var removed = 0;
    final assets = await _store.listAllAudioAssets();
    for (final a in assets) {
      if ((_pinCounts[a.requestKey] ?? 0) > 0) continue;
      _evictingKeys.add(a.requestKey);
      try {
        if ((_pinCounts[a.requestKey] ?? 0) > 0) continue;
        await _store.deleteAudioAsset(a.requestKey);
        final f = File(a.filePath);
        if (await f.exists()) await f.delete();
        removed++;
      } finally {
        _evictingKeys.remove(a.requestKey);
      }
    }
    return removed;
  }

  Future<bool> _ensureSpaceFor(int incomingBytes) async {
    await evictIfNeeded(incomingBytes: incomingBytes);
    final stats = await computeStats();
    if (stats.totalBudgetBytes + incomingBytes > cacheConfig.maxBytes) {
      return false;
    }
    if (stats.freeDiskBytes != null &&
        stats.freeDiskBytes! - incomingBytes < cacheConfig.minFreeDiskBytes) {
      return false;
    }
    return true;
  }

  Future<int?> _queryFreeDiskBytes() async {
    if (_freeDiskProbe != null) return _freeDiskProbe(audioCacheDir);
    if (!ReaderPlatform.capabilities.mediaPlayback) return null;
    try {
      final bytes = await ReaderPlatform.invoke<int>('getFreeDiskBytes', {
        'path': audioCacheDir,
      });
      return bytes != null && bytes >= 0 ? bytes : null;
    } catch (_) {
      return null;
    }
  }
}
