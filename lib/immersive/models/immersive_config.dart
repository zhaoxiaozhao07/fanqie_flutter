import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 配置字段校验错误
class ConfigValidationIssue {
  final String path;
  final String message;

  const ConfigValidationIssue(this.path, this.message);

  @override
  String toString() => '$path: $message';
}

/// 严格 JSON 解析异常（含重复键检测）
class StrictJsonException implements Exception {
  final String message;
  const StrictJsonException(this.message);

  @override
  String toString() => message;
}

/// 严格 JSON 解析器：解析前执行词法扫描，拒绝任意层级的重复对象键
class StrictJsonDecoder {
  static dynamic decode(String source) {
    _checkDuplicateKeys(source);
    return jsonDecode(source);
  }

  static void _checkDuplicateKeys(String s) {
    var i = 0;
    final n = s.length;

    void skipWs() {
      while (i < n) {
        final c = s.codeUnitAt(i);
        if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
          i++;
        } else {
          break;
        }
      }
    }

    String readString() {
      if (i >= n || s.codeUnitAt(i) != 0x22) {
        throw StrictJsonException('JSON 语法错误：位置 $i 处期望字符串');
      }
      final start = i;
      i++;
      while (i < n) {
        final c = s.codeUnitAt(i);
        if (c == 0x5C) {
          i += 2;
        } else if (c == 0x22) {
          i++;
          return jsonDecode(s.substring(start, i)) as String;
        } else {
          i++;
        }
      }
      throw const StrictJsonException('JSON 语法错误：字符串未闭合');
    }

    late final void Function(String path) parseValue;

    void parseObject(String path) {
      i++; // 跳过 '{'
      skipWs();
      final keys = <String>{};
      if (i < n && s.codeUnitAt(i) == 0x7D) {
        i++;
        return;
      }
      while (i < n) {
        skipWs();
        final key = readString();
        final fieldPath = path.isEmpty ? key : '$path.$key';
        if (!keys.add(key)) {
          throw StrictJsonException('JSON 包含重复键：$fieldPath');
        }
        skipWs();
        if (i >= n || s.codeUnitAt(i) != 0x3A) {
          throw StrictJsonException('JSON 语法错误：$fieldPath 后缺少冒号');
        }
        i++;
        skipWs();
        parseValue(fieldPath);
        skipWs();
        if (i < n && s.codeUnitAt(i) == 0x2C) {
          i++;
        } else if (i < n && s.codeUnitAt(i) == 0x7D) {
          i++;
          return;
        } else {
          throw StrictJsonException('JSON 语法错误：对象 $path 未正确结束');
        }
      }
      throw StrictJsonException('JSON 语法错误：对象 $path 未闭合');
    }

    void parseArray(String path) {
      i++; // 跳过 '['
      skipWs();
      var idx = 0;
      if (i < n && s.codeUnitAt(i) == 0x5D) {
        i++;
        return;
      }
      while (i < n) {
        skipWs();
        parseValue('$path[$idx]');
        idx++;
        skipWs();
        if (i < n && s.codeUnitAt(i) == 0x2C) {
          i++;
        } else if (i < n && s.codeUnitAt(i) == 0x5D) {
          i++;
          return;
        } else {
          throw StrictJsonException('JSON 语法错误：数组 $path 未正确结束');
        }
      }
      throw StrictJsonException('JSON 语法错误：数组 $path 未闭合');
    }

    parseValue = (String path) {
      skipWs();
      if (i >= n) throw const StrictJsonException('JSON 语法错误：意外结束');
      final c = s.codeUnitAt(i);
      if (c == 0x7B) {
        parseObject(path);
      } else if (c == 0x5B) {
        parseArray(path);
      } else if (c == 0x22) {
        readString();
      } else {
        // 读取数字、布尔或 null
        while (i < n) {
          final ch = s.codeUnitAt(i);
          if (ch == 0x2C ||
              ch == 0x7D ||
              ch == 0x5D ||
              ch == 0x20 ||
              ch == 0x09 ||
              ch == 0x0A ||
              ch == 0x0D) {
            break;
          }
          i++;
        }
      }
    };

    skipWs();
    parseValue('');
    skipWs();
    if (i != n) {
      throw StrictJsonException('JSON 语法错误：末尾存在多余内容（位置 $i）');
    }
  }
}

/// 规范 JSON 序列化：仅排序对象键，精确保留字符串值大小写与 Unicode 原值
String canonicalJsonEncode(Object? value) {
  Object? normalize(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((e) => e.toString()).toList()..sort();
      final out = <String, Object?>{};
      for (final k in keys) {
        out[k] = normalize(v[k]);
      }
      return out;
    }
    if (v is List) {
      return v.map(normalize).toList();
    }
    return v;
  }

  return jsonEncode(normalize(value));
}

/// 根据远端模型名推导默认音色 ID：去掉尾部 _female 或 _male，精确保留大小写
String deriveVoiceIdFromModel(String modelId) {
  if (modelId.endsWith('_female')) {
    return modelId.substring(0, modelId.length - '_female'.length);
  }
  if (modelId.endsWith('_male')) {
    return modelId.substring(0, modelId.length - '_male'.length);
  }
  return modelId;
}

/// 保留 Base URL 路径段（如 /v1）安全拼接接口路径，不因 endpoint 前导斜杠丢弃路径
Uri joinProviderUrl(String baseUrl, String endpoint) {
  final trimmedBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final trimmedEndpoint = endpoint.trim().replaceAll(RegExp(r'^/+'), '');
  final uri = Uri.tryParse(trimmedBase);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException('供应商 URL 不合法：$baseUrl');
  }
  final basePath = uri.path.replaceAll(RegExp(r'/+$'), '');
  final fullPath = trimmedEndpoint.isEmpty
      ? (basePath.isEmpty ? '/' : basePath)
      : '$basePath/$trimmedEndpoint';
  return uri.replace(path: fullPath);
}

/// 判断字符串是否为配置模板占位值（不将 X/x/Y/y 误判为非法）
bool isTemplatePlaceholderValue(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  return trimmed.startsWith('REPLACE_WITH_');
}

/// 判断 URL 是否指向示例保留域名
bool isExampleReservedEndpoint(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  return host == 'example.com' ||
      host.endsWith('.example.com') ||
      host == 'example.org' ||
      host.endsWith('.example.org') ||
      host == 'example.net' ||
      host.endsWith('.example.net');
}

/// 文本分析与 TTS 受保护字段集合
class ProtectedProtocolFields {
  static const textBody = <String>{
    'model',
    'messages',
    'response_format',
    'stream',
    'max_completion_tokens',
    'max_tokens',
    'temperature',
    'tools',
    'tool_choice',
    'json_format',
  };

  static const ttsBody = <String>{
    'model',
    'voice',
    'input',
    'response_format',
    'speed',
    'instructions',
    'stream_format',
  };

  static const headersLower = <String>{
    'authorization',
    'host',
    'content-type',
    'content-length',
  };
}

/// 存储路径配置
class StorageConfig {
  final String stateStore;
  final String databasePath;
  final String audioCacheDir;
  final String tempDir;

  const StorageConfig({
    this.stateStore = 'sqlite',
    this.databasePath = './data/immersive-audio/state.sqlite3',
    this.audioCacheDir = './data/immersive-audio/audio',
    this.tempDir = './data/immersive-audio/audio/tmp',
  });

  Map<String, dynamic> toJson() => {
    'state_store': stateStore,
    'database_path': databasePath,
    'audio_cache_dir': audioCacheDir,
    'temp_dir': tempDir,
  };
}

/// 结构化输出协议配置
class StructuredOutputConfig {
  final String mode;
  final String schemaNamePrefix;
  final bool strict;
  final String? vendorAdapterId;
  final bool allowPromptOnlyFallback;

  const StructuredOutputConfig({
    this.mode = 'json_schema',
    this.schemaNamePrefix = 'immersive_reader_v1',
    this.strict = true,
    this.vendorAdapterId,
    this.allowPromptOnlyFallback = false,
  });

  StructuredOutputConfig copyWith({
    String? mode,
    String? schemaNamePrefix,
    bool? strict,
    Object? vendorAdapterId = _sentinel,
    bool? allowPromptOnlyFallback,
  }) => StructuredOutputConfig(
    mode: mode ?? this.mode,
    schemaNamePrefix: schemaNamePrefix ?? this.schemaNamePrefix,
    strict: strict ?? this.strict,
    vendorAdapterId: identical(vendorAdapterId, _sentinel)
        ? this.vendorAdapterId
        : vendorAdapterId as String?,
    allowPromptOnlyFallback:
        allowPromptOnlyFallback ?? this.allowPromptOnlyFallback,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'schema_name_prefix': schemaNamePrefix,
    'strict': strict,
    'vendor_adapter_id': vendorAdapterId,
    'allow_prompt_only_fallback': allowPromptOnlyFallback,
  };
}

/// 文本分析模型思考程度枚举
class TextThinkingLevel {
  static const auto = 'auto';
  static const off = 'off';
  static const minimal = 'minimal';
  static const low = 'low';
  static const medium = 'medium';
  static const high = 'high';

  static const values = <String>{auto, off, minimal, low, medium, high};
}

/// 文本分析模型配置
class TextAnalysisConfig {
  final String id;
  final String providerId;
  final String displayName;
  final bool enabled;
  final String adapter;
  final String baseUrl;
  final String endpoint;
  final String? apiKey;
  final String? apiKeyEnv;
  final String modelId;
  final String thinkingLevel;
  final Map<String, String> extraHeaders;
  final Map<String, dynamic> extraBody;
  final int requestTimeoutMs;
  final int maxConcurrency;
  final int reservedReconciliationSlots;
  final int? requestsPerMinute;
  final int? tokensPerMinute;
  final int contextWindowTokens;
  final int maxOutputTokens;
  final String outputLimitParameter;
  final double? temperature;
  final StructuredOutputConfig structuredOutput;

  const TextAnalysisConfig({
    String? id,
    required this.providerId,
    required this.displayName,
    this.enabled = true,
    this.adapter = 'openai_chat_completions',
    required this.baseUrl,
    this.endpoint = '/chat/completions',
    this.apiKey,
    this.apiKeyEnv,
    required this.modelId,
    this.thinkingLevel = TextThinkingLevel.auto,
    this.extraHeaders = const {},
    this.extraBody = const {},
    this.requestTimeoutMs = 90000,
    this.maxConcurrency = 3,
    this.reservedReconciliationSlots = 1,
    this.requestsPerMinute = 30,
    this.tokensPerMinute,
    this.contextWindowTokens = 32768,
    this.maxOutputTokens = 6144,
    this.outputLimitParameter = 'max_completion_tokens',
    this.temperature,
    this.structuredOutput = const StructuredOutputConfig(),
  }) : id = id ?? '';

  /// 返回稳定非空的模型条目唯一标识（旧配置未显式指定 id 时自动派生）
  String get effectiveId {
    if (id.trim().isNotEmpty) return id.trim();
    final safeModel = modelId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return 'tm_${providerId}_$safeModel';
  }

  TextAnalysisConfig copyWith({
    String? id,
    String? providerId,
    String? displayName,
    bool? enabled,
    String? adapter,
    String? baseUrl,
    String? endpoint,
    Object? apiKey = _sentinel,
    Object? apiKeyEnv = _sentinel,
    String? modelId,
    String? thinkingLevel,
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
    int? requestTimeoutMs,
    int? maxConcurrency,
    int? reservedReconciliationSlots,
    Object? requestsPerMinute = _sentinel,
    Object? tokensPerMinute = _sentinel,
    int? contextWindowTokens,
    int? maxOutputTokens,
    String? outputLimitParameter,
    Object? temperature = _sentinel,
    StructuredOutputConfig? structuredOutput,
  }) => TextAnalysisConfig(
    id: id ?? this.id,
    providerId: providerId ?? this.providerId,
    displayName: displayName ?? this.displayName,
    enabled: enabled ?? this.enabled,
    adapter: adapter ?? this.adapter,
    baseUrl: baseUrl ?? this.baseUrl,
    endpoint: endpoint ?? this.endpoint,
    apiKey: identical(apiKey, _sentinel) ? this.apiKey : apiKey as String?,
    apiKeyEnv: identical(apiKeyEnv, _sentinel)
        ? this.apiKeyEnv
        : apiKeyEnv as String?,
    modelId: modelId ?? this.modelId,
    thinkingLevel: thinkingLevel ?? this.thinkingLevel,
    extraHeaders: extraHeaders ?? this.extraHeaders,
    extraBody: extraBody ?? this.extraBody,
    requestTimeoutMs: requestTimeoutMs ?? this.requestTimeoutMs,
    maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    reservedReconciliationSlots:
        reservedReconciliationSlots ?? this.reservedReconciliationSlots,
    requestsPerMinute: identical(requestsPerMinute, _sentinel)
        ? this.requestsPerMinute
        : requestsPerMinute as int?,
    tokensPerMinute: identical(tokensPerMinute, _sentinel)
        ? this.tokensPerMinute
        : tokensPerMinute as int?,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    outputLimitParameter: outputLimitParameter ?? this.outputLimitParameter,
    temperature: identical(temperature, _sentinel)
        ? this.temperature
        : temperature as double?,
    structuredOutput: structuredOutput ?? this.structuredOutput,
  );

  Map<String, dynamic> toJson({bool redactSecrets = false}) => {
    'id': effectiveId,
    'provider_id': providerId,
    'display_name': displayName,
    'enabled': enabled,
    'adapter': adapter,
    'base_url': baseUrl,
    'endpoint': endpoint,
    'api_key': redactSecrets
        ? (apiKey != null && apiKey!.isNotEmpty ? '***REDACTED***' : '')
        : apiKey,
    'api_key_env': apiKeyEnv,
    'model_id': modelId,
    'thinking_level': thinkingLevel,
    'extra_headers': extraHeaders,
    'extra_body': extraBody,
    'request_timeout_ms': requestTimeoutMs,
    'max_concurrency': maxConcurrency,
    'reserved_reconciliation_slots': reservedReconciliationSlots,
    'requests_per_minute': requestsPerMinute,
    'tokens_per_minute': tokensPerMinute,
    'context_window_tokens': contextWindowTokens,
    'max_output_tokens': maxOutputTokens,
    'output_limit_parameter': outputLimitParameter,
    'temperature': temperature,
    'structured_output': structuredOutput.toJson(),
  };

