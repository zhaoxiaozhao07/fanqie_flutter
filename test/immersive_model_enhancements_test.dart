import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/models/immersive_entities.dart';
import 'package:fanqie_flutter/immersive/services/chunk_planner.dart';
import 'package:fanqie_flutter/immersive/services/identity_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/services/text_model_adapter.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/immersive/widgets/immersive_player_panel.dart';
import 'package:fanqie_flutter/immersive/widgets/immersive_settings_dialogs.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/ai_reading_assistant_service.dart';

TextAnalysisConfig _sampleTextModel({
  String id = 'tm_deepseek_v41',
  String displayName = 'DeepSeek-V4.1-Flash',
  String modelId = 'DeepSeek-V4.1-Flash',
  String thinkingLevel = TextThinkingLevel.auto,
  int? contextWindowTokens = TextAnalysisConfig.defaultContextWindowTokens,
  int? maxOutputTokens = TextAnalysisConfig.defaultMaxOutputTokens,
  String structuredMode = 'vendor_native',
}) {
  return TextAnalysisConfig(
    id: id,
    providerId: 'analysis_test',
    displayName: displayName,
    enabled: true,
    baseUrl: 'https://api.test.local/v1',
    endpoint: '/chat/completions',
    apiKey: 'test-key-secret',
    modelId: modelId,
    thinkingLevel: thinkingLevel,
    maxConcurrency: 2,
    reservedReconciliationSlots: 1,
    contextWindowTokens: contextWindowTokens,
    maxOutputTokens: maxOutputTokens,
    structuredOutput: StructuredOutputConfig(
      mode: structuredMode,
      schemaNamePrefix: 'immersive_reader_v1',
      strict: true,
      vendorAdapterId:
          structuredMode == 'vendor_native' ? 'openai_tool_call_schema' : null,
      allowPromptOnlyFallback: false,
    ),
  );
}

Map<String, dynamic> _validAnalysisPayload(List<String> unitIds) => {
  'assignments': [
    for (final uid in unitIds)
      {
        'source_unit_ids': [uid],
        'kind': 'narration',
        'speaker_ref': 'narrator',
        'evidence_unit_ids': [uid],
        'evidence_type': 'explicit_attribution',
      },
  ],
  'new_character_proposals': const <Map<String, dynamic>>[],
  'identity_link_proposals': const <Map<String, dynamic>>[],
  'unresolved_items': const <Map<String, dynamic>>[],
};

Uint8List _validSilentWavBytes() {
  const dataLen = 3200;
  final totalLen = 36 + dataLen;
  final bd = ByteData(44 + dataLen);
  final header = ascii.encode('RIFF');
  for (var i = 0; i < 4; i++) {
    bd.setUint8(i, header[i]);
  }
  bd.setUint32(4, totalLen, Endian.little);
  final waveFmt = ascii.encode('WAVEfmt ');
  for (var i = 0; i < 8; i++) {
    bd.setUint8(8 + i, waveFmt[i]);
  }
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, 16000, Endian.little);
  bd.setUint32(28, 32000, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  final dataTag = ascii.encode('data');
  for (var i = 0; i < 4; i++) {
    bd.setUint8(36 + i, dataTag[i]);
  }
  bd.setUint32(40, dataLen, Endian.little);
  return bd.buffer.asUint8List();
}

class _FakeTtsAdapter implements TtsProviderAdapter {
  @override
  Future<SynthesizedAudioPayload> synthesize({
    required RenderSpec spec,
    required String apiKey,
    required int timeoutMs,
    bool Function()? isCancelled,
  }) async {
    return SynthesizedAudioPayload(
      bytes: _validSilentWavBytes(),
      detectedFormat: 'wav',
      durationMs: 1200,
      latencyMs: 5,
    );
  }

  @override
  Future<VoiceProfileTestResult> testVoiceProfile({
    required VoiceProfileResolution resolution,
    required String apiKey,
    String sampleText = '你好，这是沉浸式听书音色连接测试。',
  }) async {
    final bytes = _validSilentWavBytes();
    return VoiceProfileTestResult(
      success: true,
      message: 'ok',
      audioFormat: 'wav',
      durationMs: 1200,
      byteLength: bytes.length,
      latencyMs: 5,
      audioBytes: bytes,
    );
  }

  @override
  void cancelAll() {}
}

class _ScriptedTextAdapter implements TextModelAdapter {
  final Future<StructuredModelResponse> Function(
    TextAnalysisConfig config,
    String userMessage,
  )
  onAnalyze;

  final List<String> seenModelIds = [];
  int cancelCount = 0;

