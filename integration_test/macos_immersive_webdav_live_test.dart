import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/webdav/services/webdav_client.dart';
import 'package:fanqie_flutter/webdav/services/webdav_crypto.dart';

const _runLive = bool.fromEnvironment(
  'RUN_MACOS_LIVE_IMMERSIVE',
  defaultValue: false,
);
const _webdavUrl = String.fromEnvironment('WEBDAV_URL', defaultValue: '');
const _webdavUser = String.fromEnvironment('WEBDAV_USER', defaultValue: '');
const _webdavPass = String.fromEnvironment('WEBDAV_PASS', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS 真实沙箱端到端实测：WebDAV 只读拉取云端配置 + Keychain + SQLite WAL + 真实模型与 TTS 无缝切段播放',
    (tester) async {
      expect(ReaderPlatform.isMacOS, isTrue);
      expect(_webdavUrl.isNotEmpty, isTrue, reason: '请通过 WEBDAV_URL 注入地址');
      expect(_webdavUser.isNotEmpty, isTrue, reason: '请通过 WEBDAV_USER 注入账号');
      expect(_webdavPass.isNotEmpty, isTrue, reason: '请通过 WEBDAV_PASS 注入密码');

      // 1. 初始化真实 macOS 原生桥接并校验全部能力
      await ReaderPlatform.initialize();
      final caps = ReaderPlatform.capabilities;
      expect(caps.tts, isTrue);
      expect(caps.mediaPlayback, isTrue);
      expect(caps.secureStorage, isTrue);
      expect(caps.networkType, isTrue);

      // 创建隔离的沙箱内临时目录，确保位于 Application Support 授权根下且测后清空
      final appSupport = await getApplicationSupportDirectory();
      final testRoot = Directory(
        p.join(
          appSupport.path,
          'immersive_live_e2e_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      await testRoot.create(recursive: true);
      AppStorage.documentsOverride = () async => testRoot;

      // 备份可能已存在的真实 Keychain 槽位，测后完整还原避免污染本机状态
      final secretStore = PlatformImmersiveSecretStore();
      final backedUpSlots = <String, String?>{};
      Future<void> backupSlot(String slot) async {
        if (!backedUpSlots.containsKey(slot)) {
          backedUpSlots[slot] = await secretStore.read(slot);
        }
      }

      // 监听原生音频回调事件以验证双缓冲无缝切段 onAudioTransition
      final nativeEvents = <(String, Object?)>[];
      void eventListener(String method, dynamic args) {
        nativeEvents.add((method, args));
      }

      ReaderSystemService.addTtsListener(eventListener);

      final client = WebDavClient(
        serverUrl: _webdavUrl,
        username: _webdavUser,
        password: _webdavPass,
      );

      final coord = ImmersivePlaybackCoordinator();

      try {
        // 静音执行硬件播放测试，避免深夜外放干扰同时走完整 AVAudioPlayer 链路
        await ReaderPlatform.invoke('setAudioVolume', {'volume': 0.0});

        // 2. 校验 macOS 命名钥匙串隔离读写与删除
        final probeSlot =
            'immersive_live_probe_${DateTime.now().millisecondsSinceEpoch}';
        expect(await secretStore.write(probeSlot, 'probe-secret-value'), isTrue);
        expect(await secretStore.read(probeSlot), 'probe-secret-value');
        expect(await secretStore.write(probeSlot, ''), isTrue);
        expect(await secretStore.read(probeSlot), isNull);
        debugPrint('[MAC-LIVE] Keychain named secret round-trip: OK');

        // 3. 校验原生磁盘剩余空间查询
        final freeDisk = await ReaderPlatform.invoke<int>('getFreeDiskBytes', {
          'path': p.join(testRoot.path, 'immersive-audio', 'audio'),
        });
        expect(freeDisk, isNotNull);
        expect(freeDisk!, greaterThan(0));
        debugPrint(
          '[MAC-LIVE] getFreeDiskBytes: ${(freeDisk / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB',
        );

        // 4. WebDAV 只读连通性与拉取云端加密配置（绝不写入或删除远端任何文件）
        final conn = await client.testConnection();
        expect(conn.success, isTrue, reason: conn.message);
        debugPrint('[MAC-LIVE] WebDAV testConnection: ${conn.message}');

        final aiResp = await client.getJsonWithEtag('ai_config.json');
        expect(aiResp.data, isNotNull, reason: '云端缺少 ai_config.json');
        expect(
          WebDavCrypto.isEncryptedEnvelope(aiResp.data!),
          isTrue,
          reason: '云端配置应为端到端加密信封',
        );
        final decrypted = WebDavCrypto.decryptJson(
          aiResp.data!,
          passphrase: _webdavPass,
        );
        final rawImmersive = decrypted['immersive'];
        expect(rawImmersive, isA<Map>());

        final parsed = ImmersiveConfigValidator.parseAndValidateJson(
          jsonEncode(rawImmersive),
        );
        expect(parsed.isValid, isTrue, reason: '${parsed.issues}');
        final cloudConfig = parsed.config!;
        debugPrint(
          '[MAC-LIVE] Decrypted cloud immersive config: '
          'enabled=${cloudConfig.featureEnabled}, '
          'primary=${cloudConfig.primaryTextModel.modelId}, '
          'models=${cloudConfig.textAnalysisModels.length}, '
          'voices=${cloudConfig.voiceProfileIndex.length}',
        );

        // 备份涉及的钥匙串槽位
        await backupSlot('immersive_text_api_key_v1');
        for (final m in cloudConfig.textAnalysisModels) {
          await backupSlot(
            ImmersiveConfigService.textModelSecretSlot(m.effectiveId),
          );
        }
        for (final prov in cloudConfig.tts.providers) {
          await backupSlot(
            ImmersiveConfigService.ttsSecretSlot(prov.providerId),
          );
        }

        // 保存配置到本地隔离目录并确认真实写入 macOS Keychain（磁盘文件零明文密钥）
        final cfgFile = File(
          p.join(testRoot.path, 'immersive-audio', 'config.json'),
        );
        final tunedConfig = cloudConfig.copyWith(
          featureEnabled: true,
          prefetch: PrefetchConfig(
            startupBufferSeconds: 2.0,
            startupWaitAfterFirstReadyMs: 1200,
            resumeBufferSeconds: cloudConfig.prefetch.resumeBufferSeconds,
            lowWaterSeconds: cloudConfig.prefetch.lowWaterSeconds,
            targetBufferSeconds: cloudConfig.prefetch.targetBufferSeconds,
            highWaterSeconds: cloudConfig.prefetch.highWaterSeconds,
            maxJobsBeyondFirstGap: cloudConfig.prefetch.maxJobsBeyondFirstGap,
            pausePolicy: cloudConfig.prefetch.pausePolicy,
            continueInSupportedBackground:
                cloudConfig.prefetch.continueInSupportedBackground,
          ),
          playback: cloudConfig.playback.copyWith(
            sameSpeakerGapMs: 80,
            speakerSwitchGapMs: 120,
            chapterSwitchGapMs: 180,
          ),
        );
        final saveStatus = await coord.saveConfig(
          tunedConfig,
          configFile: cfgFile,
        );
        expect(saveStatus.issues, isEmpty);
        expect(saveStatus.available, isTrue);

        final diskConfigRaw = await cfgFile.readAsString();
        expect(diskConfigRaw, contains('__KEYSTORE__:'));
        debugPrint('[MAC-LIVE] Config persisted with macOS Keychain markers');

        // 重新从磁盘 + macOS Keychain 水合加载配置
        final reloadStatus = await coord.loadAndValidateConfig(
          configFile: cfgFile,
          autoInitPreset: false,
        );
        expect(reloadStatus.available, isTrue);
        expect(reloadStatus.issues, isEmpty);
        expect(coord.stateStore, isA<SqliteImmersiveStateStore>());
        debugPrint('[MAC-LIVE] Reloaded config & initialized macOS SQLite WAL');

        // 5. 拉取云端角色档案并合并入真实 macOS SQLite WAL 数据库
        final profResp = await client.getJsonWithEtag('immersive_profiles.json');
        if (profResp.data != null && profResp.data!['books'] is Map) {
          final remoteBooks = <String, Map<String, dynamic>>{};
          for (final e in (profResp.data!['books'] as Map).entries) {
            if (e.value is Map) {
              remoteBooks[e.key.toString()] = Map<String, dynamic>.from(
                e.value as Map,
              );
            }
          }
          if (remoteBooks.isNotEmpty) {
            final merged = await coord.stateStore!
                .mergeAllBookImmersiveProfiles(remoteBooks);
            expect(merged, isTrue);
            final exported = await coord.stateStore!
                .exportAllBookImmersiveProfiles();
            expect(exported.keys, containsAll(remoteBooks.keys));
            debugPrint(
              '[MAC-LIVE] Merged cloud immersive_profiles into macOS SQLite: '
              '${exported.keys.length} book(s)',
            );
          }
        }

        // 6. 验证本地打包 MP3 试听样本可在 macOS 原生播放
        final localSamplePlayed = await coord.playLocalVoiceSample(
          voiceProfileId: 'vp_oneapi_DeepSeek_female',
          assetPath: 'assets/TTS-Example/01_DeepSeek_female.mp3',
        );
        expect(localSamplePlayed, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await ReaderPlatform.invoke('stopAudio');
        debugPrint('[MAC-LIVE] Local MP3 voice sample playback: OK');

        // 7. 实测云端主文本模型 JSON 结构化返回能力（验证明文 HTTP 网关在 macOS 沙箱畅通）
        var primaryTextTest = await coord.testAnalysisProvider(
          modelEntryId: reloadStatus.config!.primaryTextModel.effectiveId,
        );
        for (var retry = 0;
            retry < 2 &&
                !primaryTextTest.success &&
                primaryTextTest.message.contains('429');
            retry++) {
          await Future<void>.delayed(Duration(seconds: 3 * (retry + 1)));
          primaryTextTest = await coord.testAnalysisProvider(
            modelEntryId: reloadStatus.config!.primaryTextModel.effectiveId,
          );
        }
        debugPrint(
          '[MAC-LIVE] Primary text model test (${reloadStatus.config!.primaryTextModel.modelId}): '
          'ok=${primaryTextTest.success} msg=${primaryTextTest.message}',
        );
        expect(
          primaryTextTest.success,
          isTrue,
          reason: primaryTextTest.message,
        );

        // 8. 实测云端 TTS 音色在线合成 + macOS 原生 probeAudioDuration 校验 + 播放
        final voiceTest = await coord.testVoiceProfile(
          'vp_oneapi_DeepSeek_female',
          playResult: true,
        );
        debugPrint(
          '[MAC-LIVE] Online TTS voice test: ok=${voiceTest.success} msg=${voiceTest.message}',
        );
        expect(voiceTest.success, isTrue, reason: voiceTest.message);
        expect(voiceTest.audioBytes, isNotNull);
        final probeTmpFile = File(
          p.join(testRoot.path, 'probe_real_tts.tmp'),
        );
        await probeTmpFile.writeAsBytes(voiceTest.audioBytes!, flush: true);
        final nativeProbe = await AudioFormatInspector.probeFileOnPlatform(
          probeTmpFile.path,
          fallbackDurationMs: voiceTest.durationMs ?? 1000,
        );
        expect(nativeProbe.valid, isTrue);
        expect(nativeProbe.durationMs, greaterThan(0));
        debugPrint(
          '[MAC-LIVE] macOS native probeAudioDuration on real MP3 .tmp: '
          'valid=${nativeProbe.valid}, durationMs=${nativeProbe.durationMs}',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await ReaderPlatform.invoke('stopAudio');

        // 9. 使用云端真实模型与 TTS 启动短篇多角色沉浸式听书全链路，验证双缓冲无缝切段与倍速
        final book = Book(
          bookId: 'mac_live_immersive_book',
          bookName: '雪夜客栈',
          author: '联调测试',
        );
        final chapters = [
          Chapter(
            itemId: 'mac_ch1',
            title: '第一章 雪夜客栈',
            order: 1,
            content:
                '风雪扑打着木窗，客栈大堂里只有一盏孤灯。\n\n'
                '“掌柜的，还有热酒吗？”沈青推门而入，抖落肩头积雪。\n\n'
                '“有，客官请坐。”苏晚端起温好的酒壶笑着走来。\n\n'
                '沈青接过酒杯，轻声道：“外头路滑，今晚怕是走不了了。”',
          ),
        ];

        nativeEvents.clear();
        await coord.startImmersivePlayback(
          book: book,
          chapters: chapters,
          chapterIndex: 0,
        );

        // 等待进入真实播放且至少 2 段音频就绪
        for (var i = 0; i < 180; i++) {
          final st = await coord.getPipelineStatus();
          if (coord.isPlaying && st.readyAudioSegments >= 2) {
            break;
          }
          if (coord.state == ImmersivePlayState.blocked) {
            fail('管线阻塞：${coord.errorMessage ?? st.blockingReason}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(coord.isPlaying, isTrue, reason: '未在超时内进入播放态');

        // 加速到 2.0x 验证实时倍速与 getAudioPosition，并等待触发真实原生无缝切段 onAudioTransition
        await coord.setPlaybackRate(2.0);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final posResp = await ReaderPlatform.invoke<Map<dynamic, dynamic>>(
          'getAudioPosition',
        );
        expect(posResp, isNotNull);
        expect(posResp!['playing'], isTrue);
        expect((posResp['durationMs'] as num).toInt(), greaterThan(0));
        debugPrint('[MAC-LIVE] getAudioPosition: $posResp');

        final initialSegIndex = coord.currentSegmentIndex;
        for (var i = 0; i < 80; i++) {
          if (nativeEvents.any((e) => e.$1 == 'onAudioTransition') ||
              coord.currentSegmentIndex > initialSegIndex) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        final hasTransition = nativeEvents.any(
          (e) => e.$1 == 'onAudioTransition',
        );
        final finalStatus = await coord.getPipelineStatus();
        final chars = await coord.stateStore!.getCharacters(book.bookId);
        debugPrint(
          '[MAC-LIVE] Pipeline summary: '
          'confirmed=${finalStatus.confirmedChunks}/${finalStatus.totalPlannedChunks}, '
          'ready=${finalStatus.readyAudioSegments}/${finalStatus.totalManifestSegments}, '
          'chars=${chars.map((c) => '${c.canonicalName}(${c.gender})').toList()}, '
          'segIdx=$initialSegIndex->${coord.currentSegmentIndex}, '
          'hasNativeTransition=$hasTransition, '
          'firstLatencyMs=${finalStatus.firstAudioLatencyMs}',
        );

        expect(finalStatus.confirmedChunks, greaterThanOrEqualTo(1));
        expect(finalStatus.readyAudioSegments, greaterThanOrEqualTo(2));
        expect(chars.length, greaterThanOrEqualTo(2));
        expect(
          hasTransition || coord.currentSegmentIndex > initialSegIndex,
          isTrue,
          reason: '未能推进到下一音频段，events=$nativeEvents',
        );

        // 验证暂停、恢复、停止全生命周期
        await coord.pause();
        expect(coord.isPaused, isTrue);
        await coord.resume();
        expect(coord.isActive, isTrue);
        await coord.stop();
        expect(coord.isActive, isFalse);
        debugPrint('[MAC-LIVE] Full macOS immersive TTS E2E passed!');
      } finally {
        await coord.stop().catchError((_) {});
        await ReaderPlatform.invoke('setAudioVolume', {'volume': 1.0})
            .catchError((_) => null);
        ReaderSystemService.removeTtsListener(eventListener);
        client.close();
        // 还原所有修改过的 Keychain 槽位
        for (final entry in backedUpSlots.entries) {
          await secretStore.write(entry.key, entry.value ?? '');
        }
        AppStorage.documentsOverride = null;
        if (await testRoot.exists()) {
          await testRoot.delete(recursive: true);
        }
      }
    },
    skip: !_runLive,
    timeout: const Timeout(Duration(seconds: 240)),
  );
}
