import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/services/text_model_adapter.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';

const _runLive = bool.fromEnvironment('RUN_LIVE_IMMERSIVE', defaultValue: false);
const _liveTextApiKey = String.fromEnvironment('IMMERSIVE_TEXT_API_KEY', defaultValue: '');
const _liveTtsApiKey = String.fromEnvironment('IMMERSIVE_TTS_API_KEY', defaultValue: '');

void main() {
  test(
    '真实供应商端到端联调：MiniMax-M3.1-Flash + OneAPI TTS 两章沉浸式听书全链路',
    () async {
      expect(
        _liveTextApiKey.isNotEmpty && _liveTtsApiKey.isNotEmpty,
        isTrue,
        reason: '请通过 --dart-define=IMMERSIVE_TEXT_API_KEY=... 和 --dart-define=IMMERSIVE_TTS_API_KEY=... 注入在线联调密钥',
      );
      final tmp = await Directory.systemTemp.createTemp('immersive_live_e2e_');
      addTearDown(() => tmp.delete(recursive: true));

      final preset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: _liveTextApiKey,
        ttsApiKey: _liveTtsApiKey,
        featureEnabled: true,
      ).copyWith(
        prefetch: const PrefetchConfig(
          startupBufferSeconds: 3.0,
          startupWaitAfterFirstReadyMs: 1500,
          resumeBufferSeconds: 3.0,
          lowWaterSeconds: 15.0,
          targetBufferSeconds: 25.0,
          highWaterSeconds: 45.0,
          maxJobsBeyondFirstGap: 4,
        ),
        jobs: const JobsConfig(
          leaseSeconds: 60,
          heartbeatSeconds: 15,
          pollIntervalMs: 150,
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
      final client = http.Client();
      addTearDown(client.close);

      final textAdapter = OpenAiChatTextModelAdapter(client);
      final ttsAdapter = OpenAiSpeechTtsAdapter(client);
      final played = <Map<String, Object?>>[];

      final coordinator = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: textAdapter,
        ttsAdapter: ttsAdapter,
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        platformAudioProbe: (_, fallback) async =>
            (valid: true, durationMs: fallback),
        invoke: (method, args) async {
          if (method == 'playAudioFile') {
            played.add(Map<String, Object?>.from(args ?? {}));
            return true;
          }
          return true;
        },
      );
      addTearDown(coordinator.dispose);

      await coordinator.loadAndValidateConfig(configFile: cfgFile);

      // 1. 逐个实测全部 3 个预置文本模型的 JSON 结构化能力（MiniMax / GLM / Qwen），遇同源短时 429 自动退避重试
      for (final tm in preset.textAnalysisModels) {
        var textTest = await coordinator.testAnalysisProvider(
          modelEntryId: tm.effectiveId,
        );
        for (var retry = 0;
            retry < 2 && !textTest.success && textTest.message.contains('429');
            retry++) {
          await Future<void>.delayed(Duration(seconds: 3 * (retry + 1)));
          textTest = await coordinator.testAnalysisProvider(
            modelEntryId: tm.effectiveId,
          );
        }
        debugPrint(
          '[LIVE] textTest(${tm.modelId}, conc=${tm.maxConcurrency}, thinking=${tm.thinkingLevel}): '
          'success=${textTest.success} msg=${textTest.message}',
        );
        expect(textTest.success, isTrue, reason: '${tm.modelId}: ${textTest.message}');
        await Future<void>.delayed(const Duration(milliseconds: 1200));
      }

      // 2. 真实音色连接测试（大小写敏感路由验证）
      final voiceTest = await coordinator.testVoiceProfile(
        'vp_oneapi_DeepSeek_female',
        playResult: false,
      );
      debugPrint('[LIVE] voiceTest: success=${voiceTest.success} msg=${voiceTest.message}');
      expect(voiceTest.success, isTrue, reason: voiceTest.message);

      // 3. 启动两章测试书完整沉浸式听书管线
      final rawBook = await File('test/fixtures/immersive_sample_book.txt').readAsString();
      final parts = rawBook.split('第二章 渡口重逢');
      final book = Book(
        bookId: 'live_sample_book',
        bookName: '雪夜来客',
        author: '联调测试',
      );
      final chapters = [
        Chapter(itemId: 'ch1', title: '第一章 雪夜来客', order: 1, content: parts[0]),
        Chapter(itemId: 'ch2', title: '第二章 渡口重逢', order: 2, content: parts[1]),
      ];

      await coordinator.startImmersivePlayback(
        book: book,
        chapters: chapters,
        chapterIndex: 0,
      );

      // 等待两章完成角色确认且首段进入播放状态（最多 90s）
      for (var i = 0; i < 180; i++) {
        final st = await coordinator.getPipelineStatus();
        if (coordinator.isPlaying && st.confirmedChunks >= 2 && st.readyAudioSegments >= 3) {
          break;
        }
        if (coordinator.state == ImmersivePlayState.blocked) {
          fail('管线进入阻塞：${coordinator.errorMessage ?? st.blockingReason}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      final finalStatus = await coordinator.getPipelineStatus();
      final chars = await store.getCharacters(book.bookId);
      final bindings = await store.getVoiceBindings(book.bookId);

      final jobs = await store.listJobs(bookId: book.bookId);
      debugPrint('[LIVE] lastError=${finalStatus.lastError}, block=${finalStatus.blockingReason}');
      for (final j in jobs) {
        debugPrint('[LIVE] job ${j.jobKey} status=${j.status} attempt=${j.attempt} err=${j.errorMessage}');
      }
      debugPrint('[LIVE] phase=${finalStatus.phaseLabel}');
      debugPrint('[LIVE] confirmed=${finalStatus.confirmedChunks}/${finalStatus.totalPlannedChunks}');
      debugPrint('[LIVE] audioReady=${finalStatus.readyAudioSegments}/${finalStatus.totalManifestSegments}, continuousSec=${finalStatus.continuousReadySeconds.toStringAsFixed(1)}s, firstLatency=${finalStatus.firstAudioLatencyMs}ms');
      debugPrint('[LIVE] characters (${chars.length}):');
      for (final c in chars) {
        final vb = bindings.where((b) => b.characterId == c.characterId).firstOrNull;
        debugPrint('  - ${c.characterId}: ${c.canonicalName} [${c.gender}] status=${c.status} voice=${vb?.voiceProfileId}');
      }
      debugPrint('[LIVE] first played segment: ${coordinator.currentSegment?.speakerDisplayName} -> ${coordinator.currentSegment?.spokenText}');

      expect(coordinator.isPlaying, isTrue);
      expect(finalStatus.confirmedChunks, greaterThanOrEqualTo(2));
      expect(finalStatus.readyAudioSegments, greaterThanOrEqualTo(1));
      expect(finalStatus.continuousReadySeconds, greaterThan(0));
      expect(chars.length, greaterThanOrEqualTo(2));
      expect(played, isNotEmpty);
      expect(await File(played.first['filePath'] as String).exists(), isTrue);

      await coordinator.pause();
      await coordinator.stop();
    },
    skip: !_runLive,
    timeout: const Timeout(Duration(seconds: 180)),
  );
}
