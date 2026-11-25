import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../immersive/models/immersive_config.dart';
import '../../immersive/services/immersive_config_service.dart';
import '../../immersive/services/immersive_database.dart';
import '../../immersive/services/immersive_playback_coordinator.dart';
import '../../models/book.dart';
import '../../models/bookshelf_book.dart';
import '../../models/reading_snapshot.dart';
import '../../services/app_storage.dart';
import '../../services/bookmark_service.dart';
import '../../services/bookshelf_service.dart';
import '../../services/external_reader_fonts.dart';
import '../../services/reader_backup_service.dart';
import '../../services/reader_library_service.dart';
import '../../services/reader_position_service.dart';
import '../../services/reader_settings_repository.dart';
import '../../services/reading_activity_service.dart';
import '../../services/reading_history_service.dart';
import '../../services/safe_zip_reader.dart';
import '../../services/tts_service.dart';
import '../models/webdav_config.dart';
import 'webdav_client.dart';
import 'webdav_crypto.dart';

/// 普通 AI 朗读配置的快照对象（含真实 API Key，仅用于同步封装与安全写回）
class NormalTtsConfigSnapshot {
  final String engine;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String voice;
  final double rate;
  final String nativeVoice;

  const NormalTtsConfigSnapshot({
    required this.engine,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.rate,
    required this.nativeVoice,
  });

  Map<String, dynamic> toJson() => {
    'version': 2,
    'engine': engine,
    'base_url': baseUrl,
    'api_key': apiKey,
    'model': model,
    'voice': voice,
    'rate': rate,
    'native_voice': nativeVoice,
  };

  factory NormalTtsConfigSnapshot.fromJson(Map<String, dynamic> json) {
    final rateNum = json['rate'];
    final rate = rateNum is num && rateNum.isFinite
        ? rateNum.toDouble().clamp(0.5, 2.0)
        : 1.0;
    final rawBase = (json['base_url']?.toString() ?? '').trim();
    final rawModel = (json['model']?.toString() ?? '').trim();
    final rawVoice = (json['voice']?.toString() ?? '').trim();
    return NormalTtsConfigSnapshot(
      engine: json['engine']?.toString() == 'openAi' ? 'openAi' : 'native',
      baseUrl: rawBase.isEmpty ? 'https://api.openai.com' : rawBase,
      apiKey: json['api_key']?.toString() ?? '',
      model: rawModel.isEmpty ? 'tts-1' : rawModel,
      voice: rawVoice.isEmpty ? 'alloy' : rawVoice,
      rate: rate,
      nativeVoice: (json['native_voice']?.toString() ?? '').trim(),
    );
  }
}

/// 普通 AI 朗读配置读写桥接（默认对接 TtsService，测试可注入内存桩）
abstract class NormalTtsConfigBridge {
  Future<NormalTtsConfigSnapshot> read();
  Future<void> write(NormalTtsConfigSnapshot snapshot);
}

class LiveNormalTtsConfigBridge implements NormalTtsConfigBridge {
  @override
  Future<NormalTtsConfigSnapshot> read() async {
    final tts = TtsService();
    await tts.loadSettings();
    return NormalTtsConfigSnapshot(
      engine: tts.engineType.name,
      baseUrl: tts.openAiBaseUrl,
      apiKey: tts.openAiApiKey,
      model: tts.openAiModel,
      voice: tts.openAiVoice,
      rate: tts.speechRate,
      nativeVoice: tts.nativeVoice,
    );
  }

  @override
  Future<void> write(NormalTtsConfigSnapshot snapshot) async {
    final tts = TtsService();
    await tts.saveSettings(
      engineType: snapshot.engine == 'openAi'
          ? TtsEngineType.openAi
          : TtsEngineType.native,
      openAiBaseUrl: snapshot.baseUrl,
      openAiApiKey: snapshot.apiKey,
      openAiModel: snapshot.model,
      openAiVoice: snapshot.voice,
      speechRate: snapshot.rate,
      nativeVoice: snapshot.nativeVoice,
    );
  }
}

/// 沉浸式书籍角色档案与手动音色锁定桥接（默认对接 SQLite 状态库，测试可注入内存桩）
abstract class ImmersiveProfilesBridge {
  Future<Map<String, Map<String, dynamic>>> exportAll();
  Future<bool> mergeAll(Map<String, Map<String, dynamic>> remoteProfiles);
}

class NoopImmersiveProfilesBridge implements ImmersiveProfilesBridge {
  const NoopImmersiveProfilesBridge();

  @override
  Future<Map<String, Map<String, dynamic>>> exportAll() async => {};

  @override
  Future<bool> mergeAll(Map<String, Map<String, dynamic>> remoteProfiles) async =>
      false;
}

class StoreImmersiveProfilesBridge implements ImmersiveProfilesBridge {
  final ImmersiveStateStore store;
  const StoreImmersiveProfilesBridge(this.store);

  @override
  Future<Map<String, Map<String, dynamic>>> exportAll() =>
      store.exportAllBookImmersiveProfiles();

  @override
  Future<bool> mergeAll(Map<String, Map<String, dynamic>> remoteProfiles) =>
      store.mergeAllBookImmersiveProfiles(remoteProfiles);
}

class LiveImmersiveProfilesBridge implements ImmersiveProfilesBridge {
  final ImmersiveConfigService _configService;
  const LiveImmersiveProfilesBridge(this._configService);

