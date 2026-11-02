import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final pageMode in [false, true]) {
    testWidgets(
      'Android ${pageMode ? 'paged' : 'scroll'} status stays lower-right',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await ReaderSettingsRepository().save(
          ReaderSettings(pageMode: pageMode, commentBubbles: false),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(
              book: Book(
                bookId: 'ui_status_$pageMode',
                bookName: '状态栏位置验证',
                author: '测试',
              ),
              resumeSavedPosition: false,
              chapterContentLoader: (chapter) async => chapter.content,
              chapterCommentStatsLoader: (_) async => null,
              chapters: [
                Chapter(
                  itemId: 'ui_status_${pageMode}_1',
                  title: '第一章',
                  content: List.filled(
                    30,
                    '青山依旧，春风拂过书页，少年沿着山道向前走去。',
                  ).join('\n\n'),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pumpAndSettle();
        }
        expect(
          find.byType(ReaderPageView),
          pageMode ? findsOneWidget : findsNothing,
        );
        expect(
          tester
              .widget<ReaderStatusBar>(find.byType(ReaderStatusBar))
              .clockSemantics,
          contains('电量'),
        );
        final media = MediaQuery.of(tester.element(find.byType(ReaderScreen)));
        final info = tester.getRect(
          find.byKey(const ValueKey('reader-status-info')),
        );
        final bar = tester.getRect(
          find.byKey(const ValueKey('reader-status-bar')),
        );
        expect(
          info.right,
          closeTo(media.size.width - media.padding.right - 16, 1),
        );
        expect(
          bar.bottom,
          closeTo(media.size.height - media.padding.bottom, 1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
