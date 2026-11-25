import 'dart:io';
import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/services/text_model_adapter.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/immersive/widgets/immersive_player_panel.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/reader_display_text.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/tts_player_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/tts_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late TtsService tts;
  final calls = <(String, Map<String, Object?>?)>[];
  setUpAll(ReaderDisplayText.ensureLoaded);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('macos-tts-widget-');
    AppStorage.documentsOverride = () async => root;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    ReaderPlatform.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          ReaderPlatform.channel,
          (call) async => call.method == 'getReaderCapabilities'
              ? {
                  'tts': true,
                  'nativeSpeech': true,
                  'secureStorage': true,
                  'mediaPlayback': true,
                }
              : null,
        );
    await ReaderPlatform.initialize();
    calls.clear();
    tts = TtsService.forTesting(
      invoke: (method, args) async {
        calls.add((method, args));
        if (method == 'readTtsSecret') return '';
        if (method == 'getNativeTtsVoices') return [];
        return true;
      },
      client: MockClient((_) async => http.Response.bytes(silentTtsWav(), 200)),
      temporary: () async => root,
    );
  });
  tearDown(() async {
    await tts.stop();
    tts.dispose();
    await ReaderSettingsRepository.flush();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, null);
    await root.delete(recursive: true);
  });
  void desktopTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        tester.view.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  desktopTest(
    'desktop TTS settings keep controllers alive through the close animation',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      await tester.runAsync(() async {
        await tts.saveSettings(
          engineType: TtsEngineType.openAi,
          openAiBaseUrl: 'https://compatible.example/v1',
          openAiApiKey: 'synthetic-only',
          openAiModel: 'custom-model',
          openAiVoice: 'custom-voice',
          speechRate: 1.25,
        );
        await tts.startChapter('测试', '仅测试文本，非用户内容。');
        await tts.pause();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TtsPlayerPanel(onClose: () {}, service: tts),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('发音与接口设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存配置'));
      await tester.tap(find.text('保存配置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-reader-dialog')), findsNothing);
      expect(tts.openAiModel, 'custom-model');
      expect(tts.openAiVoice, 'custom-voice');
      expect(tts.speechRate, 1.25);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.reset();
    },
  );
  desktopTest(
    'reader reserves the audio bar, retains source and manual keys stop listening',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      const bookId = 'local_tts_widgets';
      final book = Book(bookId: bookId, bookName: '隔离阅读', author: '测试');
      final chapters = [
        Chapter(
          itemId: 'c',
          title: '第一章',
          content: List.generate(
            50,
            (i) => '第$i段原文，听书和分页保持源坐标。' * 5,
          ).join('\n\n'),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          builder: (_, child) => DesktopShortcuts(child: child!),
          home: ReaderScreen(
            book: book,
            chapters: chapters,
            ttsService: tts,
            resumeSavedPosition: false,
            bookDocuments: () async => root,
            initialSettings: const ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: 'none',
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final oldHeight = tester.getSize(find.byType(ReaderPageView)).height;
      await tts.startBook(book, chapters, 0);
      await tester.pumpAndSettle();
      expect(tts.isPlaying, true);
      expect(find.byKey(const ValueKey('desktop-tts-player')), findsOneWidget);
      expect(
        tester.getSize(find.byType(ReaderPageView)).height,
        oldHeight - TtsPlayerPanel.desktopHeight,
      );
      final current = tts.currentPosition!;
      tts.handlePlatformEvent('onTtsComplete', {'id': 'stale'});
      await tester.pump();
      expect(tts.currentPosition!.toJson(), current.toJson());
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(tts.isActive, false);
      expect(find.byKey(const ValueKey('desktop-tts-player')), findsNothing);
      expect(tester.getSize(find.byType(ReaderPageView)).height, oldHeight);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.reset();
    },
  );

  desktopTest(
    'desktop reader exposes immersive TTS controls, reserves fixed bar height and opens desktop dialogs',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 820);
      tester.view.devicePixelRatio = 1;
      const bookId = 'local_mac_immersive_widget';
      final book = Book(bookId: bookId, bookName: '桌面沉浸式测试', author: '测试');
      final chapters = [
        Chapter(
          itemId: 'ch_mac_1',
          title: '第一章 雨夜客栈',
          content: '窗外下着大雨。\n\n“有人吗？”林晚轻声问道。\n\n掌柜抬头望去，微微笑了笑。',
        ),
      ];
      final cfgFile = File('${root.path}/immersive_config.json');
      final cfgSvc = ImmersiveConfigService(
        documents: () async => root,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final store = InMemoryImmersiveStateStore();
      final wavBytes = silentTtsWav();
      final immersiveCalls = <(String, Map<String, Object?>?)>[];
      final coord = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgSvc,
        stateStore: store,
        textAdapter: _DesktopFakeTextAdapter(),
        ttsAdapter: _DesktopFakeTtsAdapter(wavBytes),
        audioCacheDir: '${root.path}/imm_audio',
        tempDir: '${root.path}/imm_tmp',
        platformAudioProbe: (_, fallback) async =>
            (valid: true, durationMs: fallback),
        invoke: (method, args) async {
          immersiveCalls.add((method, args));
          return true;
        },
      );
      await tester.runAsync(() async {
        final saveRes = await cfgSvc.saveConfig(
          ImmersivePresetConfig.createConfiguredDefault(
            textApiKey: 'sk-synthetic-desktop-text',
            ttsApiKey: 'sk-synthetic-desktop-tts',
            featureEnabled: true,
          ).copyWith(
            prefetch: const PrefetchConfig(
              startupBufferSeconds: 0.2,
              startupWaitAfterFirstReadyMs: 100,
              resumeBufferSeconds: 0.2,
              lowWaterSeconds: 5,
              targetBufferSeconds: 10,
              highWaterSeconds: 20,
              maxJobsBeyondFirstGap: 2,
            ),
            jobs: const JobsConfig(
              leaseSeconds: 30,
              heartbeatSeconds: 10,
              pollIntervalMs: 50,
              cancelUnneededRequestsOnSeek: true,
            ),
          ),
          configFile: cfgFile,
        );
        expect(saveRes.issues, isEmpty);
        await coord.loadAndValidateConfig(configFile: cfgFile);
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          builder: (_, child) => DesktopShortcuts(child: child!),
          home: ReaderScreen(
            book: book,
            chapters: chapters,
            ttsService: tts,
            immersiveService: coord,
            resumeSavedPosition: false,
            bookDocuments: () async => root,
            initialSettings: const ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: 'none',
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 桌面工具栏暴露沉浸式听书入口按钮与更多菜单项
      expect(find.byKey(const ValueKey('immersive-listen-button')), findsOneWidget);
      final oldHeight = tester.getSize(find.byType(ReaderPageView)).height;

      await tester.tap(find.byTooltip('阅读操作'));
      await tester.pumpAndSettle();
      expect(find.text('沉浸式多角色听书'), findsOneWidget);
      expect(find.text('沉浸式听书设置'), findsOneWidget);
      expect(find.text('本书角色与音色'), findsOneWidget);

      // 打开沉浸式听书设置应以桌面居中 Dialog 展示，而非 BottomSheet
      await tester.tap(find.text('沉浸式听书设置'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const ValueKey('desktop-reader-dialog')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('沉浸式多角色听书设置'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // 启动沉浸式听书并等待进入播放状态
      await tester.runAsync(() async {
        await coord.startImmersivePlayback(
          book: book,
          chapters: chapters,
          chapterIndex: 0,
        );
        for (var i = 0; i < 60 && !coord.isPlaying; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(coord.isPlaying, isTrue);
      expect(find.byKey(const ValueKey('immersive-player-panel')), findsOneWidget);
      expect(
        tester.getSize(find.byType(ReaderPageView)).height,
        oldHeight - ImmersivePlayerPanel.desktopHeight,
      );
      expect(
        immersiveCalls.any((c) => c.$1 == 'playAudioFile'),
        isTrue,
      );

      // 打开本书角色与音色应以桌面居中 Dialog 展示
      await tester.tap(find.byTooltip('本书角色与音色'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('desktop-reader-dialog')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-reader-dialog')),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 停止播放后恢复正文视口高度
      await tester.runAsync(() => coord.stop());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(coord.isActive, isFalse);
      expect(find.byKey(const ValueKey('immersive-player-panel')), findsNothing);
      expect(tester.getSize(find.byType(ReaderPageView)).height, oldHeight);
      expect(tester.takeException(), isNull);

      coord.dispose();
    },
  );
}

class _DesktopFakeTextAdapter implements TextModelAdapter {
  @override
  void cancelAll() {}

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    final targetSection = userMessage
        .split('[TARGET_UNITS')
        .last
        .split('[/TARGET_UNITS]')
        .first;
    final ids = RegExp(r'^(u_[^\s:]+):', multiLine: true)
        .allMatches(targetSection)
        .map((m) => m.group(1)!)
        .toList();
    return StructuredModelResponse(
      data: {
        'assignments': [
          for (var i = 0; i < ids.length; i++)
            {
              'source_unit_ids': [ids[i]],
              'kind': i == 1 ? 'dialogue' : 'narration',
              'speaker_ref': i == 1 ? 'local:new_1' : 'narrator',
              'evidence_unit_ids': [ids[i]],
              'evidence_type': 'explicit_attribution',
            },
        ],
        'new_character_proposals': [
          if (ids.length > 1)
            {
              'local_ref': 'local:new_1',
              'display_name': '林晚',
              'gender': 'female',
              'suggested_voice_profile_id': 'vp_oneapi_DeepSeek_female',
              'evidence_unit_ids': [ids[1]],
            },
        ],
        'alias_evidence': const <Map<String, dynamic>>[],
        'merge_proposals': const <Map<String, dynamic>>[],
        'chapter_summary': '雨夜客栈初遇',
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
  }) async => const StructuredModelResponse(
    data: {
      'decision': 'unresolved',
      'resolved_character_id': null,
      'suggested_name': null,
      'gender': 'unknown',
      'suggested_voice_profile_id': null,
      'evidence_unit_ids': <String>[],
      'reason': 'test',
    },
    latencyMs: 5,
    schemaVersion: ImmersiveNativeSchemas.identityRecheckVersion,
  );

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async => const StructuredModelResponse(
    data: {'chapter_summary': '摘要', 'active_character_ids': <String>[]},
    latencyMs: 5,
    schemaVersion: ImmersiveNativeSchemas.summaryUpdateVersion,
  );

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
}

class _DesktopFakeTtsAdapter implements TtsProviderAdapter {
  final Uint8List wavBytes;
  _DesktopFakeTtsAdapter(this.wavBytes);

  @override
  void cancelAll() {}

  @override
  Future<SynthesizedAudioPayload> synthesize({
    required RenderSpec spec,
    required String apiKey,
    required int timeoutMs,
    bool Function()? isCancelled,
  }) async => SynthesizedAudioPayload(
    bytes: wavBytes,
    detectedFormat: 'wav',
    durationMs: 300,
    latencyMs: 5,
  );

  @override
  Future<VoiceProfileTestResult> testVoiceProfile({
    required VoiceProfileResolution resolution,
    required String apiKey,
    String sampleText = '',
  }) async => VoiceProfileTestResult(
    success: true,
    message: 'ok',
    audioFormat: 'wav',
    durationMs: 300,
    byteLength: wavBytes.length,
    latencyMs: 5,
    audioBytes: wavBytes,
  );
}