  Future<T> _withStore<T>(
    Future<T> Function(ImmersiveStateStore store) action, {
    required bool createIfMissing,
  }) async {
    final active = ImmersivePlaybackCoordinator().activeStateStore;
    if (active != null) {
      return action(active);
    }
    var paths = _configService.resolvedPaths;
    if (paths == null) {
      final status = await _configService.loadAndValidateConfig(
        autoInitPreset: false,
      );
      paths = status.paths;
    }
    if (paths == null) {
      final cfgFile = await _configService.defaultConfigFile();
      paths = _configService.resolvePaths(cfgFile, const StorageConfig());
    }
    final dbFile = File(paths.databasePath);
    if (!createIfMissing && !await dbFile.exists()) {
      return action(InMemoryImmersiveStateStore());
    }
    final store = SqliteImmersiveStateStore(paths.databasePath);
    await store.initialize();
    try {
      return await action(store);
    } finally {
      await store.close();
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> exportAll() => _withStore(
    (s) => s.exportAllBookImmersiveProfiles(),
    createIfMissing: false,
  );

  @override
  Future<bool> mergeAll(Map<String, Map<String, dynamic>> remoteProfiles) {
    if (remoteProfiles.isEmpty) return Future.value(false);
    return _withStore(
      (s) => s.mergeAllBookImmersiveProfiles(remoteProfiles),
      createIfMissing: true,
    );
  }
}

/// WebDAV 云同步核心服务（管理配置、AI配置加密同步、沉浸式角色档案、阅读数据与离线书籍）
class WebDavSyncService extends ChangeNotifier {
  static const String preferencesKey = 'webdav_sync_config_v1';
  static const String _passwordSecretSlot = 'webdav_password_v1';
  static const String _fallbackPasswordKey = 'webdav_sync_secret_fallback_v1';
  static const String _syncIndexPath = 'sync_index.json';
  static const String _aiConfigPath = 'ai_config.json';
  static const String _readingDataPath = 'reading_data.json';
  static const String _immersiveProfilesPath = 'immersive_profiles.json';
  static const Duration backgroundSyncThrottle = Duration(seconds: 60);

  static final RegExp _bookIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,180}$');

  static final WebDavSyncService _instance = WebDavSyncService._();
  factory WebDavSyncService() => _instance;

  WebDavSyncService._()
    : _documents = AppStorage.documents,
      _secretStore = PlatformImmersiveSecretStore(),
      _immersiveConfigService = ImmersiveConfigService(),
      _normalTtsBridge = LiveNormalTtsConfigBridge(),
      _profilesBridge = null,
      _clientFactory = ((config) => WebDavClient.fromConfig(config)),
      _clock = DateTime.now,
      _notifyAppServices = true;

  @visibleForTesting
  WebDavSyncService.forTesting({
    required Future<Directory> Function() documents,
    required ImmersiveSecretStore secretStore,
    required ImmersiveConfigService immersiveConfigService,
    required NormalTtsConfigBridge normalTtsBridge,
    ImmersiveProfilesBridge? profilesBridge,
    WebDavClient Function(WebDavConfig config)? clientFactory,
    DateTime Function()? clock,
    bool notifyAppServices = false,
  }) : _documents = documents,
       _secretStore = secretStore,
       _immersiveConfigService = immersiveConfigService,
       _normalTtsBridge = normalTtsBridge,
       _profilesBridge = profilesBridge ?? const NoopImmersiveProfilesBridge(),
       _clientFactory =
           clientFactory ?? ((config) => WebDavClient.fromConfig(config)),
       _clock = clock ?? DateTime.now,
       _notifyAppServices = notifyAppServices;

  final Future<Directory> Function() _documents;
  final ImmersiveSecretStore _secretStore;
  final ImmersiveConfigService _immersiveConfigService;
  final NormalTtsConfigBridge _normalTtsBridge;
  final ImmersiveProfilesBridge? _profilesBridge;
  final WebDavClient Function(WebDavConfig config) _clientFactory;
  final DateTime Function() _clock;
  final bool _notifyAppServices;

  ImmersiveProfilesBridge get _effectiveProfilesBridge =>
      _profilesBridge ?? LiveImmersiveProfilesBridge(_immersiveConfigService);

  WebDavConfig _config = const WebDavConfig();
  bool _initialized = false;
  bool _syncing = false;
  bool _autoSyncTriggered = false;
  DateTime? _lastBackgroundSyncAt;
  String _statusMessage = '';
  WebDavSyncReport? _lastReport;
  Future<WebDavSyncReport>? _inFlightSync;

  WebDavConfig get config => _config;
  bool get initialized => _initialized;
  bool get isSyncing => _syncing;
  String get statusMessage => _statusMessage;
  WebDavSyncReport? get lastReport => _lastReport;

  /// 初始化并加载已保存的 WebDAV 配置（密码从安全存储还原）
  Future<void> initialize() async {
    if (_initialized) return;
    await reloadConfig();
    _initialized = true;
  }

  /// 重新从本地存储与安全存储加载配置
  Future<void> reloadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferencesKey);
    String password = (await _secretStore.read(_passwordSecretSlot)) ?? '';
    if (password.isEmpty) {
      final fallback = prefs.getString(_fallbackPasswordKey);
      if (fallback != null && fallback.isNotEmpty) {
        try {
          password = utf8.decode(base64Decode(fallback));
        } catch (_) {
          password = '';
        }
      }
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _config = WebDavConfig.fromJson(
            Map<String, dynamic>.from(decoded),
            hydratedPassword: password,
          );
        }
      } catch (_) {
        _config = WebDavConfig(password: password);
      }
    } else {
      _config = WebDavConfig(password: password);
    }

    // 为首次启动的设备生成稳定本机标识
    if (_config.deviceId.isEmpty) {
      final generated =
          'dev_${_clock().toUtc().microsecondsSinceEpoch.toRadixString(36)}';
      _config = _config.copyWith(deviceId: generated);
      await _persistConfigMetadata(_config);
    }
    notifyListeners();
  }

  /// 保存 WebDAV 配置（密码写入安全存储，绝不明文落盘至配置 JSON）
  Future<void> saveConfig(WebDavConfig next) async {
    await initialize();
    final normalized = next.copyWith(
      serverUrl: next.normalizedServerUrl,
      username: next.username.trim(),
      deviceId: next.deviceId.isNotEmpty ? next.deviceId : _config.deviceId,
    );

    final prefs = await SharedPreferences.getInstance();
    final storedSecure = await _secretStore.write(
      _passwordSecretSlot,
      normalized.password,
    );
    if (storedSecure) {
      await prefs.remove(_fallbackPasswordKey);
    } else if (normalized.password.isEmpty) {
      await prefs.remove(_fallbackPasswordKey);
    } else {
      await prefs.setString(
        _fallbackPasswordKey,
        base64Encode(utf8.encode(normalized.password)),
      );
    }

    await _persistConfigMetadata(normalized);
    _config = normalized;
    notifyListeners();
  }

  Future<void> _persistConfigMetadata(WebDavConfig cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      preferencesKey,
      jsonEncode(cfg.toJson(includePassword: false)),
    );
  }

  /// 测试 WebDAV 连通性与鉴权（支持传入未保存的表单草稿）
  Future<WebDavConnectionTestResult> testConnection([
    WebDavConfig? draft,
  ]) async {
    await initialize();
    final target = draft ?? _config;
    if (!target.hasCredentials) {
      return const WebDavConnectionTestResult(
        success: false,
        message: '请完整填写 WebDAV 服务器地址、账号与密码',
        durationMs: 0,
      );
    }
    final client = _clientFactory(target);
    try {
      return await client.testConnection();
    } finally {
      client.close();
    }
  }

  /// 打开应用后按用户配置触发一次静默自动同步（单生命周期最多自动触发一次，不阻塞首屏）
  Future<WebDavSyncReport?> triggerAutoSyncOnStart() async {
    await initialize();
    if (_autoSyncTriggered) return null;
    _autoSyncTriggered = true;
    if (!_config.canSync || !_config.autoSyncOnStart) {
      return null;
    }
    try {
      return await syncNow(mode: WebDavSyncMode.bidirectional, isAuto: true);
    } catch (e) {
      final report = WebDavSyncReport(
        success: false,
        message: '启动自动同步失败：$e',
      );
      _lastReport = report;
      _statusMessage = report.message;
      notifyListeners();
      return report;
    }
  }

  /// 退出阅读页或应用切入后台时触发一次轻量进度增量同步（带 60 秒节流，仅同步数 KB 进度与角色档案，不传大体积离线书）
  Future<WebDavSyncReport?> triggerLightweightProgressSync({
    bool force = false,
  }) async {
    await initialize();
    if (!_config.canSync || !_config.autoSyncOnBackground) return null;
    if (_inFlightSync != null || ReaderBackupService.hasActiveTransaction) {
      return null;
    }
    final now = _clock().toUtc();
    if (!force &&
        _lastBackgroundSyncAt != null &&
        now.difference(_lastBackgroundSyncAt!) < backgroundSyncThrottle) {
      return null;
    }

    // 先比对本地阅读数据与角色档案哈希：若自上次同步后无任何改动，零网络请求直接跳过
    final localPrefs = _config.syncReadingData
        ? await _readLocalReadingPreferences()
        : const <String, Object>{};
    final localReadingHash =
        _config.syncReadingData ? _readingPrefsHash(localPrefs) : '';
    final localProfiles = _config.syncImmersiveProfiles
        ? await _effectiveProfilesBridge.exportAll()
        : const <String, Map<String, dynamic>>{};
    final localProfilesHash = _config.syncImmersiveProfiles
        ? _canonicalHash({'books': localProfiles})
        : '';

    final readingChanged =
        _config.syncReadingData &&
        localReadingHash != _config.lastSyncedReadingHash;
    final profilesChanged =
        _config.syncImmersiveProfiles &&
        localProfiles.isNotEmpty &&
        localProfilesHash != _config.lastSyncedProfilesHash;

    if (!force && !readingChanged && !profilesChanged) {
      return null;
    }
    _lastBackgroundSyncAt = now;

    final future = _runSync(
      mode: WebDavSyncMode.bidirectional,
      isAuto: true,
      lightweightOnly: true,
    );
    _inFlightSync = future;
    try {
      return await future;
    } catch (_) {
      return null;
    } finally {
      if (identical(_inFlightSync, future)) {
        _inFlightSync = null;
      }
    }
  }

  /// 执行一次完整同步（支持智能双向 / 强制上传 / 强制拉取）
  Future<WebDavSyncReport> syncNow({
    WebDavSyncMode mode = WebDavSyncMode.bidirectional,
    bool isAuto = false,
  }) async {
    await initialize();
    if (_inFlightSync != null) {
      return _inFlightSync!;
    }
    if (!_config.hasCredentials) {
      const report = WebDavSyncReport(
        success: false,
        message: '请先填写并保存 WebDAV 地址、账号与密码',
      );
      _lastReport = report;
      _statusMessage = report.message;
      notifyListeners();
      return report;
    }
    if (ReaderBackupService.hasActiveTransaction) {
      const report = WebDavSyncReport(
        success: false,
        message: '本地恢复事务正在进行中，请稍后再同步',
      );
      _lastReport = report;
      _statusMessage = report.message;
      notifyListeners();
      return report;
    }

    final future = _runSync(mode: mode, isAuto: isAuto);
    _inFlightSync = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightSync, future)) {
        _inFlightSync = null;
      }
    }
  }

  Future<WebDavSyncReport> _runSync({
    required WebDavSyncMode mode,
    required bool isAuto,
    bool lightweightOnly = false,
  }) async {
    final sw = Stopwatch()..start();
    _syncing = true;
    _statusMessage = lightweightOnly
        ? '正在后台同步阅读进度...'
        : isAuto
        ? '启动自动同步中...'
        : '正在连接 WebDAV...';
    notifyListeners();

    final client = _clientFactory(_config);
    final warnings = <String>[];
    var aiAction = '未启用';
    var readingAction = '未启用';
    var profilesAction = '未启用';
    final uploadedBooks = <String>[];
    final downloadedBooks = <String>[];

    try {
      await client.ensureAppDirectories();

      _setProgress('正在读取云端同步索引...');
      final indexResp = await client.getJsonWithEtag(_syncIndexPath);
      final rawIndex = indexResp.data;
      var indexEtag = indexResp.etag;
      final now = _clock().toUtc();
      var index = rawIndex == null
          ? WebDavSyncIndex(updatedAt: now, updatedByDeviceId: _config.deviceId)
          : WebDavSyncIndex.fromJson(rawIndex);

      var nextConfig = _config;

      // 1. 同步 AI 配置（沉浸式 TTS + 正常 AI 朗读，默认端到端 AES-256-GCM 加密）
      if (!lightweightOnly && _config.syncAiConfig) {
        _setProgress('正在同步 AI 语音与模型配置...');
        final aiRes = await _syncAiConfig(
          client: client,
          mode: mode,
          index: index,
          config: nextConfig,
          now: now,
        );
        aiAction = aiRes.action;
        index = aiRes.index;
        nextConfig = nextConfig.copyWith(lastSyncedAiHash: aiRes.finalHash);
      }

      // 2. 同步阅读历史、书架书籍信息（含未离线书元数据）、进度、书签、笔记与设置
      if (_config.syncReadingData) {
        _setProgress('正在同步阅读历史与书籍信息...');
        final readingRes = await _syncReadingData(
          client: client,
          mode: mode,
          index: index,
          config: nextConfig,
          now: now,
        );
        readingAction = readingRes.action;
        index = readingRes.index;
        nextConfig = nextConfig.copyWith(
          lastSyncedReadingHash: readingRes.finalHash,
        );
      }

      // 3. 同步每本书的沉浸式角色档案、手动音色锁定与本书配音覆盖（轻量 JSON）
      if (_config.syncImmersiveProfiles) {
        _setProgress('正在同步沉浸式角色与音色档案...');
        final profRes = await _syncImmersiveProfiles(
          client: client,
          mode: mode,
          index: index,
          config: nextConfig,
          now: now,
        );
        profilesAction = profRes.action;
        index = profRes.index;
        nextConfig = nextConfig.copyWith(
          lastSyncedProfilesHash: profRes.finalHash,
        );
      }

      // 4. 同步已离线书籍正文（未离线书籍绝不上传或下载正文；后台轻量同步不传离线大包）
      if (!lightweightOnly && _config.syncOfflineBooks) {
        _setProgress('正在比对离线书籍...');
        final localBooks = await scanLocalOfflineBooks();
        final remoteBooks = Map<String, WebDavOfflineBookMeta>.from(
          index.offlineBooks,
        );

        final allIds = <String>{...localBooks.keys, ...remoteBooks.keys}.toList()
          ..sort();

        for (final bookId in allIds) {
          final local = localBooks[bookId];
          final remote = remoteBooks[bookId];

          final shouldUpload = switch (mode) {
            WebDavSyncMode.pushToRemote =>
              local != null &&
                  (remote == null || remote.contentHash != local.contentHash),
            WebDavSyncMode.pullFromRemote => false,
            WebDavSyncMode.bidirectional =>
              local != null &&
                  (remote == null ||
                      (remote.contentHash != local.contentHash &&
                          local.updatedAt.isAfter(remote.updatedAt))),
          };

          final shouldDownload = switch (mode) {
            WebDavSyncMode.pullFromRemote =>
              remote != null &&
                  (local == null || local.contentHash != remote.contentHash),
            WebDavSyncMode.pushToRemote => false,
            WebDavSyncMode.bidirectional =>
              remote != null &&
                  (local == null ||
                      (local.contentHash != remote.contentHash &&
                          remote.updatedAt.isAfter(local.updatedAt))),
          };

          if (shouldUpload && local != null) {
            _setProgress('正在上传离线书籍《${local.bookName}》...');
            try {
              final uploaded = await _uploadOfflineBookInternal(
                client: client,
                meta: local,
              );
              remoteBooks[bookId] = uploaded;
              uploadedBooks.add(bookId);
            } catch (e) {
              warnings.add('上传离线书《${local.bookName}》失败：$e');
            }
          } else if (shouldDownload && remote != null) {
            _setProgress('正在下载离线书籍《${remote.bookName}》...');
            try {
              final ok = await _downloadOfflineBookInternal(
                client: client,
                bookId: bookId,
                remoteMeta: remote,
              );
              if (ok) {
                downloadedBooks.add(bookId);
              } else {
                warnings.add('云端离线书《${remote.bookName}》文件缺失');
              }
            } catch (e) {
              warnings.add('下载离线书《${remote.bookName}》失败：$e');
            }
          }
        }

        index = index.copyWith(offlineBooks: remoteBooks);
      }

      // 5. 原子写回最新 sync_index.json（遇并发冲突重合并最新索引后重试）
      index = index.copyWith(
        updatedAt: now,
        updatedByDeviceId: nextConfig.deviceId,
      );
      try {
        await client.putJsonAtomic(
          _syncIndexPath,
          index.toJson(),
          expectedEtag: indexEtag,
        );
      } on WebDavPreconditionFailedException {
        final latest = await client.getJsonWithEtag(_syncIndexPath);
        if (latest.data != null) {
          final remoteLatest = WebDavSyncIndex.fromJson(latest.data!);
          final mergedBooks = <String, WebDavOfflineBookMeta>{
            ...remoteLatest.offlineBooks,
            ...index.offlineBooks,
          };
          index = index.copyWith(offlineBooks: mergedBooks);
        }
        await client.putJsonAtomic(
          _syncIndexPath,
          index.toJson(),
          expectedEtag: latest.etag,
        );
      }

      sw.stop();
      final report = WebDavSyncReport(
        success: true,
        message: warnings.isEmpty ? 'WebDAV 同步完成' : '同步完成（含 ${warnings.length} 条提示）',
        aiConfigAction: aiAction,
        readingDataAction: readingAction,
        profilesAction: profilesAction,
        uploadedBookIds: uploadedBooks,
        downloadedBookIds: downloadedBooks,
        warnings: warnings,
        durationMs: sw.elapsedMilliseconds,
      );

      nextConfig = nextConfig.copyWith(
        lastSyncAt: now,
        lastSyncSummary: report.conciseSummary,
      );
      await _persistConfigMetadata(nextConfig);
      _config = nextConfig;
      _lastReport = report;
      _statusMessage = report.conciseSummary;
      return report;
    } catch (e) {
      sw.stop();
      final report = WebDavSyncReport(
        success: false,
        message: '同步失败：$e',
        aiConfigAction: aiAction,
        readingDataAction: readingAction,
        profilesAction: profilesAction,
        uploadedBookIds: uploadedBooks,
        downloadedBookIds: downloadedBooks,
        warnings: warnings,
        durationMs: sw.elapsedMilliseconds,
      );
      _lastReport = report;
      _statusMessage = report.message;
      return report;
    } finally {
      client.close();
      _syncing = false;
      notifyListeners();
    }
  }

  void _setProgress(String msg) {
    _statusMessage = msg;
    notifyListeners();
  }

  // ==================== 1. AI 配置（沉浸式 + 普通朗读） ====================

  Future<Map<String, dynamic>> _buildLocalAiPayload() async {
    final immersiveStatus = await _immersiveConfigService.loadAndValidateConfig(
      autoInitPreset: true,
    );
    final immersiveMap = immersiveStatus.config?.toJson(redactSecrets: false);
    final normalTts = await _normalTtsBridge.read();
    return {
      'version': 1,
      'immersive': immersiveMap,
      'normal_tts': normalTts.toJson(),
    };
  }

  String _canonicalHash(Map<String, dynamic> map) {
    final normalized = _sortKeysDeep(map);
    return sha256.convert(utf8.encode(jsonEncode(normalized))).toString();
  }

  Object? _sortKeysDeep(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _sortKeysDeep(value[k])};
    }
    if (value is List) {
      return value.map(_sortKeysDeep).toList();
    }
    return value;
  }

  Future<void> _applyIncomingAiPayload(Map<String, dynamic> payload) async {
    // 1. 恢复沉浸式多角色听书配置（校验通过后写入，自动转存 Android Keystore）
    final rawImmersive = payload['immersive'];
    if (rawImmersive is Map) {
      final parsed = ImmersiveConfigValidator.parseAndValidateJson(
        jsonEncode(rawImmersive),
      );
      if (parsed.isValid && parsed.config != null) {
        final saved = await _immersiveConfigService.saveConfig(parsed.config!);
        if (saved.issues.isEmpty && _notifyAppServices) {
          await ImmersivePlaybackCoordinator().loadAndValidateConfig();
        }
      }
    }

    // 2. 恢复正常 AI 朗读配置（密钥写入 writeTtsSecret）
    final rawNormalTts = payload['normal_tts'];
    if (rawNormalTts is Map) {
      final snap = NormalTtsConfigSnapshot.fromJson(
        Map<String, dynamic>.from(rawNormalTts),
      );
      await _normalTtsBridge.write(snap);
    }
  }

  Map<String, dynamic> _encodeAiUploadEnvelope({
    required Map<String, dynamic> plainPayload,
    required String hash,
    required WebDavConfig config,
    required DateTime now,
  }) {
    final meta = <String, dynamic>{
      'hash': hash,
      'updated_at': now.toUtc().toIso8601String(),
      'device_id': config.deviceId,
    };
    if (config.encryptCloudAiConfig && config.password.isNotEmpty) {
      return WebDavCrypto.encryptJson(
        plainPayload,
        passphrase: config.password,
        outerMetadata: meta,
      );
    }
    return {
      ...plainPayload,
      'encrypted': false,
      ...meta,
    };
  }

  Map<String, dynamic> _decodeAiRemoteEnvelope(
    Map<String, dynamic> remoteJson,
    WebDavConfig config,
  ) {
    if (WebDavCrypto.isEncryptedEnvelope(remoteJson)) {
      return WebDavCrypto.decryptJson(remoteJson, passphrase: config.password);
    }
    return <String, dynamic>{
      'version': remoteJson['version'] ?? 1,
      'immersive': remoteJson['immersive'],
      'normal_tts': remoteJson['normal_tts'],
    };
  }

  Future<_ModuleSyncResult> _syncAiConfig({
    required WebDavClient client,
    required WebDavSyncMode mode,
    required WebDavSyncIndex index,
    required WebDavConfig config,
    required DateTime now,
  }) async {
    final localPayload = await _buildLocalAiPayload();
    final localHash = _canonicalHash(localPayload);

    if (mode == WebDavSyncMode.pushToRemote) {
      final uploadBody = _encodeAiUploadEnvelope(
        plainPayload: localPayload,
        hash: localHash,
        config: config,
        now: now,
      );
      await client.putJsonAtomic(_aiConfigPath, uploadBody);
      return _ModuleSyncResult(
        action: config.encryptCloudAiConfig ? '已加密上传' : '已上传',
        finalHash: localHash,
        index: index.copyWith(aiConfigHash: localHash, aiConfigUpdatedAt: now),
      );
    }

    final remoteResp = await client.getJsonWithEtag(_aiConfigPath);
    final remoteJson = remoteResp.data;
    final remoteEtag = remoteResp.etag;
    if (remoteJson == null) {
      if (mode == WebDavSyncMode.pullFromRemote) {
        return _ModuleSyncResult(
          action: '云端暂无备份',
          finalHash: localHash,
          index: index,
        );
      }
      final uploadBody = _encodeAiUploadEnvelope(
        plainPayload: localPayload,
        hash: localHash,
        config: config,
        now: now,
      );
      await client.putJsonAtomic(_aiConfigPath, uploadBody);
      return _ModuleSyncResult(
        action: config.encryptCloudAiConfig ? '已加密上传' : '已上传',
        finalHash: localHash,
        index: index.copyWith(aiConfigHash: localHash, aiConfigUpdatedAt: now),
      );
    }

    final remoteWasEncrypted = WebDavCrypto.isEncryptedEnvelope(remoteJson);
    final remoteCore = _decodeAiRemoteEnvelope(remoteJson, config);
    final remoteHash =
        remoteJson['hash']?.toString().isNotEmpty == true
            ? remoteJson['hash'].toString()
            : _canonicalHash(remoteCore);

    if (mode == WebDavSyncMode.pullFromRemote) {
      await _applyIncomingAiPayload(remoteCore);
      final appliedHash = _canonicalHash(await _buildLocalAiPayload());
      return _ModuleSyncResult(
        action: remoteWasEncrypted ? '已解密恢复' : '已从云端恢复',
        finalHash: appliedHash,
        index: index.copyWith(
          aiConfigHash: remoteHash,
          aiConfigUpdatedAt:
              DateTime.tryParse(remoteJson['updated_at']?.toString() ?? '') ??
              now,
        ),
      );
    }

    // 双向模式决策
    if (localHash == remoteHash) {
      // 若云端仍为旧版明文且当前开启端到端加密，原地平滑升级为加密信封
      if (config.encryptCloudAiConfig && !remoteWasEncrypted) {
        final upgraded = _encodeAiUploadEnvelope(
          plainPayload: localPayload,
          hash: localHash,
          config: config,
          now: now,
        );
        await client.putJsonAtomic(
          _aiConfigPath,
          upgraded,
          expectedEtag: remoteEtag,
        );
        return _ModuleSyncResult(
          action: '已升级云端加密',
          finalHash: localHash,
          index: index.copyWith(aiConfigHash: localHash, aiConfigUpdatedAt: now),
        );
      }
      return _ModuleSyncResult(
        action: '已是最新',
        finalHash: localHash,
        index: index.copyWith(aiConfigHash: remoteHash),
      );
    }

    final neverSyncedLocally = config.lastSyncedAiHash.isEmpty;
    final localUnchanged =
        !neverSyncedLocally && localHash == config.lastSyncedAiHash;
    final remoteUnchanged =
        !neverSyncedLocally && remoteHash == config.lastSyncedAiHash;

    if (localUnchanged || neverSyncedLocally) {
      // 本机未改过（或首次登录已有云端配置）-> 拉取云端
      await _applyIncomingAiPayload(remoteCore);
      final appliedHash = _canonicalHash(await _buildLocalAiPayload());
      if (config.encryptCloudAiConfig && !remoteWasEncrypted) {
        final upgraded = _encodeAiUploadEnvelope(
          plainPayload: remoteCore,
          hash: remoteHash,
          config: config,
          now: now,
        );
        await client.putJsonAtomic(
          _aiConfigPath,
          upgraded,
          expectedEtag: remoteEtag,
        );
      }
      return _ModuleSyncResult(
        action: remoteWasEncrypted ? '已解密拉取' : '已拉取云端配置',
        finalHash: appliedHash,
        index: index.copyWith(aiConfigHash: remoteHash),
      );
    }

    if (remoteUnchanged) {
      // 仅本机改过 -> 加密原子上传覆盖云端
      final uploadBody = _encodeAiUploadEnvelope(
        plainPayload: localPayload,
        hash: localHash,
        config: config,
        now: now,
      );
      await client.putJsonAtomic(
        _aiConfigPath,
        uploadBody,
        expectedEtag: remoteEtag,
      );
      return _ModuleSyncResult(
        action: config.encryptCloudAiConfig ? '已加密上传更新' : '已上传更新',
        finalHash: localHash,
        index: index.copyWith(aiConfigHash: localHash, aiConfigUpdatedAt: now),
      );
    }

    // 两端同时改动：比较时间戳（云端 updated_at vs 本地沉浸式配置文件修改时间）
    final remoteTime =
        DateTime.tryParse(remoteJson['updated_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final localImmersiveFile = await _immersiveConfigService.defaultConfigFile();
    final localTime = await localImmersiveFile.exists()
        ? (await localImmersiveFile.lastModified()).toUtc()
        : now;

    if (remoteTime.isAfter(localTime)) {
      await _applyIncomingAiPayload(remoteCore);
      final appliedHash = _canonicalHash(await _buildLocalAiPayload());
      return _ModuleSyncResult(
        action: remoteWasEncrypted ? '已解密拉取较新配置' : '已拉取较新云端配置',
        finalHash: appliedHash,
        index: index.copyWith(aiConfigHash: remoteHash),
      );
    } else {
      final uploadBody = _encodeAiUploadEnvelope(
        plainPayload: localPayload,
        hash: localHash,
        config: config,
        now: now,
      );
      await client.putJsonAtomic(
        _aiConfigPath,
        uploadBody,
        expectedEtag: remoteEtag,
      );
      return _ModuleSyncResult(
        action: config.encryptCloudAiConfig ? '已加密上传较新配置' : '已上传较新本地配置',
        finalHash: localHash,
        index: index.copyWith(aiConfigHash: localHash, aiConfigUpdatedAt: now),
      );
    }
  }

  // ==================== 2. 阅读历史、书籍信息与进度 ====================

  Future<Map<String, Object>> _readLocalReadingPreferences() async {
    if (_notifyAppServices) {
      await ReadingActivityService().flush();
      await BookshelfService().flush();
    }
    await BookmarkService().flush();
    await ReaderLibraryService().flush();
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();

    final prefs = await SharedPreferences.getInstance();
    final data = <String, Object>{};
    for (final key in prefs.getKeys()) {
      if (!ReaderBackupService.allowedKey(key)) continue;
      // 外部大字体文件不随阅读元数据同步，避免跨端缺字体文件
      if (key == ExternalReaderFonts.preferencesKey) continue;
      final value = prefs.get(key);
      if (value != null) {
        data[key] = value;
      }
    }
    return data;
  }

  String _readingPrefsHash(Map<String, Object> data) {
    final keys = data.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(jsonEncode({for (final k in keys) k: data[k]})),
        )
        .toString();
  }

  /// 双向合并阅读元数据（含书架、阅读历史、书签、笔记、精准位置与章节进度）
  static Map<String, Object> mergeReadingPreferences(
    Map<String, Object> current,
    Map<String, Object> incoming,
  ) {
    final merged = ReaderBackupService.merge(current, incoming);

    // 补充合并：对于尚未生成 reader_position_* 的书籍，按 read_progress_time_* 取较新进度
    final progressIds = <String>{};
    for (final key in [...current.keys, ...incoming.keys]) {
      if (key.startsWith('read_progress_time_')) {
        progressIds.add(key.substring('read_progress_time_'.length));
      }
    }
    for (final bookId in progressIds) {
      if (merged.containsKey('reader_position_$bookId')) continue;
      final curTime = current['read_progress_time_$bookId'] as int? ?? 0;
      final incTime = incoming['read_progress_time_$bookId'] as int? ?? 0;
      if (incTime > curTime) {
        if (incoming.containsKey('read_progress_index_$bookId')) {
          merged['read_progress_index_$bookId'] =
              incoming['read_progress_index_$bookId']!;
        }
        if (incoming.containsKey('read_progress_title_$bookId')) {
          merged['read_progress_title_$bookId'] =
              incoming['read_progress_title_$bookId']!;
        }
        merged['read_progress_time_$bookId'] = incTime;
      }
    }
    return merged;
  }

  Future<void> _writeLocalReadingPreferences(
    Map<String, Object> data, {
    required bool replaceAll,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (replaceAll) {
      for (final key in prefs.getKeys().toList()) {
        if (!ReaderBackupService.allowedKey(key)) continue;
        if (key == ExternalReaderFonts.preferencesKey) continue;
        if (!data.containsKey(key)) {
          await prefs.remove(key);
        }
      }
    }
    for (final entry in data.entries) {
      if (!ReaderBackupService.allowedKey(entry.key)) continue;
      if (entry.key == ExternalReaderFonts.preferencesKey) continue;
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      }
    }
    if (_notifyAppServices) {
      BookmarkService().invalidate();
      await BookshelfService().reload();
      await ReadingHistoryService().reload();
      await ReadingActivityService().reload();
      await ReaderLibraryService().load();
    }
  }

  Map<String, Object> _parseRemotePreferences(Map<String, dynamic> remoteJson) {
    final rawPrefs = remoteJson['preferences'];
    if (rawPrefs is! Map) {
      throw const WebDavException('云端阅读数据格式损坏：缺少 preferences');
    }
    final result = <String, Object>{};
    for (final entry in rawPrefs.entries) {
      final key = entry.key.toString();
      final val = entry.value;
      if (!ReaderBackupService.allowedKey(key)) continue;
      if (key == ExternalReaderFonts.preferencesKey) continue;
      if (val is bool || val is int || val is double || val is String) {
        result[key] = val;
      } else if (val is num) {
        result[key] = val.toDouble();
      }
    }
    // 校验关键阅读锚点反序列化不崩
    for (final entry in result.entries) {
      if (entry.key.startsWith('reader_position_') && entry.value is String) {
        ReadingSnapshot.fromJson(
          Map<String, dynamic>.from(jsonDecode(entry.value as String) as Map),
        );
      }
    }
    return result;
  }

  Future<_ModuleSyncResult> _syncReadingData({
    required WebDavClient client,
    required WebDavSyncMode mode,
    required WebDavSyncIndex index,
    required WebDavConfig config,
    required DateTime now,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final localPrefs = await _readLocalReadingPreferences();
      final localHash = _readingPrefsHash(localPrefs);

      if (mode == WebDavSyncMode.pushToRemote) {
        await client.putJsonAtomic(_readingDataPath, {
          'version': 1,
          'hash': localHash,
          'updated_at': now.toUtc().toIso8601String(),
          'device_id': config.deviceId,
          'preferences': localPrefs,
        });
        return _ModuleSyncResult(
          action: '已上传',
          finalHash: localHash,
          index: index.copyWith(
            readingDataHash: localHash,
            readingDataUpdatedAt: now,
          ),
        );
      }

      final remoteResp = await client.getJsonWithEtag(_readingDataPath);
      final remoteJson = remoteResp.data;
      final remoteEtag = remoteResp.etag;
      if (remoteJson == null) {
        if (mode == WebDavSyncMode.pullFromRemote) {
          return _ModuleSyncResult(
            action: '云端暂无备份',
            finalHash: localHash,
            index: index,
          );
        }
        await client.putJsonAtomic(_readingDataPath, {
          'version': 1,
          'hash': localHash,
          'updated_at': now.toUtc().toIso8601String(),
          'device_id': config.deviceId,
          'preferences': localPrefs,
        });
        return _ModuleSyncResult(
          action: '已上传',
          finalHash: localHash,
          index: index.copyWith(
            readingDataHash: localHash,
            readingDataUpdatedAt: now,
          ),
        );
      }

      final remotePrefs = _parseRemotePreferences(remoteJson);
      final remoteHash = _readingPrefsHash(remotePrefs);

      if (mode == WebDavSyncMode.pullFromRemote) {
        await _writeLocalReadingPreferences(remotePrefs, replaceAll: true);
        return _ModuleSyncResult(
          action: '已从云端恢复',
          finalHash: remoteHash,
          index: index.copyWith(readingDataHash: remoteHash),
        );
      }

      if (localHash == remoteHash) {
        return _ModuleSyncResult(
          action: '已是最新',
          finalHash: localHash,
          index: index.copyWith(readingDataHash: remoteHash),
        );
      }

      // 双向智能合并：保留两端书架书籍信息、阅读历史、书签笔记及较新阅读进度
      final merged = mergeReadingPreferences(localPrefs, remotePrefs);
      final mergedHash = _readingPrefsHash(merged);

      var updatedLocal = false;
      var updatedRemote = false;

      if (mergedHash != localHash) {
        await _writeLocalReadingPreferences(merged, replaceAll: false);
        updatedLocal = true;
      }
      if (mergedHash != remoteHash) {
        try {
          await client.putJsonAtomic(
            _readingDataPath,
            {
              'version': 1,
              'hash': mergedHash,
              'updated_at': now.toUtc().toIso8601String(),
              'device_id': config.deviceId,
              'preferences': merged,
            },
            expectedEtag: remoteEtag,
          );
          updatedRemote = true;
        } on WebDavPreconditionFailedException {
          if (attempt == 0) continue; // 遇到并发写冲突，自动重拉合并重试一次
          rethrow;
        }
      }

      final action = updatedLocal && updatedRemote
          ? '已双向合并'
          : updatedLocal
          ? '已拉取合并'
          : updatedRemote
          ? '已上传更新'
          : '已是最新';

      return _ModuleSyncResult(
        action: action,
        finalHash: mergedHash,
        index: index.copyWith(
          readingDataHash: mergedHash,
          readingDataUpdatedAt: updatedRemote ? now : index.readingDataUpdatedAt,
        ),
      );
    }
    throw const WebDavException('阅读数据并发同步冲突重试仍失败，请稍后再试');
  }

  // ==================== 2.5 沉浸式书籍角色档案与手动音色锁定 ====================

  Map<String, Map<String, dynamic>> _parseRemoteProfiles(
    Map<String, dynamic> remoteJson,
  ) {
    final rawBooks = remoteJson['books'];
    if (rawBooks is! Map) return {};
    final out = <String, Map<String, dynamic>>{};
    for (final entry in rawBooks.entries) {
      if (entry.value is Map) {
        out[entry.key.toString()] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
    return out;
  }

  Future<_ModuleSyncResult> _syncImmersiveProfiles({
    required WebDavClient client,
    required WebDavSyncMode mode,
    required WebDavSyncIndex index,
    required WebDavConfig config,
    required DateTime now,
  }) async {
    final bridge = _effectiveProfilesBridge;

    for (var attempt = 0; attempt < 2; attempt++) {
      final localBooks = await bridge.exportAll();
      final localHash = _canonicalHash({'books': localBooks});

      if (mode == WebDavSyncMode.pushToRemote) {
        if (localBooks.isEmpty) {
          return _ModuleSyncResult(
            action: '暂无档案',
            finalHash: localHash,
            index: index,
          );
        }
        await client.putJsonAtomic(_immersiveProfilesPath, {
          'version': 1,
          'hash': localHash,
          'updated_at': now.toUtc().toIso8601String(),
          'device_id': config.deviceId,
          'books': localBooks,
        });
        return _ModuleSyncResult(
          action: '已上传 ${localBooks.length} 本',
          finalHash: localHash,
          index: index.copyWith(
            immersiveProfilesHash: localHash,
            immersiveProfilesUpdatedAt: now,
          ),
        );
      }

      final remoteResp = await client.getJsonWithEtag(_immersiveProfilesPath);
      final remoteJson = remoteResp.data;
      final remoteEtag = remoteResp.etag;
      if (remoteJson == null) {
        if (mode == WebDavSyncMode.pullFromRemote || localBooks.isEmpty) {
          return _ModuleSyncResult(
            action: localBooks.isEmpty ? '暂无档案' : '云端暂无备份',
            finalHash: localHash,
            index: index,
          );
        }
        await client.putJsonAtomic(_immersiveProfilesPath, {
          'version': 1,
          'hash': localHash,
          'updated_at': now.toUtc().toIso8601String(),
          'device_id': config.deviceId,
          'books': localBooks,
        });
        return _ModuleSyncResult(
          action: '已上传 ${localBooks.length} 本',
          finalHash: localHash,
          index: index.copyWith(
            immersiveProfilesHash: localHash,
            immersiveProfilesUpdatedAt: now,
          ),
        );
      }

      final remoteBooks = _parseRemoteProfiles(remoteJson);
      final remoteHash = _canonicalHash({'books': remoteBooks});

      if (localHash == remoteHash) {
        return _ModuleSyncResult(
          action: localBooks.isEmpty ? '暂无档案' : '已是最新',
          finalHash: localHash,
          index: index.copyWith(immersiveProfilesHash: remoteHash),
        );
      }

      final mergedIntoLocal = await bridge.mergeAll(remoteBooks);
      final afterMergeBooks = await bridge.exportAll();
      final mergedHash = _canonicalHash({'books': afterMergeBooks});

      var uploaded = false;
      if (mode != WebDavSyncMode.pullFromRemote && mergedHash != remoteHash) {
        try {
          await client.putJsonAtomic(
            _immersiveProfilesPath,
            {
              'version': 1,
              'hash': mergedHash,
              'updated_at': now.toUtc().toIso8601String(),
              'device_id': config.deviceId,
              'books': afterMergeBooks,
            },
            expectedEtag: remoteEtag,
          );
          uploaded = true;
        } on WebDavPreconditionFailedException {
          if (attempt == 0) continue;
          rethrow;
        }
      }

      final action = mergedIntoLocal && uploaded
          ? '已双向合并 ${afterMergeBooks.length} 本'
          : mergedIntoLocal
          ? '已拉取合并 ${afterMergeBooks.length} 本'
          : uploaded
          ? '已上传 ${afterMergeBooks.length} 本'
          : '已是最新';

      return _ModuleSyncResult(
        action: action,
        finalHash: mergedHash,
        index: index.copyWith(
          immersiveProfilesHash: mergedHash,
          immersiveProfilesUpdatedAt:
              uploaded ? now : index.immersiveProfilesUpdatedAt,
        ),
      );
    }
    throw const WebDavException('角色档案并发同步冲突重试仍失败，请稍后再试');
  }

  // ==================== 3. 离线书籍扫描、比对、上传与下载 ====================

  /// 扫描本地已离线书籍（仅限 `<documents>/offline_books/<bookId>/`，不包含在线临时缓存）
  Future<Map<String, WebDavOfflineBookMeta>> scanLocalOfflineBooks() async {
    final base = await _documents();
    final root = Directory(p.join(base.path, 'offline_books'));
    if (!await root.exists()) return {};

    final metaById = await _collectBookMetadataLookup();
    final result = <String, WebDavOfflineBookMeta>{};

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final bookId = p.basename(entity.path);
      if (!_bookIdPattern.hasMatch(bookId)) continue;

      final files = <File>[];
      await for (final item in entity.list(recursive: true, followLinks: false)) {
        if (item is! File) continue;
        final name = p.basename(item.path);
        if (name.endsWith('.tmp') || name.contains('.part.')) continue;
        files.add(item);
      }
      if (files.isEmpty) continue;

      files.sort(
        (a, b) => p
            .relative(a.path, from: entity.path)
            .replaceAll('\\', '/')
            .compareTo(
              p.relative(b.path, from: entity.path).replaceAll('\\', '/'),
            ),
      );

      var totalBytes = 0;
      var latestModified = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      final digestParts = <String>[];
      var chapterFiles = 0;
      Map<String, dynamic>? localMetaJson;
      int? chaptersJsonCount;

      for (final file in files) {
        final rel = p
            .relative(file.path, from: entity.path)
            .replaceAll('\\', '/');
        final stat = await file.stat();
        totalBytes += stat.size;
        final mod = stat.modified.toUtc();
        if (mod.isAfter(latestModified)) latestModified = mod;
        final fileHash = (await sha256.bind(file.openRead()).first).toString();
        digestParts.add('$rel|${stat.size}|$fileHash');

        if (rel == 'metadata.json') {
          try {
            final parsed = jsonDecode(await file.readAsString());
            if (parsed is Map) {
              localMetaJson = Map<String, dynamic>.from(parsed);
            }
          } catch (_) {}
        } else if (rel == 'chapters.json') {
          try {
            final parsed = jsonDecode(await file.readAsString());
            if (parsed is List) chaptersJsonCount = parsed.length;
          } catch (_) {}
        } else if (rel.endsWith('.txt') ||
            rel.endsWith('.html') ||
            rel.endsWith('.xhtml') ||
            rel.endsWith('.epub')) {
          chapterFiles++;
        }
      }

      // 过滤仅含封面图(cover.jpg)或评论缓存、不含真实离线章节正文的伪离线目录
      final hasRealOfflineContent =
          chapterFiles > 0 || (chaptersJsonCount != null && chaptersJsonCount > 0);
      if (!hasRealOfflineContent) continue;

      final contentHash = sha256
          .convert(utf8.encode(digestParts.join('\n')))
          .toString();

      final known = metaById[bookId];
      final bookName =
          known?.bookName ??
          localMetaJson?['book_name']?.toString() ??
          localMetaJson?['title']?.toString() ??
          '离线书籍 $bookId';
      final author =
          known?.author ??
          localMetaJson?['author']?.toString() ??
          (bookId.startsWith('local_') ? '本地导入' : '未知作者');
      final chapterCount =
          chaptersJsonCount ??
          (localMetaJson?['chapter_count'] as num?)?.toInt() ??
          chapterFiles;

      result[bookId] = WebDavOfflineBookMeta(
        bookId: bookId,
        bookName: bookName,
        author: author,
        thumbUrl: known?.thumbUrl,
        isLocalImport: bookId.startsWith('local_'),
        chapterCount: chapterCount,
        totalBytes: totalBytes,
        contentHash: contentHash,
        updatedAt: latestModified,
      );
    }

    return result;
  }

  Future<Map<String, Book>> _collectBookMetadataLookup() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, Book>{};
    for (final key in [
      'download_history',
      'reading_history_v1',
      'bookshelf_books_v1',
    ]) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final list = jsonDecode(raw) as List;
        for (final item in list.whereType<Map>()) {
          final m = Map<String, dynamic>.from(item);
          final id = m['book_id']?.toString() ?? '';
          if (id.isEmpty) continue;
          map[id] = Book(
            bookId: id,
            bookName: m['book_name']?.toString() ?? '未知书名',
            author: m['author']?.toString() ?? '未知作者',
            thumbUrl: m['thumb_url']?.toString(),
            category: m['category']?.toString(),
            creationStatus: m['creation_status']?.toString() ?? '连载中',
            score: m['score']?.toString(),
            abstract: m['abstract']?.toString(),
          );
        }
      } catch (_) {}
    }
    return map;
  }

  /// 获取本地与云端全部离线书籍的比对列表（供 UI 展示与单本上传/下载）
  Future<List<WebDavOfflineBookItem>> listOfflineBooksStatus() async {
    await initialize();
    final localMap = await scanLocalOfflineBooks();
    Map<String, WebDavOfflineBookMeta> remoteMap = {};

    if (_config.hasCredentials) {
      final client = _clientFactory(_config);
      try {
        final rawIndex = await client.getJson(_syncIndexPath);
        if (rawIndex != null) {
          remoteMap = WebDavSyncIndex.fromJson(rawIndex).offlineBooks;
        }
      } finally {
        client.close();
      }
    }

    final ids = <String>{...localMap.keys, ...remoteMap.keys}.toList()..sort();
    final items = <WebDavOfflineBookItem>[];
    for (final id in ids) {
      final local = localMap[id];
      final remote = remoteMap[id];
      final WebDavOfflineBookStatus status;
      if (local != null && remote == null) {
        status = WebDavOfflineBookStatus.localOnly;
      } else if (local == null && remote != null) {
        status = WebDavOfflineBookStatus.remoteOnly;
      } else if (local!.contentHash == remote!.contentHash) {
        status = WebDavOfflineBookStatus.synced;
      } else if (local.updatedAt.isAfter(remote.updatedAt)) {
        status = WebDavOfflineBookStatus.localNewer;
      } else {
        status = WebDavOfflineBookStatus.remoteNewer;
      }
      items.add(
        WebDavOfflineBookItem(
          bookId: id,
          bookName: local?.bookName ?? remote?.bookName ?? id,
          author: local?.author ?? remote?.author ?? '未知作者',
          localMeta: local,
          remoteMeta: remote,
          status: status,
        ),
      );
    }
    return items;
  }

  /// 单本上传指定离线书籍到 WebDAV
  Future<WebDavOfflineBookMeta> uploadOfflineBook(String bookId) async {
    await initialize();
    if (!_bookIdPattern.hasMatch(bookId)) {
      throw const FormatException('书籍 ID 不合法');
    }
    if (!_config.hasCredentials) {
      throw const WebDavException('请先填写并保存 WebDAV 账号配置');
    }
    final localBooks = await scanLocalOfflineBooks();
    final meta = localBooks[bookId];
    if (meta == null) {
      throw const WebDavException('该书尚未离线，无需上传正文文件');
    }
    final client = _clientFactory(_config);
    try {
      await client.ensureAppDirectories();
      final uploaded = await _uploadOfflineBookInternal(
        client: client,
        meta: meta,
      );
      final now = _clock().toUtc();
      final indexResp = await client.getJsonWithEtag(_syncIndexPath);
      final rawIndex = indexResp.data;
      final index = rawIndex == null
          ? WebDavSyncIndex(updatedAt: now, updatedByDeviceId: _config.deviceId)
          : WebDavSyncIndex.fromJson(rawIndex);
      final updatedBooks = Map<String, WebDavOfflineBookMeta>.from(
        index.offlineBooks,
      )..[bookId] = uploaded;
      await client.putJsonAtomic(
        _syncIndexPath,
        index
            .copyWith(
              updatedAt: now,
              updatedByDeviceId: _config.deviceId,
              offlineBooks: updatedBooks,
            )
            .toJson(),
        expectedEtag: indexResp.etag,
      );
      return uploaded;
    } finally {
      client.close();
    }
  }

  /// 单本从 WebDAV 下载并恢复指定离线书籍
  Future<void> downloadOfflineBook(String bookId) async {
    await initialize();
    if (!_bookIdPattern.hasMatch(bookId)) {
      throw const FormatException('书籍 ID 不合法');
    }
    if (!_config.hasCredentials) {
      throw const WebDavException('请先填写并保存 WebDAV 账号配置');
    }
    final client = _clientFactory(_config);
    try {
      final rawIndex = await client.getJson(_syncIndexPath);
      final remoteMeta = rawIndex == null
          ? null
          : WebDavSyncIndex.fromJson(rawIndex).offlineBooks[bookId];
      final ok = await _downloadOfflineBookInternal(
        client: client,
        bookId: bookId,
        remoteMeta: remoteMeta,
      );
      if (!ok) {
        throw const WebDavException('云端未找到该离线书籍归档');
      }
    } finally {
      client.close();
    }
  }

  Future<WebDavOfflineBookMeta> _uploadOfflineBookInternal({
    required WebDavClient client,
    required WebDavOfflineBookMeta meta,
  }) async {
    final base = await _documents();
    final sourceDir = Directory(p.join(base.path, 'offline_books', meta.bookId));
    if (!await sourceDir.exists()) {
      throw WebDavException('本地离线书籍目录不存在：${meta.bookId}');
    }

    final stagingDir = Directory(p.join(base.path, 'webdav_staging'));
    await stagingDir.create(recursive: true);
    final stamp = _clock().microsecondsSinceEpoch;
    final zipFile = File(p.join(stagingDir.path, 'up_${meta.bookId}_$stamp.zip'));
    final metaFile = File(
      p.join(stagingDir.path, 'meta_${meta.bookId}_$stamp.json'),
    );

    // 附带书架记录以便新设备单独下载此离线书时自动入书架
    Map<String, dynamic>? shelfEntry;
    final prefs = await SharedPreferences.getInstance();
    final shelfRaw = prefs.getString('bookshelf_books_v1');
    if (shelfRaw != null && shelfRaw.isNotEmpty) {
      try {
        for (final item in jsonDecode(shelfRaw) as List) {
          if (item is Map && item['book_id'] == meta.bookId) {
            shelfEntry = Map<String, dynamic>.from(item);
            break;
          }
        }
      } catch (_) {}
    }

    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      await metaFile.writeAsString(
        jsonEncode({
          'version': 1,
          'meta': meta.toJson(),
          if (shelfEntry != null) 'bookshelf_book': shelfEntry,
        }),
      );
      encoder.create(zipFile.path);
      opened = true;
      await encoder.addFile(metaFile, 'offline_book_meta.json');
      await for (final entity in sourceDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.endsWith('.tmp') || name.contains('.part.')) continue;
        final rel = p
            .relative(entity.path, from: sourceDir.path)
            .replaceAll('\\', '/');
        await encoder.addFile(entity, 'files/$rel');
      }
      await encoder.close();
      opened = false;

      await client.putFile(
        '${WebDavConfig.booksSubFolder}/${meta.bookId}.zip',
        zipFile,
        contentType: 'application/zip',
      );
      return meta;
    } finally {
      if (opened) await encoder.close();
      if (await zipFile.exists()) await zipFile.delete().catchError((_) => zipFile);
      if (await metaFile.exists()) await metaFile.delete().catchError((_) => metaFile);
    }
  }

  Future<bool> _downloadOfflineBookInternal({
    required WebDavClient client,
    required String bookId,
    WebDavOfflineBookMeta? remoteMeta,
  }) async {
    final base = await _documents();
    final stagingDir = Directory(p.join(base.path, 'webdav_staging'));
    await stagingDir.create(recursive: true);
    final stamp = _clock().microsecondsSinceEpoch;
    final zipFile = File(p.join(stagingDir.path, 'dn_${bookId}_$stamp.zip'));
    final extractDir = Directory(
      p.join(stagingDir.path, 'ex_${bookId}_$stamp'),
    );
    final backupOldDir = Directory(
      p.join(stagingDir.path, 'old_${bookId}_$stamp'),
    );

    try {
      final exists = await client.downloadToFile(
        '${WebDavConfig.booksSubFolder}/$bookId.zip',
        zipFile,
      );
      if (!exists) return false;

      final zip = await SafeZipReader.open(
        zipFile,
        fileLimit: 512 * 1024 * 1024,
        entryLimit: 50000,
        inflatedLimit: 512 * 1024 * 1024,
        individualLimit: 128 * 1024 * 1024,
      );

      Map<String, dynamic>? archiveMeta;
      await extractDir.create(recursive: true);
      var extractedFiles = 0;

      for (final entry in zip.entries.values) {
        if (entry.name.endsWith('/')) continue;
        final safe = SafeZipReader.safeName(entry.name);
        if (safe == 'offline_book_meta.json') {
          final bytes = await zip.read(entry.name, maxBytes: 2 * 1024 * 1024);
          try {
            final parsed = jsonDecode(utf8.decode(bytes));
            if (parsed is Map) {
              archiveMeta = Map<String, dynamic>.from(parsed);
            }
          } catch (_) {}
          continue;
        }
        if (!safe.startsWith('files/')) continue;
        final rel = safe.substring('files/'.length);
        if (rel.isEmpty || rel.startsWith('/') || rel.contains('..')) continue;
        final bytes = await zip.read(entry.name, maxBytes: 128 * 1024 * 1024);
        final out = File(p.joinAll([extractDir.path, ...rel.split('/')]));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes, flush: true);
        extractedFiles++;
      }

      if (extractedFiles == 0) {
        throw const WebDavException('云端离线书籍归档为空，已取消恢复');
      }

      final offlineRoot = Directory(p.join(base.path, 'offline_books'));
      await offlineRoot.create(recursive: true);
      final destination = Directory(p.join(offlineRoot.path, bookId));

      // 原子目录切换，异常自动回滚
      var movedOld = false;
      try {
        if (await destination.exists()) {
          await destination.rename(backupOldDir.path);
          movedOld = true;
        }
        await extractDir.rename(destination.path);
      } catch (e) {
        if (movedOld && await backupOldDir.exists() && !await destination.exists()) {
          await backupOldDir.rename(destination.path);
        }
        rethrow;
      }

      // 确保下载的离线书在书架中可见
      await _ensureDownloadedBookOnShelf(
        bookId: bookId,
        remoteMeta: remoteMeta,
        archiveMeta: archiveMeta,
      );
      return true;
    } finally {
      if (await zipFile.exists()) await zipFile.delete().catchError((_) => zipFile);
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true).catchError((_) => extractDir);
      }
      if (await backupOldDir.exists()) {
        await backupOldDir.delete(recursive: true).catchError((_) => backupOldDir);
      }
    }
  }

  Future<void> _ensureDownloadedBookOnShelf({
    required String bookId,
    WebDavOfflineBookMeta? remoteMeta,
    Map<String, dynamic>? archiveMeta,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bookshelf_books_v1');
    final list = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final item in jsonDecode(raw) as List) {
          if (item is Map) list.add(Map<String, dynamic>.from(item));
        }
      } catch (_) {}
    }
    if (list.any((b) => b['book_id'] == bookId)) {
      if (_notifyAppServices) await BookshelfService().reload();
      return;
    }

    Map<String, dynamic>? newBook;
    final fromArchiveShelf = archiveMeta?['bookshelf_book'];
    if (fromArchiveShelf is Map) {
      newBook = Map<String, dynamic>.from(fromArchiveShelf);
    } else {
      final metaObj = remoteMeta ??
          (archiveMeta?['meta'] is Map
              ? WebDavOfflineBookMeta.fromJson(
                  Map<String, dynamic>.from(archiveMeta!['meta'] as Map),
                )
              : null);
      if (metaObj != null) {
        newBook = BookshelfBook(
          bookId: metaObj.bookId,
          bookName: metaObj.bookName,
          author: metaObj.author,
          thumbUrl: metaObj.thumbUrl,
          creationStatus: metaObj.isLocalImport ? '已完结' : '连载中',
          totalChapters: metaObj.chapterCount,
          addedTime: _clock(),
        ).toJson();
      }
    }

    if (newBook != null) {
      list.insert(0, newBook);
      await prefs.setString('bookshelf_books_v1', jsonEncode(list));
      if (_notifyAppServices) {
        await BookshelfService().reload();
      }
    }
  }
}

class _ModuleSyncResult {
  final String action;
  final String finalHash;
  final WebDavSyncIndex index;

  const _ModuleSyncResult({
    required this.action,
    required this.finalHash,
    required this.index,
  });
}
