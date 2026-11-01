import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/widgets/simulation_page_turn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Book book;
  late Chapter chapter;
  late Directory bookDirectory;
  var sequence = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    book = Book(
      bookId: 'reader_page_interaction_${sequence++}',
      bookName: '翻页回归测试',
      author: '测试',
    );
    chapter = Chapter(itemId: 'reader_test_chapter', title: '第一章 阅读测试');
    final file = await FanqieBackendEngine().getOfflineChapterFile(
      book.bookId,
      chapter.itemId,
    );
    bookDirectory = file.parent;
    await file.writeAsString(
      List.generate(
        30,
        (index) =>
            '第${index + 1}段：夜幕降临，繁星点缀在浩瀚的天际。'
            '在这个属于修行者的神秘世界里，每一次风云激荡，'
            '都伴随着无数少年天才的崛起与陨落。'
            '岁月悠悠，唯有不屈的道心能够穿透无尽风霜。',
      ).join('\n\n'),
    );
  });

  tearDown(() async {
    if (await bookDirectory.exists()) {
      await bookDirectory.delete(recursive: true);
    }
  });

  Future<void> openReader(WidgetTester tester, String mode) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('reader_is_page_mode', true);
    await prefs.setString('reader_page_turn_animation', mode);
    await prefs.setBool('reader_show_comment_bubbles', false);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(book: book, chapters: [chapter]),
      ),
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      // 章节从离线文件读取，不依赖线上接口或实际网络状态。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (find.byType(SimulationPageTurn).evaluate().isNotEmpty ||
          find.byType(PageView).evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Rect pageRect(WidgetTester tester, String mode) => tester.getRect(
    mode == 'simulation'
        ? find.byType(SimulationPageTurn)
        : find.byType(PageView),
  );

  int currentPage(WidgetTester tester, String mode) => mode == 'simulation'
      ? tester
            .widget<SimulationPageTurn>(find.byType(SimulationPageTurn))
            .currentPageIndex
      : tester
            .widget<PageView>(find.byType(PageView))
            .controller!
            .page!
            .round();

  for (final mode in ['cover', 'simulation', 'slide', 'fade']) {
    testWidgets('$mode taps toggle controls once and do not restart turns', (
      tester,
    ) async {
      await openReader(tester, mode);
      final rect = pageRect(tester, mode);
      expect(currentPage(tester, mode), 0);
      expect(find.text('排版设置'), findsNothing);

      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(find.text('排版设置'), findsOneWidget);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      expect(find.text('排版设置'), findsNothing);

      final right = Offset(rect.right - 30, rect.top + 100);
      await tester.tapAt(right);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(right);
      await tester.pumpAndSettle();
      expect(currentPage(tester, mode), 1);
      expect(find.text('排版设置'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'switching all four modes preserves page and detaches controllers',
    (tester) async {
      await openReader(tester, 'cover');
      final rect = pageRect(tester, 'cover');
      await tester.tapAt(Offset(rect.right - 30, rect.top + 100));
      await tester.pumpAndSettle();
      expect(currentPage(tester, 'cover'), 1);
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();
      await tester.tap(find.text('排版设置'));
      await tester.pumpAndSettle();

      for (final entry in {
        'simulation': '仿真',
        'slide': '滑动',
        'fade': '渐变',
        'cover': '覆盖',
      }.entries) {
        await tester.tap(find.text(entry.value));
        await tester.pumpAndSettle();
        expect(currentPage(tester, entry.key), 1);
        expect(tester.takeException(), isNull);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