  /// 计算分析规则与模型指纹（不含密钥）
  String analysisSignatureHash() {
    final payload = canonicalJsonEncode({
      'id': effectiveId,
      'provider_id': providerId,
      'adapter': adapter,
      'base_url': baseUrl,
      'endpoint': endpoint,
      'model_id': modelId,
      'thinking_level': thinkingLevel,
      'extra_body': extraBody,
      'structured_output': structuredOutput.toJson(),
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }
}

/// TTS 模型能力声明
class TtsModelCapabilities {
  final int maxInputLength;
  final String inputLengthUnit;
  final bool supportsInstructions;
  final bool supportsSpeed;
  final List<String> supportedAudioFormats;
  final String responseTransport;
  final bool supportsWordTimestamps;

  const TtsModelCapabilities({
    this.maxInputLength = 2000,
    this.inputLengthUnit = 'unicode_codepoints',
    this.supportsInstructions = false,
    this.supportsSpeed = true,
    this.supportedAudioFormats = const ['mp3'],
    this.responseTransport = 'binary',
    this.supportsWordTimestamps = false,
  });

  Map<String, dynamic> toJson() => {
    'max_input_length': maxInputLength,
    'input_length_unit': inputLengthUnit,
    'supports_instructions': supportsInstructions,
    'supports_speed': supportsSpeed,
    'supported_audio_formats': supportedAudioFormats,
    'response_transport': responseTransport,
    'supports_word_timestamps': supportsWordTimestamps,
  };
}

/// 音色渲染参数
class VoiceRenderSettings {
  final String audioFormat;
  final double speed;
  final String? instructions;

  const VoiceRenderSettings({
    this.audioFormat = 'mp3',
    this.speed = 1.0,
    this.instructions,
  });

  VoiceRenderSettings copyWith({
    String? audioFormat,
    double? speed,
    Object? instructions = _sentinel,
  }) => VoiceRenderSettings(
    audioFormat: audioFormat ?? this.audioFormat,
    speed: speed ?? this.speed,
    instructions: identical(instructions, _sentinel)
        ? this.instructions
        : instructions as String?,
  );

  Map<String, dynamic> toJson() => {
    'audio_format': audioFormat,
    'speed': speed,
    'instructions': instructions,
  };
}

/// 音色档案配置（属于特定供应商的特定模型）
class TtsVoiceProfileConfig {
  final String voiceProfileId;
  final String voiceId;
  final String displayName;
  final bool enabled;
  final String gender;
  final String notes;
  final List<String> tags;
  final String? sampleAsset;
  final VoiceRenderSettings renderSettings;
  final Map<String, dynamic> extraBody;

  const TtsVoiceProfileConfig({
    required this.voiceProfileId,
    required this.voiceId,
    required this.displayName,
    this.enabled = true,
    required this.gender,
    this.notes = '',
    this.tags = const [],
    this.sampleAsset,
    this.renderSettings = const VoiceRenderSettings(),
    this.extraBody = const {},
  });

  TtsVoiceProfileConfig copyWith({
    String? voiceProfileId,
    String? voiceId,
    String? displayName,
    bool? enabled,
    String? gender,
    String? notes,
    List<String>? tags,
    Object? sampleAsset = _sentinel,
    VoiceRenderSettings? renderSettings,
    Map<String, dynamic>? extraBody,
  }) => TtsVoiceProfileConfig(
    voiceProfileId: voiceProfileId ?? this.voiceProfileId,
    voiceId: voiceId ?? this.voiceId,
    displayName: displayName ?? this.displayName,
    enabled: enabled ?? this.enabled,
    gender: gender ?? this.gender,
    notes: notes ?? this.notes,
    tags: tags ?? this.tags,
    sampleAsset: identical(sampleAsset, _sentinel)
        ? this.sampleAsset
        : sampleAsset as String?,
    renderSettings: renderSettings ?? this.renderSettings,
    extraBody: extraBody ?? this.extraBody,
  );

  Map<String, dynamic> toJson() => {
    'voice_profile_id': voiceProfileId,
    'voice_id': voiceId,
    'display_name': displayName,
    'enabled': enabled,
    'gender': gender,
    'notes': notes,
    'tags': tags,
    if (sampleAsset != null) 'sample_asset': sampleAsset,
    'render_settings': renderSettings.toJson(),
    'extra_body': extraBody,
  };
}

/// TTS 模型配置
class TtsModelConfig {
  final String modelKey;
  final String modelId;
  final String displayName;
  final bool enabled;
  final int maxConcurrency;
  final TtsModelCapabilities capabilities;
  final Map<String, dynamic> extraBody;
  final List<TtsVoiceProfileConfig> voices;

  const TtsModelConfig({
    required this.modelKey,
    required this.modelId,
    required this.displayName,
    this.enabled = true,
    this.maxConcurrency = 3,
    this.capabilities = const TtsModelCapabilities(),
    this.extraBody = const {},
    this.voices = const [],
  });

  TtsModelConfig copyWith({
    String? modelKey,
    String? modelId,
    String? displayName,
    bool? enabled,
    int? maxConcurrency,
    TtsModelCapabilities? capabilities,
    Map<String, dynamic>? extraBody,
    List<TtsVoiceProfileConfig>? voices,
  }) => TtsModelConfig(
    modelKey: modelKey ?? this.modelKey,
    modelId: modelId ?? this.modelId,
    displayName: displayName ?? this.displayName,
    enabled: enabled ?? this.enabled,
    maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    capabilities: capabilities ?? this.capabilities,
    extraBody: extraBody ?? this.extraBody,
    voices: voices ?? this.voices,
  );

  Map<String, dynamic> toJson() => {
    'model_key': modelKey,
    'model_id': modelId,
    'display_name': displayName,
    'enabled': enabled,
    'max_concurrency': maxConcurrency,
    'capabilities': capabilities.toJson(),
    'extra_body': extraBody,
    'voices': voices.map((v) => v.toJson()).toList(),
  };
}

/// TTS 供应商配置
class TtsProviderConfig {
  final String providerId;
  final String displayName;
  final bool enabled;
  final String adapter;
  final String baseUrl;
  final String endpoint;
  final String? apiKey;
  final String? apiKeyEnv;
  final Map<String, String> extraHeaders;
  final int requestTimeoutMs;
  final int maxConcurrency;
  final int reservedForegroundSlots;
  final int? requestsPerMinute;
  final List<TtsModelConfig> models;

  const TtsProviderConfig({
    required this.providerId,
    required this.displayName,
    this.enabled = true,
    this.adapter = 'openai_speech',
    required this.baseUrl,
    this.endpoint = '/audio/speech',
    this.apiKey,
    this.apiKeyEnv,
    this.extraHeaders = const {},
    this.requestTimeoutMs = 120000,
    this.maxConcurrency = 3,
    this.reservedForegroundSlots = 1,
    this.requestsPerMinute = 60,
    this.models = const [],
  });

  TtsProviderConfig copyWith({
    String? providerId,
    String? displayName,
    bool? enabled,
    String? adapter,
    String? baseUrl,
    String? endpoint,
    Object? apiKey = _sentinel,
    Object? apiKeyEnv = _sentinel,
    Map<String, String>? extraHeaders,
    int? requestTimeoutMs,
    int? maxConcurrency,
    int? reservedForegroundSlots,
    Object? requestsPerMinute = _sentinel,
    List<TtsModelConfig>? models,
  }) => TtsProviderConfig(
    providerId: providerId ?? this.providerId,
    displayName: displayName ?? this.displayName,
    enabled: enabled ?? this.enabled,
    adapter: adapter ?? this.adapter,
    baseUrl: baseUrl ?? this.baseUrl,
    endpoint: endpoint ?? this.endpoint,
    apiKey: identical(apiKey, _sentinel) ? this.apiKey : apiKey as String?,
    apiKeyEnv: identical(apiKeyEnv, _sentinel)
        ? this.apiKeyEnv
        : apiKeyEnv as String?,
    extraHeaders: extraHeaders ?? this.extraHeaders,
    requestTimeoutMs: requestTimeoutMs ?? this.requestTimeoutMs,
    maxConcurrency: maxConcurrency ?? this.maxConcurrency,
    reservedForegroundSlots:
        reservedForegroundSlots ?? this.reservedForegroundSlots,
    requestsPerMinute: identical(requestsPerMinute, _sentinel)
        ? this.requestsPerMinute
        : requestsPerMinute as int?,
    models: models ?? this.models,
  );

  Map<String, dynamic> toJson({bool redactSecrets = false}) => {
    'provider_id': providerId,
    'display_name': displayName,
    'enabled': enabled,
    'adapter': adapter,
    'base_url': baseUrl,
    'endpoint': endpoint,
    'api_key': redactSecrets
        ? (apiKey != null && apiKey!.isNotEmpty ? '***REDACTED***' : '')
        : apiKey,
    'api_key_env': apiKeyEnv,
    'extra_headers': extraHeaders,
    'request_timeout_ms': requestTimeoutMs,
    'max_concurrency': maxConcurrency,
    'reserved_foreground_slots': reservedForegroundSlots,
    'requests_per_minute': requestsPerMinute,
    'models': models.map((m) => m.toJson()).toList(),
  };
}

/// TTS 全局配置
class TtsConfig {
  final int globalMaxConcurrency;
  final int maxPendingJobs;
  final List<TtsProviderConfig> providers;

  const TtsConfig({
    this.globalMaxConcurrency = 6,
    this.maxPendingJobs = 64,
    this.providers = const [],
  });

  TtsConfig copyWith({
    int? globalMaxConcurrency,
    int? maxPendingJobs,
    List<TtsProviderConfig>? providers,
  }) => TtsConfig(
    globalMaxConcurrency: globalMaxConcurrency ?? this.globalMaxConcurrency,
    maxPendingJobs: maxPendingJobs ?? this.maxPendingJobs,
    providers: providers ?? this.providers,
  );

  Map<String, dynamic> toJson({bool redactSecrets = false}) => {
    'global_max_concurrency': globalMaxConcurrency,
    'max_pending_jobs': maxPendingJobs,
    'providers': providers
        .map((p) => p.toJson(redactSecrets: redactSecrets))
        .toList(),
  };
}

/// 新书默认配音方案
class BookDefaultsConfig {
  final List<String> selectedVoiceProfileIds;
  final String narratorVoiceProfileId;
  final bool allowVoiceReuse;
  final bool reserveNarratorForNonDialogue;
  final String unknownGenderPolicy;
  final String knownGenderNoMatchPolicy;
  final String unresolvedDialoguePolicy;
  final String identityConflictPolicy;
  final String thoughtAndQuotedTextPolicy;
  final String missingVoicePolicy;
  final String middleStartPolicy;

  const BookDefaultsConfig({
    required this.selectedVoiceProfileIds,
    required this.narratorVoiceProfileId,
    this.allowVoiceReuse = true,
    this.reserveNarratorForNonDialogue = true,
    this.unknownGenderPolicy = 'prefer_neutral_then_selected',
    this.knownGenderNoMatchPolicy = 'prefer_neutral_else_require_selection',
    this.unresolvedDialoguePolicy = 'narrator_fallback_after_review',
    this.identityConflictPolicy = 'pause_affected_range',
    this.thoughtAndQuotedTextPolicy = 'narrator',
    this.missingVoicePolicy = 'pause_until_reconfigured',
    this.middleStartPolicy = 'build_prefix_identity_first',
  });

  BookDefaultsConfig copyWith({
    List<String>? selectedVoiceProfileIds,
    String? narratorVoiceProfileId,
    bool? allowVoiceReuse,
    bool? reserveNarratorForNonDialogue,
  }) => BookDefaultsConfig(
    selectedVoiceProfileIds:
        selectedVoiceProfileIds ?? this.selectedVoiceProfileIds,
    narratorVoiceProfileId:
        narratorVoiceProfileId ?? this.narratorVoiceProfileId,
    allowVoiceReuse: allowVoiceReuse ?? this.allowVoiceReuse,
    reserveNarratorForNonDialogue:
        reserveNarratorForNonDialogue ?? this.reserveNarratorForNonDialogue,
    unknownGenderPolicy: unknownGenderPolicy,
    knownGenderNoMatchPolicy: knownGenderNoMatchPolicy,
    unresolvedDialoguePolicy: unresolvedDialoguePolicy,
    identityConflictPolicy: identityConflictPolicy,
    thoughtAndQuotedTextPolicy: thoughtAndQuotedTextPolicy,
    missingVoicePolicy: missingVoicePolicy,
    middleStartPolicy: middleStartPolicy,
  );

  Map<String, dynamic> toJson() => {
    'selected_voice_profile_ids': selectedVoiceProfileIds,
    'narrator_voice_profile_id': narratorVoiceProfileId,
    'allow_voice_reuse': allowVoiceReuse,
    'reserve_narrator_for_non_dialogue': reserveNarratorForNonDialogue,
    'unknown_gender_policy': unknownGenderPolicy,
    'known_gender_no_match_policy': knownGenderNoMatchPolicy,
    'unresolved_dialogue_policy': unresolvedDialoguePolicy,
    'identity_conflict_policy': identityConflictPolicy,
    'thought_and_quoted_text_policy': thoughtAndQuotedTextPolicy,
    'missing_voice_policy': missingVoicePolicy,
    'middle_start_policy': middleStartPolicy,
  };
}

/// 文本分析管线边界配置
class AnalysisPipelineConfig {
  final int aheadChapters;
  final int maxPrefixBacktrackChapters;
  final int maxAheadChunks;
  final int maxUncommittedChunks;
  final int firstChunkTargetTokens;
  final int targetChunkTokens;
  final int maxChunkTokens;
  final int contextBeforeTokens;
  final int contextAfterTokens;
  final int recentDialogueTurns;
  final int chapterSummaryMaxTokens;
  final int characterContextMaxTokens;
  final double contextSafetyMarginRatio;
  final int maxIdentityRechecks;
  final bool keepAllSelectedVoiceProfilesInSystem;
  final bool tieredThinking;

  const AnalysisPipelineConfig({
    this.aheadChapters = 3,
    this.maxPrefixBacktrackChapters = 5,
    this.maxAheadChunks = 24,
    this.maxUncommittedChunks = 8,
    this.firstChunkTargetTokens = 550,
    this.targetChunkTokens = 2500,
    this.maxChunkTokens = 4000,
    this.contextBeforeTokens = 700,
    this.contextAfterTokens = 350,
    this.recentDialogueTurns = 8,
    this.chapterSummaryMaxTokens = 500,
    this.characterContextMaxTokens = 4000,
    this.contextSafetyMarginRatio = 0.15,
    this.maxIdentityRechecks = 2,
    this.keepAllSelectedVoiceProfilesInSystem = true,
    this.tieredThinking = true,
  });

  AnalysisPipelineConfig copyWith({
    int? aheadChapters,
    int? maxPrefixBacktrackChapters,
    int? maxAheadChunks,
    int? maxUncommittedChunks,
    int? firstChunkTargetTokens,
    bool? tieredThinking,
  }) => AnalysisPipelineConfig(
    aheadChapters: aheadChapters ?? this.aheadChapters,
    maxPrefixBacktrackChapters:
        maxPrefixBacktrackChapters ?? this.maxPrefixBacktrackChapters,
    maxAheadChunks: maxAheadChunks ?? this.maxAheadChunks,
    maxUncommittedChunks: maxUncommittedChunks ?? this.maxUncommittedChunks,
    firstChunkTargetTokens:
        firstChunkTargetTokens ?? this.firstChunkTargetTokens,
    targetChunkTokens: targetChunkTokens,
    maxChunkTokens: maxChunkTokens,
    contextBeforeTokens: contextBeforeTokens,
    contextAfterTokens: contextAfterTokens,
    recentDialogueTurns: recentDialogueTurns,
    chapterSummaryMaxTokens: chapterSummaryMaxTokens,
    characterContextMaxTokens: characterContextMaxTokens,
    contextSafetyMarginRatio: contextSafetyMarginRatio,
    maxIdentityRechecks: maxIdentityRechecks,
    keepAllSelectedVoiceProfilesInSystem: keepAllSelectedVoiceProfilesInSystem,
    tieredThinking: tieredThinking ?? this.tieredThinking,
  );

  Map<String, dynamic> toJson() => {
    'ahead_chapters': aheadChapters,
    'max_prefix_backtrack_chapters': maxPrefixBacktrackChapters,
    'max_ahead_chunks': maxAheadChunks,
    'max_uncommitted_chunks': maxUncommittedChunks,
    'first_chunk_target_tokens': firstChunkTargetTokens,
    'target_chunk_tokens': targetChunkTokens,
    'max_chunk_tokens': maxChunkTokens,
    'context_before_tokens': contextBeforeTokens,
    'context_after_tokens': contextAfterTokens,
    'recent_dialogue_turns': recentDialogueTurns,
    'chapter_summary_max_tokens': chapterSummaryMaxTokens,
    'character_context_max_tokens': characterContextMaxTokens,
    'context_safety_margin_ratio': contextSafetyMarginRatio,
    'max_identity_rechecks': maxIdentityRechecks,
    'keep_all_selected_voice_profiles_in_system':
        keepAllSelectedVoiceProfilesInSystem,
    'tiered_thinking': tieredThinking,
  };
}

/// 音频合成切分配置
class AudioGenerationConfig {
  final int startupTargetCharacters;
  final int targetCharacters;
  final int maxCharacters;
  final double initialEstimatedCharactersPerSecond;
  final bool crossChapterMerge;
  final String transport;

  const AudioGenerationConfig({
    this.startupTargetCharacters = 40,
    this.targetCharacters = 120,
    this.maxCharacters = 350,
    this.initialEstimatedCharactersPerSecond = 4.0,
    this.crossChapterMerge = false,
    this.transport = 'complete_file_cache',
  });

  Map<String, dynamic> toJson() => {
    'startup_target_characters': startupTargetCharacters,
    'target_characters': targetCharacters,
    'max_characters': maxCharacters,
    'initial_estimated_characters_per_second':
        initialEstimatedCharactersPerSecond,
    'cross_chapter_merge': crossChapterMerge,
    'transport': transport,
  };
}

/// 缓冲与预取水位配置
class PrefetchConfig {
  final double startupBufferSeconds;
  final int startupWaitAfterFirstReadyMs;
  final double resumeBufferSeconds;
  final double lowWaterSeconds;
  final double targetBufferSeconds;
  final double highWaterSeconds;
  final int maxJobsBeyondFirstGap;
  final String pausePolicy;
  final bool continueInSupportedBackground;

  const PrefetchConfig({
    this.startupBufferSeconds = 8,
    this.startupWaitAfterFirstReadyMs = 3000,
    this.resumeBufferSeconds = 8,
    this.lowWaterSeconds = 90,
    this.targetBufferSeconds = 300,
    this.highWaterSeconds = 600,
    this.maxJobsBeyondFirstGap = 8,
    this.pausePolicy = 'finish_inflight_stop_new',
    this.continueInSupportedBackground = true,
  });

  Map<String, dynamic> toJson() => {
    'startup_buffer_seconds': startupBufferSeconds,
    'startup_wait_after_first_ready_ms': startupWaitAfterFirstReadyMs,
    'resume_buffer_seconds': resumeBufferSeconds,
    'low_water_seconds': lowWaterSeconds,
    'target_buffer_seconds': targetBufferSeconds,
    'high_water_seconds': highWaterSeconds,
    'max_jobs_beyond_first_gap': maxJobsBeyondFirstGap,
    'pause_policy': pausePolicy,
    'continue_in_supported_background': continueInSupportedBackground,
  };
}

/// 判断接口地址是否为非本机回环的明文 HTTP（用于安全提示）
bool isInsecureRemoteHttpUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'http') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host == '127.0.0.1' || host == '::1') {
    return false;
  }
  return true;
}

