import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/external_book_import_service.dart';
import '../test/epub_image_fixture.dart';
import '../test/helpers/tts_audio.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:fanqie_flutter/widgets/tts_player_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const manualSave = bool.fromEnvironment('WINDOWS_SAVE_PANEL_TEST');
const nativeFullScreen = bool.fromEnvironment('WINDOWS_NATIVE_FULLSCREEN_TEST');

Future<void> fullScreen(WidgetTester tester, bool enabled) async {
  await ReaderPlatform.invoke('setTestFullScreen', {'enabled': enabled});
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  Map? lastState;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final state = await ReaderPlatform.invoke<Map>('getTestWindowState');
    lastState = state;
    if (state!['fullScreen'] == enabled) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Native full-screen transition did not complete: $lastState');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  void nativeTest(
    String name,
    WidgetTesterCallback body, {
    bool skip = false,
    Timeout? timeout,
  }) {
    testWidgets(
      name,
      (tester) async {
        try {
          await body(tester);
        } finally {
          // Live desktop tests replace FocusManager after each case. Detach
          // the old route/focus nodes first, otherwise the next native resize
          // or activation can notify the already-disposed manager.
          await ReaderPlatform.invoke(
            'showMainWindow',
          ).timeout(const Duration(seconds: 5));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          FocusManager.instance.applyFocusChangesIfNeeded();
          await tester.pump();
        }
      },
      skip: skip,
      timeout: timeout,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookshelfService().reload();
    await ReaderPlatform.initialize();
    AppLifecycleService.initialize();
    final support = await AppStorage.documents();
    // The persisted data root follows the exe identity, not its location.
    expect(support.path, contains('com.fanqie'));
    expect(support.path, contains('FanqieReader'));
    expect(support.path, (await getApplicationSupportDirectory()).path);
    root = await support.createTemp('isolated-windows-test-');
    AppStorage.documentsOverride = () async => root;
  });

  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await ReaderPlatform.invoke('showMainWindow');
    AppStorage.documentsOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  nativeTest(
    'actual native capabilities, streaming import and same-platform restore',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Windows 原生验证'))),
      );
      expect(ReaderPlatform.isWindows, true);
      expect(ReaderPlatform.isDesktop, true);
      expect(ReaderPlatform.capabilities.tts, true);
      expect(ReaderPlatform.capabilities.mediaPlayback, true);
      expect(ReaderPlatform.capabilities.secureStorage, true);
      expect(ReaderPlatform.capabilities.volumeKeys, false);
      expect(ReaderPlatform.capabilities.windowBrightness, false);
      expect(ReaderPlatform.capabilities.textDecoder, true);
      expect(ReaderPlatform.capabilities.fileExport, true);
      expect(ReaderPlatform.capabilities.fileImport, true);
      expect(
        await ReaderSystemService.getNetworkType(),
        isIn(['wifi', 'ethernet', 'offline', 'mobile', 'unknown']),
      );
      final importer = LocalBookService.forTesting(documents: () async => root);
      for (final fixture in encodingFixtures.entries) {
        final source = await File(
          '${root.path}/${fixture.key}.txt',
        ).writeAsBytes(fixture.value);
        final result = await importer.importLocalFile(
          source,
          options: LocalImportOptions(encoding: fixture.key),
        );
        expect(result.chapters, isNotEmpty);
        final content = (await Future.wait(
          result.chapters.map(
            (c) => File(
              '${root.path}/offline_books/${result.book.bookId}/${c.itemId}.txt',
            ).readAsString(),
          ),
        )).join();
        expect(content, contains('中文'));
        if (fixture.key == 'GB18030') expect(content, contains('😀'));
        expect(await source.readAsBytes(), fixture.value);
        final duplicate = await importer.importLocalFile(
          source,
          options: LocalImportOptions(encoding: fixture.key),
        );
        expect(duplicate.alreadyExists, true);
        expect(duplicate.book.bookId, result.book.bookId);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reader_settings_v2',
        jsonEncode(const ReaderSettings(fontSize: 22).toJson()),
      );
      final backup = ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      );
      final archive = await backup.create(includeBooks: true);
      await prefs.remove('reader_settings_v2');
      await backup.restore(archive, mode: ReaderRestoreMode.replace);
      expect(prefs.getString('reader_settings_v2'), contains('22'));
      expect(ReaderBackupService.hasActiveTransaction, false);
      await backup.recover();
      expect(
        await File('${root.path}/reader_restore_journal.json').exists(),
        false,
      );
    },
  );

  nativeTest('auto encoding order prefers UTF-8 before GB18030 and Big5', (
    tester,
  ) async {
    // A valid UTF-8 file must decode as UTF-8 in automatic mode.
    final source = await File(
      '${root.path}/auto-utf8.txt',
    ).writeAsString('第一章 开端\n中文正文。\n第二章 结尾\n中文结尾。');
    final result = await LocalBookService.forTesting(
      documents: () async => root,
    ).importLocalFile(source);
    expect(result.chapters.length, greaterThanOrEqualTo(2));
    // Bytes valid in GB18030 but invalid UTF-8 must fall through to GB18030.
    final mixed = await File(
      '${root.path}/auto-gb.txt',
    ).writeAsBytes(encodingFixtures['GBK']!);
    final gb = await LocalBookService.forTesting(
      documents: () async => root,
    ).importLocalFile(mixed);
    expect(gb.chapters.length, greaterThanOrEqualTo(2));
  });

  nativeTest('direct download commits never overwrite and number duplicates', (
    tester,
  ) async {
    final target = (await root.createTemp('downloads-')).path;
    final source = await File('${root.path}/book.txt').writeAsString('正文');
    Future<Map<dynamic, dynamic>?> commit(String name, String id) =>
        ReaderPlatform.invoke<Map<dynamic, dynamic>>('commitDownloadFile', {
          'id': id,
          'sourcePath': source.path,
          'directory': target,
          'fileName': name,
        });
    final first = await commit('fanqie-download-test.txt', 'dl-1');
    expect(first!['status'], 'saved');
    final second = await commit('fanqie-download-test.txt', 'dl-2');
    expect(second!['status'], 'saved');
    expect(second['path'], isNot(first['path']));
    expect(await File(first['path'] as String).readAsString(), '正文');
    expect(await File(second['path'] as String).exists(), true);
    // Existing unrelated files are never silently replaced.
    final guard = await File('$target/guard.txt').writeAsString('已有文件');
    final third = await commit('guard.txt', 'dl-3');
    expect(third!['status'], 'saved');
    expect(third['path'], isNot('$target\\guard.txt'));
    expect(await guard.readAsString(), '已有文件');
    // Hostile names never create ADS, device files or trailing-dot paths.
    String fileNameOf(Map<dynamic, dynamic> r) =>
        (r['path'] as String).split('\\').last;
    final ads = await commit('书名:流.txt', 'dl-4');
    expect(ads!['status'], 'saved');
    expect(fileNameOf(ads), isNot(contains(':')));
    expect(await File(ads['path'] as String).exists(), true);
    final device = await commit('CON', 'dl-5');
    expect(device!['status'], 'saved');
    expect(fileNameOf(device), isNot(equals('CON')));
    expect(await File(device['path'] as String).exists(), true);
    final dotted = await commit('书名...', 'dl-6');
    expect(dotted!['status'], 'saved');
    expect(fileNameOf(dotted), isNot(endsWith('.')));
    expect(await File(dotted['path'] as String).exists(), true);
  });

  nativeTest(
    'same-platform EPUB restore resolves cover and illustrations against the new root',
    (tester) async {
      final source = await imageEpub(
        root,
        ['<p>恢复前正文。</p><img src="../Images/图%201.png"/><p>恢复后正文。</p>'],
        resources: {
          'OPS/book.opf': utf8.encode(
            '''<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>恢复插图</dc:title><dc:creator>测试</dc:creator></metadata>
<manifest><item id="c0" href="Text/0.xhtml" media-type="application/xhtml+xml"/>
<item id="cover" href="Images/图%201.png" media-type="image/png" properties="cover-image"/></manifest>
<spine><itemref idref="c0"/></spine></package>''',
          ),
        },
      );
      final imported = await LocalBookService.forTesting(
        documents: () async => root,
      ).importLocalEpub(source);
      expect(imported.book.thumbUrl, startsWith(root.path));
      final backup = await ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      ).create(includeBooks: true);
      final restored = await (await getApplicationSupportDirectory())
          .createTemp('isolated-restored-epub-win-');
      try {
        await ReaderBackupService(
          documents: () async => restored,
          notifyServices: false,
        ).restore(backup, mode: ReaderRestoreMode.replace);
        await root.delete(
          recursive: true,
        ); // Old absolute paths can no longer work.
        AppStorage.documentsOverride = () async => restored;
        final folder = '${restored.path}/offline_books/${imported.book.bookId}';
        final chapters =
            (jsonDecode(await File('$folder/directory.json').readAsString())
                    as List)
                .asMap()
                .entries
                .map(
                  (e) => Chapter.fromDirectoryJson(
                    Map<String, dynamic>.from(e.value as Map),
                    e.key,
                  ),
                )
                .toList();
        final asset = chapters.expand((c) => c.illustrations).first.asset!;
        expect(await File('$folder/$asset').readAsBytes(), imagePng());
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [readerRouteObserver],
            home: ReaderScreen(
              book: imported.book,
              chapters: chapters,
              bookDocuments: () async => restored,
              resumeSavedPosition: false,
              initialSettings: const ReaderSettingsRecord(
                ReaderSettings(
                  pageMode: false,
                  pureMode: true,
                  commentBubbles: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        AppStorage.documentsOverride = () async => root;
        await restored.delete(recursive: true);
      }
    },
  );

  nativeTest('real save panel cancellation has no success or source deletion', (
    tester,
  ) async {
    final source = await File(
      '${root.path}/cancel-source.txt',
    ).writeAsString('保留正文');
    final result = FileExportService().save(
      source,
      name: 'fanqie-windows-test.txt',
      mimeType: 'text/plain',
      requestId: 'cancel-panel',
    );
    final cancellationClock = Stopwatch()..start();
    debugPrint('NATIVE_CANCEL_INTEGRATION save-started; waiting real delay');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    debugPrint(
      'NATIVE_CANCEL_INTEGRATION delay-complete '
      'elapsedMs=${cancellationClock.elapsedMilliseconds}; invoking cancel',
    );
    expect(
      await ReaderPlatform.invoke<bool>('cancelExport', {
        'id': 'cancel-panel',
      }).timeout(const Duration(seconds: 4)),
      true,
    );
    debugPrint('NATIVE_CANCEL_INTEGRATION cancel-acknowledged');
    expect(
      (await result.timeout(const Duration(seconds: 4))).status,
      FileExportStatus.cancelled,
    );
    expect(await source.readAsString(), '保留正文');
  }, timeout: const Timeout(Duration(seconds: 15)));

  nativeTest('real window resize, minimize and power assertion release', (
    tester,
  ) async {
    await ReaderPlatform.invoke('setTestWindowSize', {
      'width': 1024.0,
      'height': 768.0,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(
            bookId: 'local_native_window',
            bookName: '原生窗口验收',
            author: '测试',
          ),
          chapters: [
            Chapter(
              itemId: 'c',
              title: '正文',
              content: List.generate(
                200,
                (i) =>
                    '正文第${i.toString().padLeft(3, '0')}段。窗口大小变化后仍然应该保留阅读位置，不能返回开头。',
              ).join('\n\n'),
            ),
          ],
          bookDocuments: () async => root,
          initialSettings: const ReaderSettingsRecord(
            ReaderSettings(
              pageMode: false,
              pureMode: true,
              commentBubbles: false,
              keepScreenOn: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
    }
    await ReaderSystemService.flushParticipants();
    final before = await ReaderPositionService().load('local_native_window');
    expect(before!.paragraphIndex, greaterThan(0));
    await ReaderPlatform.invoke('setTestWindowSize', {
      'width': 720.0,
      'height': 520.0,
    });
    await tester.pumpAndSettle();
    await ReaderSystemService.flushParticipants();
    final after = await ReaderPositionService().load('local_native_window');
    expect(after!.paragraphIndex, before.paragraphIndex);
    await ReaderPlatform.invoke('hideTestWindow');
    await tester.pump(const Duration(milliseconds: 500));
    final hidden = await ReaderPlatform.invoke<Map>('getTestWindowState');
    expect(hidden!['minimized'], true);
    expect(hidden['displayAssertion'], false);
    expect(
      (await ReaderPositionService().load(
        'local_native_window',
      ))!.paragraphIndex,
      after.paragraphIndex,
    );
    await ReaderPlatform.invoke('showMainWindow');
    await tester.pumpAndSettle();
    final shown = await ReaderPlatform.invoke<Map>('getTestWindowState');
    expect(shown!['visible'], true);
    expect(shown['minimized'], false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  // A real desktop session is required; the CI-headless resize result above
  // does not replace this manual gate.
  nativeTest('native full-screen preserves exact reading anchors', (
    tester,
  ) async {
    await ReaderPlatform.invoke('setTestWindowSize', {
      'width': 1024.0,
      'height': 768.0,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(
            bookId: 'local_native_window',
            bookName: '全屏验收',
            author: '隔离测试',
          ),
          chapters: [
            Chapter(
              itemId: 'c',
              title: '正文',
              content: List.generate(
                200,
                (i) => '正文第$i段。全屏与窗口切换必须保持当前原文字符锚点，而不是返回章节开头。',
              ).join('\n\n'),
            ),
          ],
          bookDocuments: () async => root,
          initialSettings: const ReaderSettingsRecord(
            ReaderSettings(
              pageMode: false,
              pureMode: true,
              commentBubbles: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
    }
    await ReaderSystemService.flushParticipants();
    final after = await ReaderPositionService().load('local_native_window');
    expect(after!.paragraphIndex, greaterThan(0));
    try {
      await fullScreen(tester, true);
      await ReaderSystemService.flushParticipants();
      final enlarged = await ReaderPositionService().load(
        'local_native_window',
      );
      expect(enlarged!.paragraphIndex, after.paragraphIndex);
      expect(enlarged.characterOffset, after.characterOffset);
      final state = await ReaderPlatform.invoke<Map>('getTestWindowState');
      debugPrint(
        'WINDOWS_NATIVE_DISPLAY backingScale=${state!['backingScaleFactor']}',
      );
    } finally {
      await fullScreen(tester, false);
    }
    await ReaderSystemService.flushParticipants();
    final returned = await ReaderPositionService().load('local_native_window');
    expect(returned!.paragraphIndex, after.paragraphIndex);
    expect(returned.characterOffset, after.characterOffset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, skip: !nativeFullScreen);

  nativeTest('manual native save panel round-trip', (tester) async {
    final source = await File(
      '${root.path}/source.txt',
    ).writeAsString('Windows 真实保存验证');
    debugPrint(
      'FANQIE_WINDOWS_SAVE_PANEL_READY: save to a new isolated test path',
    );
    final result = await FileExportService().save(
      source,
      name: 'fanqie-windows-export-test.txt',
      mimeType: 'text/plain',
    );
    expect(result.status, FileExportStatus.saved);
    final saved = File(result.path!);
    expect(await saved.readAsString(), 'Windows 真实保存验证');
    // Keep the chosen output for inspection; only the isolated input
    // directory is cleaned automatically.
  }, skip: !manualSave);

  nativeTest('native external file inbox stages and releases dropped files', (
    tester,
  ) async {
    final source = await File(
      '${root.path}/dropped-book.txt',
    ).writeAsString('第一章 拖入小说\n拖入正文内容。');
    await ReaderPlatform.invoke('stageTestExternalFiles', {
      'paths': [source.path],
    });
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (await ReaderPlatform.invoke<bool>('externalImportsBusy') == true &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final service = ExternalBookImportService();
    await service.drain();
    final req = service.takeNext();
    expect(req, isNotNull);
    expect(req!.filePath, isNotNull);
    final stagedFile = File(req.filePath!);
    expect(await stagedFile.exists(), true);
    expect(await stagedFile.readAsString(), contains('拖入正文内容'));
    await service.complete(req);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await stagedFile.exists(), false);
    expect(await source.exists(), true);
  });

  nativeTest(
    'OpenAI-compatible loopback audio uses real native playback without user secrets',
    (tester) async {
      final caps = await ReaderPlatform.invoke<Map>('getReaderCapabilities');
      if (caps?['audioOutput'] != true) {
        debugPrint('WINDOWS_NATIVE_AUDIO_SKIPPED no output device');
        return;
      }
      final temporary = await (await getTemporaryDirectory()).createTemp(
        'isolated-native-tts-win-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map>[];
      server.listen((request) async {
        final json = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(request.uri.path, '/v1/audio/speech');
        expect(
          request.headers.value('authorization'),
          'Bearer synthetic-native-test',
        );
        received.add(json);
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(silentTtsWav(milliseconds: 1200));
        await request.response.close();
      });
      var secret = '';
      final tts = TtsService.forTesting(
        invoke: (method, args) async {
          if (method == 'readTtsSecret') return secret;
          if (method == 'writeTtsSecret') {
            secret = args!['value'] as String;
            return true;
          }
          return ReaderPlatform.invoke<Object?>(method, args);
        },
        temporary: () async => temporary,
        bindPlatformEvents: true,
        nativeSpeechAvailable: ReaderPlatform.capabilities.nativeSpeech,
      );
      try {
        await tts.saveSettings(
          engineType: TtsEngineType.openAi,
          openAiBaseUrl: 'http://127.0.0.1:${server.port}/v1',
          openAiApiKey: 'synthetic-native-test',
          openAiModel: 'local-compatible-model',
          openAiVoice: 'local-compatible-voice',
          speechRate: 1.25,
        );
        await tts.startChapter('隔离接口测试', '这是一段隔离接口测试。');
        expect(tts.isPlaying, true, reason: tts.errorMessage ?? tts.notice);
        expect(tts.actualEngine, TtsEngineType.openAi);
        final token = tts.currentPlaybackToken;
        await tts.pause();
        expect(
          (await ReaderPlatform.invoke<Map>('getPlaybackState'))!['playing'],
          false,
        );
        expect(received.single['model'], 'local-compatible-model');
        expect(received.single['voice'], 'local-compatible-voice');
        expect(received.single['input'], '这是一段隔离接口测试。');
        expect(received.single['response_format'], 'mp3');
        expect(received.single['speed'], 1.25);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TtsPlayerPanel(onClose: () {}, service: tts),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-tts-player')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('发音与接口设置'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-reader-dialog')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('保存配置'));
        await tester.tap(find.text('保存配置'));
        await tester.pumpAndSettle();
        expect(tts.currentPlaybackToken, token);
        await tts.resume();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (tts.isActive && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(tts.isActive, false, reason: tts.errorMessage);
        expect(
          (await ReaderPlatform.invoke<Map>('getPlaybackState'))!['playing'],
          false,
        );
        expect(received.length, 1);
      } finally {
        await tts.stop();
        tts.dispose();
        await server.close(force: true);
        await tester.pumpWidget(const SizedBox.shrink());
        await temporary.delete(recursive: true);
      }
    },
  );
}

// Byte fixtures exercise the actual C++ decoder, not a mock bridge.
const encodingFixtures = <String, List<int>>{
  'UTF-8': [
    231,
    172,
    172,
    228,
    184,
    128,
    231,
    171,
    160,
    32,
    233,
    150,
    139,
    231,
    175,
    135,
    10,
    228,
    184,
    173,
    230,
    150,
    135,
    230,
    173,
    163,
    230,
    150,
    135,
    227,
    128,
    130,
    10,
    231,
    172,
    172,
    228,
    186,
    140,
    231,
    171,
    160,
    32,
    231,
    181,
    144,
    229,
    176,
    190,
    10,
    228,
    184,
    173,
    230,
    150,
    135,
    231,
    181,
    144,
    229,
    176,
    190,
    227,
    128,
    130,
  ],
  'UTF-16LE': [
    255,
    254,
    44,
    123,
    0,
    78,
    224,
    122,
    32,
    0,
    139,
    149,
    199,
    123,
    10,
    0,
    45,
    78,
    135,
    101,
    99,
    107,
    135,
    101,
    2,
    48,
    10,
    0,
    44,
    123,
    140,
    78,
    224,
    122,
    32,
    0,
    80,
    125,
    62,
    92,
    10,
    0,
    45,
    78,
    135,
    101,
    80,
    125,
    62,
    92,
    2,
    48,
  ],
  'UTF-16BE': [
    254,
    255,
    123,
    44,
    78,
    0,
    122,
    224,
    0,
    32,
    149,
    139,
    123,
    199,
    0,
    10,
    78,
    45,
    101,
    135,
    107,
    99,
    101,
    135,
    48,
    2,
    0,
    10,
    123,
    44,
    78,
    140,
    122,
    224,
    0,
    32,
    125,
    80,
    92,
    62,
    0,
    10,
    78,
    45,
    101,
    135,
    125,
    80,
    92,
    62,
    48,
    2,
  ],
  'GB18030': [
    181,
    218,
    210,
    187,
    213,
    194,
    32,
    233,
    95,
    198,
    170,
    10,
    214,
    208,
    206,
    196,
    213,
    253,
    206,
    196,
    161,
    163,
    148,
    57,
    252,
    54,
    10,
    181,
    218,
    182,
    254,
    213,
    194,
    32,
    189,
    89,
    206,
    178,
    10,
    214,
    208,
    206,
    196,
    189,
    89,
    206,
    178,
    161,
    163,
  ],
  'GBK': [
    181,
    218,
    210,
    187,
    213,
    194,
    32,
    233,
    95,
    198,
    170,
    10,
    214,
    208,
    206,
    196,
    213,
    253,
    206,
    196,
    161,
    163,
    10,
    181,
    218,
    182,
    254,
    213,
    194,
    32,
    189,
    89,
    206,
    178,
    10,
    214,
    208,
    206,
    196,
    189,
    89,
    206,
    178,
    161,
    163,
  ],
  'Big5': [
    178,
    196,
    164,
    64,
    179,
    181,
    32,
    182,
    125,
    189,
    103,
    10,
    164,
    164,
    164,
    229,
    165,
    191,
    164,
    229,
    161,
    67,
    10,
    178,
    196,
    164,
    71,
    179,
    181,
    32,
    181,
    178,
    167,
    192,
    10,
    164,
    164,
    164,
    229,
    181,
    178,
    167,
    192,
    161,
    67,
  ],
};
