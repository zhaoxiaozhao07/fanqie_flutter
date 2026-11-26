import '../models/immersive_config.dart';

/// 预置音色样本定义（映射 assets/TTS-Example 中的 13 个试听样本）
class PresetVoiceDefinition {
  final String modelId;
  final String displayName;
  final String gender;
  final String notes;
  final List<String> tags;
  final String sampleAsset;

  const PresetVoiceDefinition({
    required this.modelId,
    required this.displayName,
    required this.gender,
    required this.notes,
    required this.tags,
    required this.sampleAsset,
  });

  String get voiceId => deriveVoiceIdFromModel(modelId);
  String get modelKey => 'oneapi_$modelId';
  String get voiceProfileId => 'vp_oneapi_$modelId';
}

/// 沉浸式听书预置骨架配置（仅包含默认模型与本地试听样本模板，不在源码中硬编码任何真实密钥）
class ImmersivePresetConfig {
  static const textProviderBaseUrl = 'http://ingsys.net:8099/v1';
  static const textProviderApiKey = String.fromEnvironment(
    'IMMERSIVE_TEXT_API_KEY',
    defaultValue: '',
  );
  static const textProviderModelId = 'MiniMax-M3.1-Flash';

  static const ttsProviderBaseUrl = 'https://oneapi.971218.xyz/v1';
  static const ttsProviderApiKey = String.fromEnvironment(
    'IMMERSIVE_TTS_API_KEY',
    defaultValue: '',
  );

  static const defaultNarratorProfileId = 'vp_oneapi_Anthropic_male';
  static const nativeSystemProviderId = 'tts_system_native';
  static const nativeSystemModelKey = 'system_tts_default';
  static const nativeSystemVoiceProfileId = 'vp_system_native_default';

  /// 构建内置本地系统朗读 TTS 供应商（零 API Key、免费离线，特别适合设为全书固定旁白以节省 AI 额度）
  static TtsProviderConfig nativeSystemTtsProvider() => const TtsProviderConfig(
    providerId: nativeSystemProviderId,
    displayName: '系统朗读 (本地离线免费)',
    enabled: true,
    adapter: 'native_tts',
    baseUrl: 'http://127.0.0.1/native-tts',
    endpoint: '/synthesize',
    apiKey: '',
    apiKeyEnv: null,
    extraHeaders: {},
    requestTimeoutMs: 25000,
    maxConcurrency: 1,
    reservedForegroundSlots: 0,
    requestsPerMinute: null,
    models: [
      TtsModelConfig(
        modelKey: nativeSystemModelKey,
        modelId: 'system-tts',
        displayName: '系统内置语音引擎',
        enabled: true,
        maxConcurrency: 1,
        capabilities: TtsModelCapabilities(
          maxInputLength: 2000,
          inputLengthUnit: 'unicode_codepoints',
          supportsInstructions: false,
          supportsSpeed: true,
          supportedAudioFormats: ['wav'],
          responseTransport: 'binary',
          supportsWordTimestamps: false,
        ),
        extraBody: {},
        voices: [
          TtsVoiceProfileConfig(
            voiceProfileId: nativeSystemVoiceProfileId,
            voiceId: 'default',
            displayName: '系统默认朗读 (本地离线)',
            enabled: true,
            gender: 'neutral',
            notes: '调用本机系统 TTS 离线合成，免费且响应快，适合设为固定旁白节省 AI 语音额度。',
            tags: ['系统朗读', '离线', '旁白推荐'],
            sampleAsset: null,
            renderSettings: VoiceRenderSettings(
              audioFormat: 'wav',
              speed: 1.0,
              instructions: null,
            ),
            extraBody: {},
          ),
        ],
      ),
    ],
  );

  /// 幂等地向现有沉浸式配置补入系统朗读供应商（保留原有所有模型、密钥与默认旁白）
  static ImmersiveConfig ensureNativeSystemTts(ImmersiveConfig cfg) {
    final exists = cfg.tts.providers.any(
      (p) =>
          p.adapter == 'native_tts' || p.providerId == nativeSystemProviderId,
    );
    if (exists) return cfg;
    return cfg.copyWith(
      tts: cfg.tts.copyWith(
        providers: [...cfg.tts.providers, nativeSystemTtsProvider()],
      ),
    );
  }