/// 播放行为配置
class PlaybackConfig {
  final double defaultRate;
  final bool preservePitch;
  final String highlightGranularity;
  final int cursorSaveIntervalMs;
  final bool chapterAutoAdvance;
  final String gapPolicy;
  final int sameSpeakerGapMs;
  final int speakerSwitchGapMs;
  final int chapterSwitchGapMs;

  const PlaybackConfig({
    this.defaultRate = 1.0,
    this.preservePitch = true,
    this.highlightGranularity = 'audio_segment',
    this.cursorSaveIntervalMs = 1000,
    this.chapterAutoAdvance = true,
    this.gapPolicy = 'wait_without_skipping',
    this.sameSpeakerGapMs = 120,
    this.speakerSwitchGapMs = 260,
    this.chapterSwitchGapMs = 480,
  });

  PlaybackConfig copyWith({
    double? defaultRate,
    bool? preservePitch,
    int? sameSpeakerGapMs,
    int? speakerSwitchGapMs,
    int? chapterSwitchGapMs,
  }) => PlaybackConfig(
    defaultRate: defaultRate ?? this.defaultRate,
    preservePitch: preservePitch ?? this.preservePitch,
    highlightGranularity: highlightGranularity,
    cursorSaveIntervalMs: cursorSaveIntervalMs,
    chapterAutoAdvance: chapterAutoAdvance,
    gapPolicy: gapPolicy,
    sameSpeakerGapMs: sameSpeakerGapMs ?? this.sameSpeakerGapMs,
    speakerSwitchGapMs: speakerSwitchGapMs ?? this.speakerSwitchGapMs,
    chapterSwitchGapMs: chapterSwitchGapMs ?? this.chapterSwitchGapMs,
  );

  Map<String, dynamic> toJson() => {
    'default_rate': defaultRate,
    'preserve_pitch': preservePitch,
    'highlight_granularity': highlightGranularity,
    'cursor_save_interval_ms': cursorSaveIntervalMs,
    'chapter_auto_advance': chapterAutoAdvance,
    'gap_policy': gapPolicy,
    'same_speaker_gap_ms': sameSpeakerGapMs,
    'speaker_switch_gap_ms': speakerSwitchGapMs,
    'chapter_switch_gap_ms': chapterSwitchGapMs,
  };
}

/// 音频缓存预算与清理配置
class CacheConfig {
  final int maxBytes;
  final double evictToRatio;
  final int minFreeDiskBytes;
  final String evictionPolicy;
  final int protectRecentPlaybackSeconds;
  final bool verifyChecksumOnReuse;
  final int cleanupIncompleteFilesAfterSeconds;

  const CacheConfig({
    this.maxBytes = 2147483648,
    this.evictToRatio = 0.8,
    this.minFreeDiskBytes = 268435456,
    this.evictionPolicy = 'lru_unpinned',
    this.protectRecentPlaybackSeconds = 120,
    this.verifyChecksumOnReuse = true,
    this.cleanupIncompleteFilesAfterSeconds = 3600,
  });

  Map<String, dynamic> toJson() => {
    'max_bytes': maxBytes,
    'evict_to_ratio': evictToRatio,
    'min_free_disk_bytes': minFreeDiskBytes,
    'eviction_policy': evictionPolicy,
    'protect_recent_playback_seconds': protectRecentPlaybackSeconds,
    'verify_checksum_on_reuse': verifyChecksumOnReuse,
    'cleanup_incomplete_files_after_seconds':
        cleanupIncompleteFilesAfterSeconds,
  };
}

/// 任务租约与心跳配置
class JobsConfig {
  final int leaseSeconds;
  final int heartbeatSeconds;
  final int pollIntervalMs;
  final bool cancelUnneededRequestsOnSeek;

  const JobsConfig({
    this.leaseSeconds = 60,
    this.heartbeatSeconds = 15,
    this.pollIntervalMs = 500,
    this.cancelUnneededRequestsOnSeek = true,
  });

  Map<String, dynamic> toJson() => {
    'lease_seconds': leaseSeconds,
    'heartbeat_seconds': heartbeatSeconds,
    'poll_interval_ms': pollIntervalMs,
    'cancel_unneeded_requests_on_seek': cancelUnneededRequestsOnSeek,
  };
}

/// 重试退避配置
class RetryConfig {
  final int maxAttempts;
  final int initialBackoffMs;
  final int maxBackoffMs;
  final double jitterRatio;
  final bool respectRetryAfter;

  const RetryConfig({
    this.maxAttempts = 3,
    this.initialBackoffMs = 1000,
    this.maxBackoffMs = 30000,
    this.jitterRatio = 0.2,
    this.respectRetryAfter = true,
  });

  Map<String, dynamic> toJson() => {
    'max_attempts': maxAttempts,
    'initial_backoff_ms': initialBackoffMs,
    'max_backoff_ms': maxBackoffMs,
    'jitter_ratio': jitterRatio,
    'respect_retry_after': respectRetryAfter,
  };
}

/// 日志与诊断配置
class ObservabilityConfig {
  final String logLevel;
  final bool logBookText;
  final bool logRawModelResponses;
  final int retainDebugPayloadDays;
  final bool collectLocalMetrics;

  const ObservabilityConfig({
    this.logLevel = 'info',
    this.logBookText = false,
    this.logRawModelResponses = false,
    this.retainDebugPayloadDays = 7,
    this.collectLocalMetrics = true,
  });

  Map<String, dynamic> toJson() => {
    'log_level': logLevel,
    'log_book_text': logBookText,
    'log_raw_model_responses': logRawModelResponses,
    'retain_debug_payload_days': retainDebugPayloadDays,
    'collect_local_metrics': collectLocalMetrics,
  };
}

/// 通过 voice_profile_id 解析得到的完整三维路由对象
class VoiceProfileResolution {
  final TtsProviderConfig provider;
  final TtsModelConfig model;
  final TtsVoiceProfileConfig voice;

  const VoiceProfileResolution({
    required this.provider,
    required this.model,
    required this.voice,
  });

  bool get isEffectivelyEnabled =>
      provider.enabled && model.enabled && voice.enabled;

  /// 合并模型级与音色级扩展参数（音色级覆盖同名非保留扩展参数）
  Map<String, dynamic> mergedExtraBody() => {
    ...model.extraBody,
    ...voice.extraBody,
  };

  /// 计算渲染规格哈希（不包含密钥、显示名、备注等非合成字段）
  String computeRenderSpecHash({String preprocessVersion = 'v1'}) {
    final nonSecretHeaders = <String, String>{};
    provider.extraHeaders.forEach((k, v) {
      if (!ProtectedProtocolFields.headersLower.contains(k.toLowerCase())) {
        nonSecretHeaders[k] = v;
      }
    });
    final spec = canonicalJsonEncode({
      'provider_id': provider.providerId,
      'adapter': provider.adapter,
      'url': joinProviderUrl(provider.baseUrl, provider.endpoint).toString(),
      'model_id': model.modelId,
      'voice_id': voice.voiceId,
      'audio_format': voice.renderSettings.audioFormat,
      'speed': voice.renderSettings.speed,
      'instructions': voice.renderSettings.instructions,
      'extra_body': mergedExtraBody(),
      'extra_headers': nonSecretHeaders,
      'preprocess_version': preprocessVersion,
    });
    return sha256.convert(utf8.encode(spec)).toString();
  }
}

/// 同性别音色自动兜底解析结果
class VoiceFallbackResolution {
  final VoiceProfileResolution resolution;
  final bool didFallback;
  final String? fallbackReason;

  const VoiceFallbackResolution({
    required this.resolution,
    this.didFallback = false,
    this.fallbackReason,
  });
}

/// 沉浸式听书总配置（不可变运行快照）
class ImmersiveConfig {
  final int schemaVersion;
  final bool featureEnabled;
  final StorageConfig storage;
  final TextAnalysisConfig textAnalysis;
  final List<TextAnalysisConfig> textAnalysisModels;
  final String primaryTextModelId;
  final String? fallbackTextModelId;
  final int textFailoverThreshold;
  final TtsConfig tts;
  final BookDefaultsConfig bookDefaults;
  final AnalysisPipelineConfig analysisPipeline;
  final AudioGenerationConfig audioGeneration;
  final PrefetchConfig prefetch;
  final PlaybackConfig playback;
  final CacheConfig cache;
  final JobsConfig jobs;
  final RetryConfig retry;
  final ObservabilityConfig observability;

  late final Map<String, TtsProviderConfig> providerIndex = {
    for (final p in tts.providers) p.providerId: p,
  };

  late final Map<String, VoiceProfileResolution> voiceProfileIndex = _buildIndex();

  ImmersiveConfig._({
    required this.schemaVersion,
    required this.featureEnabled,
    required this.storage,
    required this.textAnalysis,
    required this.textAnalysisModels,
    required this.primaryTextModelId,
    required this.fallbackTextModelId,
    required this.textFailoverThreshold,
    required this.tts,
    required this.bookDefaults,
    required this.analysisPipeline,
    required this.audioGeneration,
    required this.prefetch,
    required this.playback,
    required this.cache,
    required this.jobs,
    required this.retry,
    required this.observability,
  });

  factory ImmersiveConfig({
    int schemaVersion = 1,
    required bool featureEnabled,
    StorageConfig storage = const StorageConfig(),
    required TextAnalysisConfig textAnalysis,
    List<TextAnalysisConfig>? textAnalysisModels,
    String? primaryTextModelId,
    String? fallbackTextModelId,
    int textFailoverThreshold = 2,
    required TtsConfig tts,
    required BookDefaultsConfig bookDefaults,
    AnalysisPipelineConfig analysisPipeline = const AnalysisPipelineConfig(),
    AudioGenerationConfig audioGeneration = const AudioGenerationConfig(),
    PrefetchConfig prefetch = const PrefetchConfig(),
    PlaybackConfig playback = const PlaybackConfig(),
    CacheConfig cache = const CacheConfig(),
    JobsConfig jobs = const JobsConfig(),
    RetryConfig retry = const RetryConfig(),
    ObservabilityConfig observability = const ObservabilityConfig(),
  }) {
    final models = (textAnalysisModels == null || textAnalysisModels.isEmpty)
        ? <TextAnalysisConfig>[textAnalysis]
        : List<TextAnalysisConfig>.unmodifiable(textAnalysisModels);
    final resolvedPrimaryId =
        (primaryTextModelId != null && primaryTextModelId.trim().isNotEmpty)
        ? primaryTextModelId.trim()
        : (models.any((m) => m.effectiveId == textAnalysis.effectiveId)
              ? textAnalysis.effectiveId
              : models.first.effectiveId);
    final primaryModel = models.firstWhere(
      (m) => m.effectiveId == resolvedPrimaryId,
      orElse: () => textAnalysis,
    );
    final normalizedFallbackId =
        (fallbackTextModelId != null &&
            fallbackTextModelId.trim().isNotEmpty &&
            fallbackTextModelId.trim() != resolvedPrimaryId)
        ? fallbackTextModelId.trim()
        : null;
    return ImmersiveConfig._(
      schemaVersion: schemaVersion,
      featureEnabled: featureEnabled,
      storage: storage,
      textAnalysis: primaryModel,
      textAnalysisModels: models,
      primaryTextModelId: resolvedPrimaryId,
      fallbackTextModelId: normalizedFallbackId,
      textFailoverThreshold: textFailoverThreshold.clamp(1, 10),
      tts: tts,
      bookDefaults: bookDefaults,
      analysisPipeline: analysisPipeline,
      audioGeneration: audioGeneration,
      prefetch: prefetch,
      playback: playback,
      cache: cache,
      jobs: jobs,
      retry: retry,
      observability: observability,
    );
  }

  /// 所有已启用的文本分析模型列表
  List<TextAnalysisConfig> get enabledTextModels =>
      textAnalysisModels.where((m) => m.enabled).toList(growable: false);

