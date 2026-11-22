import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/external_reader_fonts.dart';
import 'package:fanqie_flutter/services/reader_display_text.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:fanqie_flutter/widgets/reader_fonts_dialog.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

const _sample = '春风轻拂书页，故事从这里继续。';
const _title = '章节 Chapter 0123「閱讀」';
const _windowsFallback = [
  'Microsoft YaHei',
  'Microsoft YaHei UI',
  'sans-serif',
  'Roboto',
];
const _macFallback = ['sans-serif', 'Roboto'];
// SHA-256 values checked directly from the bundled files, not familyFor().
const _importedSongId =
    'external_a42b620140f493db42f741351dfbf343c0936d58588ee8004b8b2a218d997ff1';
const _importedSongFamily =
    'ReaderExternal_a42b620140f493db42f741351dfbf343c0936d58588ee8004b8b2a218d997ff1';
const _importedKaiFamily =
    'ReaderExternal_f799a538a3355877e597a0ae04050e897932c9ae7689eb9227c2953c5dd549ea';

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

TextStyle _paintedStyle(WidgetTester tester, Finder finder) =>
    tester.renderObject<RenderParagraph>(finder).text.style!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String ownedRoot;
  late String temporaryParent;
  Future<Directory> Function()? previousDocuments;
  TargetPlatform? previousPlatform;
  setUp(() async {
    previousDocuments = AppStorage.documentsOverride;
    previousPlatform = debugDefaultTargetPlatformOverride;
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ReaderPlatform.resetForTesting();
    temporaryParent = await Directory.systemTemp.resolveSymbolicLinks();
    root = await Directory(
      temporaryParent,
    ).createTemp('fanqie-font-consistency-');
    ownedRoot = await root.resolveSymbolicLinks();
    AppStorage.documentsOverride = () async => root;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, (_) async => null);
    await ReaderDisplayText.ensureLoaded();
  });
  tearDown(() async {
    try {
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      await DesktopReaderPreferences.flush();
    } finally {
      try {
        expect(
          await FileSystemEntity.type(root.path, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(await root.resolveSymbolicLinks(), ownedRoot);
        expect(path.isWithin(temporaryParent, ownedRoot), isTrue);
        expect(path.dirname(ownedRoot), temporaryParent);
        expect(
          path.basename(ownedRoot).startsWith('fanqie-font-consistency-'),
          isTrue,
        );
        await root.delete(recursive: true);
      } finally {
        AppStorage.documentsOverride = previousDocuments;
        ReaderPlatform.resetForTesting();
        debugDefaultTargetPlatformOverride = previousPlatform;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ReaderPlatform.channel, null);
      }
    }
  });

  void fontTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 850);
      addTearDown(tester.view.reset);
      try {
        await body(tester);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    group(platform == TargetPlatform.macOS ? 'Mac' : 'Windows', () {
      setUp(() => debugDefaultTargetPlatformOverride = platform);
      final fallback = platform == TargetPlatform.macOS
          ? _macFallback
          : _windowsFallback;
      final families = platform == TargetPlatform.macOS
          ? const {
              'system': 'Roboto',
              'sans-serif': 'sans-serif',
              'kaiti': 'ReaderKaiTi',
              'serif': 'ReaderSongTi',
              _importedSongId: _importedSongFamily,
            }
          : const {
              'system': 'Microsoft YaHei',
              'sans-serif': 'Microsoft YaHei',
              'kaiti': 'ReaderKaiTi',
              'serif': 'ReaderSongTi',
              _importedSongId: _importedSongFamily,
            };
      for (final pageMode in [true, false]) {
        for (final font in families.entries) {
          fontTest(
            '${pageMode ? 'paged' : 'scroll'} ${font.key} keeps preview, body and title faces consistent',
            (tester) async {
              if (font.key == _importedSongId) {
                final bytes = (await rootBundle.load(
                  'assets/fonts/ZCOOLXiaoWei-Regular.ttf',
                )).buffer.asUint8List();
                final imported = await tester.runAsync(
                  () => ExternalReaderFonts().importBytes(bytes),
                );
                expect(imported!.id, _importedSongId);
              }
              final settings = ReaderSettings(
                fontFamily: font.key,
                fontSize: 21,
                lineHeight: 2,
                letterSpacing: .75,
                displayScript: 'traditional',
                pageMode: pageMode,
                pageAnimation: 'none',
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
                desktopColumns: 'single',
              );
              await ReaderSettingsRepository().save(settings);
              await tester.pumpWidget(
                MaterialApp(
                  home: ReaderScreen(
                    book: Book(
                      bookId: 'local_font_consistency',
                      bookName: '字体一致性',
                      author: '测试',
                    ),
                    chapters: [
                      Chapter(
                        itemId: 'font',
                        title: _title,
                        content:
                            '$_sample Reading 0123。中文與 English「标点」。\n\n'
                            '另一段文字保持常规字重，不因继承样式或选择状态变粗。',
                      ),
                    ],
                    initialSettings: ReaderSettingsRecord(settings),
                    resumeSavedPosition: false,
                    offlineOnly: true,
                    bookDocuments: () async => root,
                  ),
                ),
              );
              for (var attempt = 0; attempt < 20; attempt++) {
                await _settle(tester);
                if (find
                    .byType(DesktopSelectableParagraph)
                    .evaluate()
                    .isNotEmpty) {
                  break;
                }
              }
              final paragraphs = tester.widgetList<DesktopSelectableParagraph>(
                find.byType(DesktopSelectableParagraph),
              );
              expect(paragraphs, isNotEmpty);
              for (final paragraph in paragraphs) {
                expect(paragraph.style.fontFamily, font.value);
                expect(paragraph.style.fontFamilyFallback, fallback);
                expect(paragraph.style.fontWeight, FontWeight.normal);
                expect(paragraph.style.locale, const Locale('zh', 'TW'));
              }
              final title = _paintedStyle(
                tester,
                find
                    .text(ReaderDisplayText.convert(_title, 'traditional'))
                    .first,
              );
              expect(title.fontFamily, font.value);
              expect(title.fontFamilyFallback, fallback);
              expect(title.locale, const Locale('zh', 'TW'));
              expect(title.fontWeight, FontWeight.bold);

              expect(DesktopCommands.dispatch('settings'), isTrue);
              await _settle(tester);
              final preview = _paintedStyle(
                tester,
                find.text(ReaderDisplayText.convert(_sample, 'traditional')),
              );
              expect(preview.fontFamily, font.value);
              expect(preview.fontFamilyFallback, fallback);
              expect(preview.fontWeight, FontWeight.normal);
              expect(preview.locale, const Locale('zh', 'TW'));
              expect(preview.fontSize, 21);
              expect(preview.height, 2);
              expect(preview.letterSpacing, .75);
              expect(preview.leadingDistribution, TextLeadingDistribution.even);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }

      fontTest(
        'global settings load an existing imported font before painting its preview',
        (tester) async {
          final bytes = (await rootBundle.load(
            'assets/fonts/ZCOOLXiaoWei-Regular.ttf',
          )).buffer.asUint8List();
          // Prepare a durable font library as a previous app instance would.
          // Only its native registration is bypassed; import validation, file
          // publication and metadata are real, and the current instance must load it.
          final previous = ExternalReaderFonts.forTesting(
            documents: () async => root,
            loadBytes: (_, _) async {},
          );
          final font = (await tester.runAsync(
            () => previous.importBytes(bytes),
          ))!;
          expect(font.id, _importedSongId);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ReaderSettingsSheet(
                  bookId: 'global',
                  settings: ReaderSettings(fontFamily: font.id),
                  bookOverride: false,
                  allowBookOverride: false,
                  onChanged: (_, _) async {},
                ),
              ),
            ),
          );
          expect(find.text('正在加载字体…'), findsOneWidget);
          expect(find.text(_sample), findsNothing);
          for (var attempt = 0; attempt < 50; attempt++) {
            await _settle(tester);
            if (find.text(_sample).evaluate().isNotEmpty) break;
          }
          final style = _paintedStyle(tester, find.text(_sample));
          expect(style.fontFamily, _importedSongFamily);
          expect(style.fontFamilyFallback, fallback);
          expect(style.fontWeight, FontWeight.normal);
          expect(style.locale, const Locale('zh', 'CN'));
        },
      );

      for (final theme in {
        ReaderTheme.presets[0]: const Color(0xFF222222),
        ReaderTheme.presets[3]: const Color(0xFFB8B8B8),
      }.entries) {
        fontTest('imported font dialog remains readable in ${theme.key.name}', (
          tester,
        ) async {
          final bytes = (await rootBundle.load(
            'assets/fonts/LXGWWenKaiLite-Regular.ttf',
          )).buffer.asUint8List();
          final font = (await tester.runAsync(
            () => ExternalReaderFonts().importBytes(bytes),
          ))!;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.key.materialTheme,
              home: Scaffold(body: ReaderFontsDialog(selected: font.id)),
            ),
          );
          await _settle(tester);
          await tester.tap(find.byTooltip('预览'));
          // The library deliberately remains busy while the preview dialog is open;
          // its indeterminate indicator must not be mistaken for a never-ending route.
          final sample = find.textContaining('The quick brown fox. 0123456789');
          for (var attempt = 0; attempt < 20; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 50));
            if (sample.evaluate().isNotEmpty) break;
          }
          await tester.pump(const Duration(milliseconds: 300));
          final style = _paintedStyle(tester, sample);
          expect(style.fontFamily, _importedKaiFamily);
          expect(style.fontFamilyFallback, fallback);
          expect(style.fontWeight, FontWeight.normal);
          expect(style.locale, const Locale('zh', 'CN'));
          expect(style.color, theme.value);
          await tester.tap(find.text('关闭预览'));
          await _settle(tester);
        });
      }

      fontTest(
        'missing imported font keeps its preference and readable fallback',
        (tester) async {
          final missing = 'external_${'0' * 64}';
          final settings = ReaderSettings(fontFamily: missing);
          await ReaderSettingsRepository().save(settings);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: ReaderSettingsSheet(
                  bookId: 'missing',
                  settings: settings,
                  bookOverride: false,
                  onChanged: (_, _) async =>
                      fail('A read must not rewrite settings'),
                ),
              ),
            ),
          );
          await _settle(tester);
          final style = _paintedStyle(tester, find.text(_sample));
          expect(style.fontFamily, families['system']);
          expect(style.fontWeight, FontWeight.normal);
          expect(style.fontFamilyFallback, fallback);
          expect(
            (await ReaderSettingsRepository().load()).settings.fontFamily,
            missing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    });
  }
}
