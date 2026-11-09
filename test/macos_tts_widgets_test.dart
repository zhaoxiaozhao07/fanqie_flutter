import 'dart:io';
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
}
