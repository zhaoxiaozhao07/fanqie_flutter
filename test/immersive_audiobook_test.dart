import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/models/immersive_entities.dart';
import 'package:fanqie_flutter/immersive/services/audio_cache_manager.dart';
import 'package:fanqie_flutter/immersive/services/chunk_planner.dart';
import 'package:fanqie_flutter/immersive/services/context_builder.dart';
import 'package:fanqie_flutter/immersive/services/identity_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_audio_player_bridge.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_job_scheduler.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/services/manifest_builder.dart';
import 'package:fanqie_flutter/immersive/services/source_normalizer.dart';
import 'package:fanqie_flutter/immersive/services/text_model_adapter.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';

/// 构造一个带精确时长的最小合法 WAV 二进制音频（便于精准测试水位与解码）
Uint8List buildValidWavBytes({int durationMs = 2000, int sampleRate = 8000, int seed = 1}) {
  final numSamples = (sampleRate * durationMs) ~/ 1000;
  final dataSize = numSamples * 2;
  final totalSize = 44 + dataSize;
  final bytes = Uint8List(totalSize);
  final bd = ByteData.sublistView(bytes);
  // RIFF header
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  bd.setUint32(4, totalSize - 8, Endian.little);
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  // fmt chunk
  bytes.setRange(12, 16, ascii.encode('fmt '));
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, 1, Endian.little); // mono
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little); // byteRate
  bd.setUint16(32, 2, Endian.little); // blockAlign
  bd.setUint16(34, 16, Endian.little); // bitsPerSample
  // data chunk
  bytes.setRange(36, 40, ascii.encode('data'));
  bd.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < numSamples; i++) {
    bd.setInt16(44 + i * 2, ((i * seed) % 300) - 150, Endian.little);
  }
  return bytes;
}

/// 可控文本模型模拟器
class MockTextModelAdapter implements TextModelAdapter {
  Future<StructuredModelResponse> Function(String sys, String user)? onAnalyze;
  Future<StructuredModelResponse> Function(String sys, String user)? onRecheck;
  int analyzeCalls = 0;
  int recheckCalls = 0;

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    analyzeCalls++;
    if (onAnalyze != null) return onAnalyze!(systemMessage, userMessage);
    throw UnimplementedError();
  }

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    recheckCalls++;
    if (onRecheck != null) return onRecheck!(systemMessage, userMessage);
    return const StructuredModelResponse(
      data: {
        'decision': 'unresolved',
        'resolved_character_id': null,
        'suggested_name': null,
        'gender': 'unknown',
        'suggested_voice_profile_id': null,
        'evidence_unit_ids': <String>[],
        'reason': '默认无法确认',
      },
      latencyMs: 10,
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
      data: {'chapter_summary': '摘要', 'active_character_ids': <String>[]},
      latencyMs: 5,
      schemaVersion: ImmersiveNativeSchemas.summaryUpdateVersion,
    );
  }

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async => const AnalysisProviderTestResult(
    success: true,
    message: 'ok',
    latencyMs: 5,
    modeUsed: 'mock',
  );

  @override
  void cancelAll() {}
}

/// 可控 TTS 模拟器（可控制顺序、延迟、损坏音频）
class MockTtsProviderAdapter implements TtsProviderAdapter {
  Future<SynthesizedAudioPayload> Function(RenderSpec spec)? onSynthesize;
  final List<RenderSpec> receivedSpecs = [];

  @override
  Future<SynthesizedAudioPayload> synthesize({
    required RenderSpec spec,
    required String apiKey,
    required int timeoutMs,
    bool Function()? isCancelled,
  }) async {
    receivedSpecs.add(spec);
    if (onSynthesize != null) return onSynthesize!(spec);
    final bytes = buildValidWavBytes(durationMs: 3000, seed: receivedSpecs.length + 1);
    return SynthesizedAudioPayload(
      bytes: bytes,
      detectedFormat: 'wav',
      durationMs: 3000,
      latencyMs: 10,
    );
  }

  @override
  Future<VoiceProfileTestResult> testVoiceProfile({
    required VoiceProfileResolution resolution,
    required String apiKey,
    String sampleText = '测试',
  }) async => const VoiceProfileTestResult(
    success: true,
    message: 'ok',
    audioFormat: 'wav',
    durationMs: 1000,
    byteLength: 1000,
    latencyMs: 5,
  );

  @override
  void cancelAll() {}
}

ImmersiveConfig _testPresetConfig() =>
    ImmersivePresetConfig.createConfiguredDefault(
      textApiKey: 'sk-unit-test-text-key',
      ttsApiKey: 'sk-unit-test-tts-key',
      featureEnabled: true,
    );

