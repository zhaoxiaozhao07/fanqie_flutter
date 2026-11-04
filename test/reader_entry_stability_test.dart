import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/book_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'resume lays out the saved paragraph before exposing scroll content',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const native = MethodChannel('com.fanqie.fanqie_flutter/download');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (_) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(native, null),
      );
      final navigator = GlobalKey<NavigatorState>();
      await ReaderPositionService().save(
        'local_entry',
        const ReadingPosition(chapterId: 'c', paragraphIndex: 40),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [readerRouteObserver],
          home: const Scaffold(),
        ),
      );
      navigator.currentState!.push(
        BookPageRoute(
          builder: (_) => ReaderScreen(
            book: Book(bookId: 'local_entry', bookName: '恢复阅读', author: '测试'),
            chapters: [
              Chapter(
                itemId: 'c',
                title: '正文章',
                content: List.generate(
                  100,
                  (i) => '正文第${i.toString().padLeft(3, '0')}段，保存的位置不能先闪回开头。',
                ).join('\n\n'),
              ),
            ],
            initialSettings: const ReaderSettingsRecord(
              ReaderSettings(
                pageMode: false,
                commentBubbles: false,
                pureMode: true,
              ),
            ),
          ),
        ),
      );
      var sawMask = false;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find
            .byKey(const ValueKey('reader-initial-position'))
            .evaluate()
            .isNotEmpty) {
          sawMask = true;
          final opacities = tester.widgetList<Opacity>(
            find.descendant(
              of: find.byType(ReaderScreen),
              matching: find.byType(Opacity),
            ),
          );
          expect(opacities.any((o) => o.opacity == 0), true);
          expect(
            find.byType(RawImage),
            findsNothing,
          ); // No old-page screenshot.
        }
      }
      await tester.pumpAndSettle();
      expect(sawMask, true);
      expect(
        find.byKey(const ValueKey('reader-initial-position')),
        findsNothing,
      );
      final target = find.textContaining('正文第040段', findRichText: true);
      expect(target, findsWidgets);
      expect(tester.getTopLeft(target.first).dy, inInclusiveRange(0, 150));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
