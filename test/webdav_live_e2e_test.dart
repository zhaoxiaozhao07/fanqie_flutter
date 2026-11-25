import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fanqie_flutter/immersive/models/immersive_entities.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/models/bookshelf_book.dart';
import 'package:fanqie_flutter/models/reading_history.dart';
import 'package:fanqie_flutter/webdav/models/webdav_config.dart';
import 'package:fanqie_flutter/webdav/services/webdav_client.dart';
import 'package:fanqie_flutter/webdav/services/webdav_crypto.dart';
import 'package:fanqie_flutter/webdav/services/webdav_sync_service.dart';

class _LiveTtsBridge implements NormalTtsConfigBridge {
  NormalTtsConfigSnapshot value;
  _LiveTtsBridge(this.value);

  @override
  Future<NormalTtsConfigSnapshot> read() async => value;

  @override
  Future<void> write(NormalTtsConfigSnapshot snapshot) async {
    value = snapshot;
  }
}

void main() {
  const runLive = bool.fromEnvironment('RUN_LIVE_WEBDAV', defaultValue: false);
  const webdavUrl = String.fromEnvironment('WEBDAV_URL', defaultValue: '');
  const webdavUser = String.fromEnvironment('WEBDAV_USER', defaultValue: '');
  const webdavPass = String.fromEnvironment('WEBDAV_PASS', defaultValue: '');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    HttpOverrides.global = null;
  });

  test(
    '真实 WebDAV 服务端端到端联调：连接 + AI配置 + 阅读历史 + 离线书上传下载 + 清理',
    () async {
      expect(webdavUrl.isNotEmpty, isTrue, reason: '请通过 --dart-define=WEBDAV_URL 传入地址');
      expect(webdavUser.isNotEmpty, isTrue, reason: '请通过 --dart-define=WEBDAV_USER 传入账号');
      expect(webdavPass.isNotEmpty, isTrue, reason: '请通过 --dart-define=WEBDAV_PASS 传入密码');

      final tempRoot = await Directory.systemTemp.createTemp('webdav_live_e2e_');
      final dirA = Directory(p.join(tempRoot.path, 'devA'))..createSync();
      final dirB = Directory(p.join(tempRoot.path, 'devB'))..createSync();
      const testOfflineBookId = 'local_txt_webdav_live_probe';

      try {
        SharedPreferences.setMockInitialValues({});
        final secretA = MemoryImmersiveSecretStore();
        final immA = ImmersiveConfigService(
          documents: () async => dirA,
          secretStore: secretA,
        );
        await immA.saveConfig(
          ImmersivePresetConfig.createConfiguredDefault(
            textApiKey: 'sk-live-e2e-text-dummy-key',
            ttsApiKey: 'sk-live-e2e-tts-dummy-key',
            featureEnabled: true,
          ),
        );

        final ttsA = _LiveTtsBridge(
          const NormalTtsConfigSnapshot(
            engine: 'openAi',
            baseUrl: 'https://oneapi.971218.xyz/v1',
            apiKey: 'live-normal-tts-probe-token',
            model: 'DeepSeek_female',
            voice: 'DeepSeek',
            rate: 1.2,
            nativeVoice: '',
          ),
        );

        final bookDirA = Directory(
          p.join(dirA.path, 'offline_books', testOfflineBookId),
        )..createSync(recursive: true);
        File(p.join(bookDirA.path, 'metadata.json')).writeAsStringSync(
          jsonEncode({
            'book_id': testOfflineBookId,
            'book_name': 'WebDAV实测离线书',
            'author': '联调校验',
            'chapter_count': 1,
          }),
        );
        File(p.join(bookDirA.path, 'ch_01.txt'))
            .writeAsStringSync('这是一段用于验证真实 WebDAV 上传与下载一致性的离线正文。');

        final prefsA = await SharedPreferences.getInstance();
        await prefsA.setString(
          'bookshelf_books_v1',
          jsonEncode([
            BookshelfBook(
              bookId: testOfflineBookId,
              bookName: 'WebDAV实测离线书',
              author: '联调校验',
              lastReadChapterIndex: 0,
              lastReadChapterTitle: '第一章',
              lastReadTime: DateTime.utc(2026, 11, 25, 15, 0),
              totalChapters: 1,
            ).toJson(),
            BookshelfBook(
              bookId: 'online_probe_777',
              bookName: '未离线在线书元数据',
              author: '在线作者',
              lastReadChapterIndex: 42,
              lastReadChapterTitle: '第四十三章',
              lastReadTime: DateTime.utc(2026, 11, 25, 15, 5),
              totalChapters: 200,
            ).toJson(),
          ]),
        );
        await prefsA.setString(
          'reading_history_v1',
          jsonEncode([
            ReadingHistory(
              bookId: 'online_probe_777',
              bookName: '未离线在线书元数据',
              author: '在线作者',
              lastReadChapterTitle: '第四十三章',
              lastReadChapterIndex: 42,
              lastReadTime: DateTime.utc(2026, 11, 25, 15, 5),
            ).toJson(),
          ]),
        );

        final storeA = InMemoryImmersiveStateStore();
        await storeA.saveCharacter(
          const ImmersiveCharacter(
            characterId: 'char_live_01',
            bookId: testOfflineBookId,
            canonicalName: '联调女主角',
            gender: 'female',
            firstSeenUnitId: 'u_0',
            updatedAtMs: 1000,
          ),
        );
        await storeA.upsertVoiceBinding(
          const VoiceBinding(
            bookId: testOfflineBookId,
            characterId: 'char_live_01',
            voiceProfileId: 'vp_oneapi_Kimi_female',
            manualLocked: true,
            bindingRevision: 1,
            updatedAtMs: 1000,
          ),
        );

        final syncA = WebDavSyncService.forTesting(
          documents: () async => dirA,
          secretStore: secretA,
          immersiveConfigService: immA,
          normalTtsBridge: ttsA,
          profilesBridge: StoreImmersiveProfilesBridge(storeA),
        );
        await syncA.saveConfig(
          WebDavConfig(
            enabled: true,
            serverUrl: webdavUrl,
            username: webdavUser,
            password: webdavPass,
            autoSyncOnStart: true,
            syncAiConfig: true,
            syncReadingData: true,
            syncOfflineBooks: true,
            syncImmersiveProfiles: true,
            encryptCloudAiConfig: true,
          ),
        );

        final conn = await syncA.testConnection();
        stdout.writeln('[LIVE-WEBDAV] testConnection: ok=${conn.success} msg=${conn.message}');
        expect(conn.success, isTrue, reason: conn.message);

        final pushReport = await syncA.syncNow(mode: WebDavSyncMode.pushToRemote);
        stdout.writeln('[LIVE-WEBDAV] push: ok=${pushReport.success} summary=${pushReport.conciseSummary} (${pushReport.durationMs}ms)');
        expect(pushReport.success, isTrue, reason: pushReport.message);
        expect(pushReport.uploadedBookIds, contains(testOfflineBookId));

        // 核验云端 ai_config.json 已端到端加密且不含任何明文 API Key
        final probeClient = WebDavClient(
          serverUrl: webdavUrl,
          username: webdavUser,
          password: webdavPass,
        );
        try {
          final remoteRawBytes = await probeClient.getBytes('ai_config.json');
          expect(remoteRawBytes, isNotNull);
          final remoteText = utf8.decode(remoteRawBytes!);
          expect(remoteText.contains('sk-live-e2e'), isFalse);
          expect(remoteText.contains('live-normal-tts-probe-token'), isFalse);
          expect(
            WebDavCrypto.isEncryptedEnvelope(
              jsonDecode(remoteText) as Map<String, dynamic>,
            ),
            isTrue,
          );
          stdout.writeln('[LIVE-WEBDAV] 云端 ai_config.json AES-256-GCM 密文校验通过（零明文密钥）');
        } finally {
          probeClient.close();
        }

        // 模拟全新设备 B 启动自动同步，完整拉取并验证一致性
        SharedPreferences.setMockInitialValues({});
        final secretB = MemoryImmersiveSecretStore();
        final immB = ImmersiveConfigService(
          documents: () async => dirB,
          secretStore: secretB,
        );
        final storeB = InMemoryImmersiveStateStore();
        final ttsB = _LiveTtsBridge(
          const NormalTtsConfigSnapshot(
            engine: 'native',
            baseUrl: 'https://api.openai.com',
            apiKey: '',
            model: 'tts-1',
            voice: 'alloy',
            rate: 1.0,
            nativeVoice: '',
          ),
        );
        final syncB = WebDavSyncService.forTesting(
          documents: () async => dirB,
          secretStore: secretB,
          immersiveConfigService: immB,
          normalTtsBridge: ttsB,
          profilesBridge: StoreImmersiveProfilesBridge(storeB),
        );
        await syncB.saveConfig(
          WebDavConfig(
            enabled: true,
            serverUrl: webdavUrl,
            username: webdavUser,
            password: webdavPass,
            autoSyncOnStart: true,
            syncAiConfig: true,
            syncReadingData: true,
            syncOfflineBooks: true,
            syncImmersiveProfiles: true,
            encryptCloudAiConfig: true,
          ),
        );

        final autoReport = await syncB.triggerAutoSyncOnStart();
        stdout.writeln('[LIVE-WEBDAV] autoSyncOnStart: ok=${autoReport?.success} summary=${autoReport?.conciseSummary} (${autoReport?.durationMs}ms)');
        expect(autoReport, isNotNull);
        expect(autoReport!.success, isTrue, reason: autoReport.message);
        expect(autoReport.downloadedBookIds, contains(testOfflineBookId));

        // 校验沉浸式配置、普通朗读配置、角色档案锁定、离线正文和未离线元数据全部精确还原
        final immStatusB = await immB.loadAndValidateConfig(autoInitPreset: false);
        expect(immStatusB.available, isTrue);
        expect(immStatusB.config!.textAnalysisModels.length, 3);
        expect(ttsB.value.engine, 'openAi');
        expect(ttsB.value.rate, closeTo(1.2, 0.001));
        expect(ttsB.value.apiKey, 'live-normal-tts-probe-token');

        final restoredBindingsB = await storeB.getVoiceBindings(testOfflineBookId);
        expect(restoredBindingsB.length, 1);
        expect(restoredBindingsB.first.manualLocked, isTrue);
        expect(restoredBindingsB.first.voiceProfileId, 'vp_oneapi_Kimi_female');

        final chB = File(
          p.join(dirB.path, 'offline_books', testOfflineBookId, 'ch_01.txt'),
        );
        expect(await chB.exists(), isTrue);
        expect(
          await chB.readAsString(),
          '这是一段用于验证真实 WebDAV 上传与下载一致性的离线正文。',
        );
        expect(
          await Directory(p.join(dirB.path, 'offline_books', 'online_probe_777')).exists(),
          isFalse,
        );

        // 清理本次 E2E 测试写入的远端临时离线书，保持用户 WebDAV 空间整洁
        final client = WebDavClient(
          serverUrl: webdavUrl,
          username: webdavUser,
          password: webdavPass,
        );
        try {
          await client.delete('books/$testOfflineBookId.zip');
          await client.delete('sync_index.json');
          await client.delete('ai_config.json');
          await client.delete('reading_data.json');
          await client.delete('immersive_profiles.json');
        } finally {
          client.close();
        }
      } finally {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      }
    },
    skip: !runLive,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