void _registerSafeTempCleanup(Directory dir) {
  addTearDown(() async {
    for (var i = 0; i < 3; i++) {
      try {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
  });
}

void main() {
  group('阶段 1：配置契约与协议适配器 (C01-C10)', () {
    test('C01: 解析真实 docs/config.example.json 索引全部供应商/模型/音色并拒绝重复键', () async {
      final raw = await File('docs/config.example.json').readAsString();
      final res = ImmersiveConfigValidator.parseAndValidateJson(raw);
      expect(res.issues, isEmpty);
      expect(res.isValid, isTrue);
      final cfg = res.config!;
      expect(cfg.tts.providers.length, 2);
      final totalModels = cfg.tts.providers.fold<int>(0, (s, p) => s + p.models.length);
      expect(totalModels, 3);
      expect(cfg.voiceProfileIndex.length, 5);

      // 拒绝重复 JSON 键
      const dupJson = '{"schema_version": 1, "schema_version": 1}';
      final dupRes = ImmersiveConfigValidator.parseAndValidateJson(dupJson);
      expect(dupRes.isValid, isFalse);
      expect(dupRes.issues.first.message, contains('重复键'));
    });

    test('C02 & C03: X/Y、X/Z、x/y、x/Y 大小写严格区分且同 voice_id 精确路由', () async {
      final raw = await File('docs/config.example.json').readAsString();
      final cfg = ImmersiveConfigValidator.parseAndValidateJson(raw).config!;

      final rXY = cfg.resolveVoiceProfile('vp_a_X_Y')!;
      final rXZ = cfg.resolveVoiceProfile('vp_a_X_Z')!;
      final rxy = cfg.resolveVoiceProfile('vp_a_x_y')!;
      final rxY = cfg.resolveVoiceProfile('vp_a_x_Y')!;

      expect(rXY.model.modelId, 'X');
      expect(rXY.voice.voiceId, 'Y');
      expect(rxy.model.modelId, 'x');
      expect(rxy.voice.voiceId, 'y');
      expect(rxY.model.modelId, 'x');
      expect(rxY.voice.voiceId, 'Y');

      final specs = [rXY, rXZ, rxy, rxY]
          .map((r) => RenderSpec.fromResolution(resolution: r, inputText: '同一句话'))
          .toList();
      final keys = specs.map((s) => s.requestKey).toSet();
      expect(keys.length, 4, reason: '四个大小写组合必须产生四个独立缓存 request_key');

      // 请求体精确原值发送，不转小写
      final bodyUpper = OpenAiSpeechTtsAdapter.buildRequestBody(specs[0]);
      final bodyLower = OpenAiSpeechTtsAdapter.buildRequestBody(specs[2]);
      expect(bodyUpper['model'], 'X');
      expect(bodyUpper['voice'], 'Y');
      expect(bodyLower['model'], 'x');
      expect(bodyLower['voice'], 'y');
    });

    test('C04: 旁白不在人物候选池配置有效，系统消息包含去重并集并明确用途', () async {
      final raw = await File('docs/config.example.json').readAsString();
      final cfg = ImmersiveConfigValidator.parseAndValidateJson(raw).config!;
      expect(
        cfg.bookDefaults.selectedVoiceProfileIds
            .contains(cfg.bookDefaults.narratorVoiceProfileId),
        isFalse,
      );
      final bookCfg = BookAudioConfig(
        bookId: 'b1',
        selectedVoiceProfileIds: cfg.bookDefaults.selectedVoiceProfileIds,
        narratorVoiceProfileId: cfg.bookDefaults.narratorVoiceProfileId,
        updatedAtMs: 1,
      );
      expect(bookCfg.systemCatalogVoiceProfileIds.length, 5);
      final sys = ContextBuilder.buildSystemMessage(
        config: cfg,
        bookConfig: bookCfg,
      );
      expect(sys.message, contains('vp_b_narrator'));
      expect(sys.message, contains('固定旁白专用'));
      expect(sys.message, contains('vp_a_X_Y'));
      expect(sys.message, contains('人物对白候选音色'));
    });

    test('C05 & 预置配置: 并发=1 保留席位必须为 0；预置 13 音色与去后缀规则合法且默认无硬编码密钥', () {
      final rawDefault = ImmersivePresetConfig.createConfiguredDefault();
      expect(ImmersiveConfigValidator.validateConfig(rawDefault), isEmpty);
      expect(rawDefault.textAnalysis.apiKey ?? '', isEmpty);
      expect(rawDefault.tts.providers.first.apiKey ?? '', isEmpty);
      expect(rawDefault.featureEnabled, isFalse);

      final preset = _testPresetConfig();
      final issues = ImmersiveConfigValidator.validateConfig(preset);
      expect(issues, isEmpty);
      expect(preset.textAnalysis.maxConcurrency, 3);
      expect(preset.textAnalysis.thinkingLevel, TextThinkingLevel.auto);
      expect(preset.textAnalysisModels.length, 3);
      expect(deriveVoiceIdFromModel('DeepSeek_female'), 'DeepSeek');
      expect(deriveVoiceIdFromModel('Anthropic_male'), 'Anthropic');
      expect(preset.voiceProfileIndex.length, 13);

      // 并发=1 且保留席=1 报错；改为保留席=0 通过
      final invalidConc = preset.copyWith(
        textAnalysis: preset.textAnalysis.copyWith(
          maxConcurrency: 1,
          reservedReconciliationSlots: 1,
        ),
      );
      expect(ImmersiveConfigValidator.validateConfig(invalidConc), isNotEmpty);

      final validConc1 = preset.copyWith(
        textAnalysis: preset.textAnalysis.copyWith(
          maxConcurrency: 1,
          reservedReconciliationSlots: 0,
        ),
      );
      expect(ImmersiveConfigValidator.validateConfig(validConc1), isEmpty);
    });

    test('C06 & C07 & C09 & C10: 禁止覆盖受保护字段、占位值拦截、省略 null、保留 /v1', () async {
      final raw = await File('docs/config.example.json').readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;

      // C07: 占位配置开启 feature_enabled=true 时校验报错
      map['feature_enabled'] = true;
      final placeholderRes = ImmersiveConfigValidator.parseAndValidateMap(map);
      expect(placeholderRes.isValid, isFalse);

      // C06: extra_body 覆盖 model / response_format 报错
      map['feature_enabled'] = false;
      (map['text_analysis'] as Map<String, dynamic>)['extra_body'] = {
        'model': 'hacked',
      };
      final overrideRes = ImmersiveConfigValidator.parseAndValidateMap(map);
      expect(overrideRes.isValid, isFalse);
      expect(
        overrideRes.issues.any((i) => i.path.contains('extra_body.model')),
        isTrue,
      );

      // C09 & C10: temperature=null 与 instructions=null 严格省略，URL 保留 /v1
      final preset = _testPresetConfig();
      final textBody = OpenAiChatTextModelAdapter.buildRequestBody(
        config: preset.textAnalysis,
        taskSchemaSuffix: 'test',
        toolDescription: 'test',
        schema: ImmersiveNativeSchemas.chunkAnalysisSchema(),
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      expect(textBody.containsKey('temperature'), isFalse);

      final ttsSpec = RenderSpec.fromResolution(
        resolution: preset.resolveVoiceProfile('vp_oneapi_DeepSeek_female')!,
        inputText: '你好',
      );
      final ttsBody = OpenAiSpeechTtsAdapter.buildRequestBody(ttsSpec);
      expect(ttsBody.containsKey('instructions'), isFalse);
      expect(ttsBody['model'], 'DeepSeek_female');
      expect(ttsBody['voice'], 'DeepSeek');

      expect(
        joinProviderUrl('https://oneapi.971218.xyz/v1', '/audio/speech').toString(),
        'https://oneapi.971218.xyz/v1/audio/speech',
      );
      expect(
        joinProviderUrl('http://ingsys.net:8099/v1/', '/chat/completions').toString(),
        'http://ingsys.net:8099/v1/chat/completions',
      );
    });

    test('C08: 原生 Schema 不支持时明确报协议不兼容，绝不降级提示词 JSON', () async {
      final mockHttp = MockClient((req) async {
        // 模拟供应商返回普通文本而非 tool_calls
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': '好的，以下是JSON: {}'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final adapter = OpenAiChatTextModelAdapter(mockHttp);
      final preset = _testPresetConfig();
      await expectLater(
        () => adapter.analyzeChunk(
          config: preset.textAnalysis,
          apiKey: 'test-key',
          systemMessage: 'sys',
          userMessage: 'usr',
        ),
        throwsA(
          isA<TextModelException>().having(
            (e) => e.kind,
            'kind',
            TextModelErrorKind.unsupportedStructuredOutput,
          ),
        ),
      );
    });

    test('A11: TTS 返回 HTTP 200 JSON 错误体或损坏音频时拒绝标 ready', () async {
      final badClient = MockClient((req) async {
        return http.Response(
          '{"error":"bad"}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final adapter = OpenAiSpeechTtsAdapter(badClient);
      final preset = _testPresetConfig();
      final spec = RenderSpec.fromResolution(
        resolution: preset.resolveVoiceProfile('vp_oneapi_DeepSeek_female')!,
        inputText: '测试',
      );
      await expectLater(
        () => adapter.synthesize(spec: spec, apiKey: 'k', timeoutMs: 5000),
        throwsA(
          isA<TtsAdapterException>().having(
            (e) => e.kind,
            'kind',
            TtsAdapterErrorKind.invalidAudioPayload,
          ),
        ),
      );

      // 二进制头损坏也拒绝
      expect(
        () => AudioFormatInspector.inspectBytes(Uint8List.fromList(List.filled(64, 0x11))),
        throwsA(isA<TtsAdapterException>()),
      );
    });
  });

  group('阶段 2 & 3：原文定位、角色记忆与有序确认 (I01-I13)', () {
    test('I03 & I12: 对白-旁白-对白精确切分、重复句独立 ID 与 emoji Unicode 码点计数', () {
      const chText = '“别动。”林岚说，“后面有人。”\n\n走吧！\n\n走吧！🔥';
      final snap = SourceNormalizer.normalizeChapters(
        bookId: 'book_1',
        chapters: [Chapter(itemId: 'c1', title: '第一章', order: 1)],
        chapterRawTexts: {'c1': chText},
      );
      final units = snap.allUnits;
      // 第一段被准确分为 3 个 unit
      final p0Units = units.where((u) => u.paragraphIndex == 0).toList();
      expect(p0Units.length, 3);
      expect(p0Units[0].text, '“别动。”');
      expect(p0Units[1].text, '林岚说，');
      expect(p0Units[2].text, '“后面有人。”');
      expect(p0Units.map((u) => u.text).join(), '“别动。”林岚说，“后面有人。”');

      // 重复句有不同 unit_id，不按文本哈希去重
      final p1 = units.firstWhere((u) => u.paragraphIndex == 1);
      final p2 = units.firstWhere((u) => u.paragraphIndex == 2);
      expect(p1.unitId, isNot(p2.unitId));
      // 🔥 UTF-16 length=2，Unicode 码点数=1
      expect(p2.text.length, 5);
      expect(p2.codePointLength, 4);

      // 原文锚点子单元拆分验证
      final subUnits = SourceNormalizer.splitUnitWithAnchors(p0Units[1], ['林岚', '说，']);
      expect(subUnits.map((u) => u.text).join(), p0Units[1].text);
    });

    test('I11 & I13: 缺失/重复/乱序/越界/不存在角色 ID 均被业务校验拒绝', () {
      final snap = SourceNormalizer.normalizeChapters(
        bookId: 'b',
        chapters: [Chapter(itemId: 'c1', title: '一', order: 1)],
        chapterRawTexts: {'c1': '林岚问：“你好。”'},
      );
      final unitById = {for (final u in snap.allUnits) u.unitId: u};
      final chunk = AnalysisChunk(
        chunkId: 'chk_0',
        bookRevisionId: snap.revision.revisionId,
        bookId: 'b',
        chapterIndex: 0,
        chapterId: 'c1',
        chunkOrder: 0,
        targetUnitIds: snap.allUnits.map((u) => u.unitId).toList(),
        contextBeforeUnitIds: const [],
        contextAfterUnitIds: const [],
        startGlobalOrder: 0,
        endGlobalOrder: snap.allUnits.last.globalOrder,
        estimatedTokens: 20,
      );

      // 遗漏最后一个 unit
      expect(
        () => IdentityCoordinator.validateDraftAgainstChunk(
          payload: {
            'assignments': [
              {
                'source_unit_ids': [snap.allUnits.first.unitId],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [snap.allUnits.first.unitId],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': const [],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          chunk: chunk,
          unitById: unitById,
          knownCharacterIds: const {},
        ),
        throwsA(isA<DraftSemanticValidationException>()),
      );

      // 引用不存在角色 ID (I13)
      expect(
        () => IdentityCoordinator.validateDraftAgainstChunk(
          payload: {
            'assignments': [
              {
                'source_unit_ids': [snap.allUnits[0].unitId],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [snap.allUnits[0].unitId],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': [snap.allUnits[1].unitId],
                'kind': 'dialogue',
                'speaker_ref': 'char_not_exist',
                'evidence_unit_ids': [snap.allUnits[0].unitId],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': const [],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          chunk: chunk,
          unitById: unitById,
          knownCharacterIds: const {},
        ),
        throwsA(isA<DraftSemanticValidationException>()),
      );
    });

    test('I01/I02/I05/I06/I08/I09: 乱序草稿有序提交、泛称不合并、心理与引用旁白、未确定兜底与可逆冲突合并', () async {
      final preset = _testPresetConfig();
      final store = InMemoryImmersiveStateStore();
      await store.initialize();
      final coord = IdentityCoordinator(store);

      final sampleText = await File('test/fixtures/immersive_sample_book.txt').readAsString();
      final parts = sampleText.split('第二章 渡口重逢');
      final chapters = [
        Chapter(itemId: 'ch1', title: '第一章 雪夜来客', order: 1, content: parts[0]),
        Chapter(itemId: 'ch2', title: '第二章 渡口重逢', order: 2, content: parts[1]),
      ];
      final snap = SourceNormalizer.normalizeChapters(
        bookId: 'sample_book',
        chapters: chapters,
        chapterRawTexts: {'ch1': parts[0], 'ch2': parts[1]},
      );
      final bookCfg = BookAudioConfig(
        bookId: 'sample_book',
        selectedVoiceProfileIds: preset.bookDefaults.selectedVoiceProfileIds,
        narratorVoiceProfileId: preset.bookDefaults.narratorVoiceProfileId,
        updatedAtMs: 1,
      );
      await store.saveBookAudioConfig(bookCfg);

      // 每章各 1 个 chunk
      final ch1Units = snap.allUnits.where((u) => u.chapterIndex == 0).toList();
      final ch2Units = snap.allUnits.where((u) => u.chapterIndex == 1).toList();
      final chunk0 = AnalysisChunk(
        chunkId: 'chk_0',
        bookRevisionId: snap.revision.revisionId,
        bookId: 'sample_book',
        chapterIndex: 0,
        chapterId: 'ch1',
        chunkOrder: 0,
        targetUnitIds: ch1Units.map((u) => u.unitId).toList(),
        contextBeforeUnitIds: const [],
        contextAfterUnitIds: [ch2Units.first.unitId],
        startGlobalOrder: ch1Units.first.globalOrder,
        endGlobalOrder: ch1Units.last.globalOrder,
        estimatedTokens: 300,
      );
      final chunk1 = AnalysisChunk(
        chunkId: 'chk_1',
        bookRevisionId: snap.revision.revisionId,
        bookId: 'sample_book',
        chapterIndex: 1,
        chapterId: 'ch2',
        chunkOrder: 1,
        targetUnitIds: ch2Units.map((u) => u.unitId).toList(),
        contextBeforeUnitIds: [ch1Units.last.unitId],
        contextAfterUnitIds: const [],
        startGlobalOrder: ch2Units.first.globalOrder,
        endGlobalOrder: ch2Units.last.globalOrder,
        estimatedTokens: 200,
      );
      await store.saveBookRevisionWithUnits(
        revision: snap.revision,
        units: snap.allUnits,
        chunks: [chunk0, chunk1],
      );

      // 故意先写入 chunk1 草稿（模拟并发乱序返回 I06）：确认前沿不得推进
      Map<String, dynamic> buildSimpleDraft(List<SourceUnit> units, {required bool isCh2}) {
        final assigns = <Map<String, dynamic>>[];
        final newChars = <Map<String, dynamic>>[];
        if (!isCh2) {
          newChars.addAll([
            {
              'local_ref': 'local:new_1',
              'display_name': '林岚',
              'gender': 'female',
              'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
              'evidence_unit_ids': [units.first.unitId],
            },
            {
              'local_ref': 'local:new_2',
              'display_name': '李青',
              'gender': 'male',
              'suggested_voice_profile_id': 'vp_oneapi_wenxin_male',
              'evidence_unit_ids': [units.first.unitId],
            },
            {
              'local_ref': 'local:new_3',
              'display_name': '黑衣人',
              'gender': 'male',
              'suggested_voice_profile_id': 'vp_oneapi_tongyi_male',
              'evidence_unit_ids': [units.first.unitId],
            },
            {
              'local_ref': 'local:new_4',
              'display_name': '黑衣人',
              'gender': 'male',
              'suggested_voice_profile_id': 'vp_oneapi_xunfei_male',
              'evidence_unit_ids': [units.first.unitId],
            },
          ]);
        } else {
          // 模拟旧快照把李青再次提议为局部新角色 + 提议老船夫
          newChars.addAll([
            {
              'local_ref': 'local:new_1',
              'display_name': '李青',
              'gender': 'male',
              'suggested_voice_profile_id': 'vp_oneapi_tongyi_male',
              'evidence_unit_ids': [units.first.unitId],
            },
            {
              'local_ref': 'local:new_2',
              'display_name': '老船夫',
              'gender': 'male',
              'suggested_voice_profile_id': 'vp_oneapi_xunfei_male',
              'evidence_unit_ids': [units.first.unitId],
            },
          ]);
        }

        for (final u in units) {
          if (u.text.contains('心里暗想')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'inner_monologue',
              'speaker_ref': 'narrator',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.contains('子时三刻')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'quoted_text',
              'speaker_ref': 'narrator',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.contains('这趟浑水')) {
            // I08: 未确定说话人
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': null,
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'unresolved',
            });
          } else if (u.text.startsWith('“') && u.text.contains('交出玉佩')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_3',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.startsWith('“') && u.text.contains('废话少说')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_4',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.startsWith('“') && !isCh2 && u.text.contains('你终于来了')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_1',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.startsWith('“') && !isCh2) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_2',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.startsWith('“') && isCh2 && u.text.contains('有劳船家')) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_1',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else if (u.text.startsWith('“') && isCh2) {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'dialogue',
              'speaker_ref': 'local:new_2',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          } else {
            assigns.add({
              'source_unit_ids': [u.unitId],
              'kind': 'narration',
              'speaker_ref': 'narrator',
              'evidence_unit_ids': [u.unitId],
              'evidence_type': 'explicit_attribution',
            });
          }
        }
        return {
          'assignments': assigns,
          'new_character_proposals': newChars,
          'identity_link_proposals': const [],
          'unresolved_items': const [],
        };
      }

      // 先存 chunk1（未来块先完成）
      await store.saveDraft(
        AnalysisDraft(
          draftId: 'd1',
          bookId: 'sample_book',
          bookRevisionId: snap.revision.revisionId,
          chunkId: 'chk_1',
          chunkOrder: 1,
          analysisRunRevision: 1,
          snapshotRegistryRevision: 1,
          castRevision: 1,
          payloadJson: jsonEncode(buildSimpleDraft(ch2Units, isCh2: true)),
          createdAtMs: 100,
        ),
      );
      final earlyOut = await coord.drainOrderedCommits(
        bookId: 'sample_book',
        bookRevisionId: snap.revision.revisionId,
        config: preset,
      );
      expect(earlyOut, isEmpty, reason: '前块未完成时，后块草稿不得越序提交');

      // 再存 chunk0，一次性有序排空 chunk0 -> chunk1
      await store.saveDraft(
        AnalysisDraft(
          draftId: 'd0',
          bookId: 'sample_book',
          bookRevisionId: snap.revision.revisionId,
          chunkId: 'chk_0',
          chunkOrder: 0,
          analysisRunRevision: 1,
          snapshotRegistryRevision: 1,
          castRevision: 1,
          payloadJson: jsonEncode(buildSimpleDraft(ch1Units, isCh2: false)),
          createdAtMs: 200,
        ),
      );
      final outs = await coord.drainOrderedCommits(
        bookId: 'sample_book',
        bookRevisionId: snap.revision.revisionId,
        config: preset,
      );
      expect(outs.length, 2);
      expect(outs.every((o) => o.committed), isTrue);

      final chars = await store.getCharacters('sample_book');
      // 两个黑衣人绝不自动合并（I02）
      final blackMen = chars.where((c) => c.canonicalName == '黑衣人').toList();
      expect(blackMen.length, 2);

      // 第二章的“李青”即使在旧快照里被提议为 local:new_1，有序提交时仍准确复用第一章的同一 character_id 和固定音色（I01/I06/I07）
      final liQings = chars.where((c) => c.canonicalName == '李青').toList();
      expect(liQings.length, 1);
      final liBinding = await store.getVoiceBinding('sample_book', liQings.first.characterId);
      expect(liBinding!.voiceProfileId, 'vp_oneapi_wenxin_male');

      // I05 & I08 & A24: 心理/书信全旁白；未确定对白 accepted + unresolved + 旁白兜底，且无永久“未知人”
      expect(chars.any((c) => c.canonicalName.contains('未知')), isFalse);
      final allocs = await store.getAllocations('sample_book', snap.revision.revisionId);
      final unresolved = allocs.where((a) => a.speakerResolution == SpeakerResolution.unresolved).toList();
      expect(unresolved.length, 1);
      expect(unresolved.first.allocationStatus, AllocationStatus.accepted);
      expect(unresolved.first.speakerRef, isNull);
      expect(unresolved.first.effectiveVoiceProfileId, preset.bookDefaults.narratorVoiceProfileId);
      expect(unresolved.first.isReadyForTts, isTrue);

      // I09: 可逆合并与撤销拆分
      final mergeChange = await coord.mergeCharacters(
        bookId: 'sample_book',
        sourceCharacterId: blackMen[1].characterId,
        targetCharacterId: blackMen[0].characterId,
        resolvedVoiceProfileId: 'vp_oneapi_tongyi_male',
      );
      var afterMerge = await store.getCharacters('sample_book');
      expect(
        afterMerge.firstWhere((c) => c.characterId == blackMen[1].characterId).status,
        'merged',
      );
      final undone = await coord.undoIdentityChange(
        bookId: 'sample_book',
        changeId: mergeChange.changeId,
      );
      expect(undone, isTrue);
      afterMerge = await store.getCharacters('sample_book');
      expect(
        afterMerge.firstWhere((c) => c.characterId == blackMen[1].characterId).status,
        isNot('merged'),
      );
    });
  });

  group('阶段 4-6：调度器配额、fence 防迟到、缓存互斥与顺序播放器 (A01-A25)', () {
    test('A04 & A05: 供应商共享并发/模型子上限/复核保留席位防饿死', () {
      final pool = SchedulerQuotaPool();
      final textCfg = _testPresetConfig().textAnalysis;
      // 并发=3，保留复核席位=1 -> 普通候选最多占 2 席，复核永远有第 3 席（A05）
      expect(pool.tryAcquireText(config: textCfg, isReconciliation: false), isTrue);
      expect(pool.tryAcquireText(config: textCfg, isReconciliation: false), isTrue);
      expect(pool.tryAcquireText(config: textCfg, isReconciliation: false), isFalse);
      expect(pool.tryAcquireText(config: textCfg, isReconciliation: true), isTrue);
      pool.releaseText(isReconciliation: true);
      pool.releaseText(isReconciliation: false);
      pool.releaseText(isReconciliation: false);

      // 供应商共享并发与模型子上限，满额供应商不占死全局槽（A04）
      final raw = File('docs/config.example.json').readAsStringSync();
      final cfg = ImmersiveConfigValidator.parseAndValidateJson(raw).config!;
      final rUpperX = cfg.resolveVoiceProfile('vp_a_X_Y')!; // model max 4, provider max 4, fg reserved 1 -> bg max 3
      final rLowerX = cfg.resolveVoiceProfile('vp_a_x_y')!; // model max 2, same provider A
      final rProvB = cfg.resolveVoiceProfile('vp_b_narrator')!; // provider B max 2

      // 模型 x 最多 2 并发（模型子限额）
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rLowerX, isForegroundPriority: true), isTrue);
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rLowerX, isForegroundPriority: true), isTrue);
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rLowerX, isForegroundPriority: true), isFalse);
      // 同供应商模型 X 还可再占 2 席，填满供应商 A 总上限 4
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rUpperX, isForegroundPriority: true), isTrue);
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rUpperX, isForegroundPriority: true), isTrue);
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rUpperX, isForegroundPriority: true), isFalse);
      // 此时供应商 B 依然可正常拿到全局第 5、6 席，不被满额供应商 A 阻塞
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rProvB, isForegroundPriority: true), isTrue);
      expect(pool.tryAcquireTts(ttsConfig: cfg.tts, resolution: rProvB, isForegroundPriority: true), isTrue);
    });

    test('A09 & A10 & A14 & A23: 多 worker 认领、租约过期 fence 防迟到覆盖、缓存钉住互斥淘汰', () async {
      final tmp = await Directory.systemTemp.createTemp('immersive_cache_test_');
      _registerSafeTempCleanup(tmp);

      final store = InMemoryImmersiveStateStore();
      var now = DateTime(2026, 11, 25, 12, 0, 0);
      final cache = AudioCacheManager(
        store: store,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        cacheConfig: const CacheConfig(
          maxBytes: 120000,
          evictToRatio: 0.5,
          minFreeDiskBytes: 0,
          protectRecentPlaybackSeconds: 0,
          verifyChecksumOnReuse: true,
        ),
        now: () => now,
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
      );

      final job = ImmersiveJob(
        jobKey: 'tts:req_1',
        jobType: ImmersiveJobType.ttsSynthesize,
        bookId: 'b1',
        bookRevisionId: 'r1',
        status: ImmersiveJobStatus.queued,
        priority: 0,
        inputVersion: 'v1',
        payloadJson: '{}',
        createdAtMs: now.millisecondsSinceEpoch,
        updatedAtMs: now.millisecondsSinceEpoch,
      );
      await store.enqueueOrReviveJob(job);

      // A09: 两个 worker 竞争认领，仅 A 成功
      final claimA = await store.claimJob(
        jobKey: job.jobKey,
        workerId: 'workerA',
        leaseSeconds: 60,
        nowMs: now.millisecondsSinceEpoch,
      );
      final claimB1 = await store.claimJob(
        jobKey: job.jobKey,
        workerId: 'workerB',
        leaseSeconds: 60,
        nowMs: now.millisecondsSinceEpoch,
      );
      expect(claimA, isNotNull);
      expect(claimB1, isNull);

      // A10: A 租约过期，B 接管递增 fence 并率先成功发布；A 迟到尝试发布被拒绝且不覆盖 B
      now = now.add(const Duration(seconds: 65));
      final claimB2 = await store.claimJob(
        jobKey: job.jobKey,
        workerId: 'workerB',
        leaseSeconds: 60,
        nowMs: now.millisecondsSinceEpoch,
      );
      expect(claimB2, isNotNull);
      expect(claimB2!.fence, greaterThan(claimA!.fence));

      final wavB = buildValidWavBytes(durationMs: 2500, seed: 2);
      final resB = await cache.writeAndPublishAtomically(
        jobKey: job.jobKey,
        workerId: 'workerB',
        attempt: claimB2.attempt,
        fence: claimB2.fence,
        requestKey: 'req_1',
        audio: SynthesizedAudioPayload(bytes: wavB, detectedFormat: 'wav', durationMs: 2500, latencyMs: 5),
      );
      expect(resB.publishResult.published, isTrue);

      final wavA = buildValidWavBytes(durationMs: 1500, seed: 9);
      final resA = await cache.writeAndPublishAtomically(
        jobKey: job.jobKey,
        workerId: 'workerA',
        attempt: claimA.attempt,
        fence: claimA.fence,
        requestKey: 'req_1',
        audio: SynthesizedAudioPayload(bytes: wavA, detectedFormat: 'wav', durationMs: 1500, latencyMs: 5),
      );
      expect(resA.publishResult.published, isFalse);
      final storedAsset = await store.getAudioAsset('req_1');
      expect(storedAsset!.durationMs, 2500, reason: '旧 worker 迟到绝不能覆盖新 worker 的索引');

      // A14 & A23: 钉住 req_1，继续写入大缓存触发 LRU 淘汰时，req_1 受保护不被删除
      final pinned = await cache.acquireAssetForPlayback('req_1');
      expect(pinned, isNotNull);

      for (var k = 2; k <= 5; k++) {
        now = now.add(const Duration(seconds: 1));
        final j = ImmersiveJob(
          jobKey: 'tts:req_$k',
          jobType: ImmersiveJobType.ttsSynthesize,
          bookId: 'b1',
          bookRevisionId: 'r1',
          status: ImmersiveJobStatus.queued,
          priority: 1,
          inputVersion: 'v1',
          payloadJson: '{}',
          createdAtMs: now.millisecondsSinceEpoch,
          updatedAtMs: now.millisecondsSinceEpoch,
        );
        await store.enqueueOrReviveJob(j);
        final c = await store.claimJob(
          jobKey: j.jobKey,
          workerId: 'w',
          leaseSeconds: 60,
          nowMs: now.millisecondsSinceEpoch,
        );
        await cache.writeAndPublishAtomically(
          jobKey: j.jobKey,
          workerId: 'w',
          attempt: c!.attempt,
          fence: c.fence,
          requestKey: 'req_$k',
          audio: SynthesizedAudioPayload(
            bytes: buildValidWavBytes(durationMs: 2500, seed: k + 10),
            detectedFormat: 'wav',
            durationMs: 2500,
            latencyMs: 5,
          ),
        );
      }

      expect(await store.getAudioAsset('req_1'), isNotNull, reason: '钉住的当前播放文件绝不能被淘汰');
      expect(await File(pinned!.asset.filePath).exists(), isTrue);
      pinned.release();
    });

    test('A01/A02/A06/A07/A08/A15/A21/A22: 乱序完成顺序播放、缺口等待、倍速不重合成、seek epoch 隔离、局部失效与播放中切边界', () async {
      final tmp = await Directory.systemTemp.createTemp('immersive_e2e_test_');
      _registerSafeTempCleanup(tmp);

      final preset = _testPresetConfig().copyWith(
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 2.0,
          startupWaitAfterFirstReadyMs: 50,
          resumeBufferSeconds: 2.0,
          lowWaterSeconds: 10.0,
          targetBufferSeconds: 20.0,
          highWaterSeconds: 40.0,
          maxJobsBeyondFirstGap: 8,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 50,
          cancelUnneededRequestsOnSeek: true,
        ),
        audioGeneration: const AudioGenerationConfig(
          startupTargetCharacters: 15,
          targetCharacters: 20,
          maxCharacters: 60,
        ),
      );
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await cfgSvc.saveConfig(preset, configFile: cfgFile);

      final store = InMemoryImmersiveStateStore();
      final mockText = MockTextModelAdapter();
      final mockTts = MockTtsProviderAdapter();

      // 构造 4 段清晰交替台词（旁白 -> 林岚 -> 旁白 -> 李青）
      const chText = '林岚开口问道：\n\n“你今天过得怎么样？”\n\n李青微微一笑：\n\n“一切顺利，谢谢关心。”';
      mockText.onAnalyze = (sys, user) async {
        final targetSection = user.split('[TARGET_UNITS').last.split('[/TARGET_UNITS]').first;
        final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
            .allMatches(targetSection)
            .map((m) => m.group(1)!)
            .toList();
        return StructuredModelResponse(
          data: {
            'assignments': [
              {
                'source_unit_ids': [ids[0]],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': [ids[1]],
                'kind': 'dialogue',
                'speaker_ref': 'local:new_1',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': [ids[2]],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids[2]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': [ids[3]],
                'kind': 'dialogue',
                'speaker_ref': 'local:new_2',
                'evidence_unit_ids': [ids[2]],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': [
              {
                'local_ref': 'local:new_1',
                'display_name': '林岚',
                'gender': 'female',
                'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
                'evidence_unit_ids': [ids[0]],
              },
              {
                'local_ref': 'local:new_2',
                'display_name': '李青',
                'gender': 'male',
                'suggested_voice_profile_id': 'vp_oneapi_wenxin_male',
                'evidence_unit_ids': [ids[2]],
              },
            ],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      };

      // A01: 控制 TTS 乱序返回：第 3 段最快(5ms)、第 1 段(40ms)、第 4 段(10ms)、第 2 段最慢(90ms)
      mockTts.onSynthesize = (spec) async {
        final delayMs = spec.inputText.contains('微微一笑')
            ? 5
            : spec.inputText.contains('一切顺利')
                ? 10
                : spec.inputText.contains('林岚开口')
                    ? 40
                    : 90;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        return SynthesizedAudioPayload(
          bytes: buildValidWavBytes(durationMs: 3000, seed: delayMs),
          detectedFormat: 'wav',
          durationMs: 3000,
          latencyMs: delayMs,
        );
      };

      final playedFiles = <String>[];
      final playedTokens = <String>[];
      final playedRates = <double>[];

      final coordinator = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: mockText,
        ttsAdapter: mockTts,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (method, args) async {
          if (method == 'playAudioFile') {
            playedTokens.add(args!['id'] as String);
            playedFiles.add(args['filePath'] as String);
            playedRates.add((args['rate'] as num).toDouble());
            return true;
          }
          if (method == 'setPlaybackRate') {
            playedRates.add((args!['rate'] as num).toDouble());
            return true;
          }
          return true;
        },
      );
      addTearDown(coordinator.dispose);

      await coordinator.loadAndValidateConfig(configFile: cfgFile);
      final book = Book(
        bookId: 'test_e2e_book',
        bookName: '测试书',
        author: '作者',
      );
      final chapters = [
        Chapter(itemId: 'c1', title: '第一章', order: 1, content: chText),
      ];

      await coordinator.startImmersivePlayback(
        book: book,
        chapters: chapters,
        chapterIndex: 0,
      );

      // 等待全部 4 段准备就绪并开始播放第 0 段
      for (var w = 0; w < 60 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(coordinator.isPlaying, isTrue);
      expect(coordinator.currentSegmentIndex, 0);
      expect(coordinator.currentSegment!.spokenText, contains('林岚开口'));

      // 等待全部 4 段缓存完成
      for (var w = 0; w < 60; w++) {
        final st = await coordinator.getPipelineStatus();
        if (st.readyAudioSegments == 4) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      // A06: 倍速 1x -> 2x 不触发重新合成，连续可播秒数减半
      final synthCountBeforeRate = mockTts.receivedSpecs.length;
      final secAt1x = await coordinator.computeContinuousReadySeconds();
      await coordinator.setPlaybackRate(2.0);
      final secAt2x = await coordinator.computeContinuousReadySeconds();
      expect(mockTts.receivedSpecs.length, synthCountBeforeRate);
      expect(secAt2x, closeTo(secAt1x / 2.0, 0.2));
      await coordinator.setPlaybackRate(1.0);

      // A15 & A22: 播放第 0 段期间修改“林岚”音色 -> 第 0 段保持不被打断，仅第 1 段（林岚）新 requestKey，李青与旁白继续命中缓存
      final chars = await store.getCharacters(book.bookId);
      final linLan = chars.firstWhere((c) => c.canonicalName == '林岚');
      final oldSeg0Key = coordinator.manifestSegments[0].requestKey;
      final oldSeg3Key = coordinator.manifestSegments[3].requestKey;
      await coordinator.setCharacterVoice(
        bookId: book.bookId,
        characterId: linLan.characterId,
        voiceProfileId: 'vp_oneapi_Kimi_female',
      );
      expect(coordinator.manifestSegments[0].requestKey, oldSeg0Key);
      expect(coordinator.manifestSegments[1].voiceProfileId, 'vp_oneapi_Kimi_female');
      expect(coordinator.manifestSegments[3].requestKey, oldSeg3Key, reason: '无关角色缓存继续命中');

      // 模拟第 0 段播完 -> 自动顺播第 1 段（已用新音色 Kimi 合成），验证严格顺序 0 -> 1 -> 2 -> 3
      for (var w = 0; w < 40; w++) {
        if (coordinator.manifestSegments[1].status == AudioSegmentStatus.ready) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final playedOrderTexts = <String>[coordinator.currentSegment!.spokenText];
      for (var step = 0; step < 3; step++) {
        final curTok = playedTokens.last;
        coordinator.handlePlatformEvent('onAudioComplete', {'id': curTok});
        for (var w = 0; w < 40; w++) {
          if (coordinator.isPlaying && coordinator.currentSegmentIndex == step + 1) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        playedOrderTexts.add(coordinator.currentSegment!.spokenText);
      }
      expect(playedOrderTexts[0], contains('林岚开口'));
      expect(playedOrderTexts[1], contains('你今天过得怎么样'));
      expect(playedOrderTexts[2], contains('李青微微一笑'));
      expect(playedOrderTexts[3], contains('一切顺利'));

      // A07: seek 后旧 playback_epoch 回调被忽略，绝不推进新会话
      final staleToken = playedTokens.last;
      await coordinator.seekToSource(
        chapterIndex: 0,
        position: const ReadingPosition(chapterId: 'c1', paragraphIndex: 0, characterOffset: 0),
      );
      for (var w = 0; w < 40 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(coordinator.currentSegmentIndex, 0);
      coordinator.handlePlatformEvent('onAudioComplete', {'id': staleToken});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(coordinator.currentSegmentIndex, 0, reason: '旧 epoch 完成回调不得控制新播放会话');

      // A08: 暂停持久保存 userPaused=true
      await coordinator.pause();
      expect(coordinator.isPaused, isTrue);
      final savedCursor = await store.getPlaybackCursor(book.bookId);
      expect(savedCursor?.userPaused, isTrue);

      // A21: 资产被淘汰后 seek 回该段，能原子递增执行代次重建并恢复播放
      final seg0Key = coordinator.manifestSegments[0].requestKey;
      final oldAsset = await store.getAudioAsset(seg0Key);
      await store.deleteAudioAsset(seg0Key);
      if (oldAsset != null && await File(oldAsset.filePath).exists()) {
        await File(oldAsset.filePath).delete();
      }
      await coordinator.seekToSource(
        chapterIndex: 0,
        position: const ReadingPosition(chapterId: 'c1', paragraphIndex: 0, characterOffset: 0),
      );
      for (var w = 0; w < 60 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(coordinator.isPlaying, isTrue);
      final revivedJob = await store.getJob('tts:$seg0Key');
      expect(revivedJob!.executionGeneration, greaterThanOrEqualTo(2));
    });

    test('I10 & A25: 从中间章节首次起听补齐前文人物档案且绝不合成前文音频', () async {
      final tmp = await Directory.systemTemp.createTemp('immersive_mid_start_');
      addTearDown(() async {
        try {
          if (await tmp.exists()) {
            await tmp.delete(recursive: true);
          }
        } catch (_) {}
      });

      final preset = _testPresetConfig().copyWith(
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 2.0,
          startupWaitAfterFirstReadyMs: 50,
          resumeBufferSeconds: 2.0,
          lowWaterSeconds: 10.0,
          targetBufferSeconds: 20.0,
          highWaterSeconds: 40.0,
          maxJobsBeyondFirstGap: 8,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 50,
          cancelUnneededRequestsOnSeek: true,
        ),
      );
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final saved = await cfgSvc.saveConfig(preset, configFile: cfgFile);
      expect(saved.issues, isEmpty);

      final store = InMemoryImmersiveStateStore();
      final mockText = MockTextModelAdapter();
      final mockTts = MockTtsProviderAdapter();

      final chapters = [
        Chapter(itemId: 'c0', title: '第一章', order: 1, content: '林岚轻声道：“第一章台词。”'),
        Chapter(itemId: 'c1', title: '第二章', order: 2, content: '林岚微笑道：“第二章台词。”'),
        Chapter(itemId: 'c2', title: '第三章', order: 3, content: '林岚坚定地说：“第三章目标台词。”'),
      ];

      mockText.onAnalyze = (sys, user) async {
        final targetSection = user.split('[TARGET_UNITS').last.split('[/TARGET_UNITS]').first;
        final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
            .allMatches(targetSection)
            .map((m) => m.group(1)!)
            .toList();
        final hasChar001 = user.contains('id="char_0001"');
        return StructuredModelResponse(
          data: {
            'assignments': [
              {
                'source_unit_ids': [ids[0]],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': [ids[1]],
                'kind': 'dialogue',
                'speaker_ref': hasChar001 ? 'char_0001' : 'local:new_1',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': hasChar001
                ? const []
                : [
                    {
                      'local_ref': 'local:new_1',
                      'display_name': '林岚',
                      'gender': 'female',
                      'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
                      'evidence_unit_ids': [ids[0]],
                    },
                  ],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      };

      final invokedMethods = <String>[];
      final coordinator = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: mockText,
        ttsAdapter: mockTts,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (m, a) async {
          invokedMethods.add('$m:${a?['id'] ?? ''}');
          return true;
        },
      );
      addTearDown(coordinator.dispose);

      await coordinator.loadAndValidateConfig(configFile: cfgFile);
      await coordinator.startImmersivePlayback(
        book: Book(bookId: 'mid_book', bookName: '中途起听测试', author: 'A'),
        chapters: chapters,
        chapterIndex: 2, // 从第 3 章首次起听
      );

      for (var w = 0; w < 80 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final st = await coordinator.getPipelineStatus();
      final segSummary = coordinator.manifestSegments
          .map((s) => '${s.segmentOrder}:${s.status}:${s.spokenText}')
          .join(' | ');
      expect(
        coordinator.isPlaying,
        isTrue,
        reason:
            'state=${coordinator.state}, err=${coordinator.errorMessage}, '
            'phase=${st.phaseLabel}, confirmed=${st.confirmedChunks}/${st.totalPlannedChunks}, '
            'seg=${coordinator.currentSegmentIndex}/${coordinator.manifestSegments.length}, '
            'ready=${st.readyAudioSegments}, contSec=${st.continuousReadySeconds}, '
            'analyze=${mockText.analyzeCalls}, tts=${mockTts.receivedSpecs.length}, '
            'segs=[$segSummary], invoked=$invokedMethods, lastErr=${st.lastError}, block=${st.blockingReason}',
      );
      // 3 章全部分析了前文人物
      expect(mockText.analyzeCalls, 3);
      // 但绝不合成第 1 章和第 2 章的前文音频！
      expect(
        mockTts.receivedSpecs.any((s) => s.inputText.contains('第一章') || s.inputText.contains('第二章')),
        isFalse,
        reason: '中途起听补齐前文人物档案时不得合成前文音频',
      );
      expect(
        mockTts.receivedSpecs.any((s) => s.inputText.contains('第三章')),
        isTrue,
      );
    });
  });

  group('阶段 7：空降最多回溯5章、多文本主备切换、思考清洗、同性音色兜底与重建编排', () {
    test('千章长书直接从第1000章空降开听：仅回溯往前5章(994..998)建档且绝不加载更早章节', () async {
      final tmp = await Directory.systemTemp.createTemp('immersive_jump1000_');
      _registerSafeTempCleanup(tmp);
      final preset = _testPresetConfig().copyWith(
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
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await cfgSvc.saveConfig(preset, configFile: cfgFile);
      final store = InMemoryImmersiveStateStore();
      final mockText = MockTextModelAdapter();
      final mockTts = MockTtsProviderAdapter();

      // 构造 1005 章长篇小说（不预填 content，通过懒加载回调监控究竟拉取了哪几章）
      final chapters = List.generate(
        1005,
        (i) => Chapter(itemId: 'ch_$i', title: '第${i + 1}章', order: i + 1),
      );
      final loadedChapterIndices = <int>[];
      final analyzedChapterIndices = <int>[];

      mockText.onAnalyze = (sys, usr) async {
        final targetSection = usr.split('[TARGET_UNITS')[1].split('[/TARGET_UNITS]')[0];
        final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
            .allMatches(targetSection)
            .map((m) => m.group(1)!)
            .toList();
        final chMatch = RegExp(r'_c(\d+)_p').firstMatch(ids.first);
        if (chMatch != null) {
          analyzedChapterIndices.add(int.parse(chMatch.group(1)!));
        }
        final hasChar = usr.contains('id="char_001"');
        return StructuredModelResponse(
          data: {
            'assignments': [
              {
                'source_unit_ids': [ids[0]],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': ids.sublist(1),
                'kind': 'dialogue',
                'speaker_ref': hasChar ? 'char_001' : 'local:new_1',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': hasChar
                ? const []
                : [
                    {
                      'local_ref': 'local:new_1',
                      'display_name': '林岚',
                      'gender': 'female',
                      'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
                      'evidence_unit_ids': [ids[0]],
                    },
                  ],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      };

      final coordinator = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: mockText,
        ttsAdapter: mockTts,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (_, _) async => true,
      );
      addTearDown(coordinator.dispose);

      await coordinator.loadAndValidateConfig(configFile: cfgFile);
      await coordinator.startImmersivePlayback(
        book: Book(bookId: 'long_1000_book', bookName: '千章修仙录', author: '测试'),
        chapters: chapters,
        chapterIndex: 999, // 直接从第 1000 章空降起听
        contentLoader: (ch) async {
          final idx = ch.order - 1;
          loadedChapterIndices.add(idx);
          return '林岚在第${ch.order}章说道：“这是第${ch.order}章的正文台词。”';
        },
      );

      for (var w = 0; w < 100 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      expect(coordinator.isPlaying, isTrue);
      // 严禁加载第 0..993 章，仅允许加载 [994 .. 1002]（往前最多 5 章 + 当前 + 预取 3 章）
      expect(loadedChapterIndices.every((i) => i >= 994 && i <= 1002), isTrue,
          reason: '加载了越界章节：$loadedChapterIndices');
      expect(loadedChapterIndices, containsAll([994, 995, 996, 997, 998, 999]));
      // 不得合成前 5 章（994..998）的音频，但合成并播放了第 1000 章
      expect(
        mockTts.receivedSpecs.any((s) => s.inputText.contains('第995章') || s.inputText.contains('第999章')),
        isFalse,
      );
      expect(
        mockTts.receivedSpecs.any((s) => s.inputText.contains('第1000章')),
        isTrue,
      );

      // 重启新 Coordinator 实例再次听第 1000 章：稳定 BookRevision 100% 命中，已确认章节 0 次重新编排！
      await coordinator.stop();
      final analyzeCallsBeforeRestart = mockText.analyzeCalls;
      analyzedChapterIndices.clear();
      final ttsBeforeRestartCount = mockTts.receivedSpecs.length;

      final coordinator2 = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: mockText,
        ttsAdapter: mockTts,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (_, _) async => true,
      );
      addTearDown(coordinator2.dispose);

      await coordinator2.loadAndValidateConfig(configFile: cfgFile);
      await coordinator2.startImmersivePlayback(
        book: Book(bookId: 'long_1000_book', bookName: '千章修仙录', author: '测试'),
        chapters: chapters,
        chapterIndex: 999,
        contentLoader: (ch) async => '林岚在第${ch.order}章说道：“这是第${ch.order}章的正文台词。”',
      );
      for (var w = 0; w < 40 && !coordinator2.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(coordinator2.isPlaying, isTrue);
      // 重启后绝不会重新编排已确认的第 994..999 章（含第 1000 章），且第 1000 章音频 100% 命中缓存不重合成！
      expect(
        analyzedChapterIndices.any((c) => c <= 999),
        isFalse,
        reason: '已听/已确认章节不得重复分析：$analyzedChapterIndices',
      );
      expect(
        mockTts.receivedSpecs
            .skip(ttsBeforeRestartCount)
            .any((s) => s.inputText.contains('第1000章')),
        isFalse,
        reason: '已听的第 1000 章音频应直接命中缓存不重合成',
      );

      // 重建编排功能：从第 1000 章重建，清空旧编排并仅回溯往前 5 章重新分析
      loadedChapterIndices.clear();
      await coordinator2.rebuildArrangementFromCurrentChapter(
        book: Book(bookId: 'long_1000_book', bookName: '千章修仙录', author: '测试'),
        chapters: chapters,
        chapterIndex: 999,
        contentLoader: (ch) async {
          loadedChapterIndices.add(ch.order - 1);
          return '林岚在第${ch.order}章说道：“这是第${ch.order}章的正文台词。”';
        },
      );
      for (var w = 0; w < 100 && !coordinator2.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(coordinator2.isPlaying, isTrue);
      expect(mockText.analyzeCalls, greaterThan(analyzeCallsBeforeRestart));
      expect(loadedChapterIndices.every((i) => i >= 994 && i <= 1002), isTrue);
    });

    test('多文本模型独立并发 + 主模型连续失败自动切换兜底模型', () async {
      final preset = _testPresetConfig();
      // 验证预置 3 个文本模型及独立并发：MiniMax(3), GLM(3), Qwen(1)
      expect(preset.textAnalysisModels.length, 3);
      final qwen = preset.textAnalysisModels.firstWhere((m) => m.modelId == 'qwen3.8-flash-next');
      final glm = preset.textAnalysisModels.firstWhere((m) => m.modelId == 'glm-5.3-flash');
      expect(qwen.maxConcurrency, 1);
      expect(qwen.reservedReconciliationSlots, 0);
      expect(glm.maxConcurrency, 3);

      // 验证 SchedulerQuotaPool 按文本模型独立限额
      final pool = SchedulerQuotaPool();
      expect(pool.tryAcquireText(config: qwen, isReconciliation: false), isTrue);
      expect(pool.tryAcquireText(config: qwen, isReconciliation: false), isFalse); // qwen 并发上限 1
      expect(pool.tryAcquireText(config: glm, isReconciliation: false), isTrue); // glm 独立不冲突
      pool.releaseText(isReconciliation: false, modelEntryId: qwen.effectiveId);
      pool.releaseText(isReconciliation: false, modelEntryId: glm.effectiveId);

      // 端到端主备自动切换：主模型(MiniMax)持续网络失败 -> 自动切换至兜底模型(glm-5.3-flash)成功完成
      final tmp = await Directory.systemTemp.createTemp('immersive_failover_');
      _registerSafeTempCleanup(tmp);
      final fastCfg = preset.copyWith(
        textFailoverThreshold: 2,
        retry: const RetryConfig(
          maxAttempts: 5,
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
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final saveRes = await cfgSvc.saveConfig(fastCfg, configFile: cfgFile);
      expect(saveRes.issues, isEmpty);
      final store = InMemoryImmersiveStateStore();
      final calledModels = <String>[];
      final failoverAdapter = _ModelAwareMockTextAdapter((modelId, sys, usr) async {
        calledModels.add(modelId);
        if (modelId == 'MiniMax-M3.1-Flash') {
          throw const TextModelException(
            kind: TextModelErrorKind.transientNetwork,
            message: '模拟主模型临时故障',
          );
        }
        final targetSection = usr.split('[TARGET_UNITS')[1].split('[/TARGET_UNITS]')[0];
        final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
            .allMatches(targetSection)
            .map((m) => m.group(1)!)
            .toList();
        return StructuredModelResponse(
          data: {
            'assignments': [
              {
                'source_unit_ids': ids,
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids.first],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': const [],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      });

      final coordinator = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: failoverAdapter,
        ttsAdapter: MockTtsProviderAdapter(),
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (_, _) async => true,
      );
      addTearDown(coordinator.dispose);

      await coordinator.loadAndValidateConfig(configFile: cfgFile);
      await coordinator.startImmersivePlayback(
        book: Book(bookId: 'failover_book', bookName: '主备测试', author: 'A'),
        chapters: [Chapter(itemId: 'c1', title: '第一章', order: 1, content: '雪落满山。')],
        chapterIndex: 0,
      );

      for (var w = 0; w < 100 && !coordinator.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(coordinator.isPlaying, isTrue);
      expect(coordinator.isUsingFallbackTextModel, isTrue);
      expect(calledModels.where((m) => m == 'MiniMax-M3.1-Flash').length, greaterThanOrEqualTo(2));
      expect(calledModels, contains('glm-5.3-flash'));
    });

    test('思考内容清洗与冗余键过滤：正确剥离<think>、reasoning_content与多余字段并通过校验', () async {
      final mockHttp = MockClient((req) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'reasoning_content': '这是一段很长的内部推理思考过程……',
                  'content':
                      '<think>模型内部思考：u1 是旁白，u2 是林岚对话</think>\n'
                      '```json\n'
                      '{"assignments":['
                      '{"source_unit_ids":["u1"],"kind":"narration","speaker_ref":null,"evidence_unit_ids":["u1"],"evidence_type":"explicit_attribution","evidence_unit_ids2":[]}'
                      '],"new_character_proposals":[]}\n'
                      '```',
                },
              },
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 20},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final adapter = OpenAiChatTextModelAdapter(mockHttp);
      final preset = _testPresetConfig();
      final resp = await adapter.analyzeChunk(
        config: preset.primaryTextModel,
        apiKey: 'test-key',
        systemMessage: 'sys',
        userMessage: 'usr',
      );
      final assignments = resp.data['assignments'] as List;
      expect(assignments.length, 1);
      expect((assignments.first as Map).containsKey('evidence_unit_ids2'), isFalse);
      expect(resp.data['identity_link_proposals'], isEmpty);
      expect(resp.reasoningTokens, greaterThan(0));
    });

    test('已编排数据在 TTS 模型停用或删除后自动按性别兜底（男对男、女对女）', () {
      final preset = _testPresetConfig();
      // 禁用男声 wenxin_male，并彻底删除女声 DeepSeek_female
      final p0 = preset.tts.providers.first;
      final mutatedModels = p0.models
          .where((m) => m.modelId != 'DeepSeek_female')
          .map((m) => m.modelId == 'wenxin_male' ? m.copyWith(enabled: false) : m)
          .toList();
      final mutatedCfg = preset.copyWith(
        tts: preset.tts.copyWith(
          providers: [p0.copyWith(models: mutatedModels)],
        ),
      );

      final uMale = SourceUnit(
        unitId: 'u_m',
        bookRevisionId: 'rev1',
        bookId: 'b1',
        chapterIndex: 0,
        chapterId: 'c0',
        paragraphIndex: 0,
        globalOrder: 0,
        startOffset: 0,
        endOffset: 5,
        text: '“我来了。”',
      );
      final uFemale = SourceUnit(
        unitId: 'u_f',
        bookRevisionId: 'rev1',
        bookId: 'b1',
        chapterIndex: 0,
        chapterId: 'c0',
        paragraphIndex: 1,
        globalOrder: 1,
        startOffset: 0,
        endOffset: 5,
        text: '“小心点。”',
      );
      final chars = {
        'char_male': ImmersiveCharacter(
          characterId: 'char_male',
          bookId: 'b1',
          canonicalName: '李青',
          gender: 'male',
          firstSeenUnitId: 'u_m',
          updatedAtMs: 1,
        ),
        'char_female': ImmersiveCharacter(
          characterId: 'char_female',
          bookId: 'b1',
          canonicalName: '林岚',
          gender: 'female',
          firstSeenUnitId: 'u_f',
          updatedAtMs: 1,
        ),
      };
      final allocs = [
        Allocation(
          allocationId: 'a_m',
          bookId: 'b1',
          bookRevisionId: 'rev1',
          chunkId: 'chk_0',
          chapterIndex: 0,
          orderInBook: 0,
          sourceUnitIds: const ['u_m'],
          kind: AllocationKind.dialogue,
          speakerRef: 'char_male',
          originalSpeakerRef: 'char_male',
          allocationStatus: AllocationStatus.accepted,
          speakerResolution: SpeakerResolution.resolved,
          effectiveVoiceProfileId: 'vp_oneapi_wenxin_male', // 已被禁用！
          evidenceUnitIds: const ['u_m'],
          evidenceType: EvidenceType.explicitAttribution,
        ),
        Allocation(
          allocationId: 'a_f',
          bookId: 'b1',
          bookRevisionId: 'rev1',
          chunkId: 'chk_0',
          chapterIndex: 0,
          orderInBook: 1,
          sourceUnitIds: const ['u_f'],
          kind: AllocationKind.dialogue,
          speakerRef: 'char_female',
          originalSpeakerRef: 'char_female',
          allocationStatus: AllocationStatus.accepted,
          speakerResolution: SpeakerResolution.resolved,
          effectiveVoiceProfileId: 'vp_oneapi_DeepSeek_female', // 已被删除！
          evidenceUnitIds: const ['u_f'],
          evidenceType: EvidenceType.explicitAttribution,
        ),
      ];

      final notices = <String>[];
      final segs = ManifestBuilder.buildSegments(
        bookId: 'b1',
        bookRevisionId: 'rev1',
        manifestRevision: 2,
        config: mutatedCfg,
        orderedAllocations: allocs,
        unitById: {'u_m': uMale, 'u_f': uFemale},
        characterById: chars,
        bindingByCharId: const {},
        existingAssetsByRequestKey: const {},
        preferredPoolIds: preset.bookDefaults.selectedVoiceProfileIds,
        onVoiceFallback: notices.add,
      );

      expect(segs.length, 2);
      expect(segs[0].status, isNot(AudioSegmentStatus.blocked));
      expect(segs[1].status, isNot(AudioSegmentStatus.blocked));
      // 男性角色兜底为另一启用男声
      final resolvedMale = mutatedCfg.resolveVoiceProfile(segs[0].voiceProfileId);
      expect(resolvedMale, isNotNull);
      expect(resolvedMale!.isEffectivelyEnabled, isTrue);
      expect(resolvedMale.voice.gender, 'male');
      expect(resolvedMale.voice.voiceProfileId, isNot('vp_oneapi_wenxin_male'));
      // 女性角色兜底为另一启用女声
      final resolvedFemale = mutatedCfg.resolveVoiceProfile(segs[1].voiceProfileId);
      expect(resolvedFemale, isNotNull);
      expect(resolvedFemale!.isEffectivelyEnabled, isTrue);
      expect(resolvedFemale.voice.gender, 'female');
      expect(resolvedFemale.voice.voiceProfileId, isNot('vp_oneapi_DeepSeek_female'));
      expect(notices.length, 2);
    });

    test('明文 HTTP 风险检测与旧配置 WAV->MP3 试听样本自动平滑迁移', () async {
      // 1) 明文 HTTP 安全识别
      expect(isInsecureRemoteHttpUrl('http://ingsys.net:8099/v1'), isTrue);
      expect(isInsecureRemoteHttpUrl('https://oneapi.971218.xyz/v1'), isFalse);
      expect(isInsecureRemoteHttpUrl('http://127.0.0.1:8080/v1'), isFalse);
      expect(isInsecureRemoteHttpUrl('http://localhost:11434/v1'), isFalse);

      // 2) 模拟老版 config.json 含 .wav 路径 -> 加载时自动平滑升级为 .mp3 并持久化
      final tmp = await Directory.systemTemp.createTemp('immersive_wav_mig_');
      _registerSafeTempCleanup(tmp);
      final oldCfg = _testPresetConfig();
      final p0 = oldCfg.tts.providers.first;
      final legacyModels = p0.models
          .map(
            (m) => m.copyWith(
              voices: m.voices
                  .map(
                    (v) => v.sampleAsset != null
                        ? v.copyWith(
                            sampleAsset: v.sampleAsset!.replaceAll('.mp3', '.wav'),
                          )
                        : v,
                  )
                  .toList(),
            ),
          )
          .toList();
      final legacyCfg = oldCfg.copyWith(
        tts: oldCfg.tts.copyWith(
          providers: [p0.copyWith(models: legacyModels)],
        ),
      );
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final svc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await svc.saveConfig(legacyCfg, configFile: cfgFile);
      expect((await cfgFile.readAsString()).contains('.wav'), isTrue);

      final reloaded = await svc.loadAndValidateConfig(configFile: cfgFile);
      expect(reloaded.available, isTrue);
      final allAssets = reloaded.config!.allVoiceProfiles
          .map((e) => e.voice.sampleAsset)
          .whereType<String>()
          .toList();
      expect(allAssets, isNotEmpty);
      expect(allAssets.every((a) => a.endsWith('.mp3')), isTrue);
      expect((await cfgFile.readAsString()).contains('.wav'), isFalse);
    });

    test('首块微切分（Fast-Start）与分级思考降档（auto -> minimal）', () async {
      final preset = _testPresetConfig();
      final longParagraphs = List.generate(
        26,
        (i) => '林岚在第${i + 1}段低声说道：“这是一段用来测试首块微切分与常规大块吞吐差异的长对白正文内容，确保整体估算 Token 远超首块微切分目标。”',
      ).join('\n');
      final units = SourceNormalizer.normalizeSingleChapter(
        bookId: 'fast_start_book',
        bookRevisionId: 'rev_fs',
        chapterIndex: 0,
        chapter: Chapter(itemId: 'c0', title: '第一章', order: 1),
        rawText: longParagraphs,
        startingGlobalOrder: 0,
      );

      final chunks = ChunkPlanner.planChunks(
        bookId: 'fast_start_book',
        bookRevisionId: 'rev_fs',
        allOrderedUnits: units,
        pipelineConfig: preset.analysisPipeline.copyWith(
          firstChunkTargetTokens: 450,
        ),
        textConfig: preset.primaryTextModel,
        systemVoiceCatalogTokens: 400,
        fastStartChapterIndex: 0,
      );

      expect(chunks.length, greaterThanOrEqualTo(2));
      // 锚点章第 0 块按首块微切分目标收敛，后续块明显更大
      expect(chunks.first.estimatedTokens, lessThanOrEqualTo(750));
      expect(chunks[1].estimatedTokens, greaterThan(chunks.first.estimatedTokens));

      // 验证分级思考：tieredThinking=true 且模型为 auto 时，常规分块分析实际传入 minimal
      final tmp = await Directory.systemTemp.createTemp('immersive_tiered_');
      _registerSafeTempCleanup(tmp);
      final fastCfg = preset.copyWith(
        analysisPipeline: preset.analysisPipeline.copyWith(
          tieredThinking: true,
        ),
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
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final saveRes = await cfgSvc.saveConfig(fastCfg, configFile: cfgFile);
      expect(saveRes.issues, isEmpty);
      final seenThinkingLevels = <String>[];
      final captureAdapter = _ThinkingCaptureTextAdapter(seenThinkingLevels);
      final coord = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: InMemoryImmersiveStateStore(),
        textAdapter: captureAdapter,
        ttsAdapter: MockTtsProviderAdapter(),
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (_, _) async => true,
      );
      addTearDown(coord.dispose);
      await coord.loadAndValidateConfig(configFile: cfgFile);
      await coord.startImmersivePlayback(
        book: Book(bookId: 'tiered_book', bookName: '分级测试', author: 'A'),
        chapters: [Chapter(itemId: 'c1', title: '第一章', order: 1, content: '雪落满山。')],
        chapterIndex: 0,
      );
      for (var w = 0; w < 80 && !coord.isPlaying; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(
        coord.isPlaying,
        isTrue,
        reason:
            'state=${coord.state}, err=${coord.errorMessage}, notice=${coord.notice}, '
            'schedErr=${coord.scheduler?.lastError}, issues=${cfgSvc.lastIssues}, '
            'seen=$seenThinkingLevels',
      );
      expect(seenThinkingLevels, isNotEmpty);
      expect(seenThinkingLevels.every((l) => l == TextThinkingLevel.minimal), isTrue);
    });

    test('原生段间呼吸停顿计算 + preloadNextAudio 与 onAudioTransition 无缝切换', () async {
      // 1) 呼吸停顿时长规则验证
      AudioSegment segOf({
        required int order,
        required int chIdx,
        required String speakerRef,
        required String speakerName,
      }) => AudioSegment(
        segmentId: 'seg_$order',
        bookId: 'b1',
        bookRevisionId: 'r1',
        manifestRevision: 1,
        chapterIndex: chIdx,
        chapterId: 'ch_$chIdx',
        segmentOrder: order,
        sourceUnitIds: ['u_$order'],
        startGlobalOrder: order,
        endGlobalOrder: order,
        startParagraphIndex: order,
        startCharOffset: 0,
        endParagraphIndex: order,
        endCharOffset: 4,
        spokenText: '台词$order',
        kind: speakerRef == 'narrator'
            ? AllocationKind.narration
            : AllocationKind.dialogue,
        speakerRef: speakerRef,
        speakerDisplayName: speakerName,
        voiceProfileId: 'vp_oneapi_Anthropic_male',
        bindingRevision: 1,
        renderSpecHash: 'hash_$order',
        requestKey: 'rk_$order',
        status: AudioSegmentStatus.ready,
      );

      const pbCfg = PlaybackConfig(
        sameSpeakerGapMs: 120,
        speakerSwitchGapMs: 260,
        chapterSwitchGapMs: 480,
      );
      final s0 = segOf(order: 0, chIdx: 0, speakerRef: 'narrator', speakerName: '旁白');
      final s1 = segOf(order: 1, chIdx: 0, speakerRef: 'narrator', speakerName: '旁白');
      final s2 = segOf(order: 2, chIdx: 0, speakerRef: 'char_1', speakerName: '林岚');
      final s3 = segOf(order: 3, chIdx: 1, speakerRef: 'char_1', speakerName: '林岚');

      expect(
        ImmersiveAudioPlayerBridge.computeSegmentGapMs(
          playbackConfig: pbCfg,
          current: s0,
          next: s1,
        ),
        120,
      );
      expect(
        ImmersiveAudioPlayerBridge.computeSegmentGapMs(
          playbackConfig: pbCfg,
          current: s1,
          next: s2,
        ),
        260,
      );
      expect(
        ImmersiveAudioPlayerBridge.computeSegmentGapMs(
          playbackConfig: pbCfg,
          current: s2,
          next: s3,
        ),
        480,
      );

      // 2) 端到端预装与原生 onAudioTransition 无缝切换推进
      final tmp = await Directory.systemTemp.createTemp('immersive_preload_');
      _registerSafeTempCleanup(tmp);
      final preset = _testPresetConfig().copyWith(
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 1.0,
          startupWaitAfterFirstReadyMs: 80,
          resumeBufferSeconds: 1.0,
          lowWaterSeconds: 5.0,
          targetBufferSeconds: 10.0,
          highWaterSeconds: 20.0,
          maxJobsBeyondFirstGap: 6,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 50,
          cancelUnneededRequestsOnSeek: true,
        ),
      );
      final cfgFile = File(p.join(tmp.path, 'config.json'));
      final cfgSvc = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      await cfgSvc.saveConfig(preset, configFile: cfgFile);

      final invokedMethods = <({String method, Map<String, Object?>? args})>[];
      final mockText = MockTextModelAdapter();
      mockText.onAnalyze = (sys, usr) async {
        final targetSection = usr.split('[TARGET_UNITS')[1].split('[/TARGET_UNITS]')[0];
        final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
            .allMatches(targetSection)
            .map((m) => m.group(1)!)
            .toList();
        return StructuredModelResponse(
          data: {
            'assignments': [
              {
                'source_unit_ids': [ids[0]],
                'kind': 'narration',
                'speaker_ref': 'narrator',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
              {
                'source_unit_ids': ids.sublist(1),
                'kind': 'dialogue',
                'speaker_ref': 'local:new_1',
                'evidence_unit_ids': [ids[0]],
                'evidence_type': 'explicit_attribution',
              },
            ],
            'new_character_proposals': [
              {
                'local_ref': 'local:new_1',
                'display_name': '林岚',
                'gender': 'female',
                'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
                'evidence_unit_ids': [ids[0]],
              },
            ],
            'identity_link_proposals': const [],
            'unresolved_items': const [],
          },
          latencyMs: 5,
          schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
        );
      };

      final coord = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: InMemoryImmersiveStateStore(),
        textAdapter: mockText,
        ttsAdapter: MockTtsProviderAdapter(),
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async => (valid: true, durationMs: fallback),
        invoke: (method, args) async {
          invokedMethods.add((method: method, args: args));
          return true;
        },
      );
      addTearDown(coord.dispose);

      await coord.loadAndValidateConfig(configFile: cfgFile);
      await coord.startImmersivePlayback(
        book: Book(bookId: 'preload_book', bookName: '预装无缝测试', author: 'A'),
        chapters: [
          Chapter(
            itemId: 'c1',
            title: '第一章',
            order: 1,
            content: '雪夜寂静，林岚推门进来。\n“炉火还暖着呢。”',
          ),
        ],
        chapterIndex: 0,
      );

      for (var w = 0; w < 100; w++) {
        if (coord.isPlaying &&
            invokedMethods.any((e) => e.method == 'preloadNextAudio')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      final preloadCall = invokedMethods
          .where((e) => e.method == 'preloadNextAudio')
          .firstOrNull;
      expect(preloadCall, isNotNull, reason: '播放第 0 段时应自动向原生预装第 1 段');
      expect(preloadCall!.args!['gapMs'], 260); // 旁白 -> 林岚（切换角色）应为 260ms

      final playCallsBefore = invokedMethods
          .where((e) => e.method == 'playAudioFile')
          .length;
      final completedId = preloadCall.args!['afterId'] as String;
      final startedId = preloadCall.args!['id'] as String;

      // 模拟原生播放器完成第 0 段并无缝启动已预热的第 1 段
      coord.handlePlatformEvent('onAudioTransition', {
        'completedId': completedId,
        'startedId': startedId,
      });

      expect(coord.currentSegmentIndex, 1);
      expect(coord.currentSegment?.speakerDisplayName, '林岚');
      expect(coord.isPlaying, isTrue);
      // 绝不再次调用 playAudioFile 重启播放器
      expect(
        invokedMethods.where((e) => e.method == 'playAudioFile').length,
        playCallsBefore,
      );
    });
  });
}

class _ThinkingCaptureTextAdapter implements TextModelAdapter {
  final List<String> capturedLevels;
  _ThinkingCaptureTextAdapter(this.capturedLevels);

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    capturedLevels.add(config.thinkingLevel);
    final targetSection = userMessage.split('[TARGET_UNITS')[1].split('[/TARGET_UNITS]')[0];
    final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
        .allMatches(targetSection)
        .map((m) => m.group(1)!)
        .toList();
    return StructuredModelResponse(
      data: {
        'assignments': [
          {
            'source_unit_ids': ids,
            'kind': 'narration',
            'speaker_ref': 'narrator',
            'evidence_unit_ids': [ids.first],
            'evidence_type': 'explicit_attribution',
          },
        ],
        'new_character_proposals': const [],
        'identity_link_proposals': const [],
        'unresolved_items': const [],
      },
      latencyMs: 5,
      schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
    );
  }

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async => const AnalysisProviderTestResult(
    success: true,
    message: 'ok',
    latencyMs: 1,
    modeUsed: 'mock',
  );

  @override
  void cancelAll() {}
}

class _ModelAwareMockTextAdapter implements TextModelAdapter {
  final Future<StructuredModelResponse> Function(
    String modelId,
    String sys,
    String usr,
  ) _handler;

  _ModelAwareMockTextAdapter(this._handler);

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) => _handler(config.modelId, systemMessage, userMessage);

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) => throw UnimplementedError();

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async => const AnalysisProviderTestResult(
    success: true,
    message: 'ok',
    latencyMs: 1,
    modeUsed: 'mock',
  );

  @override
  void cancelAll() {}
}