  /// 当前构建是否通过编译参数注入了完整默认密钥
  static bool get hasBundledCredentials =>
      textProviderApiKey.trim().isNotEmpty &&
      ttsProviderApiKey.trim().isNotEmpty;

  /// 13 个已实测通过且自带本地 MP3 试听样本的音色模型
  static const List<PresetVoiceDefinition> oneApiVoices = [
    PresetVoiceDefinition(
      modelId: 'DeepSeek_female',
      displayName: '深求女声 (DeepSeek)',
      gender: 'female',
      notes: '青年女声，清晰自然、节奏明快，适合女主角或主线年轻女性角色。',
      tags: ['青年', '清晰', '自然'],
      sampleAsset: 'assets/TTS-Example/01_DeepSeek_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'Kimi_female',
      displayName: '月之女声 (Kimi)',
      gender: 'female',
      notes: '温柔女声，柔和平缓、细腻舒展，适合温婉善良或文静女性角色。',
      tags: ['温柔', '柔和', '细腻'],
      sampleAsset: 'assets/TTS-Example/02_Kimi_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'zhipu_female',
      displayName: '智谱女声 (zhipu)',
      gender: 'female',
      notes: '知性女声，沉稳干练、逻辑清晰，适合职场女性、师姐或冷静角色。',
      tags: ['知性', '干练', '沉稳'],
      sampleAsset: 'assets/TTS-Example/03_zhipu_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'doubao_female',
      displayName: '豆包女声 (doubao)',
      gender: 'female',
      notes: '灵动女声，亲切活泼、语调轻盈，适合开朗少女或好友角色。',
      tags: ['灵动', '亲切', '少女'],
      sampleAsset: 'assets/TTS-Example/04_doubao_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'MiniMax_female',
      displayName: '稀宇女声 (MiniMax)',
      gender: 'female',
      notes: '细腻女声，富有情绪张力，适合情感起伏丰富的女性角色。',
      tags: ['细腻', '表现力', '情感'],
      sampleAsset: 'assets/TTS-Example/05_MiniMax_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'shangtang_female',
      displayName: '商汤女声 (shangtang)',
      gender: 'female',
      notes: '端庄女声，吐字标准大方，适合长辈女性、贵妇或权威女性角色。',
      tags: ['端庄', '成熟', '大方'],
      sampleAsset: 'assets/TTS-Example/06_shangtang_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'baixiaoying_female',
      displayName: '百小应女声 (baixiaoying)',
      gender: 'female',
      notes: '清甜女声，声线轻快明亮，适合可爱机灵或年少女性角色。',
      tags: ['清甜', '明亮', '年少'],
      sampleAsset: 'assets/TTS-Example/07_baixiaoying_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'stepspark_female',
      displayName: '阶跃女声 (stepspark)',
      gender: 'female',
      notes: '活泼女声，语调生动鲜明，适合外向爽朗或古灵精怪的女性角色。',
      tags: ['活泼', '爽朗', '生动'],
      sampleAsset: 'assets/TTS-Example/08_stepspark_female.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'tongyi_male',
      displayName: '通义男声 (tongyi)',
      gender: 'male',
      notes: '沉稳男声，浑厚有力，适合成熟男性、掌门、反派或年长男角色。',
      tags: ['成熟', '沉稳', '浑厚'],
      sampleAsset: 'assets/TTS-Example/09_tongyi_male.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'wenxin_male',
      displayName: '文心男声 (wenxin)',
      gender: 'male',
      notes: '青年男声，清朗阳光、富有朝气，适合男主角或少年公子。',
      tags: ['青年', '清朗', '阳光'],
      sampleAsset: 'assets/TTS-Example/10_wenxin_male.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'xunfei_male',
      displayName: '讯飞男声 (xunfei)',
      gender: 'male',
      notes: '磁性男声，克制深沉，适合冷峻高手、谋士或神秘男性角色。',
      tags: ['磁性', '深沉', '克制'],
      sampleAsset: 'assets/TTS-Example/11_xunfei_male.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'Anthropic_male',
      displayName: '安索男声·旁白 (Anthropic)',
      gender: 'male',
      notes: '温和男声，叙事稳定耐听，吐字均匀清晰，默认用作全书固定旁白。',
      tags: ['旁白', '温和', '平稳'],
      sampleAsset: 'assets/TTS-Example/12_Anthropic_male.mp3',
    ),
    PresetVoiceDefinition(
      modelId: 'zhinao_female',
      displayName: '智脑女声 (zhinao)',
      gender: 'female',
      notes: '成熟女声，冷静沉着，适合城府较深或高冷御姐型角色。',
      tags: ['成熟', '冷静', '御姐'],
      sampleAsset: 'assets/TTS-Example/13_zhinao_female.mp3',
    ),
  ];