  /// 按模型条目 ID 查找文本分析模型
  TextAnalysisConfig? findTextModel(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    for (final m in textAnalysisModels) {
      if (m.effectiveId == id.trim()) return m;
    }
    return null;
  }

  /// 当前主文本分析模型（优先主模型 ID，若被禁用则回退至首个启用模型）
  TextAnalysisConfig get primaryTextModel {
    final p = findTextModel(primaryTextModelId);
    if (p != null && p.enabled) return p;
    final enabled = enabledTextModels;
    if (enabled.isNotEmpty) return enabled.first;
    return textAnalysis;
  }

  /// 当前兜底文本分析模型（仅返回已启用且不同于主模型的项）
  TextAnalysisConfig? get fallbackTextModel {
    final fb = findTextModel(fallbackTextModelId);
    if (fb != null &&
        fb.enabled &&
        fb.effectiveId != primaryTextModel.effectiveId) {
      return fb;
    }
    return null;
  }

  Map<String, VoiceProfileResolution> _buildIndex() {
    final map = <String, VoiceProfileResolution>{};
    for (final p in tts.providers) {
      for (final m in p.models) {
        for (final v in m.voices) {
          map[v.voiceProfileId] = VoiceProfileResolution(
            provider: p,
            model: m,
            voice: v,
          );
        }
      }
    }
    return Map.unmodifiable(map);
  }

  /// 按全局唯一的 voice_profile_id 查找路由信息（不按 voice_id 全局查找）
  VoiceProfileResolution? resolveVoiceProfile(String voiceProfileId) =>
      voiceProfileIndex[voiceProfileId];

  /// 全部音色配置列表（保持声明顺序）
  List<VoiceProfileResolution> get allVoiceProfiles =>
      voiceProfileIndex.values.toList(growable: false);

  /// 全部三层均处于启用状态的音色列表
  List<VoiceProfileResolution> get allEnabledVoiceProfiles => voiceProfileIndex
      .values
      .where((r) => r.isEffectivelyEnabled)
      .toList(growable: false);

  /// 当首选音色被禁用、删除或失效时，按性别自动寻找可用兜底音色（男对男、女对女）
  VoiceFallbackResolution? resolveVoiceProfileWithFallback({
    required String? preferredVoiceProfileId,
    String gender = 'unknown',
    Iterable<String> preferredPoolIds = const [],
    Set<String> excludeProfileIds = const {},
    bool isNarrator = false,
  }) {
    final normalizedGender = gender.trim().toLowerCase();
    final preferredId = preferredVoiceProfileId?.trim();
    if (preferredId != null &&
        preferredId.isNotEmpty &&
        !excludeProfileIds.contains(preferredId)) {
      final exact = resolveVoiceProfile(preferredId);
      if (exact != null && exact.isEffectivelyEnabled) {
        return VoiceFallbackResolution(resolution: exact, didFallback: false);
      }
    }

    // 推断原始目标性别（若调用方未传明确性别，尝试从原被禁用音色配置中读取原性别）
    var targetGender = normalizedGender;
    if ((targetGender.isEmpty || targetGender == 'unknown') &&
        preferredId != null &&
        preferredId.isNotEmpty) {
      final old = resolveVoiceProfile(preferredId);
      if (old != null) {
        targetGender = old.voice.gender.toLowerCase();
      }
    }

    final enabledAll = allEnabledVoiceProfiles
        .where((r) => !excludeProfileIds.contains(r.voice.voiceProfileId))
        .toList();
    if (enabledAll.isEmpty) return null;

    final poolSet = preferredPoolIds.toSet();
    final enabledInPool = enabledAll
        .where((r) => poolSet.contains(r.voice.voiceProfileId))
        .toList();
    final narratorId = bookDefaults.narratorVoiceProfileId;

    VoiceProfileResolution? pick(
      List<VoiceProfileResolution> list,
      bool Function(VoiceProfileResolution) predicate,
    ) {
      for (final item in list) {
        if (predicate(item)) return item;
      }
      return null;
    }

    VoiceProfileResolution? chosen;
    final hasBinaryGender = targetGender == 'male' || targetGender == 'female';

    // 1. 优先在本书候选池中严格同性别匹配（男对男、女对女）
    if (hasBinaryGender) {
      chosen ??= pick(
        enabledInPool,
        (r) =>
            r.voice.gender.toLowerCase() == targetGender &&
            (isNarrator || r.voice.voiceProfileId != narratorId),
      );
      // 2. 全局已启用音色中严格同性别匹配
      chosen ??= pick(
        enabledAll,
        (r) =>
            r.voice.gender.toLowerCase() == targetGender &&
            (isNarrator || r.voice.voiceProfileId != narratorId),
      );
      // 3. 若同性别仅剩旁白音色，允许回退同性别旁白
      chosen ??= pick(
        enabledAll,
        (r) => r.voice.gender.toLowerCase() == targetGender,
      );
    }

    // 4. 中性或未知性别：优先中性，其次本书候选池中可用非旁白音色
    chosen ??= pick(
      enabledInPool,
      (r) =>
          r.voice.gender.toLowerCase() == 'neutral' &&
          (isNarrator || r.voice.voiceProfileId != narratorId),
    );
    chosen ??= pick(
      enabledAll,
      (r) =>
          r.voice.gender.toLowerCase() == 'neutral' &&
          (isNarrator || r.voice.voiceProfileId != narratorId),
    );
    chosen ??= pick(
      enabledInPool,
      (r) => isNarrator || r.voice.voiceProfileId != narratorId,
    );
    chosen ??= pick(
      enabledAll,
      (r) => isNarrator || r.voice.voiceProfileId != narratorId,
    );
    // 5. 最终保底：使用启用的旁白或全局任一启用音色
    chosen ??= enabledAll.first;

    final reason = preferredId == null || preferredId.isEmpty
        ? '未指定音色，已自动分配 ${chosen.voice.displayName}'
        : '原音色 $preferredId 已停用或不可用，已按性别($targetGender)自动兜底为 ${chosen.voice.displayName}';
    return VoiceFallbackResolution(
      resolution: chosen,
      didFallback: true,
      fallbackReason: reason,
    );
  }

  /// 有效配置哈希（脱敏后）
  String configSnapshotHash() => sha256
      .convert(utf8.encode(canonicalJsonEncode(toJson(redactSecrets: true))))
      .toString();

  ImmersiveConfig copyWith({
    bool? featureEnabled,
    StorageConfig? storage,
    TextAnalysisConfig? textAnalysis,
    List<TextAnalysisConfig>? textAnalysisModels,
    String? primaryTextModelId,
    Object? fallbackTextModelId = _sentinel,
    int? textFailoverThreshold,
    TtsConfig? tts,
    BookDefaultsConfig? bookDefaults,
    AnalysisPipelineConfig? analysisPipeline,
    AudioGenerationConfig? audioGeneration,
    PrefetchConfig? prefetch,
    PlaybackConfig? playback,
    CacheConfig? cache,
    JobsConfig? jobs,
    RetryConfig? retry,
    ObservabilityConfig? observability,
  }) {
    List<TextAnalysisConfig> nextModels;
    if (textAnalysisModels != null) {
      nextModels = textAnalysisModels;
    } else if (textAnalysis != null) {
      final replaced = this.textAnalysisModels
          .map(
            (m) => m.effectiveId == this.primaryTextModelId ? textAnalysis : m,
          )
          .toList();
      if (!replaced.any((m) => m.effectiveId == textAnalysis.effectiveId)) {
        replaced.insert(0, textAnalysis);
      }
      nextModels = replaced;
    } else {
      nextModels = this.textAnalysisModels;
    }
    final nextPrimaryId =
        primaryTextModelId ??
        (textAnalysis != null && textAnalysisModels == null
            ? textAnalysis.effectiveId
            : this.primaryTextModelId);
    final nextPrimary = nextModels.firstWhere(
      (m) => m.effectiveId == nextPrimaryId,
      orElse: () => textAnalysis ?? nextModels.first,
    );
    return ImmersiveConfig(
      schemaVersion: schemaVersion,
      featureEnabled: featureEnabled ?? this.featureEnabled,
      storage: storage ?? this.storage,
      textAnalysis: nextPrimary,
      textAnalysisModels: nextModels,
      primaryTextModelId: nextPrimaryId,
      fallbackTextModelId: identical(fallbackTextModelId, _sentinel)
          ? this.fallbackTextModelId
          : fallbackTextModelId as String?,
      textFailoverThreshold:
          textFailoverThreshold ?? this.textFailoverThreshold,
      tts: tts ?? this.tts,
      bookDefaults: bookDefaults ?? this.bookDefaults,
      analysisPipeline: analysisPipeline ?? this.analysisPipeline,
      audioGeneration: audioGeneration ?? this.audioGeneration,
      prefetch: prefetch ?? this.prefetch,
      playback: playback ?? this.playback,
      cache: cache ?? this.cache,
      jobs: jobs ?? this.jobs,
      retry: retry ?? this.retry,
      observability: observability ?? this.observability,
    );
  }

  Map<String, dynamic> toJson({bool redactSecrets = false}) => {
    'schema_version': schemaVersion,
    'feature_enabled': featureEnabled,
    'storage': storage.toJson(),
    'text_analysis': textAnalysis.toJson(redactSecrets: redactSecrets),
    'text_analysis_models': textAnalysisModels
        .map((m) => m.toJson(redactSecrets: redactSecrets))
        .toList(),
    'primary_text_model_id': primaryTextModelId,
    'fallback_text_model_id': fallbackTextModelId,
    'text_failover_threshold': textFailoverThreshold,
    'tts': tts.toJson(redactSecrets: redactSecrets),
    'book_defaults': bookDefaults.toJson(),
    'analysis_pipeline': analysisPipeline.toJson(),
    'audio_generation': audioGeneration.toJson(),
    'prefetch': prefetch.toJson(),
    'playback': playback.toJson(),
    'cache': cache.toJson(),
    'jobs': jobs.toJson(),
    'retry': retry.toJson(),
    'observability': observability.toJson(),
  };

  /// 脱敏配置摘要（可安全展示在 UI 与诊断日志中）
  Map<String, dynamic> toRedactedSummary() => {
    'schema_version': schemaVersion,
    'feature_enabled': featureEnabled,
    'text_model': primaryTextModel.modelId,
    'text_model_count': textAnalysisModels.length,
    'enabled_text_model_count': enabledTextModels.length,
    'fallback_text_model': fallbackTextModel?.modelId,
    'text_concurrency': primaryTextModel.maxConcurrency,
    'structured_output_mode': primaryTextModel.structuredOutput.mode,
    'tts_provider_count': tts.providers.length,
    'tts_model_count': tts.providers.fold<int>(
      0,
      (sum, p) => sum + p.models.length,
    ),
    'tts_voice_count': voiceProfileIndex.length,
    'enabled_tts_voice_count': allEnabledVoiceProfiles.length,
    'narrator_voice_profile_id': bookDefaults.narratorVoiceProfileId,
    'selected_voice_count': bookDefaults.selectedVoiceProfileIds.length,
    'max_prefix_backtrack_chapters': analysisPipeline.maxPrefixBacktrackChapters,
    'snapshot_hash': configSnapshotHash().substring(0, 12),
  };
}

/// 配置解析与校验结果
class ConfigLoadResult {
  final ImmersiveConfig? config;
  final List<ConfigValidationIssue> issues;

  const ConfigLoadResult({required this.config, required this.issues});

  bool get isValid => config != null && issues.isEmpty;
}

/// 沉浸式配置严格加载器与完整 Schema 校验器
class ImmersiveConfigValidator {
  static const supportedSchemaVersion = 1;
  static const registeredVendorStructuredAdapters = <String>{
    'openai_tool_call_schema',
  };

  static const _rootKeys = <String>{
    'schema_version',
    'feature_enabled',
    'storage',
    'text_analysis',
    'tts',
    'book_defaults',
    'analysis_pipeline',
    'audio_generation',
    'prefetch',
    'playback',
    'cache',
    'jobs',
    'retry',
    'observability',
  };

  /// 从 JSON 文本严格解析并校验完整配置
  static ConfigLoadResult parseAndValidateJson(
    String rawJson, {
    Map<String, String>? environment,
  }) {
    final Object? decoded;
    try {
      decoded = StrictJsonDecoder.decode(rawJson);
    } on StrictJsonException catch (e) {
      return ConfigLoadResult(
        config: null,
        issues: [ConfigValidationIssue(r'$', e.message)],
      );
    } on FormatException catch (e) {
      return ConfigLoadResult(
        config: null,
        issues: [ConfigValidationIssue(r'$', 'JSON 格式错误：${e.message}')],
      );
    }
    return parseAndValidateMap(decoded, environment: environment);
  }

