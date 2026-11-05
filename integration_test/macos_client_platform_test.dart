import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/cover_cache_service.dart';
import '../test/epub_image_fixture.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const manualSave = bool.fromEnvironment('MACOS_SAVE_PANEL_TEST');
const nativeFullScreen = bool.fromEnvironment('MACOS_NATIVE_FULLSCREEN_TEST');

Future<void> fullScreen(WidgetTester tester, bool enabled) async {
  await ReaderPlatform.invoke('setTestFullScreen', {'enabled': enabled});
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  Map? lastState;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final state = await ReaderPlatform.invoke<Map>('getTestWindowState');
    lastState = state;
    if (state!['fullScreen'] == enabled &&
        state['fullScreenTransitioning'] == false) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Native full-screen transition did not complete: $lastState');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookshelfService().reload();
    await ReaderPlatform.initialize();
    AppLifecycleService.initialize();
    final support = await AppStorage.documents();
    expect(support.path, (await getApplicationSupportDirectory()).path);
    root = await support.createTemp('isolated-platform-test-');
    AppStorage.documentsOverride = () async => root;
  });

  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await ReaderPlatform.invoke('showMainWindow');
    AppStorage.documentsOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
    'actual native capabilities, streaming import and same-platform restore',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('macOS 原生验证'))),
      );
      expect(ReaderPlatform.isMacOS, true);
      expect(ReaderPlatform.capabilities.tts, false);
      expect(ReaderPlatform.capabilities.textDecoder, true);
      expect(ReaderPlatform.capabilities.fileExport, true);
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
        expect(
          await Directory(
            '${root.path}/offline_books/${result.book.bookId}',
          ).exists(),
          true,
        );
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

  testWidgets(
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
          .createTemp('isolated-restored-epub-');
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
        expect(
          await CoverCacheService.forTesting(
            documents: () async => restored,
            client: null,
          ).hasLocalCover(imported.book.bookId),
          true,
        );
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

  testWidgets(
    'real save panel cancellation has no success or source deletion',
    (tester) async {
      final source = await File(
        '${root.path}/cancel-source.txt',
      ).writeAsString('保留正文');
      final result = FileExportService().save(
        source,
        name: 'fanqie-platform-test.txt',
        mimeType: 'text/plain',
        requestId: 'cancel-panel',
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await ReaderPlatform.invoke('cancelExport', {'id': 'cancel-panel'});
      expect((await result).status, FileExportStatus.cancelled);
      expect(await source.readAsString(), '保留正文');
    },
  );

  testWidgets(
    'real window resize, hidden-window save and power assertion release',
    (tester) async {
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
        'height': 540.0,
      });
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('local_native_window');
      expect(after!.paragraphIndex, before.paragraphIndex);
      await ReaderPlatform.invoke('hideTestWindow');
      await tester.pump(const Duration(milliseconds: 300));
      final hidden = await ReaderPlatform.invoke<Map>('getTestWindowState');
      expect(hidden!['visible'], false);
      expect(hidden['displayAssertion'], false);
      expect(
        (await ReaderPositionService().load(
          'local_native_window',
        ))!.paragraphIndex,
        after.paragraphIndex,
      );
      await ReaderPlatform.invoke('showMainWindow');
      await tester.pumpAndSettle();
      expect(
        (await ReaderPlatform.invoke<Map>('getTestWindowState'))!['visible'],
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  // A real Aqua/foreground session is required. This is a mandatory manual
  // acceptance gate, not covered by the ordinary CI/window-resize result.
  testWidgets('native full-screen preserves exact reading anchors', (
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
        'MACOS_NATIVE_DISPLAY backingScale=${state!['backingScaleFactor']}',
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

  testWidgets('manual native save panel round-trip', (tester) async {
    final source = await File(
      '${root.path}/source.txt',
    ).writeAsString('macOS 真实保存验证');
    debugPrint(
      'FANQIE_MACOS_SAVE_PANEL_READY: save to a new isolated test path',
    );
    final result = await FileExportService().save(
      source,
      name: 'fanqie-native-export-test.txt',
      mimeType: 'text/plain',
    );
    expect(result.status, FileExportStatus.saved);
    final saved = File(result.path!);
    expect(await saved.readAsString(), 'macOS 真实保存验证');
    // Keep the chosen output for inspection. Only the isolated input directory
    // is automatically cleaned, never an arbitrary external destination.
  }, skip: !manualSave);
}

// Byte fixtures exercise the actual Swift decoder, not a mock bridge.
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
    185,
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
    185,
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