  /// 构建预置沉浸式配置骨架；若未传入且未通过编译参数注入密钥，默认 featureEnabled=false 等待用户在应用内填写或通过 WebDAV 拉取
  static ImmersiveConfig createConfiguredDefault({
    String databasePath = './data/immersive-audio/state.sqlite3',
    String audioCacheDir = './data/immersive-audio/audio',
    String tempDir = './data/immersive-audio/audio/tmp',
    String? textApiKey,
    String? ttsApiKey,
    bool? featureEnabled,
  }) {
    final resolvedTextKey = (textApiKey ?? textProviderApiKey).trim();
    final resolvedTtsKey = (ttsApiKey ?? ttsProviderApiKey).trim();
    final enabled =
        featureEnabled ??
        (resolvedTextKey.isNotEmpty && resolvedTtsKey.isNotEmpty);

    final models = <TtsModelConfig>[
      for (final def in oneApiVoices)
        TtsModelConfig(
          modelKey: def.modelKey,
          modelId: def.modelId,
          displayName: def.displayName,
          enabled: true,
          maxConcurrency: 3,
          capabilities: const TtsModelCapabilities(
            maxInputLength: 2000,
            inputLengthUnit: 'unicode_codepoints',
            supportsInstructions: false,
            supportsSpeed: true,
            supportedAudioFormats: ['mp3'],
            responseTransport: 'binary',
            supportsWordTimestamps: false,
          ),
          extraBody: const {},
          voices: [
            TtsVoiceProfileConfig(
              voiceProfileId: def.voiceProfileId,
              voiceId: def.voiceId,
              displayName: def.displayName,
              enabled: true,
              gender: def.gender,
              notes: def.notes,
              tags: def.tags,
              sampleAsset: def.sampleAsset,
              renderSettings: const VoiceRenderSettings(
                audioFormat: 'mp3',
                speed: 1.0,
                instructions: null,
              ),
              extraBody: const {},
            ),
          ],
        ),
    ];

    final characterPool = oneApiVoices
        .where((d) => d.voiceProfileId != defaultNarratorProfileId)
        .map((d) => d.voiceProfileId)
        .toList(growable: false);

    final primaryMiniMax = TextAnalysisConfig(
      id: 'tm_minimax_m31_flash',
      providerId: 'analysis_ingsys',
      displayName: 'MiniMax M3.1 Flash',
      enabled: true,
      adapter: 'openai_chat_completions',
      baseUrl: textProviderBaseUrl,
      endpoint: '/chat/completions',
      apiKey: resolvedTextKey,
      apiKeyEnv: null,
      modelId: textProviderModelId,
      thinkingLevel: TextThinkingLevel.auto,
      extraHeaders: const {},
      extraBody: const {},
      requestTimeoutMs: 45000,
      maxConcurrency: 3,
      reservedReconciliationSlots: 1,
      requestsPerMinute: 60,
      tokensPerMinute: null,
      contextWindowTokens: TextAnalysisConfig.defaultContextWindowTokens,
      maxOutputTokens: TextAnalysisConfig.defaultMaxOutputTokens,
      outputLimitParameter: 'max_completion_tokens',
      temperature: null,
      structuredOutput: const StructuredOutputConfig(
        mode: 'vendor_native',
        schemaNamePrefix: 'immersive_reader_v1',
        strict: true,
        vendorAdapterId: 'openai_tool_call_schema',
        allowPromptOnlyFallback: false,
      ),
    );

    final fallbackGlm = TextAnalysisConfig(
      id: 'tm_glm_53_flash',
      providerId: 'analysis_ingsys',
      displayName: 'GLM 5.3 Flash',
      enabled: true,
      adapter: 'openai_chat_completions',
      baseUrl: textProviderBaseUrl,
      endpoint: '/chat/completions',
      apiKey: resolvedTextKey,
      apiKeyEnv: null,
      modelId: 'glm-5.3-flash',
      thinkingLevel: TextThinkingLevel.auto,
      extraHeaders: const {},
      extraBody: const {},
      requestTimeoutMs: 45000,
      maxConcurrency: 3,
      reservedReconciliationSlots: 1,
      requestsPerMinute: 60,
      tokensPerMinute: null,
      contextWindowTokens: TextAnalysisConfig.defaultContextWindowTokens,
      maxOutputTokens: TextAnalysisConfig.defaultMaxOutputTokens,
      outputLimitParameter: 'max_completion_tokens',
      temperature: null,
      structuredOutput: const StructuredOutputConfig(
        mode: 'vendor_native',
        schemaNamePrefix: 'immersive_reader_v1',
        strict: true,
        vendorAdapterId: 'openai_tool_call_schema',
        allowPromptOnlyFallback: false,
      ),
    );

    final extraQwen = TextAnalysisConfig(
      id: 'tm_qwen38_flash_next',
      providerId: 'analysis_ingsys',
      displayName: 'Qwen 3.8 Flash Next',
      enabled: true,
      adapter: 'openai_chat_completions',
      baseUrl: textProviderBaseUrl,
      endpoint: '/chat/completions',
      apiKey: resolvedTextKey,
      apiKeyEnv: null,
      modelId: 'qwen3.8-flash-next',
      thinkingLevel: TextThinkingLevel.auto,
      extraHeaders: const {},
      extraBody: const {},
      requestTimeoutMs: 45000,
      maxConcurrency: 1,
      reservedReconciliationSlots: 0,
      requestsPerMinute: 30,
      tokensPerMinute: null,
      contextWindowTokens: TextAnalysisConfig.defaultContextWindowTokens,
      maxOutputTokens: TextAnalysisConfig.defaultMaxOutputTokens,
      outputLimitParameter: 'max_completion_tokens',
      temperature: null,
      structuredOutput: const StructuredOutputConfig(
        mode: 'vendor_native',
        schemaNamePrefix: 'immersive_reader_v1',
        strict: true,
        vendorAdapterId: 'openai_tool_call_schema',
        allowPromptOnlyFallback: false,
      ),
    );

    return ImmersiveConfig(
      schemaVersion: 1,
      featureEnabled: enabled,
      storage: StorageConfig(
        stateStore: 'sqlite',
        databasePath: databasePath,
        audioCacheDir: audioCacheDir,
        tempDir: tempDir,
      ),
      textAnalysis: primaryMiniMax,
      textAnalysisModels: [primaryMiniMax, fallbackGlm, extraQwen],
      primaryTextModelId: primaryMiniMax.effectiveId,
      fallbackTextModelId: fallbackGlm.effectiveId,
      textFailoverThreshold: 2,
      tts: TtsConfig(
        globalMaxConcurrency: 6,
        maxPendingJobs: 64,
        providers: [
          TtsProviderConfig(
            providerId: 'tts_oneapi_primary',
            displayName: 'OneAPI 多音色 TTS',
            enabled: true,
            adapter: 'openai_speech',
            baseUrl: ttsProviderBaseUrl,
            endpoint: '/audio/speech',
            apiKey: resolvedTtsKey,
            apiKeyEnv: null,
            extraHeaders: const {},
            requestTimeoutMs: 120000,
            maxConcurrency: 3,
            reservedForegroundSlots: 1,
            requestsPerMinute: 60,
            models: models,
          ),
        ],
      ),
      bookDefaults: BookDefaultsConfig(
        selectedVoiceProfileIds: characterPool,
        narratorVoiceProfileId: defaultNarratorProfileId,
      ),
      analysisPipeline: const AnalysisPipelineConfig(
        maxPrefixBacktrackChapters: 5,
      ),
      audioGeneration: const AudioGenerationConfig(),
      prefetch: const PrefetchConfig(),
      playback: const PlaybackConfig(),
      cache: const CacheConfig(),
      jobs: const JobsConfig(),
      retry: const RetryConfig(),
      observability: const ObservabilityConfig(),
    );
  }

  /// 提供默认预置的 3 个文本分析模型列表（供旧配置平滑迁移或一键恢复使用）
  static List<TextAnalysisConfig> defaultTextModels({String? textApiKey}) {
    return createConfiguredDefault(textApiKey: textApiKey).textAnalysisModels;
  }
}
