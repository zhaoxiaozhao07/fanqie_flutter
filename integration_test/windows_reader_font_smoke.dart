import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real Windows font/rendering smoke; unlike widget tests, this runner does not
/// substitute Ahem for system fonts. Screenshots contain synthetic book data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ReaderPlatform.initialize();
    root = await Directory.systemTemp.createTemp('fanqie-native-font-smoke-');
    AppStorage.documentsOverride = () async => root;
  });
  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
    AppStorage.documentsOverride = null;
    await root.delete(recursive: true);
  });

  testWidgets(
    'actual Windows fonts agree between reader, measurements and settings',
    (tester) async {
      try {
        for (final font in {
          'system': 'Microsoft YaHei',
          'sans-serif': 'Microsoft YaHei',
          'kaiti': 'ReaderKaiTi',
          'serif': 'ReaderSongTi',
        }.entries) {
          final capture = GlobalKey();
          final settings = ReaderSettings(
            fontFamily: font.key,
            fontSize: 22,
            pageMode: true,
            pageAnimation: 'none',
            commentBubbles: false,
            showHeader: false,
            showStatus: false,
            desktopColumns: 'single',
          );
          await ReaderSettingsRepository().save(settings);
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                home: ReaderScreen(
                  book: Book(
                    bookId: 'local_native_font_smoke',
                    bookName: '字体原生验收',
                    author: '合成测试数据',
                  ),
                  chapters: [
                    Chapter(
                      itemId: 'native-font',
                      title: '字体一致性 Chapter 0123',
                      content:
                          '春风轻拂书页，故事从这里继续。\n\n'
                          '中文與 English 0123456789「标点」，'
                          '同一正文固定常规字重，不随机加粗。',
                    ),
                  ],
                  initialSettings: ReaderSettingsRecord(settings),
                  resumeSavedPosition: false,
                  offlineOnly: true,
                  bookDocuments: () async => root,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final body = tester
              .widget<DesktopSelectableParagraph>(
                find.byType(DesktopSelectableParagraph).first,
              )
              .style;
          expect(body.fontFamily, font.value);
          expect(body.fontWeight, FontWeight.normal);
          expect(DesktopCommands.dispatch('settings'), isTrue);
          await tester.pumpAndSettle();
          final sample = find.descendant(
            of: find.byType(ReaderSettingsSheet),
            matching: find.text('春风轻拂书页，故事从这里继续。'),
          );
          final preview = tester
              .renderObject<RenderParagraph>(sample)
              .text
              .style!;
          expect(preview.fontFamily, font.value);
          expect(preview.fontWeight, FontWeight.normal);
          expect(preview.fontFamilyFallback, body.fontFamilyFallback);
          expect(preview.locale, body.locale);
          const mixed = '春风 Reading 0123456789「中文與標點」';
          Size measure(TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(text: mixed, style: style),
              textDirection: TextDirection.ltr,
            )..layout();
            final size = painter.size;
            painter.dispose();
            return size;
          }

          expect(measure(preview), measure(body));
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final output = File(
              '${Directory.current.path}/.dart_tool/codex-windows-reading/'
              'native-font-${font.key}.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(png!.buffer.asUint8List());
            debugPrint(
              'WINDOWS_NATIVE_FONT ${font.key}=${font.value} '
              'regular mixed_metrics=${measure(body)} screenshot=${output.path}',
            );
          } finally {
            image.dispose();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        FocusManager.instance.applyFocusChangesIfNeeded();
        await tester.pump();
      }
    },
    skip: !ReaderPlatform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