  /// 从已解码对象校验并构建不可变配置快照
  static ConfigLoadResult parseAndValidateMap(
    Object? raw, {
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final issues = <ConfigValidationIssue>[];
    if (raw is! Map) {
      return const ConfigLoadResult(
        config: null,
        issues: [ConfigValidationIssue(r'$', '配置根节点必须为 JSON 对象')],
      );
    }
    final root = Map<String, dynamic>.from(raw);
    _checkUnknownAndMissingKeys(
      root,
      _rootKeys,
      '',
      issues,
      optionalKeys: const {
        'text_analysis_models',
        'primary_text_model_id',
        'fallback_text_model_id',
        'text_failover_threshold',
      },
    );

    final schemaVersion = _reqInt(root, 'schema_version', 'schema_version', issues);
    if (schemaVersion != null && schemaVersion != supportedSchemaVersion) {
      issues.add(
        ConfigValidationIssue(
          'schema_version',
          '不支持的配置版本 $schemaVersion，当前仅支持版本 $supportedSchemaVersion，请先迁移配置',
        ),
      );
    }
    final featureEnabled =
        _reqBool(root, 'feature_enabled', 'feature_enabled', issues) ?? false;

    final storage = _parseStorage(root['storage'], issues);
    final textAnalysis = _parseTextAnalysis(root['text_analysis'], issues);
    List<TextAnalysisConfig>? textModels;
    if (root.containsKey('text_analysis_models') &&
        root['text_analysis_models'] != null) {
      final rawModels = root['text_analysis_models'];
      if (rawModels is! List) {
        issues.add(
          const ConfigValidationIssue('text_analysis_models', '必须为模型配置数组'),
        );
      } else {
        final parsed = <TextAnalysisConfig>[];
        for (var i = 0; i < rawModels.length; i++) {
          final m = _parseTextAnalysis(
            rawModels[i],
            issues,
            pathPrefix: 'text_analysis_models[$i]',
          );
          if (m != null) parsed.add(m);
        }
        textModels = parsed;
      }
    }
    final primaryTextModelId = _optString(
      root,
      'primary_text_model_id',
      'primary_text_model_id',
      issues,
    );
    final fallbackTextModelId = _optString(
      root,
      'fallback_text_model_id',
      'fallback_text_model_id',
      issues,
    );
    final failoverThreshold =
        _optInt(
          root,
          'text_failover_threshold',
          'text_failover_threshold',
          issues,
          min: 1,
        ) ??
        2;
    final tts = _parseTts(root['tts'], issues);
    final bookDefaults = _parseBookDefaults(root['book_defaults'], issues);
    final pipeline = _parsePipeline(root['analysis_pipeline'], issues);
    final audioGen = _parseAudioGen(root['audio_generation'], issues);
    final prefetch = _parsePrefetch(root['prefetch'], issues);
    final playback = _parsePlayback(root['playback'], issues);
    final cache = _parseCache(root['cache'], issues);
    final jobs = _parseJobs(root['jobs'], issues);
    final retry = _parseRetry(root['retry'], issues);
    final observability = _parseObservability(root['observability'], issues);

    if (storage == null ||
        textAnalysis == null ||
        tts == null ||
        bookDefaults == null ||
        pipeline == null ||
        audioGen == null ||
        prefetch == null ||
        playback == null ||
        cache == null ||
        jobs == null ||
        retry == null ||
        observability == null) {
      return ConfigLoadResult(config: null, issues: issues);
    }

    final config = ImmersiveConfig(
      schemaVersion: schemaVersion ?? supportedSchemaVersion,
      featureEnabled: featureEnabled,
      storage: storage,
      textAnalysis: textAnalysis,
      textAnalysisModels: textModels,
      primaryTextModelId: primaryTextModelId,
      fallbackTextModelId: fallbackTextModelId,
      textFailoverThreshold: failoverThreshold,
      tts: tts,
      bookDefaults: bookDefaults,
      analysisPipeline: pipeline,
      audioGeneration: audioGen,
      prefetch: prefetch,
      playback: playback,
      cache: cache,
      jobs: jobs,
      retry: retry,
      observability: observability,
    );

    _validateCrossFieldRules(config, env, issues);
    return ConfigLoadResult(
      config: issues.isEmpty ? config : null,
      issues: issues,
    );
  }

  /// 对已构建的配置对象直接执行完整规则校验（用于 UI 保存前）
  static List<ConfigValidationIssue> validateConfig(
    ImmersiveConfig config, {
    Map<String, String>? environment,
  }) {
    final res = parseAndValidateMap(config.toJson(), environment: environment);
    return res.issues;
  }

  /// 解析供应商密钥（api_key_env 优先且缺失不回退明文）
  static String resolveApiKey({
    required String? apiKey,
    required String? apiKeyEnv,
    required String fieldPath,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    if (apiKeyEnv != null && apiKeyEnv.trim().isNotEmpty) {
      final envName = apiKeyEnv.trim();
      final val = env[envName];
      if (val == null || val.trim().isEmpty) {
        throw FormatException('$fieldPath.api_key_env 指向的环境变量 $envName 缺失或为空');
      }
      return val.trim();
    }
    return (apiKey ?? '').trim();
  }

  static void _validateCrossFieldRules(
    ImmersiveConfig config,
    Map<String, String> env,
    List<ConfigValidationIssue> issues,
  ) {
    // 1. 文本分析多模型并发、唯一性与保留席位校验
    final seenTextIds = <String>{};
    for (var i = 0; i < config.textAnalysisModels.length; i++) {
      final tm = config.textAnalysisModels[i];
      final prefix = config.textAnalysisModels.length == 1
          ? 'text_analysis'
          : 'text_analysis_models[$i]';
      if (!seenTextIds.add(tm.effectiveId)) {
        issues.add(
          ConfigValidationIssue(
            '$prefix.id',
            '重复的文本模型标识：${tm.effectiveId}',
          ),
        );
      }
      if (tm.reservedReconciliationSlots >= tm.maxConcurrency) {
        issues.add(
          ConfigValidationIssue(
            '$prefix.reserved_reconciliation_slots',
            '保留复核席位必须严格小于 max_concurrency（当并发为 1 时必须设为 0）',
          ),
        );
      }
      if (tm.maxOutputTokens >= tm.contextWindowTokens) {
        issues.add(
          ConfigValidationIssue(
            '$prefix.max_output_tokens',
            'max_output_tokens 必须小于 context_window_tokens',
          ),
        );
      }
      if (tm.structuredOutput.mode == 'vendor_native') {
        final vid = tm.structuredOutput.vendorAdapterId;
        if (vid == null || !registeredVendorStructuredAdapters.contains(vid)) {
          issues.add(
            ConfigValidationIssue(
              '$prefix.structured_output.vendor_adapter_id',
              'vendor_native 模式必须指向已注册适配器（当前支持：${registeredVendorStructuredAdapters.join(', ')}）',
            ),
          );
        }
      }
    }

    // 2. 分块与缓冲范围校验
    final ap = config.analysisPipeline;
    if (ap.targetChunkTokens > ap.maxChunkTokens) {
      issues.add(
        const ConfigValidationIssue(
          'analysis_pipeline.target_chunk_tokens',
          'target_chunk_tokens 不能大于 max_chunk_tokens',
        ),
      );
    }
    final ag = config.audioGeneration;
    if (ag.startupTargetCharacters > ag.maxCharacters ||
        ag.targetCharacters > ag.maxCharacters) {
      issues.add(
        const ConfigValidationIssue(
          'audio_generation.max_characters',
          'startup_target_characters 和 target_characters 不能大于 max_characters',
        ),
      );
    }
    final pf = config.prefetch;
    if (!(pf.lowWaterSeconds < pf.targetBufferSeconds &&
        pf.targetBufferSeconds <= pf.highWaterSeconds)) {
      issues.add(
        const ConfigValidationIssue(
          'prefetch',
          '必须满足 0 < low_water_seconds < target_buffer_seconds <= high_water_seconds',
        ),
      );
    }
    if (pf.startupBufferSeconds > pf.highWaterSeconds) {
      issues.add(
        const ConfigValidationIssue(
          'prefetch.startup_buffer_seconds',
          'startup_buffer_seconds 不能超过 high_water_seconds',
        ),
      );
    }
    if (pf.resumeBufferSeconds > pf.highWaterSeconds) {
      issues.add(
        const ConfigValidationIssue(
          'prefetch.resume_buffer_seconds',
          'resume_buffer_seconds 不能超过 high_water_seconds',
        ),
      );
    }
    if (config.jobs.heartbeatSeconds >= config.jobs.leaseSeconds) {
      issues.add(
        const ConfigValidationIssue(
          'jobs.heartbeat_seconds',
          'heartbeat_seconds 必须严格小于 lease_seconds',
        ),
      );
    }
    if (config.retry.initialBackoffMs > config.retry.maxBackoffMs) {
      issues.add(
        const ConfigValidationIssue(
          'retry.initial_backoff_ms',
          'initial_backoff_ms 不能大于 max_backoff_ms',
        ),
      );
    }

    // 3. 供应商、模型、音色唯一性（大小写敏感精确比较）
    final providerIds = <String>{};
    final voiceProfileIds = <String>{};
    for (var pi = 0; pi < config.tts.providers.length; pi++) {
      final p = config.tts.providers[pi];
      final pPath = 'tts.providers[$pi]';
      if (!providerIds.add(p.providerId)) {
        issues.add(
          ConfigValidationIssue(
            '$pPath.provider_id',
            '重复的 provider_id：${p.providerId}',
          ),
        );
      }
      if (p.reservedForegroundSlots >= p.maxConcurrency) {
        issues.add(
          ConfigValidationIssue(
            '$pPath.reserved_foreground_slots',
            'reserved_foreground_slots 必须严格小于供应商 max_concurrency',
          ),
        );
      }
      final modelKeys = <String>{};
      for (var mi = 0; mi < p.models.length; mi++) {
        final m = p.models[mi];
        final mPath = '$pPath.models[$mi]';
        if (!modelKeys.add(m.modelKey)) {
          issues.add(
            ConfigValidationIssue(
              '$mPath.model_key',
              '同供应商内重复的 model_key：${m.modelKey}',
            ),
          );
        }
        if (m.capabilities.inputLengthUnit == 'tokens') {
          issues.add(
            ConfigValidationIssue(
              '$mPath.capabilities.input_length_unit',
              '当前适配器未提供精确 tokenizer 计数器，请使用 unicode_codepoints 或 utf8_bytes',
            ),
          );
        }
        for (var vi = 0; vi < m.voices.length; vi++) {
          final v = m.voices[vi];
          final vPath = '$mPath.voices[$vi]';
          if (!voiceProfileIds.add(v.voiceProfileId)) {
            issues.add(
              ConfigValidationIssue(
                '$vPath.voice_profile_id',
                '重复的 voice_profile_id：${v.voiceProfileId}',
              ),
            );
          }
          if (!m.capabilities.supportedAudioFormats.contains(
            v.renderSettings.audioFormat,
          )) {
            issues.add(
              ConfigValidationIssue(
                '$vPath.render_settings.audio_format',
                'audio_format (${v.renderSettings.audioFormat}) 不在模型支持列表 ${m.capabilities.supportedAudioFormats} 中',
              ),
            );
          }
          if (!m.capabilities.supportsInstructions &&
              v.renderSettings.instructions != null &&
              v.renderSettings.instructions!.trim().isNotEmpty) {
            issues.add(
              ConfigValidationIssue(
                '$vPath.render_settings.instructions',
                '当前模型不支持 instructions，请将 instructions 设为 null',
              ),
            );
          }
          if (!m.capabilities.supportsSpeed &&
              (v.renderSettings.speed - 1.0).abs() > 1e-6) {
            issues.add(
              ConfigValidationIssue(
                '$vPath.render_settings.speed',
                '当前模型不支持自定义合成语速，请将 speed 设为 1.0 并使用本地播放倍速',
              ),
            );
          }
        }
      }
    }

    // 4. book_defaults 引用检查（允许历史或全局默认指向已删除/禁用的音色，运行期自动按性别兜底；仅校验占位与至少存在可用音色）
    final bd = config.bookDefaults;
    final narrator = config.resolveVoiceProfile(bd.narratorVoiceProfileId);
    final hasAnyEnabledVoice = config.allEnabledVoiceProfiles.isNotEmpty;
    if (narrator == null && !hasAnyEnabledVoice) {
      issues.add(
        ConfigValidationIssue(
          'book_defaults.narrator_voice_profile_id',
          '引用的旁白音色不存在且当前无可用启用音色：${bd.narratorVoiceProfileId}',
        ),
      );
    }
    final activeVoiceResolutions = <VoiceProfileResolution>[
      if (narrator != null && narrator.isEffectivelyEnabled) narrator,
    ];
    for (var i = 0; i < bd.selectedVoiceProfileIds.length; i++) {
      final id = bd.selectedVoiceProfileIds[i];
      final res = config.resolveVoiceProfile(id);
      if (res != null && res.isEffectivelyEnabled) {
        activeVoiceResolutions.add(res);
      }
    }
    if (activeVoiceResolutions.isEmpty && hasAnyEnabledVoice) {
      activeVoiceResolutions.addAll(config.allEnabledVoiceProfiles);
    }

    // 5. 当 feature_enabled=true 时校验活动资源的占位值与环境变量密钥
    if (config.featureEnabled) {
      final enabledTexts = config.enabledTextModels;
      if (enabledTexts.isEmpty) {
        issues.add(
          const ConfigValidationIssue(
            'text_analysis_models',
            '启用沉浸式听书时至少需要启用 1 个文本分析模型',
          ),
        );
      }
      for (var i = 0; i < enabledTexts.length; i++) {
        final tm = enabledTexts[i];
        _checkActiveEndpointAndKey(
          baseUrl: tm.baseUrl,
          apiKey: tm.apiKey,
          apiKeyEnv: tm.apiKeyEnv,
          modelId: tm.modelId,
          fieldPrefix: enabledTexts.length == 1
              ? 'text_analysis'
              : 'text_analysis_models[${tm.effectiveId}]',
          env: env,
          issues: issues,
        );
      }

      if (!hasAnyEnabledVoice) {
        issues.add(
          const ConfigValidationIssue(
            'tts.providers',
            '启用沉浸式听书时至少需要启用 1 个 TTS 音色',
          ),
        );
      }

      final checkedProviders = <String>{};
      for (final res in activeVoiceResolutions) {
        if (isTemplatePlaceholderValue(res.model.modelId)) {
          issues.add(
            ConfigValidationIssue(
              'tts.${res.provider.providerId}.${res.model.modelKey}.model_id',
              '启用功能时活动模型不能包含模板占位值 ${res.model.modelId}',
            ),
          );
        }
        if (isTemplatePlaceholderValue(res.voice.voiceId)) {
          issues.add(
            ConfigValidationIssue(
              'tts.${res.provider.providerId}.${res.voice.voiceProfileId}.voice_id',
              '启用功能时活动音色不能包含模板占位值 ${res.voice.voiceId}',
            ),
          );
        }
        if (checkedProviders.add(res.provider.providerId) &&
            res.provider.adapter != 'native_tts') {
          _checkActiveEndpointAndKey(
            baseUrl: res.provider.baseUrl,
            apiKey: res.provider.apiKey,
            apiKeyEnv: res.provider.apiKeyEnv,
            modelId: null,
            fieldPrefix: 'tts.${res.provider.providerId}',
            env: env,
            issues: issues,
          );
        }
      }
    }
  }

  static void _checkActiveEndpointAndKey({
    required String baseUrl,
    required String? apiKey,
    required String? apiKeyEnv,
    required String? modelId,
    required String fieldPrefix,
    required Map<String, String> env,
    required List<ConfigValidationIssue> issues,
  }) {
    if (isExampleReservedEndpoint(baseUrl) ||
        isTemplatePlaceholderValue(baseUrl)) {
      issues.add(
        ConfigValidationIssue(
          '$fieldPrefix.base_url',
          '功能启用时不能使用示例保留域名或占位端点：$baseUrl',
        ),
      );
    }
    if (modelId != null && isTemplatePlaceholderValue(modelId)) {
      issues.add(
        ConfigValidationIssue(
          '$fieldPrefix.model_id',
          '功能启用时模型 ID 不能为占位值：$modelId',
        ),
      );
    }
    if (apiKeyEnv != null && apiKeyEnv.trim().isNotEmpty) {
      final val = env[apiKeyEnv.trim()];
      if (val == null || val.trim().isEmpty) {
        issues.add(
          ConfigValidationIssue(
            '$fieldPrefix.api_key_env',
            '环境变量 ${apiKeyEnv.trim()} 未设置或为空（不回退明文 api_key）',
          ),
        );
      } else if (isTemplatePlaceholderValue(val)) {
        issues.add(
          ConfigValidationIssue(
            '$fieldPrefix.api_key_env',
            '环境变量 ${apiKeyEnv.trim()} 包含占位值',
          ),
        );
      }
    } else if (isTemplatePlaceholderValue(apiKey)) {
      issues.add(
        ConfigValidationIssue(
          '$fieldPrefix.api_key',
          '功能启用时不能使用模板占位密钥，请填写真实 API Key',
        ),
      );
    }
  }

  static StorageConfig? _parseStorage(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'storage', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {'state_store', 'database_path', 'audio_cache_dir', 'temp_dir'},
      'storage',
      issues,
    );
    final store = _reqEnum(
      map,
      'state_store',
      'storage.state_store',
      const {'sqlite'},
      issues,
    );
    final db = _reqNonEmptyString(
      map,
      'database_path',
      'storage.database_path',
      issues,
    );
    final audio = _reqNonEmptyString(
      map,
      'audio_cache_dir',
      'storage.audio_cache_dir',
      issues,
    );
    final tmp = _reqNonEmptyString(map, 'temp_dir', 'storage.temp_dir', issues);
    if (store == null || db == null || audio == null || tmp == null) {
      return null;
    }
    return StorageConfig(
      stateStore: store,
      databasePath: db,
      audioCacheDir: audio,
      tempDir: tmp,
    );
  }

  static TextAnalysisConfig? _parseTextAnalysis(
    Object? raw,
    List<ConfigValidationIssue> issues, {
    String pathPrefix = 'text_analysis',
  }) {
    final map = _reqMap(raw, pathPrefix, issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'provider_id',
        'display_name',
        'adapter',
        'base_url',
        'endpoint',
        'api_key',
        'api_key_env',
        'model_id',
        'extra_headers',
        'extra_body',
        'request_timeout_ms',
        'max_concurrency',
        'reserved_reconciliation_slots',
        'requests_per_minute',
        'tokens_per_minute',
        'context_window_tokens',
        'max_output_tokens',
        'output_limit_parameter',
        'temperature',
        'structured_output',
      },
      pathPrefix,
      issues,
      optionalKeys: const {'id', 'enabled', 'thinking_level'},
    );
    final entryId = _optString(map, 'id', '$pathPrefix.id', issues);
    final enabledVal = map.containsKey('enabled')
        ? (_reqBool(map, 'enabled', '$pathPrefix.enabled', issues) ?? true)
        : true;
    final thinkingLevel = map.containsKey('thinking_level') &&
            map['thinking_level'] != null
        ? (_reqEnum(
              map,
              'thinking_level',
              '$pathPrefix.thinking_level',
              TextThinkingLevel.values,
              issues,
            ) ??
            TextThinkingLevel.auto)
        : TextThinkingLevel.auto;
    final pid = _reqNonEmptyString(
      map,
      'provider_id',
      '$pathPrefix.provider_id',
      issues,
    );
    final name = _reqNonEmptyString(
      map,
      'display_name',
      '$pathPrefix.display_name',
      issues,
    );
    final adapter = _reqEnum(
      map,
      'adapter',
      '$pathPrefix.adapter',
      const {'openai_chat_completions'},
      issues,
    );
    final baseUrl = _reqNonEmptyString(
      map,
      'base_url',
      '$pathPrefix.base_url',
      issues,
    );
    final endpoint = _reqNonEmptyString(
      map,
      'endpoint',
      '$pathPrefix.endpoint',
      issues,
    );
    if (baseUrl != null && endpoint != null) {
      try {
        joinProviderUrl(baseUrl, endpoint);
      } on FormatException catch (e) {
        issues.add(ConfigValidationIssue('$pathPrefix.base_url', e.message));
      }
    }
    final apiKey = _optString(map, 'api_key', '$pathPrefix.api_key', issues);
    final apiKeyEnv = _optEnvName(
      map,
      'api_key_env',
      '$pathPrefix.api_key_env',
      issues,
    );
    final modelId = _reqNonEmptyString(
      map,
      'model_id',
      '$pathPrefix.model_id',
      issues,
    );
    final headers = _reqStringMap(
      map['extra_headers'],
      '$pathPrefix.extra_headers',
      issues,
      forbiddenKeysLower: ProtectedProtocolFields.headersLower,
    );
    final body = _reqJsonObject(
      map['extra_body'],
      '$pathPrefix.extra_body',
      issues,
      forbiddenKeys: ProtectedProtocolFields.textBody,
    );
    final timeout = _reqInt(
      map,
      'request_timeout_ms',
      '$pathPrefix.request_timeout_ms',
      issues,
      min: 1000,
    );
    final conc = _reqInt(
      map,
      'max_concurrency',
      '$pathPrefix.max_concurrency',
      issues,
      min: 1,
      max: 32,
    );
    final reserved = _reqInt(
      map,
      'reserved_reconciliation_slots',
      '$pathPrefix.reserved_reconciliation_slots',
      issues,
      min: 0,
      max: 31,
    );
    final rpm = _optInt(
      map,
      'requests_per_minute',
      '$pathPrefix.requests_per_minute',
      issues,
      min: 1,
    );
    final tpm = _optInt(
      map,
      'tokens_per_minute',
      '$pathPrefix.tokens_per_minute',
      issues,
      min: 1,
    );
    final ctx = _reqInt(
      map,
      'context_window_tokens',
      '$pathPrefix.context_window_tokens',
      issues,
      min: 1024,
    );
    final maxOut = _reqInt(
      map,
      'max_output_tokens',
      '$pathPrefix.max_output_tokens',
      issues,
      min: 128,
    );
    final outParam = _reqEnum(
      map,
      'output_limit_parameter',
      '$pathPrefix.output_limit_parameter',
      const {'max_completion_tokens', 'max_tokens'},
      issues,
    );
    final temp = _optDouble(
      map,
      'temperature',
      '$pathPrefix.temperature',
      issues,
      min: 0,
      max: 2,
    );

    final soMap = _reqMap(
      map['structured_output'],
      '$pathPrefix.structured_output',
      issues,
    );
    StructuredOutputConfig? so;
    if (soMap != null) {
      _checkUnknownAndMissingKeys(
        soMap,
        const {
          'mode',
          'schema_name_prefix',
          'strict',
          'vendor_adapter_id',
          'allow_prompt_only_fallback',
        },
        '$pathPrefix.structured_output',
        issues,
      );
      final mode = _reqEnum(
        soMap,
        'mode',
        '$pathPrefix.structured_output.mode',
        const {'json_schema', 'vendor_native'},
        issues,
      );
      final prefix = _reqNonEmptyString(
        soMap,
        'schema_name_prefix',
        '$pathPrefix.structured_output.schema_name_prefix',
        issues,
      );
      if (prefix != null && !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(prefix)) {
        issues.add(
          ConfigValidationIssue(
            '$pathPrefix.structured_output.schema_name_prefix',
            'schema_name_prefix 只能包含字母、数字、下划线或连字符',
          ),
        );
      }
      final strict = _reqBool(
        soMap,
        'strict',
        '$pathPrefix.structured_output.strict',
        issues,
      );
      final vid = _optString(
        soMap,
        'vendor_adapter_id',
        '$pathPrefix.structured_output.vendor_adapter_id',
        issues,
      );
      final fallback = _reqBool(
        soMap,
        'allow_prompt_only_fallback',
        '$pathPrefix.structured_output.allow_prompt_only_fallback',
        issues,
      );
      if (fallback == true) {
        issues.add(
          ConfigValidationIssue(
            '$pathPrefix.structured_output.allow_prompt_only_fallback',
            '严禁开启提示词 JSON 兜底，allow_prompt_only_fallback 必须为 false',
          ),
        );
      }
      if (mode != null &&
          prefix != null &&
          strict != null &&
          fallback != null) {
        so = StructuredOutputConfig(
          mode: mode,
          schemaNamePrefix: prefix,
          strict: strict,
          vendorAdapterId: vid,
          allowPromptOnlyFallback: fallback,
        );
      }
    }

    if (pid == null ||
        name == null ||
        adapter == null ||
        baseUrl == null ||
        endpoint == null ||
        modelId == null ||
        headers == null ||
        body == null ||
        timeout == null ||
        conc == null ||
        reserved == null ||
        ctx == null ||
        maxOut == null ||
        outParam == null ||
        so == null) {
      return null;
    }

    return TextAnalysisConfig(
      id: entryId,
      providerId: pid,
      displayName: name,
      enabled: enabledVal,
      adapter: adapter,
      baseUrl: baseUrl,
      endpoint: endpoint,
      apiKey: apiKey,
      apiKeyEnv: apiKeyEnv,
      modelId: modelId,
      thinkingLevel: thinkingLevel,
      extraHeaders: headers,
      extraBody: body,
      requestTimeoutMs: timeout,
      maxConcurrency: conc,
      reservedReconciliationSlots: reserved,
      requestsPerMinute: rpm,
      tokensPerMinute: tpm,
      contextWindowTokens: ctx,
      maxOutputTokens: maxOut,
      outputLimitParameter: outParam,
      temperature: temp,
      structuredOutput: so,
    );
  }

