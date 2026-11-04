import 'dart:io';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_illustration.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test/epub_image_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final pageMode in [false, true]) {
    for (final pureImage in [false, true]) {
      final name =
          '${pureImage ? 'image_only' : 'mixed'}_${pageMode ? 'page' : 'scroll'}';
      testWidgets('Android imports and renders EPUB $name', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final root = await Directory.systemTemp.createTemp('epub-platform-');
        try {
          final source = await imageEpub(root, [
            if (pureImage)
              '<img src="../Images/图%201.png" alt="纯图片章节"/>'
            else
              '<p>插图前文<img src="../Images/图%201.png" alt="位图插图"/>插图后文</p>'
                  '<svg viewBox="0 0 64 48"><rect width="64" height="48" fill="#e35151"/>'
                  '<circle cx="32" cy="24" r="15" fill="#fff"/></svg><p>矢量图后文</p>',
          ]);
          final imported = await LocalBookService.forTesting(
            documents: () async => root,
          ).importLocalFile(source);
          expect(
            imported.chapters.single.illustrations.length,
            pureImage ? 1 : 2,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderScreen(
                book: imported.book,
                chapters: imported.chapters,
                resumeSavedPosition: false,
                bookDocuments: () async => root,
                initialSettings: ReaderSettingsRecord(
                  ReaderSettings(
                    pageMode: pageMode,
                    pageAnimation: 'none',
                    commentBubbles: false,
                  ),
                ),
                chapterContentLoader: (chapter) => File(
                  '${root.path}/offline_books/${imported.book.bookId}/${chapter.itemId}.txt',
                ).readAsString(),
                chapterCommentStatsLoader: (_) async => null,
              ),
            ),
          );
          for (var i = 0; i < 12; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pumpAndSettle();
          }
          expect(find.byType(ReaderIllustrationView), findsWidgets);
          expect(find.byType(Image), findsWidgets);
          expect(find.textContaining('插图缺失'), findsNothing);
          expect(
            find.byType(ReaderPageView),
            pageMode ? findsOneWidget : findsNothing,
          );
          if (!pureImage) {
            expect(find.byType(SvgPicture), findsWidgets);
            expect(
              find.textContaining('插图前文', findRichText: true),
              findsWidgets,
            );
            expect(
              find.textContaining('插图后文', findRichText: true),
              findsWidgets,
            );
          }
          // Short capture window for a local adb screenshot; never a CI gate.
          debugPrint('EPUB_CAPTURE_$name');
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await tester.tap(find.byType(Image).first);
          await tester.pumpAndSettle();
          expect(find.byType(InteractiveViewer), findsOneWidget);
          await tester.tap(find.byTooltip('关闭图片'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          await root.delete(recursive: true);
        }
      });
    }
  }
}
