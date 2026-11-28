import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../services/app_storage.dart';
import '../../services/atomic_file.dart';
import '../../services/reader_platform.dart';
import '../models/immersive_config.dart';
import 'immersive_preset_config.dart';

/// 密钥安全读写接口（默认在 Android 走 Keystore，测试可注入内存桩）
abstract class ImmersiveSecretStore {
  Future<String?> read(String slot);
  Future<bool> write(String slot, String value);
}

/// 基于 Android 原生 Keystore (ReaderSecrets) 的密钥存储
class PlatformImmersiveSecretStore implements ImmersiveSecretStore {
  @override
  Future<String?> read(String slot) async {
    if (!ReaderPlatform.capabilities.secureStorage) return null;
    try {
      return await ReaderPlatform.invoke<String>('readNamedSecret', {
        'key': slot,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> write(String slot, String value) async {
    if (!ReaderPlatform.capabilities.secureStorage) return false;
    try {
      final ok = await ReaderPlatform.invoke<bool>('writeNamedSecret', {
        'key': slot,
        'value': value,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

/// 内存密钥存储（仅用于单元测试或无 Keystore 平台）
class MemoryImmersiveSecretStore implements ImmersiveSecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String slot) async => _values[slot];

  @override
  Future<bool> write(String slot, String value) async {
    if (value.isEmpty) {
      _values.remove(slot);
    } else {
      _values[slot] = value;
    }
    return true;
  }
}

/// 解析后的实际磁盘路径集合
class ResolvedStoragePaths {
  final String configDir;
  final String configFilePath;
  final String databasePath;
  final String audioCacheDir;
  final String tempDir;

  const ResolvedStoragePaths({
    required this.configDir,
    required this.configFilePath,
    required this.databasePath,
    required this.audioCacheDir,
    required this.tempDir,
  });
}

/// 配置服务状态结果（绝不包含明文密钥）
class ConfigServiceStatus {
  final bool available;
  final ImmersiveConfig? config;
  final List<ConfigValidationIssue> issues;
  final Map<String, dynamic> redactedSummary;
  final ResolvedStoragePaths? paths;

  const ConfigServiceStatus({
    required this.available,
    required this.config,
    required this.issues,
    required this.redactedSummary,
    required this.paths,
  });
}

/// 沉浸式听书配置加载、校验、密钥隔离持久化与路径解析服务
class ImmersiveConfigService {
  static const _secretMarkerPrefix = '__KEYSTORE__:';
  static const _textSecretSlot = 'immersive_text_api_key_v1';

  final Future<Directory> Function() _documents;
  final ImmersiveSecretStore _secretStore;
  final Map<String, String>? _environment;

  ImmersiveConfig? _currentConfig;
  ResolvedStoragePaths? _resolvedPaths;
  List<ConfigValidationIssue> _lastIssues = const [];

  ImmersiveConfigService({
    Future<Directory> Function()? documents,
    ImmersiveSecretStore? secretStore,
    Map<String, String>? environment,
  }) : _documents = documents ?? AppStorage.documents,
       _secretStore = secretStore ?? PlatformImmersiveSecretStore(),
       _environment = environment;

  ImmersiveConfig? get currentConfig => _currentConfig;
  ResolvedStoragePaths? get resolvedPaths => _resolvedPaths;
  List<ConfigValidationIssue> get lastIssues => List.unmodifiable(_lastIssues);

  static String textModelSecretSlot(String modelEntryId) {
    final safe = modelEntryId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return 'immersive_text_model_api_key_${safe}_v1';
  }

  static String ttsSecretSlot(String providerId) =>
      'immersive_tts_api_key_${providerId}_v1';

  Future<File> defaultConfigFile() async {
    final root = await _documents();
    final dir = Directory(p.join(root.path, 'immersive-audio'));
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'config.json'));
  }

  /// 加载并校验应用内配置；首次运行尚无配置时自动初始化预置配置，旧单模型预置配置平滑补齐多模型
  Future<ConfigServiceStatus> loadAndValidateConfig({
    File? configFile,
    bool autoInitPreset = true,
  }) async {
    final file = configFile ?? await defaultConfigFile();
    if (!await file.exists()) {
      if (!autoInitPreset) {
        _currentConfig = null;
        _lastIssues = const [
          ConfigValidationIssue('config.json', '应用内沉浸式配置尚未创建，请在设置中配置模型'),
        ];
        return ConfigServiceStatus(
          available: false,
          config: null,
          issues: _lastIssues,
          redactedSummary: const {},
          paths: null,
        );
      }
      final preset = ImmersivePresetConfig.createConfiguredDefault();
      await saveConfig(preset, configFile: file);
    }

    final rawText = await file.readAsString();
    final restoredJson = await _hydrateSecretsIntoJson(rawText);
    final result = ImmersiveConfigValidator.parseAndValidateJson(
      restoredJson,
      environment: _environment,
    );
    _lastIssues = result.issues;

    if (!result.isValid || result.config == null) {
      _currentConfig = null;
      return ConfigServiceStatus(
        available: false,
        config: null,
        issues: result.issues,
        redactedSummary: const {},
        paths: null,
      );
    }

    var config = result.config!;
    var migrated = false;
    // 平滑迁移旧版单文本模型预置配置：若尚未升级多模型列表且使用预置文本网关，自动补充 glm-5.3-flash 与 qwen3.8-flash-next
    if (autoInitPreset &&
        !rawText.contains('"text_analysis_models"') &&
        config.textAnalysis.baseUrl.trim().replaceAll(RegExp(r'/+$'), '') ==
            ImmersivePresetConfig.textProviderBaseUrl) {
      final presetModels = ImmersivePresetConfig.defaultTextModels();
      final existingPrimary = config.textAnalysis.copyWith(
        id: 'tm_minimax_m31_flash',
        thinkingLevel: TextThinkingLevel.auto,
        extraBody: Map<String, dynamic>.from(config.textAnalysis.extraBody)
          ..remove('reasoning_effort'),
      );
      final migratedModels = <TextAnalysisConfig>[existingPrimary];
      for (final pm in presetModels) {
        if (!migratedModels.any((m) => m.modelId == pm.modelId)) {
          migratedModels.add(pm.copyWith(apiKey: existingPrimary.apiKey));
        }
      }
      final glm = migratedModels.where((m) => m.modelId == 'glm-5.3-flash');
      config = config.copyWith(
        textAnalysis: existingPrimary,
        textAnalysisModels: migratedModels,
        primaryTextModelId: existingPrimary.effectiveId,
        fallbackTextModelId: glm.isNotEmpty ? glm.first.effectiveId : null,
        analysisPipeline: config.analysisPipeline.copyWith(
          maxPrefixBacktrackChapters: 5,
        ),
      );
      migrated = true;
    }

    // 平滑迁移内置试听样本路径：assets/TTS-Example/*.wav -> *.mp3
    var sampleMigrated = false;
    final migratedProviders = <TtsProviderConfig>[];
    for (final provider in config.tts.providers) {
      var providerChanged = false;
      final migratedModels = <TtsModelConfig>[];
      for (final model in provider.models) {
        var modelChanged = false;
        final migratedVoices = <TtsVoiceProfileConfig>[];
        for (final voice in model.voices) {
          final sa = voice.sampleAsset;
          if (sa != null &&
              sa.startsWith('assets/TTS-Example/') &&
              sa.endsWith('.wav')) {
            migratedVoices.add(
              voice.copyWith(
                sampleAsset: '${sa.substring(0, sa.length - 4)}.mp3',
              ),
            );
            modelChanged = true;
            providerChanged = true;
            sampleMigrated = true;
          } else {
            migratedVoices.add(voice);
          }
        }
        migratedModels.add(
          modelChanged ? model.copyWith(voices: migratedVoices) : model,
        );
      }
      migratedProviders.add(
        providerChanged ? provider.copyWith(models: migratedModels) : provider,
      );
    }
    if (sampleMigrated) {
      config = config.copyWith(
        tts: config.tts.copyWith(providers: migratedProviders),
      );
      migrated = true;
    }

    // 应用内默认配置平滑升级：统一采用 OpenAI 兼容 json_object 模式、8192 输出上限及 3 次重试切兜底
    if (configFile == null) {
      final upgraded = upgradeLegacyOrCloudTextModels(config);
      if (!identical(upgraded, config)) {
        config = upgraded;
        migrated = true;
      }
    }

    if (migrated) {
      await saveConfig(config, configFile: file);
    }

    final paths = resolvePaths(file, config.storage);
    _currentConfig = config;
    _resolvedPaths = paths;
    return ConfigServiceStatus(
      available: config.featureEnabled,
      config: config,
      issues: const [],
      redactedSummary: config.toRedactedSummary(),
      paths: paths,
    );
  }

  /// 校验并原子保存配置；在支持 Keystore 的平台上密钥密文存入安全存储，配置文件只留槽位标记
  Future<ConfigServiceStatus> saveConfig(
    ImmersiveConfig config, {
    File? configFile,
  }) async {
    final issues = ImmersiveConfigValidator.validateConfig(
      config,
      environment: _environment,
    );
    if (issues.isNotEmpty) {
      _lastIssues = issues;
      return ConfigServiceStatus(
        available: false,
        config: null,
        issues: issues,
        redactedSummary: config.toRedactedSummary(),
        paths: _resolvedPaths,
      );
    }

    final file = configFile ?? await defaultConfigFile();
    final jsonMap = config.toJson(redactSecrets: false);
    await _persistSecretsFromMap(jsonMap);
    final pretty = const JsonEncoder.withIndent('  ').convert(jsonMap);
    await AtomicFile.writeString(file, pretty);

    final paths = resolvePaths(file, config.storage);
    _currentConfig = config;
    _resolvedPaths = paths;
    _lastIssues = const [];
    return ConfigServiceStatus(
      available: config.featureEnabled,
      config: config,
      issues: const [],
      redactedSummary: config.toRedactedSummary(),
      paths: paths,
    );
  }

  /// 相对路径以 config.json 所在目录解析，确保缓存与临时目录位于同一文件系统
  ResolvedStoragePaths resolvePaths(File configFile, StorageConfig storage) {
    final baseDir = configFile.parent.path;
    String resolve(String value) =>
        p.isAbsolute(value) ? p.normalize(value) : p.normalize(p.join(baseDir, value));
    return ResolvedStoragePaths(
      configDir: baseDir,
      configFilePath: configFile.path,
      databasePath: resolve(storage.databasePath),
      audioCacheDir: resolve(storage.audioCacheDir),
      tempDir: resolve(storage.tempDir),
    );
  }

  /// 将旧版或云端拉取的文本模型配置平滑升级为标准 json_object 模式、8192 输出上限及 3 次重试阈值
  static ImmersiveConfig upgradeLegacyOrCloudTextModels(ImmersiveConfig config) {
    var changed = false;
    TextAnalysisConfig upgradeSingle(TextAnalysisConfig m) {
      var next = m;
      if (next.structuredOutput.mode == 'vendor_native') {
        next = next.copyWith(
          structuredOutput: next.structuredOutput.copyWith(
            mode: 'json_object',
            vendorAdapterId: null,
          ),
        );
        changed = true;
      }
      if (next.maxOutputTokens == 12800) {
        next = next.copyWith(
          maxOutputTokens: TextAnalysisConfig.defaultMaxOutputTokens,
        );
        changed = true;
      }
      return next;
    }

    final nextModels = config.textAnalysisModels.map(upgradeSingle).toList();
    final nextPrimary = upgradeSingle(config.textAnalysis);
    final nextThreshold =
        config.textFailoverThreshold < 3 ? 3 : config.textFailoverThreshold;
    if (nextThreshold != config.textFailoverThreshold) {
      changed = true;
    }
    var nextRetry = config.retry;
    if (nextRetry.maxAttempts < 4) {
      nextRetry = RetryConfig(
        maxAttempts: 4,
        initialBackoffMs: nextRetry.initialBackoffMs,
        maxBackoffMs: nextRetry.maxBackoffMs,
        jitterRatio: nextRetry.jitterRatio,
        respectRetryAfter: nextRetry.respectRetryAfter,
      );
      changed = true;
    }
    if (!changed) return config;
    return config.copyWith(
      textAnalysis: nextPrimary,
      textAnalysisModels: nextModels,
      textFailoverThreshold: nextThreshold,
      retry: nextRetry,
    );
  }

  /// 解析指定文本分析模型的真实 API Key（不写入日志）
  String resolveTextModelApiKey(TextAnalysisConfig model) =>
      ImmersiveConfigValidator.resolveApiKey(
        apiKey: model.apiKey,
        apiKeyEnv: model.apiKeyEnv,
        fieldPath: 'text_analysis_models.${model.effectiveId}',
        environment: _environment,
      );

  /// 解析当前主文本模型的真实 API Key（不写入日志）
  String resolveTextApiKey(ImmersiveConfig config) =>
      resolveTextModelApiKey(config.primaryTextModel);

  /// 解析指定 TTS 供应商的真实 API Key
  String resolveTtsApiKey(TtsProviderConfig provider) =>
      ImmersiveConfigValidator.resolveApiKey(
        apiKey: provider.apiKey,
        apiKeyEnv: provider.apiKeyEnv,
        fieldPath: 'tts.${provider.providerId}',
        environment: _environment,
      );

  Future<void> _persistSecretsFromMap(Map<String, dynamic> map) async {
    final ta = map['text_analysis'] as Map<String, dynamic>?;
    if (ta != null) {
      final rawKey = ta['api_key'] as String?;
      if (rawKey != null &&
          rawKey.isNotEmpty &&
          !rawKey.startsWith(_secretMarkerPrefix) &&
          !isTemplatePlaceholderValue(rawKey)) {
        final stored = await _secretStore.write(_textSecretSlot, rawKey);
        if (stored) {
          ta['api_key'] = '$_secretMarkerPrefix$_textSecretSlot';
        }
      }
    }
    final textModels = map['text_analysis_models'] as List?;
    if (textModels != null) {
      for (var i = 0; i < textModels.length; i++) {
        final item = textModels[i];
        if (item is! Map<String, dynamic>) continue;
        final id =
            (item['id'] as String?) ??
            (item['model_id'] as String?) ??
            'model_$i';
        final rawKey = item['api_key'] as String?;
        if (rawKey != null &&
            rawKey.isNotEmpty &&
            !rawKey.startsWith(_secretMarkerPrefix) &&
            !isTemplatePlaceholderValue(rawKey)) {
          final slot = textModelSecretSlot(id);
          final stored = await _secretStore.write(slot, rawKey);
          if (stored) {
            item['api_key'] = '$_secretMarkerPrefix$slot';
          }
        }
      }
    }
    final tts = map['tts'] as Map<String, dynamic>?;
    final providers = tts?['providers'] as List?;
    if (providers != null) {
      for (final item in providers.whereType<Map<String, dynamic>>()) {
        final pid = item['provider_id'] as String?;
        final rawKey = item['api_key'] as String?;
        if (pid != null &&
            rawKey != null &&
            rawKey.isNotEmpty &&
            !rawKey.startsWith(_secretMarkerPrefix) &&
            !isTemplatePlaceholderValue(rawKey)) {
          final slot = ttsSecretSlot(pid);
          final stored = await _secretStore.write(slot, rawKey);
          if (stored) {
            item['api_key'] = '$_secretMarkerPrefix$slot';
          }
        }
      }
    }
  }

  Future<String> _hydrateSecretsIntoJson(String rawJson) async {
    if (!rawJson.contains(_secretMarkerPrefix)) return rawJson;
    final Object? decoded;
    try {
      decoded = StrictJsonDecoder.decode(rawJson);
    } catch (_) {
      return rawJson;
    }
    if (decoded is! Map<String, dynamic>) return rawJson;
    final ta = decoded['text_analysis'];
    if (ta is Map<String, dynamic>) {
      final k = ta['api_key'];
      if (k is String && k.startsWith(_secretMarkerPrefix)) {
        final slot = k.substring(_secretMarkerPrefix.length);
        ta['api_key'] = await _secretStore.read(slot) ?? '';
      }
    }
    final textModels = decoded['text_analysis_models'];
    if (textModels is List) {
      for (final item in textModels.whereType<Map<String, dynamic>>()) {
        final k = item['api_key'];
        if (k is String && k.startsWith(_secretMarkerPrefix)) {
          final slot = k.substring(_secretMarkerPrefix.length);
          item['api_key'] = await _secretStore.read(slot) ?? '';
        }
      }
    }
    final tts = decoded['tts'];
    if (tts is Map<String, dynamic> && tts['providers'] is List) {
      for (final item in (tts['providers'] as List).whereType<Map<String, dynamic>>()) {
        final k = item['api_key'];
        if (k is String && k.startsWith(_secretMarkerPrefix)) {
          final slot = k.substring(_secretMarkerPrefix.length);
          item['api_key'] = await _secretStore.read(slot) ?? '';
        }
      }
    }
    return jsonEncode(decoded);
  }
}