  static TtsConfig? _parseTts(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'tts', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {'global_max_concurrency', 'max_pending_jobs', 'providers'},
      'tts',
      issues,
    );
    final globalConc = _reqInt(
      map,
      'global_max_concurrency',
      'tts.global_max_concurrency',
      issues,
      min: 1,
      max: 64,
    );
    final maxPending = _reqInt(
      map,
      'max_pending_jobs',
      'tts.max_pending_jobs',
      issues,
      min: 1,
      max: 1024,
    );
    final rawProviders = map['providers'];
    if (rawProviders is! List) {
      issues.add(const ConfigValidationIssue('tts.providers', '必须为数组'));
      return null;
    }
    final providers = <TtsProviderConfig>[];
    for (var i = 0; i < rawProviders.length; i++) {
      final p = _parseTtsProvider(rawProviders[i], 'tts.providers[$i]', issues);
      if (p != null) providers.add(p);
    }
    if (globalConc == null || maxPending == null) return null;
    return TtsConfig(
      globalMaxConcurrency: globalConc,
      maxPendingJobs: maxPending,
      providers: providers,
    );
  }

  static TtsProviderConfig? _parseTtsProvider(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, path, issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'provider_id',
        'display_name',
        'enabled',
        'adapter',
        'base_url',
        'endpoint',
        'api_key',
        'api_key_env',
        'extra_headers',
        'request_timeout_ms',
        'max_concurrency',
        'reserved_foreground_slots',
        'requests_per_minute',
        'models',
      },
      path,
      issues,
    );
    final pid = _reqNonEmptyString(
      map,
      'provider_id',
      '$path.provider_id',
      issues,
    );
    final name = _reqNonEmptyString(
      map,
      'display_name',
      '$path.display_name',
      issues,
    );
    final enabled = _reqBool(map, 'enabled', '$path.enabled', issues);
    final adapter = _reqEnum(
      map,
      'adapter',
      '$path.adapter',
      const {'openai_speech', 'native_tts'},
      issues,
    );
    final baseUrl = _reqNonEmptyString(map, 'base_url', '$path.base_url', issues);
    final endpoint = _reqNonEmptyString(
      map,
      'endpoint',
      '$path.endpoint',
      issues,
    );
    if (baseUrl != null && endpoint != null) {
      try {
        joinProviderUrl(baseUrl, endpoint);
      } on FormatException catch (e) {
        issues.add(ConfigValidationIssue('$path.base_url', e.message));
      }
    }
    final apiKey = _optString(map, 'api_key', '$path.api_key', issues);
    final apiKeyEnv = _optEnvName(
      map,
      'api_key_env',
      '$path.api_key_env',
      issues,
    );
    final headers = _reqStringMap(
      map['extra_headers'],
      '$path.extra_headers',
      issues,
      forbiddenKeysLower: ProtectedProtocolFields.headersLower,
    );
    final timeout = _reqInt(
      map,
      'request_timeout_ms',
      '$path.request_timeout_ms',
      issues,
      min: 1000,
    );
    final conc = _reqInt(
      map,
      'max_concurrency',
      '$path.max_concurrency',
      issues,
      min: 1,
      max: 64,
    );
    final reserved = _reqInt(
      map,
      'reserved_foreground_slots',
      '$path.reserved_foreground_slots',
      issues,
      min: 0,
      max: 63,
    );
    final rpm = _optInt(
      map,
      'requests_per_minute',
      '$path.requests_per_minute',
      issues,
      min: 1,
    );
    final rawModels = map['models'];
    if (rawModels is! List) {
      issues.add(ConfigValidationIssue('$path.models', '必须为数组'));
      return null;
    }
    final models = <TtsModelConfig>[];
    for (var i = 0; i < rawModels.length; i++) {
      final m = _parseTtsModel(rawModels[i], '$path.models[$i]', issues);
      if (m != null) models.add(m);
    }
    if (pid == null ||
        name == null ||
        enabled == null ||
        adapter == null ||
        baseUrl == null ||
        endpoint == null ||
        headers == null ||
        timeout == null ||
        conc == null ||
        reserved == null) {
      return null;
    }
    return TtsProviderConfig(
      providerId: pid,
      displayName: name,
      enabled: enabled,
      adapter: adapter,
      baseUrl: baseUrl,
      endpoint: endpoint,
      apiKey: apiKey,
      apiKeyEnv: apiKeyEnv,
      extraHeaders: headers,
      requestTimeoutMs: timeout,
      maxConcurrency: conc,
      reservedForegroundSlots: reserved,
      requestsPerMinute: rpm,
      models: models,
    );
  }

  static TtsModelConfig? _parseTtsModel(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, path, issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'model_key',
        'model_id',
        'display_name',
        'enabled',
        'max_concurrency',
        'capabilities',
        'extra_body',
        'voices',
      },
      path,
      issues,
    );
    final modelKey = _reqNonEmptyString(
      map,
      'model_key',
      '$path.model_key',
      issues,
    );
    final modelId = _reqNonEmptyString(map, 'model_id', '$path.model_id', issues);
    final name = _reqNonEmptyString(
      map,
      'display_name',
      '$path.display_name',
      issues,
    );
    final enabled = _reqBool(map, 'enabled', '$path.enabled', issues);
    final conc = _reqInt(
      map,
      'max_concurrency',
      '$path.max_concurrency',
      issues,
      min: 1,
      max: 64,
    );
    final extraBody = _reqJsonObject(
      map['extra_body'],
      '$path.extra_body',
      issues,
      forbiddenKeys: ProtectedProtocolFields.ttsBody,
    );
    final capsMap = _reqMap(map['capabilities'], '$path.capabilities', issues);
    TtsModelCapabilities? caps;
    if (capsMap != null) {
      _checkUnknownAndMissingKeys(
        capsMap,
        const {
          'max_input_length',
          'input_length_unit',
          'supports_instructions',
          'supports_speed',
          'supported_audio_formats',
          'response_transport',
          'supports_word_timestamps',
        },
        '$path.capabilities',
        issues,
      );
      final maxLen = _reqInt(
        capsMap,
        'max_input_length',
        '$path.capabilities.max_input_length',
        issues,
        min: 1,
      );
      final unit = _reqEnum(
        capsMap,
        'input_length_unit',
        '$path.capabilities.input_length_unit',
        const {'unicode_codepoints', 'utf8_bytes', 'tokens'},
        issues,
      );
      final supInst = _reqBool(
        capsMap,
        'supports_instructions',
        '$path.capabilities.supports_instructions',
        issues,
      );
      final supSpd = _reqBool(
        capsMap,
        'supports_speed',
        '$path.capabilities.supports_speed',
        issues,
      );
      final fmts = _reqStringList(
        capsMap['supported_audio_formats'],
        '$path.capabilities.supported_audio_formats',
        issues,
        allowedValues: const {'mp3', 'wav'},
        nonEmpty: true,
      );
      final trans = _reqEnum(
        capsMap,
        'response_transport',
        '$path.capabilities.response_transport',
        const {'binary'},
        issues,
      );
      final wordTs = _reqBool(
        capsMap,
        'supports_word_timestamps',
        '$path.capabilities.supports_word_timestamps',
        issues,
      );
      if (wordTs == true) {
        issues.add(
          ConfigValidationIssue(
            '$path.capabilities.supports_word_timestamps',
            '首版标准 Speech 适配器不提供词级时间戳，supports_word_timestamps 必须为 false',
          ),
        );
      }
      if (maxLen != null &&
          unit != null &&
          supInst != null &&
          supSpd != null &&
          fmts != null &&
          trans != null &&
          wordTs != null) {
        caps = TtsModelCapabilities(
          maxInputLength: maxLen,
          inputLengthUnit: unit,
          supportsInstructions: supInst,
          supportsSpeed: supSpd,
          supportedAudioFormats: fmts,
          responseTransport: trans,
          supportsWordTimestamps: wordTs,
        );
      }
    }

    final rawVoices = map['voices'];
    if (rawVoices is! List) {
      issues.add(ConfigValidationIssue('$path.voices', '必须为数组'));
      return null;
    }
    final voices = <TtsVoiceProfileConfig>[];
    for (var i = 0; i < rawVoices.length; i++) {
      final v = _parseTtsVoice(rawVoices[i], '$path.voices[$i]', issues);
      if (v != null) voices.add(v);
    }

    if (modelKey == null ||
        modelId == null ||
        name == null ||
        enabled == null ||
        conc == null ||
        caps == null ||
        extraBody == null) {
      return null;
    }

    return TtsModelConfig(
      modelKey: modelKey,
      modelId: modelId,
      displayName: name,
      enabled: enabled,
      maxConcurrency: conc,
      capabilities: caps,
      extraBody: extraBody,
      voices: voices,
    );
  }

  static TtsVoiceProfileConfig? _parseTtsVoice(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, path, issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'voice_profile_id',
        'voice_id',
        'display_name',
        'enabled',
        'gender',
        'notes',
        'tags',
        'render_settings',
        'extra_body',
      },
      path,
      issues,
      optionalKeys: const {'sample_asset'},
    );
    final vpid = _reqNonEmptyString(
      map,
      'voice_profile_id',
      '$path.voice_profile_id',
      issues,
    );
    final vid = _reqNonEmptyString(map, 'voice_id', '$path.voice_id', issues);
    final name = _reqNonEmptyString(
      map,
      'display_name',
      '$path.display_name',
      issues,
    );
    final enabled = _reqBool(map, 'enabled', '$path.enabled', issues);
    final gender = _reqEnum(
      map,
      'gender',
      '$path.gender',
      const {'male', 'female', 'neutral', 'unknown'},
      issues,
    );
    final notes = _reqString(map, 'notes', '$path.notes', issues);
    final tags = _reqStringList(map['tags'], '$path.tags', issues);
    final sampleAsset = _optString(
      map,
      'sample_asset',
      '$path.sample_asset',
      issues,
    );
    final extraBody = _reqJsonObject(
      map['extra_body'],
      '$path.extra_body',
      issues,
      forbiddenKeys: ProtectedProtocolFields.ttsBody,
    );
    final rsMap = _reqMap(
      map['render_settings'],
      '$path.render_settings',
      issues,
    );
    VoiceRenderSettings? rs;
    if (rsMap != null) {
      _checkUnknownAndMissingKeys(
        rsMap,
        const {'audio_format', 'speed', 'instructions'},
        '$path.render_settings',
        issues,
      );
      final fmt = _reqEnum(
        rsMap,
        'audio_format',
        '$path.render_settings.audio_format',
        const {'mp3', 'wav'},
        issues,
      );
      final spd = _reqDouble(
        rsMap,
        'speed',
        '$path.render_settings.speed',
        issues,
        min: 0.25,
        max: 4.0,
      );
      final inst = _optString(
        rsMap,
        'instructions',
        '$path.render_settings.instructions',
        issues,
      );
      if (fmt != null && spd != null) {
        rs = VoiceRenderSettings(
          audioFormat: fmt,
          speed: spd,
          instructions: inst,
        );
      }
    }
    if (vpid == null ||
        vid == null ||
        name == null ||
        enabled == null ||
        gender == null ||
        notes == null ||
        tags == null ||
        rs == null ||
        extraBody == null) {
      return null;
    }
    return TtsVoiceProfileConfig(
      voiceProfileId: vpid,
      voiceId: vid,
      displayName: name,
      enabled: enabled,
      gender: gender,
      notes: notes,
      tags: tags,
      sampleAsset: sampleAsset,
      renderSettings: rs,
      extraBody: extraBody,
    );
  }

  static BookDefaultsConfig? _parseBookDefaults(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'book_defaults', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'selected_voice_profile_ids',
        'narrator_voice_profile_id',
        'allow_voice_reuse',
        'reserve_narrator_for_non_dialogue',
        'unknown_gender_policy',
        'known_gender_no_match_policy',
        'unresolved_dialogue_policy',
        'identity_conflict_policy',
        'thought_and_quoted_text_policy',
        'missing_voice_policy',
        'middle_start_policy',
      },
      'book_defaults',
      issues,
    );
    final selected = _reqStringList(
      map['selected_voice_profile_ids'],
      'book_defaults.selected_voice_profile_ids',
      issues,
    );
    final narrator = _reqNonEmptyString(
      map,
      'narrator_voice_profile_id',
      'book_defaults.narrator_voice_profile_id',
      issues,
    );
    final reuse = _reqBool(
      map,
      'allow_voice_reuse',
      'book_defaults.allow_voice_reuse',
      issues,
    );
    final reserveNarrator = _reqBool(
      map,
      'reserve_narrator_for_non_dialogue',
      'book_defaults.reserve_narrator_for_non_dialogue',
      issues,
    );
    final unknownGender = _reqEnum(
      map,
      'unknown_gender_policy',
      'book_defaults.unknown_gender_policy',
      const {'prefer_neutral_then_selected'},
      issues,
    );
    final noMatch = _reqEnum(
      map,
      'known_gender_no_match_policy',
      'book_defaults.known_gender_no_match_policy',
      const {'prefer_neutral_else_require_selection'},
      issues,
    );
    final unresolved = _reqEnum(
      map,
      'unresolved_dialogue_policy',
      'book_defaults.unresolved_dialogue_policy',
      const {'narrator_fallback_after_review'},
      issues,
    );
    final conflict = _reqEnum(
      map,
      'identity_conflict_policy',
      'book_defaults.identity_conflict_policy',
      const {'pause_affected_range'},
      issues,
    );
    final thought = _reqEnum(
      map,
      'thought_and_quoted_text_policy',
      'book_defaults.thought_and_quoted_text_policy',
      const {'narrator'},
      issues,
    );
    final missing = _reqEnum(
      map,
      'missing_voice_policy',
      'book_defaults.missing_voice_policy',
      const {'pause_until_reconfigured'},
      issues,
    );
    final middle = _reqEnum(
      map,
      'middle_start_policy',
      'book_defaults.middle_start_policy',
      const {'build_prefix_identity_first'},
      issues,
    );
    if (selected == null ||
        narrator == null ||
        reuse == null ||
        reserveNarrator == null ||
        unknownGender == null ||
        noMatch == null ||
        unresolved == null ||
        conflict == null ||
        thought == null ||
        missing == null ||
        middle == null) {
      return null;
    }
    return BookDefaultsConfig(
      selectedVoiceProfileIds: selected,
      narratorVoiceProfileId: narrator,
      allowVoiceReuse: reuse,
      reserveNarratorForNonDialogue: reserveNarrator,
      unknownGenderPolicy: unknownGender,
      knownGenderNoMatchPolicy: noMatch,
      unresolvedDialoguePolicy: unresolved,
      identityConflictPolicy: conflict,
      thoughtAndQuotedTextPolicy: thought,
      missingVoicePolicy: missing,
      middleStartPolicy: middle,
    );
  }

  static AnalysisPipelineConfig? _parsePipeline(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'analysis_pipeline', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'ahead_chapters',
        'max_ahead_chunks',
        'max_uncommitted_chunks',
        'target_chunk_tokens',
        'max_chunk_tokens',
        'context_before_tokens',
        'context_after_tokens',
        'recent_dialogue_turns',
        'chapter_summary_max_tokens',
        'character_context_max_tokens',
        'context_safety_margin_ratio',
        'max_identity_rechecks',
        'keep_all_selected_voice_profiles_in_system',
      },
      'analysis_pipeline',
      issues,
      optionalKeys: const {
        'max_prefix_backtrack_chapters',
        'first_chunk_target_tokens',
        'tiered_thinking',
      },
    );
    final ahead = _reqInt(map, 'ahead_chapters', 'analysis_pipeline.ahead_chapters', issues, min: 0, max: 20);
    final maxPrefixBacktrack = map.containsKey('max_prefix_backtrack_chapters')
        ? (_reqInt(
              map,
              'max_prefix_backtrack_chapters',
              'analysis_pipeline.max_prefix_backtrack_chapters',
              issues,
              min: 0,
              max: 50,
            ) ??
            5)
        : 5;
    final firstChunkTok = map.containsKey('first_chunk_target_tokens')
        ? (_reqInt(
              map,
              'first_chunk_target_tokens',
              'analysis_pipeline.first_chunk_target_tokens',
              issues,
              min: 100,
              max: 2500,
            ) ??
            550)
        : 550;
    final tieredThinking = map.containsKey('tiered_thinking')
        ? (_reqBool(
              map,
              'tiered_thinking',
              'analysis_pipeline.tiered_thinking',
              issues,
            ) ??
            true)
        : true;
    final maxAhead = _reqInt(map, 'max_ahead_chunks', 'analysis_pipeline.max_ahead_chunks', issues, min: 1, max: 128);
    final maxUncommitted = _reqInt(map, 'max_uncommitted_chunks', 'analysis_pipeline.max_uncommitted_chunks', issues, min: 1, max: 64);
    final targetTok = _reqInt(map, 'target_chunk_tokens', 'analysis_pipeline.target_chunk_tokens', issues, min: 100);
    final maxTok = _reqInt(map, 'max_chunk_tokens', 'analysis_pipeline.max_chunk_tokens', issues, min: 100);
    final beforeTok = _reqInt(map, 'context_before_tokens', 'analysis_pipeline.context_before_tokens', issues, min: 0);
    final afterTok = _reqInt(map, 'context_after_tokens', 'analysis_pipeline.context_after_tokens', issues, min: 0);
    final recentTurns = _reqInt(map, 'recent_dialogue_turns', 'analysis_pipeline.recent_dialogue_turns', issues, min: 0);
    final summaryTok = _reqInt(map, 'chapter_summary_max_tokens', 'analysis_pipeline.chapter_summary_max_tokens', issues, min: 0);
    final charCtxTok = _reqInt(map, 'character_context_max_tokens', 'analysis_pipeline.character_context_max_tokens', issues, min: 128);
    final safety = _reqDouble(map, 'context_safety_margin_ratio', 'analysis_pipeline.context_safety_margin_ratio', issues, min: 0.01, max: 0.79);
    final rechecks = _reqInt(map, 'max_identity_rechecks', 'analysis_pipeline.max_identity_rechecks', issues, min: 0, max: 10);
    final keepAll = _reqBool(map, 'keep_all_selected_voice_profiles_in_system', 'analysis_pipeline.keep_all_selected_voice_profiles_in_system', issues);
    if (keepAll == false) {
      issues.add(
        const ConfigValidationIssue(
          'analysis_pipeline.keep_all_selected_voice_profiles_in_system',
          '勾选音色目录不允许静默裁剪，必须为 true',
        ),
      );
    }
    if (ahead == null ||
        maxAhead == null ||
        maxUncommitted == null ||
        targetTok == null ||
        maxTok == null ||
        beforeTok == null ||
        afterTok == null ||
        recentTurns == null ||
        summaryTok == null ||
        charCtxTok == null ||
        safety == null ||
        rechecks == null ||
        keepAll == null) {
      return null;
    }
    return AnalysisPipelineConfig(
      aheadChapters: ahead,
      maxPrefixBacktrackChapters: maxPrefixBacktrack,
      maxAheadChunks: maxAhead,
      maxUncommittedChunks: maxUncommitted,
      firstChunkTargetTokens: firstChunkTok,
      targetChunkTokens: targetTok,
      maxChunkTokens: maxTok,
      contextBeforeTokens: beforeTok,
      contextAfterTokens: afterTok,
      recentDialogueTurns: recentTurns,
      chapterSummaryMaxTokens: summaryTok,
      characterContextMaxTokens: charCtxTok,
      contextSafetyMarginRatio: safety,
      maxIdentityRechecks: rechecks,
      keepAllSelectedVoiceProfilesInSystem: keepAll,
      tieredThinking: tieredThinking,
    );
  }

  static AudioGenerationConfig? _parseAudioGen(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'audio_generation', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'startup_target_characters',
        'target_characters',
        'max_characters',
        'initial_estimated_characters_per_second',
        'cross_chapter_merge',
        'transport',
      },
      'audio_generation',
      issues,
    );
    final startChars = _reqInt(map, 'startup_target_characters', 'audio_generation.startup_target_characters', issues, min: 1);
    final targetChars = _reqInt(map, 'target_characters', 'audio_generation.target_characters', issues, min: 1);
    final maxChars = _reqInt(map, 'max_characters', 'audio_generation.max_characters', issues, min: 1);
    final cps = _reqDouble(map, 'initial_estimated_characters_per_second', 'audio_generation.initial_estimated_characters_per_second', issues, min: 0.1);
    final cross = _reqBool(map, 'cross_chapter_merge', 'audio_generation.cross_chapter_merge', issues);
    if (cross == true) {
      issues.add(
        const ConfigValidationIssue(
          'audio_generation.cross_chapter_merge',
          '首版禁止跨章节合并音频片段，cross_chapter_merge 必须为 false',
        ),
      );
    }
    final transport = _reqEnum(map, 'transport', 'audio_generation.transport', const {'complete_file_cache'}, issues);
    if (startChars == null ||
        targetChars == null ||
        maxChars == null ||
        cps == null ||
        cross == null ||
        transport == null) {
      return null;
    }
    return AudioGenerationConfig(
      startupTargetCharacters: startChars,
      targetCharacters: targetChars,
      maxCharacters: maxChars,
      initialEstimatedCharactersPerSecond: cps,
      crossChapterMerge: cross,
      transport: transport,
    );
  }

  static PrefetchConfig? _parsePrefetch(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'prefetch', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'startup_buffer_seconds',
        'startup_wait_after_first_ready_ms',
        'resume_buffer_seconds',
        'low_water_seconds',
        'target_buffer_seconds',
        'high_water_seconds',
        'max_jobs_beyond_first_gap',
        'pause_policy',
        'continue_in_supported_background',
      },
      'prefetch',
      issues,
    );
    final startSec = _reqDouble(map, 'startup_buffer_seconds', 'prefetch.startup_buffer_seconds', issues, min: 0.1);
    final startWait = _reqInt(map, 'startup_wait_after_first_ready_ms', 'prefetch.startup_wait_after_first_ready_ms', issues, min: 0);
    final resumeSec = _reqDouble(map, 'resume_buffer_seconds', 'prefetch.resume_buffer_seconds', issues, min: 0.1);
    final low = _reqDouble(map, 'low_water_seconds', 'prefetch.low_water_seconds', issues, min: 0.1);
    final target = _reqDouble(map, 'target_buffer_seconds', 'prefetch.target_buffer_seconds', issues, min: 0.1);
    final high = _reqDouble(map, 'high_water_seconds', 'prefetch.high_water_seconds', issues, min: 0.1);
    final beyondGap = _reqInt(map, 'max_jobs_beyond_first_gap', 'prefetch.max_jobs_beyond_first_gap', issues, min: 1, max: 64);
    final pausePolicy = _reqEnum(map, 'pause_policy', 'prefetch.pause_policy', const {'finish_inflight_stop_new'}, issues);
    final bg = _reqBool(map, 'continue_in_supported_background', 'prefetch.continue_in_supported_background', issues);
    if (startSec == null ||
        startWait == null ||
        resumeSec == null ||
        low == null ||
        target == null ||
        high == null ||
        beyondGap == null ||
        pausePolicy == null ||
        bg == null) {
      return null;
    }
    return PrefetchConfig(
      startupBufferSeconds: startSec,
      startupWaitAfterFirstReadyMs: startWait,
      resumeBufferSeconds: resumeSec,
      lowWaterSeconds: low,
      targetBufferSeconds: target,
      highWaterSeconds: high,
      maxJobsBeyondFirstGap: beyondGap,
      pausePolicy: pausePolicy,
      continueInSupportedBackground: bg,
    );
  }

  static PlaybackConfig? _parsePlayback(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'playback', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'default_rate',
        'preserve_pitch',
        'highlight_granularity',
        'cursor_save_interval_ms',
        'chapter_auto_advance',
        'gap_policy',
      },
      'playback',
      issues,
      optionalKeys: const {
        'same_speaker_gap_ms',
        'speaker_switch_gap_ms',
        'chapter_switch_gap_ms',
      },
    );
    final rate = _reqDouble(map, 'default_rate', 'playback.default_rate', issues, min: 0.5, max: 2.0);
    final pitch = _reqBool(map, 'preserve_pitch', 'playback.preserve_pitch', issues);
    final hl = _reqEnum(map, 'highlight_granularity', 'playback.highlight_granularity', const {'audio_segment'}, issues);
    final saveMs = _reqInt(map, 'cursor_save_interval_ms', 'playback.cursor_save_interval_ms', issues, min: 100);
    final autoAdv = _reqBool(map, 'chapter_auto_advance', 'playback.chapter_auto_advance', issues);
    final gap = _reqEnum(map, 'gap_policy', 'playback.gap_policy', const {'wait_without_skipping'}, issues);
    final sameGapMs = map.containsKey('same_speaker_gap_ms')
        ? (_reqInt(map, 'same_speaker_gap_ms', 'playback.same_speaker_gap_ms', issues, min: 0, max: 2000) ?? 120)
        : 120;
    final switchGapMs = map.containsKey('speaker_switch_gap_ms')
        ? (_reqInt(map, 'speaker_switch_gap_ms', 'playback.speaker_switch_gap_ms', issues, min: 0, max: 2000) ?? 260)
        : 260;
    final chapterGapMs = map.containsKey('chapter_switch_gap_ms')
        ? (_reqInt(map, 'chapter_switch_gap_ms', 'playback.chapter_switch_gap_ms', issues, min: 0, max: 3000) ?? 480)
        : 480;
    if (rate == null ||
        pitch == null ||
        hl == null ||
        saveMs == null ||
        autoAdv == null ||
        gap == null) {
      return null;
    }
    return PlaybackConfig(
      defaultRate: rate,
      preservePitch: pitch,
      highlightGranularity: hl,
      cursorSaveIntervalMs: saveMs,
      chapterAutoAdvance: autoAdv,
      gapPolicy: gap,
      sameSpeakerGapMs: sameGapMs,
      speakerSwitchGapMs: switchGapMs,
      chapterSwitchGapMs: chapterGapMs,
    );
  }

  static CacheConfig? _parseCache(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'cache', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'max_bytes',
        'evict_to_ratio',
        'min_free_disk_bytes',
        'eviction_policy',
        'protect_recent_playback_seconds',
        'verify_checksum_on_reuse',
        'cleanup_incomplete_files_after_seconds',
      },
      'cache',
      issues,
    );
    final maxB = _reqInt(map, 'max_bytes', 'cache.max_bytes', issues, min: 1048576);
    final ratio = _reqDouble(map, 'evict_to_ratio', 'cache.evict_to_ratio', issues, min: 0.01, max: 0.99);
    final freeB = _reqInt(map, 'min_free_disk_bytes', 'cache.min_free_disk_bytes', issues, min: 0);
    final evict = _reqEnum(map, 'eviction_policy', 'cache.eviction_policy', const {'lru_unpinned'}, issues);
    final protect = _reqInt(map, 'protect_recent_playback_seconds', 'cache.protect_recent_playback_seconds', issues, min: 0);
    final verify = _reqBool(map, 'verify_checksum_on_reuse', 'cache.verify_checksum_on_reuse', issues);
    final cleanup = _reqInt(map, 'cleanup_incomplete_files_after_seconds', 'cache.cleanup_incomplete_files_after_seconds', issues, min: 1);
    if (maxB == null ||
        ratio == null ||
        freeB == null ||
        evict == null ||
        protect == null ||
        verify == null ||
        cleanup == null) {
      return null;
    }
    return CacheConfig(
      maxBytes: maxB,
      evictToRatio: ratio,
      minFreeDiskBytes: freeB,
      evictionPolicy: evict,
      protectRecentPlaybackSeconds: protect,
      verifyChecksumOnReuse: verify,
      cleanupIncompleteFilesAfterSeconds: cleanup,
    );
  }

  static JobsConfig? _parseJobs(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'jobs', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'lease_seconds',
        'heartbeat_seconds',
        'poll_interval_ms',
        'cancel_unneeded_requests_on_seek',
      },
      'jobs',
      issues,
    );
    final lease = _reqInt(map, 'lease_seconds', 'jobs.lease_seconds', issues, min: 5);
    final hb = _reqInt(map, 'heartbeat_seconds', 'jobs.heartbeat_seconds', issues, min: 1);
    final poll = _reqInt(map, 'poll_interval_ms', 'jobs.poll_interval_ms', issues, min: 50);
    final cancel = _reqBool(map, 'cancel_unneeded_requests_on_seek', 'jobs.cancel_unneeded_requests_on_seek', issues);
    if (lease == null || hb == null || poll == null || cancel == null) {
      return null;
    }
    return JobsConfig(
      leaseSeconds: lease,
      heartbeatSeconds: hb,
      pollIntervalMs: poll,
      cancelUnneededRequestsOnSeek: cancel,
    );
  }

  static RetryConfig? _parseRetry(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'retry', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'max_attempts',
        'initial_backoff_ms',
        'max_backoff_ms',
        'jitter_ratio',
        'respect_retry_after',
      },
      'retry',
      issues,
    );
    final maxAtt = _reqInt(map, 'max_attempts', 'retry.max_attempts', issues, min: 1, max: 10);
    final initB = _reqInt(map, 'initial_backoff_ms', 'retry.initial_backoff_ms', issues, min: 50);
    final maxB = _reqInt(map, 'max_backoff_ms', 'retry.max_backoff_ms', issues, min: 50);
    final jitter = _reqDouble(map, 'jitter_ratio', 'retry.jitter_ratio', issues, min: 0, max: 1);
    final ra = _reqBool(map, 'respect_retry_after', 'retry.respect_retry_after', issues);
    if (maxAtt == null ||
        initB == null ||
        maxB == null ||
        jitter == null ||
        ra == null) {
      return null;
    }
    return RetryConfig(
      maxAttempts: maxAtt,
      initialBackoffMs: initB,
      maxBackoffMs: maxB,
      jitterRatio: jitter,
      respectRetryAfter: ra,
    );
  }

  static ObservabilityConfig? _parseObservability(
    Object? raw,
    List<ConfigValidationIssue> issues,
  ) {
    final map = _reqMap(raw, 'observability', issues);
    if (map == null) return null;
    _checkUnknownAndMissingKeys(
      map,
      const {
        'log_level',
        'log_book_text',
        'log_raw_model_responses',
        'retain_debug_payload_days',
        'collect_local_metrics',
      },
      'observability',
      issues,
    );
    final level = _reqEnum(map, 'log_level', 'observability.log_level', const {'debug', 'info', 'warn', 'error'}, issues);
    final logText = _reqBool(map, 'log_book_text', 'observability.log_book_text', issues);
    final logRaw = _reqBool(map, 'log_raw_model_responses', 'observability.log_raw_model_responses', issues);
    final retain = _reqInt(map, 'retain_debug_payload_days', 'observability.retain_debug_payload_days', issues, min: 1);
    final metrics = _reqBool(map, 'collect_local_metrics', 'observability.collect_local_metrics', issues);
    if (level == null ||
        logText == null ||
        logRaw == null ||
        retain == null ||
        metrics == null) {
      return null;
    }
    return ObservabilityConfig(
      logLevel: level,
      logBookText: logText,
      logRawModelResponses: logRaw,
      retainDebugPayloadDays: retain,
      collectLocalMetrics: metrics,
    );
  }

  static void _checkUnknownAndMissingKeys(
    Map<String, dynamic> map,
    Set<String> requiredKeys,
    String prefix,
    List<ConfigValidationIssue> issues, {
    Set<String> optionalKeys = const {},
  }) {
    for (final key in map.keys) {
      if (!requiredKeys.contains(key) && !optionalKeys.contains(key)) {
        final p = prefix.isEmpty ? key : '$prefix.$key';
        issues.add(ConfigValidationIssue(p, '未知配置字段'));
      }
    }
    for (final key in requiredKeys) {
      if (!map.containsKey(key)) {
        final p = prefix.isEmpty ? key : '$prefix.$key';
        issues.add(ConfigValidationIssue(p, '缺少必填字段'));
      }
    }
  }

  static Map<String, dynamic>? _reqMap(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    if (raw is! Map) {
      issues.add(ConfigValidationIssue(path, '必须为对象'));
      return null;
    }
    return Map<String, dynamic>.from(raw);
  }

  static int? _reqInt(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues, {
    int? min,
    int? max,
  }) {
    final v = map[key];
    if (v is! int) {
      issues.add(ConfigValidationIssue(path, '必须为整数'));
      return null;
    }
    if (min != null && v < min) {
      issues.add(ConfigValidationIssue(path, '数值不能小于 $min'));
      return null;
    }
    if (max != null && v > max) {
      issues.add(ConfigValidationIssue(path, '数值不能大于 $max'));
      return null;
    }
    return v;
  }

  static int? _optInt(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues, {
    int? min,
  }) {
    final v = map[key];
    if (v == null) return null;
    if (v is! int) {
      issues.add(ConfigValidationIssue(path, '必须为整数或 null'));
      return null;
    }
    if (min != null && v < min) {
      issues.add(ConfigValidationIssue(path, '数值不能小于 $min'));
      return null;
    }
    return v;
  }

  static double? _reqDouble(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues, {
    double? min,
    double? max,
  }) {
    final v = map[key];
    if (v is! num || !v.isFinite) {
      issues.add(ConfigValidationIssue(path, '必须为有限数字'));
      return null;
    }
    final d = v.toDouble();
    if (min != null && d < min) {
      issues.add(ConfigValidationIssue(path, '数值不能小于 $min'));
      return null;
    }
    if (max != null && d > max) {
      issues.add(ConfigValidationIssue(path, '数值不能大于 $max'));
      return null;
    }
    return d;
  }

  static double? _optDouble(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues, {
    double? min,
    double? max,
  }) {
    final v = map[key];
    if (v == null) return null;
    if (v is! num || !v.isFinite) {
      issues.add(ConfigValidationIssue(path, '必须为有限数字或 null'));
      return null;
    }
    final d = v.toDouble();
    if (min != null && d < min) {
      issues.add(ConfigValidationIssue(path, '数值不能小于 $min'));
      return null;
    }
    if (max != null && d > max) {
      issues.add(ConfigValidationIssue(path, '数值不能大于 $max'));
      return null;
    }
    return d;
  }

  static bool? _reqBool(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final v = map[key];
    if (v is! bool) {
      issues.add(ConfigValidationIssue(path, '必须为布尔值'));
      return null;
    }
    return v;
  }

  static String? _reqString(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final v = map[key];
    if (v is! String) {
      issues.add(ConfigValidationIssue(path, '必须为字符串'));
      return null;
    }
    return v;
  }

  static String? _reqNonEmptyString(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final v = map[key];
    if (v is! String || v.trim().isEmpty) {
      issues.add(ConfigValidationIssue(path, '必须为非空字符串'));
      return null;
    }
    return v;
  }

  static String? _optString(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final v = map[key];
    if (v == null) return null;
    if (v is! String) {
      issues.add(ConfigValidationIssue(path, '必须为字符串或 null'));
      return null;
    }
    return v;
  }

  static String? _optEnvName(
    Map<String, dynamic> map,
    String key,
    String path,
    List<ConfigValidationIssue> issues,
  ) {
    final v = _optString(map, key, path, issues);
    if (v != null &&
        v.isNotEmpty &&
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(v)) {
      issues.add(ConfigValidationIssue(path, '环境变量名格式非法：$v'));
    }
    return v;
  }

  static String? _reqEnum(
    Map<String, dynamic> map,
    String key,
    String path,
    Set<String> allowed,
    List<ConfigValidationIssue> issues,
  ) {
    final v = map[key];
    if (v is! String || !allowed.contains(v)) {
      issues.add(
        ConfigValidationIssue(path, '无效枚举值，允许值：${allowed.join(', ')}'),
      );
      return null;
    }
    return v;
  }

  static List<String>? _reqStringList(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues, {
    Set<String>? allowedValues,
    bool nonEmpty = false,
  }) {
    if (raw is! List) {
      issues.add(ConfigValidationIssue(path, '必须为字符串数组'));
      return null;
    }
    if (nonEmpty && raw.isEmpty) {
      issues.add(ConfigValidationIssue(path, '数组不能为空'));
      return null;
    }
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! String) {
        issues.add(ConfigValidationIssue('$path[$i]', '数组元素必须为字符串'));
        return null;
      }
      if (allowedValues != null && !allowedValues.contains(item)) {
        issues.add(
          ConfigValidationIssue(
            '$path[$i]',
            '不允许的值 $item，允许值：${allowedValues.join(', ')}',
          ),
        );
        return null;
      }
      out.add(item);
    }
    return out;
  }

  static Map<String, String>? _reqStringMap(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues, {
    Set<String> forbiddenKeysLower = const {},
  }) {
    if (raw is! Map) {
      issues.add(ConfigValidationIssue(path, '必须为键值对象'));
      return null;
    }
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final k = entry.key.toString();
      if (forbiddenKeysLower.contains(k.toLowerCase())) {
        issues.add(ConfigValidationIssue('$path.$k', '禁止覆盖受保护的请求头 $k'));
      }
      if (entry.value is! String) {
        issues.add(ConfigValidationIssue('$path.$k', '请求头值必须为字符串'));
        continue;
      }
      out[k] = entry.value as String;
    }
    return out;
  }

  static Map<String, dynamic>? _reqJsonObject(
    Object? raw,
    String path,
    List<ConfigValidationIssue> issues, {
    Set<String> forbiddenKeys = const {},
  }) {
    if (raw is! Map) {
      issues.add(ConfigValidationIssue(path, '必须为对象'));
      return null;
    }
    final out = <String, dynamic>{};
    for (final entry in raw.entries) {
      final k = entry.key.toString();
      if (forbiddenKeys.contains(k)) {
        issues.add(ConfigValidationIssue('$path.$k', '禁止在 extra_body 中覆盖受保护字段 $k'));
      }
      out[k] = entry.value;
    }
    return out;
  }
}

const _sentinel = Object();