  _ScriptedTextAdapter(this.onAnalyze);

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    seenModelIds.add(config.modelId);
    return onAnalyze(config, userMessage);
  }

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    return const StructuredModelResponse(
      data: {'verdicts': []},
      latencyMs: 1,
      schemaVersion: ImmersiveNativeSchemas.identityRecheckVersion,
    );
  }

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    return const StructuredModelResponse(
      data: {'rolling_summary': 'ok', 'active_character_ids': []},
      latencyMs: 1,
      schemaVersion: ImmersiveNativeSchemas.summaryUpdateVersion,
    );
  }

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async {
    return const AnalysisProviderTestResult(
      success: true,
      message: 'ok',
      latencyMs: 1,
      modeUsed: 'vendor_native',
    );
  }

  @override
  void cancelAll() {
    cancelCount++;
  }
}

void main() {
  group('模型配置、思考程度与上下文/最大输出参数', () {
    test('默认上下文为 1M、默认最大输出为 8192、默认协议为 json_object，且支持 none/max 思考程度', () {
      final preset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
      );
      expect(preset.primaryTextModel.contextWindowTokens, 1000000);
      expect(preset.primaryTextModel.maxOutputTokens, 8192);
      expect(preset.primaryTextModel.structuredOutput.mode, 'json_object');
      expect(preset.textFailoverThreshold, 3);
      expect(TextThinkingLevel.values.contains(TextThinkingLevel.none), isTrue);
      expect(TextThinkingLevel.values.contains(TextThinkingLevel.max), isTrue);

      final customNone = _sampleTextModel(
        thinkingLevel: TextThinkingLevel.none,
        contextWindowTokens: null,
        maxOutputTokens: null,
      );
      final customMax = _sampleTextModel(
        id: 'tm_max',
        thinkingLevel: TextThinkingLevel.max,
        contextWindowTokens: 2000000,
        maxOutputTokens: 32000,
      );
      final cfg = preset.copyWith(
        textAnalysisModels: [customNone, customMax],
        primaryTextModelId: customNone.effectiveId,
        fallbackTextModelId: customMax.effectiveId,
      );

      final validated = ImmersiveConfigValidator.parseAndValidateMap(
        cfg.toJson(),
      );
      expect(validated.isValid, isTrue, reason: '${validated.issues}');
      expect(validated.config!.primaryTextModel.thinkingLevel, 'none');
      expect(validated.config!.primaryTextModel.contextWindowTokens, isNull);
      expect(validated.config!.primaryTextModel.maxOutputTokens, isNull);
      expect(
        validated.config!.primaryTextModel.effectiveContextWindowTokens,
        1000000,
      );
      expect(validated.config!.fallbackTextModel!.thinkingLevel, 'max');
      expect(
        validated.config!.fallbackTextModel!.contextWindowTokens,
        2000000,
      );
      expect(validated.config!.fallbackTextModel!.maxOutputTokens, 32000);
    });

    test('最大输出为空时不传入输出上限字段，思考 none/max 正确映射', () {
      final schema = ImmersiveNativeSchemas.chunkAnalysisSchema();

      final modelWithoutLimit = _sampleTextModel(
        thinkingLevel: TextThinkingLevel.none,
        maxOutputTokens: null,
      );
      final bodyNoLimit = OpenAiChatTextModelAdapter.buildRequestBody(
        config: modelWithoutLimit,
        taskSchemaSuffix: 'chunk_v1',
        toolDescription: 'desc',
        schema: schema,
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(bodyNoLimit.containsKey('max_completion_tokens'), isFalse);
      expect(bodyNoLimit.containsKey('max_tokens'), isFalse);
      expect(bodyNoLimit['reasoning_effort'], 'none');

      final modelMax = _sampleTextModel(
        thinkingLevel: TextThinkingLevel.max,
        maxOutputTokens: 12800,
      );
      final bodyMax = OpenAiChatTextModelAdapter.buildRequestBody(
        config: modelMax,
        taskSchemaSuffix: 'chunk_v1',
        toolDescription: 'desc',
        schema: schema,
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(bodyMax['max_completion_tokens'], 12800);
      expect(bodyMax['reasoning_effort'], 'max');
    });

    test('AI 阅读助手在最大输出留空时同样不发送输出上限字段', () async {
      final tmpDir = await Directory.systemTemp.createTemp('ai_assist_limit_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final preset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
      );
      final noLimitModel = _sampleTextModel(maxOutputTokens: null);
      final cfg = preset.copyWith(
        textAnalysisModels: [noLimitModel],
        primaryTextModelId: noLimitModel.effectiveId,
        fallbackTextModelId: null,
      );
      final cfgService = ImmersiveConfigService(
        documents: () async => tmpDir,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final cfgFile = await cfgService.defaultConfigFile();
      final saveRes = await cfgService.saveConfig(cfg, configFile: cfgFile);
      expect(saveRes.issues, isEmpty);
      await cfgService.loadAndValidateConfig(configFile: cfgFile);

      Map<String, dynamic>? capturedBody;
      final client = MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'role': 'assistant', 'content': '测试提要回复'},
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final service = AiReadingAssistantService.forTesting(
        httpClient: client,
        configService: cfgService,
      );
      await service.generateRecap(
        bookId: 'b1',
        bookName: '测试书',
        chapters: [Chapter(itemId: 'c1', title: '第一章')],
        currentChapterIndex: 0,
        currentParagraphIndex: 0,
        chapterLoader: (_) async => '第一章正文内容。',
      );

      expect(capturedBody, isNotNull);
      expect(capturedBody!.containsKey('max_completion_tokens'), isFalse);
      expect(capturedBody!.containsKey('max_tokens'), isFalse);
    });

    test('ChunkPlanner 在 1M 上下文与空 maxOutputTokens 下预算计算正确', () {
      final model = _sampleTextModel(
        contextWindowTokens: null,
        maxOutputTokens: null,
      );
      final budget = ChunkPlanner.effectiveTargetBudget(
        textConfig: model,
        pipelineConfig: const AnalysisPipelineConfig(),
        systemVoiceCatalogTokens: 800,
      );
      expect(budget, greaterThan(1000));
    });

    test('Token 输入解析与短格式展示正确处理 1M/128K/留空/非法字符', () {
      expect(parseTokenCountInput('').value, isNull);
      expect(parseTokenCountInput('').error, isNull);
      expect(parseTokenCountInput('1M').value, 1000000);
      expect(parseTokenCountInput('128k').value, 128000);
      expect(parseTokenCountInput('12,800').value, 12800);
      expect(parseTokenCountInput('abc').error, isNotNull);
      expect(formatTokenCountShort(1000000), '1M');
      expect(formatTokenCountShort(12800), '12800');
      expect(formatTokenCountShort(null), '不传');
    });
  });

  group('/v1/models 拉取与结构化输出容错增强', () {
    test('通过 /v1/models 拉取并去重排序可用模型，且支持缺少 /v1 路径自动回退', () async {
      final requestedPaths = <String>[];
      final client = MockClient((req) async {
        requestedPaths.add(req.url.path);
        if (req.url.path == '/models') {
          return http.Response('Not Found', 404);
        }
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'MiniMax-M3.1-Flash'},
              {'id': 'DeepSeek-V4.1-Flash'},
              {'id': 'DeepSeek-V4.1-Flash'},
              {'id': 'glm-5.3-flash'},
            ],
          }),
          200,
        );
      });

      final models = await OpenAiChatTextModelAdapter.fetchAvailableModels(
        baseUrl: 'https://api.test.local',
        apiKey: 'secret-token',
        client: client,
      );
      expect(requestedPaths, ['/models', '/v1/models']);
      expect(models, [
        'DeepSeek-V4.1-Flash',
        'glm-5.3-flash',
        'MiniMax-M3.1-Flash',
      ]);
    });

    test('输出被长度截断时自动降思考至 none 重试并成功', () async {
      final seenEfforts = <Object?>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        seenEfforts.add(body['reasoning_effort']);
        if (seenEfforts.length == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'length',
                  'message': {'role': 'assistant', 'content': ''},
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'tool_calls',
                'message': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'id': 'call_1',
                      'type': 'function',
                      'function': {
                        'name': 'immersive_reader_v1_chunk_analysis_v1',
                        'arguments': jsonEncode(_validAnalysisPayload(['u1'])),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = OpenAiChatTextModelAdapter(client);
      final resp = await adapter.analyzeChunk(
        config: _sampleTextModel(thinkingLevel: TextThinkingLevel.minimal),
        apiKey: 'k',
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(seenEfforts, ['minimal', 'none']);
      expect((resp.data['assignments'] as List).length, 1);
    });

    test('vendor_native 返回非合法 JSON 时自动协议协商切换原生 json_schema 并成功', () async {
      final seenModes = <String>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final isToolCall = body.containsKey('tools');
        seenModes.add(isToolCall ? 'vendor_native' : 'json_schema');
        if (isToolCall) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'tool_calls': [
                      {
                        'id': 'call_bad',
                        'type': 'function',
                        'function': {
                          'name': 'immersive_reader_v1_chunk_analysis_v1',
                          'arguments': 'invalid-json-not-object',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': jsonEncode(_validAnalysisPayload(['u1'])),
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = OpenAiChatTextModelAdapter(client);
      final resp = await adapter.analyzeChunk(
        config: _sampleTextModel(structuredMode: 'vendor_native'),
        apiKey: 'k',
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(seenModes, ['vendor_native', 'json_schema']);
      expect((resp.data['assignments'] as List).length, 1);
    });

    test('tool_calls.arguments 未闭合（截断误报 stop）按截断识别并自动降思考重试', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'tool_calls': [
                      {
                        'id': 'call_trunc',
                        'type': 'function',
                        'function': {
                          'name': 'immersive_reader_v1_chunk_analysis_v1',
                          'arguments': '{"assignments":[{"source_unit_ids":["u1"',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'tool_calls',
                'message': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'id': 'call_ok',
                      'type': 'function',
                      'function': {
                        'name': 'immersive_reader_v1_chunk_analysis_v1',
                        'arguments': jsonEncode(
                          jsonEncode(_validAnalysisPayload(['u1'])),
                        ),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = OpenAiChatTextModelAdapter(client);
      final resp = await adapter.analyzeChunk(
        config: _sampleTextModel(thinkingLevel: TextThinkingLevel.high),
        apiKey: 'k',
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(calls, 2);
      expect((resp.data['assignments'] as List).length, 1);
    });
  });

  group('切模生效、重试必响应、关闭与重开状态机', () {
    test('切换主模型立刻清除旧阻塞并复活 blocked 任务，重试/关闭提示/停止重开全链路无残留', () async {
      final tmpDir = await Directory.systemTemp.createTemp('immersive_state_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final cfgFile = File('${tmpDir.path}/config.json');

      final badModel = _sampleTextModel(
        id: 'tm_bad_ds',
        displayName: 'DeepSeek-V4.1-Flash',
        modelId: 'DeepSeek-V4.1-Flash',
      );
      final goodModel = _sampleTextModel(
        id: 'tm_good_mm',
        displayName: 'MiniMax-M3.1-Flash',
        modelId: 'MiniMax-M3.1-Flash',
      );

      final preset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
        featureEnabled: true,
      );
      final initialConfig = preset.copyWith(
        textAnalysisModels: [badModel, goodModel],
        primaryTextModelId: badModel.effectiveId,
        fallbackTextModelId: null,
      );

      final store = InMemoryImmersiveStateStore();
      await store.initialize();

      var failBadModel = true;
      final scriptedText = _ScriptedTextAdapter((cfg, userMessage) async {
        if (cfg.modelId == 'DeepSeek-V4.1-Flash' && failBadModel) {
          throw const TextModelException(
            kind: TextModelErrorKind.unsupportedStructuredOutput,
            message: '[DeepSeek-V4.1-Flash] 模型输出不是合法 JSON',
          );
        }
        final section = RegExp(
          r'\[TARGET_UNITS[^\]]*\]([\s\S]*?)\[/TARGET_UNITS\]',
        ).firstMatch(userMessage)?.group(1) ?? '';
        final unitIds = <String>[];
        for (final line in section.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          final idx = trimmed.indexOf(':');
          if (idx > 0) {
            unitIds.add(trimmed.substring(0, idx).trim());
          }
        }
        return StructuredModelResponse(
          data: _validAnalysisPayload(unitIds),
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      });

      final cfgService = ImmersiveConfigService(
        documents: () async => tmpDir,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await cfgService.saveConfig(initialConfig, configFile: cfgFile);

      final coord = ImmersivePlaybackCoordinator.forTesting(
        invoke: (_, _) async => true,
        configService: cfgService,
        stateStore: store,
        textAdapter: scriptedText,
        ttsAdapter: _FakeTtsAdapter(),
        audioCacheDir: '${tmpDir.path}/audio',
        tempDir: '${tmpDir.path}/tmp',
        platformAudioProbe: (_, dur) async => (valid: true, durationMs: dur),
      );
      addTearDown(coord.dispose);

      await coord.loadAndValidateConfig(configFile: cfgFile);
      expect(coord.activeTextModelLabel, 'DeepSeek-V4.1-Flash');

      final book = Book(bookId: 'book_1', bookName: '测试小说', author: '作者');
      final chapters = [Chapter(itemId: 'ch_1', title: '第一章')];
      Future<String?> loader(Chapter c) async => '风吹过树梢，林岚轻轻推开了门。';

      await coord.startImmersivePlayback(
        book: book,
        chapters: chapters,
        chapterIndex: 0,
        contentLoader: loader,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // 1. 坏模型失败后进入阻塞，且阻塞信息带模型名
      expect(coord.scheduler?.blockingReason, contains('DeepSeek-V4.1-Flash'));
      final blockedJobs = await store.listJobs(
        bookId: book.bookId,
        statuses: const {ImmersiveJobStatus.blocked},
      );
      expect(blockedJobs, isNotEmpty);

      // 2. dismissIssue 可立即关闭横幅错误提示
      coord.dismissIssue();
      expect(coord.errorMessage, isNull);
      expect(coord.notice, isNull);
      expect(coord.scheduler?.blockingReason, isNull);

      // 3. 点击 retryBlockedRange：先让模型恢复正常，验证点击重试立即复活任务并推进确认
      failBadModel = false;
      await coord.retryBlockedRange();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final stAfterRetry = await coord.getPipelineStatus();
      expect(stAfterRetry.blockingReason, isNull);
      expect(stAfterRetry.confirmedChunks, greaterThanOrEqualTo(1));

      // 4. 再测试“切模型后旧报错不残留”：换到新书触发阻塞，然后切主模型
      failBadModel = true;
      await coord.stop();
      expect(coord.state, ImmersivePlayState.stopped);
      expect(coord.scheduler?.blockingReason, isNull);

      final book2 = Book(bookId: 'book_2', bookName: '第二本', author: '作者');
      await coord.startImmersivePlayback(
        book: book2,
        chapters: chapters,
        chapterIndex: 0,
        contentLoader: loader,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(coord.scheduler?.blockingReason, contains('DeepSeek-V4.1-Flash'));

      // 切换主模型到 MiniMax-M3.1-Flash，验证自动清错 + 复活任务 + 新模型完成分析
      await coord.saveConfig(
        initialConfig.copyWith(primaryTextModelId: goodModel.effectiveId),
        configFile: cfgFile,
      );
      expect(coord.activeTextModelLabel, 'MiniMax-M3.1-Flash');
      expect(coord.scheduler?.blockingReason, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final st2 = await coord.getPipelineStatus();
      expect(st2.blockingReason, isNull);
      expect(st2.confirmedChunks, greaterThanOrEqualTo(1));
      expect(scriptedText.seenModelIds, contains('MiniMax-M3.1-Flash'));
    });
  });

  group('UI 组件测试：模型下拉获取、思考/上下文/输出配置与播放器面板', () {
    testWidgets('文本模型编辑弹窗支持拉取 /v1/models 下拉选择、none/max 与留空最大输出', (
      tester,
    ) async {
      final preset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
      );
      TextAnalysisConfig? dialogResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  dialogResult = await showTextModelEditorDialog(
                    ctx,
                    preset,
                    modelsFetcher: ({required baseUrl, required apiKey}) async {
                      return const ['DeepSeek-V4.1-Flash', 'MiniMax-M3.1-Flash'];
                    },
                  );
                },
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      // 验证默认预填上下文 1M、最大输出 8192，且输入 http:// 地址不显示明文 HTTP 警告横幅
      final ctxField = tester.widget<TextField>(
        find.byKey(const ValueKey('text-model-context-field')),
      );
      final outField = tester.widget<TextField>(
        find.byKey(const ValueKey('text-model-max-output-field')),
      );
      expect(ctxField.controller?.text, '1M');
      expect(outField.controller?.text, '8192');
      expect(find.textContaining('当前接口使用明文 HTTP'), findsNothing);

      // 点击获取模型，验证下拉列表出现并自动填入首个模型 DeepSeek-V4.1-Flash
      await tester.tap(find.byKey(const ValueKey('fetch-text-models-btn')));
      await tester.pumpAndSettle();
      expect(find.text('DeepSeek-V4.1-Flash'), findsWidgets);

      await tester.ensureVisible(
        find.byKey(const ValueKey('text-model-thinking-dropdown')),
      );
      await tester.tap(
        find.byKey(const ValueKey('text-model-thinking-dropdown')),
      );
      await tester.pumpAndSettle();
      expect(find.text('最高 (max)'), findsOneWidget);
      await tester.tap(find.text('关闭思考 (none)').last);
      await tester.pumpAndSettle();

      // 清空最大输出（表示不传该字段）
      await tester.ensureVisible(
        find.byKey(const ValueKey('text-model-max-output-field')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('text-model-max-output-field')),
        '',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('save-text-model-btn')));
      await tester.pumpAndSettle();

      expect(dialogResult, isNotNull);
      expect(dialogResult!.modelId, 'DeepSeek-V4.1-Flash');
      expect(dialogResult!.thinkingLevel, TextThinkingLevel.none);
      expect(dialogResult!.contextWindowTokens, 1000000);
      expect(dialogResult!.maxOutputTokens, isNull);
    });

    testWidgets('沉浸式播放器常态显示当前模型并支持关闭错误横幅', (tester) async {
      late Directory tmpDir;
      late ImmersivePlaybackCoordinator coord;
      await tester.runAsync(() async {
        tmpDir = await Directory.systemTemp.createTemp('immersive_panel_');
        final cfgFile = File('${tmpDir.path}/config.json');
        final model = _sampleTextModel(
          displayName: 'DeepSeek-V4.1-Flash',
          modelId: 'DeepSeek-V4.1-Flash',
        );
        final preset = ImmersivePresetConfig.createConfiguredDefault(
          textApiKey: 'test-key',
          ttsApiKey: 'test-tts',
          featureEnabled: true,
        ).copyWith(
          textAnalysisModels: [model],
          primaryTextModelId: model.effectiveId,
          fallbackTextModelId: null,
        );

        final cfgService = ImmersiveConfigService(
          documents: () async => tmpDir,
          secretStore: MemoryImmersiveSecretStore(),
        );
        await cfgService.saveConfig(preset, configFile: cfgFile);
        final store = InMemoryImmersiveStateStore();
        await store.initialize();

        coord = ImmersivePlaybackCoordinator.forTesting(
          invoke: (_, _) async => true,
          configService: cfgService,
          stateStore: store,
          textAdapter: _ScriptedTextAdapter((_, _) async {
            throw const TextModelException(
              kind: TextModelErrorKind.unsupportedStructuredOutput,
              message: '[DeepSeek-V4.1-Flash] 测试报错信息',
            );
          }),
          ttsAdapter: _FakeTtsAdapter(),
          audioCacheDir: '${tmpDir.path}/audio',
          tempDir: '${tmpDir.path}/tmp',
          platformAudioProbe: (_, dur) async => (valid: true, durationMs: dur),
        );

        await coord.loadAndValidateConfig(configFile: cfgFile);
        await coord.startImmersivePlayback(
          book: Book(bookId: 'b_panel', bookName: '面板书', author: '作者'),
          chapters: [Chapter(itemId: 'c1', title: '第一章')],
          chapterIndex: 0,
          contentLoader: (_) async => '测试正文第一句。',
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      });
      addTearDown(() async {
        coord.dispose();
        if (await tmpDir.exists()) {
          await tmpDir.delete(recursive: true);
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ImmersivePlayerPanel(
                coordinator: coord,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 常态显示当前使用的模型标签与实时线性进度条
      expect(
        find.byKey(const ValueKey('immersive-active-model-badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('immersive-progress-bar')),
        findsOneWidget,
      );
      expect(find.textContaining('DeepSeek-V4.1-Flash'), findsWidgets);

      // 错误横幅存在，点击关闭按钮后立即消失
      expect(
        find.byKey(const ValueKey('immersive-dismiss-issue-btn')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('immersive-dismiss-issue-btn')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('immersive-dismiss-issue-btn')),
        findsNothing,
      );

      // 停掉定时器并卸载面板，避免遗留 pending timers
      await tester.runAsync(() => coord.stop());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  group('DeepSeek json_object 模板测试、长分块修复与三次重试切兜底回归', () {
    test('testProvider 使用标准 json_object 示例模板：成功解析与不支持 JSON 明确报错', () async {
      Map<String, dynamic>? capturedReq;
      final okClient = MockClient((req) async {
        capturedReq = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': jsonEncode({
                    'question': 'Which is the longest river in the world?',
                    'answer': 'The Nile River',
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final okAdapter = OpenAiChatTextModelAdapter(okClient);
      final okRes = await okAdapter.testProvider(
        config: _sampleTextModel(structuredMode: 'json_object'),
        apiKey: 'sk-test',
      );
      expect(okRes.success, isTrue);
      expect(okRes.modeUsed, 'json_object');
      expect(capturedReq?['response_format'], {'type': 'json_object'});
      final msgs = (capturedReq?['messages'] as List).cast<Map>();
      expect(msgs.first['content'], contains('Mount Everest'));
      expect(msgs.last['content'], contains('The Nile River'));

      // 测试模型不支持 JSON 格式化输出时明确提示“不支持 JSON 格式化输出”
      final badClient = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': 'The longest river is the Nile River.',
                },
              },
            ],
          }),
          200,
        );
      });
      final badAdapter = OpenAiChatTextModelAdapter(badClient);
      final badRes = await badAdapter.testProvider(
        config: _sampleTextModel(
          modelId: 'plain-chat-model',
          structuredMode: 'json_object',
        ),
        apiKey: 'sk-test',
      );
      expect(badRes.success, isFalse);
      expect(badRes.message, contains('不支持 JSON 格式化输出'));
    });

    test('长分块重复引用单元与省略 evidence_type 时自动修复且通过严格校验', () {
      final units = <String, SourceUnit>{};
      final targetIds = <String>[];
      for (var i = 1; i <= 12; i++) {
        final uid = 'u_$i';
        targetIds.add(uid);
        units[uid] = SourceUnit(
          unitId: uid,
          bookRevisionId: 'rev1',
          bookId: 'b1',
          chapterIndex: 0,
          chapterId: 'ch0',
          paragraphIndex: i,
          globalOrder: i,
          startOffset: 0,
          endOffset: 6,
          text: i.isEven ? '“这是第$i句。”' : '这是第$i段叙述。',
        );
      }
      final chunk = AnalysisChunk(
        chunkId: 'chk_0',
        bookRevisionId: 'rev1',
        bookId: 'b1',
        chapterIndex: 0,
        chapterId: 'ch0',
        chunkOrder: 0,
        targetUnitIds: targetIds,
        contextBeforeUnitIds: const ['u_before_ctx'],
        contextAfterUnitIds: const ['u_after_ctx'],
        startGlobalOrder: 1,
        endGlobalOrder: 12,
        estimatedTokens: 300,
      );

      // 构造含重复 u_2、误带 u_before_ctx、省略 evidence_type 且漏标 u_12 的模拟模型输出
      final rawPayload = <String, dynamic>{
        'assignments': [
          {
            'source_unit_ids': ['u_before_ctx', 'u_1', 'u_2'],
            'kind': 'narration',
            'speaker_ref': 'narrator',
          },
          {
            'source_unit_ids': ['u_2', 'u_3', 'u_4', 'u_5', 'u_6', 'u_7', 'u_8', 'u_9', 'u_10', 'u_11'],
            'kind': 'narration',
            'speaker_ref': 'narrator',
            'evidence_unit_ids': ['u_1', 'u_invalid_999'],
            'evidence_type': 'explicit',
          },
        ],
      };

      ImmersiveNativeSchemas.validateChunkAnalysisPayload(rawPayload);
      IdentityCoordinator.repairMinorDraftDeviations(
        payload: rawPayload,
        chunk: chunk,
        unitById: units,
        knownCharacterIds: const {},
      );
      IdentityCoordinator.validateDraftAgainstChunk(
        payload: rawPayload,
        chunk: chunk,
        unitById: units,
        knownCharacterIds: const {},
      );
      final fixed = (rawPayload['assignments'] as List).cast<Map>();
      final flattened = <String>[
        for (final item in fixed)
          ...(item['source_unit_ids'] as List).cast<String>(),
      ];
      expect(flattened, targetIds);
    });

    test('高并发下首块在主模型自动重试 3 次（共调用 4 次）仍失败时，不被其他成功块掩盖并自动切换兜底模型', () async {
      final tmpDir = await Directory.systemTemp.createTemp('immersive_retry3_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final cfgFile = File('${tmpDir.path}/config.json');

      final primaryDs = _sampleTextModel(
        id: 'tm_ds_primary',
        displayName: 'DeepSeek',
        modelId: 'deepseek-chat',
        structuredMode: 'json_object',
      ).copyWith(maxConcurrency: 4, reservedReconciliationSlots: 1);
      final fallbackQwen = _sampleTextModel(
        id: 'tm_qwen_fb',
        displayName: 'Qwen-Fallback',
        modelId: 'qwen-plus',
        structuredMode: 'json_object',
      );

      final cfg = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
        featureEnabled: true,
      ).copyWith(
        textAnalysisModels: [primaryDs, fallbackQwen],
        primaryTextModelId: primaryDs.effectiveId,
        fallbackTextModelId: fallbackQwen.effectiveId,
        textFailoverThreshold: 3,
        retry: const RetryConfig(
          maxAttempts: 4,
          initialBackoffMs: 50,
          maxBackoffMs: 100,
          jitterRatio: 0.0,
        ),
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 1.0,
          startupWaitAfterFirstReadyMs: 100,
          resumeBufferSeconds: 1.0,
          lowWaterSeconds: 5.0,
          targetBufferSeconds: 10.0,
          highWaterSeconds: 20.0,
          maxJobsBeyondFirstGap: 4,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 50,
          cancelUnneededRequestsOnSeek: true,
        ),
      );

      final store = InMemoryImmersiveStateStore();
      await store.initialize();
      var primaryChunk0Calls = 0;

      final scripted = _ScriptedTextAdapter((model, userMessage) async {
        final section = RegExp(
          r'\[TARGET_UNITS[^\]]*\]([\s\S]*?)\[/TARGET_UNITS\]',
        ).firstMatch(userMessage)?.group(1) ?? '';
        final unitIds = <String>[];
        for (final line in section.split('\n')) {
          final trimmed = line.trim();
          final idx = trimmed.indexOf(':');
          if (idx > 0) unitIds.add(trimmed.substring(0, idx).trim());
        }
        final isFirstChunk = section.contains('风吹雪落');
        if (model.modelId == 'deepseek-chat' && isFirstChunk) {
          primaryChunk0Calls++;
          throw const TextModelException(
            kind: TextModelErrorKind.transientNetwork,
            message: '模拟首块在主模型失败',
          );
        }
        return StructuredModelResponse(
          data: _validAnalysisPayload(unitIds),
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      });

      final cfgService = ImmersiveConfigService(
        documents: () async => tmpDir,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final saveRes = await cfgService.saveConfig(cfg, configFile: cfgFile);
      expect(saveRes.issues, isEmpty);

      final coord = ImmersivePlaybackCoordinator.forTesting(
        invoke: (_, _) async => true,
        configService: cfgService,
        stateStore: store,
        textAdapter: scripted,
        ttsAdapter: _FakeTtsAdapter(),
        audioCacheDir: '${tmpDir.path}/audio',
        tempDir: '${tmpDir.path}/tmp',
        platformAudioProbe: (_, dur) async => (valid: true, durationMs: dur),
      );
      addTearDown(coord.dispose);

      await coord.loadAndValidateConfig(configFile: cfgFile);
      await coord.startImmersivePlayback(
        book: Book(bookId: 'b_retry3', bookName: '重试切换测试', author: 'A'),
        chapters: [
          Chapter(itemId: 'ch0', title: '第一章', content: '风吹雪落，客栈灯火摇曳。'),
          Chapter(itemId: 'ch1', title: '第二章', content: '渡口薄雾，小船缓缓驶出。'),
        ],
        chapterIndex: 1, // 从第 2 章起听，触发前文档案补齐
      );

      for (var i = 0; i < 80 && !coord.isUsingFallbackTextModel; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      for (var i = 0; i < 80 && !coord.isPlaying; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      // 首次调用 1 次 + 自动重试 3 次 = 恰好 4 次后切换至兜底模型并顺利出声播放
      expect(primaryChunk0Calls, 4);
      expect(coord.isUsingFallbackTextModel, isTrue);
      expect(coord.isPlaying, isTrue);
    });

    test('8192 最大输出下自动限制单块单元数，且遭遇 outputTruncated 时自动对半拆块自愈', () async {
      final tmpDir = await Directory.systemTemp.createTemp('immersive_split_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final cfgFile = File('${tmpDir.path}/config.json');

      final model8k = _sampleTextModel(
        id: 'tm_ds_8k',
        displayName: 'DeepSeek-8K',
        modelId: 'deepseek-chat',
        maxOutputTokens: 8192,
        structuredMode: 'json_object',
      );
      expect(ChunkPlanner.maxSafeUnitsForOutput(model8k), lessThanOrEqualTo(50));

      final cfg = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'test-key',
        ttsApiKey: 'test-tts',
        featureEnabled: true,
      ).copyWith(
        textAnalysisModels: [model8k],
        primaryTextModelId: model8k.effectiveId,
        fallbackTextModelId: null,
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 1.0,
          startupWaitAfterFirstReadyMs: 80,
          resumeBufferSeconds: 1.0,
          lowWaterSeconds: 5.0,
          targetBufferSeconds: 10.0,
          highWaterSeconds: 20.0,
          maxJobsBeyondFirstGap: 4,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 50,
          cancelUnneededRequestsOnSeek: true,
        ),
      );

      var truncatedOnce = false;
      final scripted = _ScriptedTextAdapter((_, userMessage) async {
        final section = RegExp(
          r'\[TARGET_UNITS[^\]]*\]([\s\S]*?)\[/TARGET_UNITS\]',
        ).firstMatch(userMessage)?.group(1) ?? '';
        final unitIds = <String>[];
        for (final line in section.split('\n')) {
          final trimmed = line.trim();
          final idx = trimmed.indexOf(':');
          if (idx > 0) unitIds.add(trimmed.substring(0, idx).trim());
        }
        // 模拟超过 20 个单元的分块触发一次 finish_reason=length 截断，验证自动对半拆块
        if (!truncatedOnce && unitIds.length > 20) {
          truncatedOnce = true;
          throw const TextModelException(
            kind: TextModelErrorKind.truncated,
            message: '模拟输出长度上限截断',
          );
        }
        return StructuredModelResponse(
          data: _validAnalysisPayload(unitIds),
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      });

      final cfgService = ImmersiveConfigService(
        documents: () async => tmpDir,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await cfgService.saveConfig(cfg, configFile: cfgFile);
      final store = InMemoryImmersiveStateStore();
      await store.initialize();

      final coord = ImmersivePlaybackCoordinator.forTesting(
        invoke: (_, _) async => true,
        configService: cfgService,
        stateStore: store,
        textAdapter: scripted,
        ttsAdapter: _FakeTtsAdapter(),
        audioCacheDir: '${tmpDir.path}/audio',
        tempDir: '${tmpDir.path}/tmp',
        platformAudioProbe: (_, dur) async => (valid: true, durationMs: dur),
      );
      addTearDown(coord.dispose);

      // 构造 100 段密集短句章节
      final denseChapter = List.generate(
        100,
        (i) => '第${i + 1}句旁白与短促对白交锋。',
      ).join('\n');
      await coord.loadAndValidateConfig(configFile: cfgFile);
      await coord.startImmersivePlayback(
        book: Book(bookId: 'b_split', bookName: '拆块自愈测试', author: 'A'),
        chapters: [
          Chapter(itemId: 'ch0', title: '第一章', content: denseChapter),
          Chapter(itemId: 'ch1', title: '第二章', content: '终章水落石出。'),
        ],
        chapterIndex: 1,
      );

      for (var i = 0; i < 100 && !coord.isPlaying; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(truncatedOnce, isTrue);
      expect(coord.isPlaying, isTrue);
    });
  });
}
