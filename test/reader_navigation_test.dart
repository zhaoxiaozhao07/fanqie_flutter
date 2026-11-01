import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _native = MethodChannel('com.fanqie.fanqie_flutter/download');
var _sequence = 0;

String chapterText(int chapter, {int paragraphs = 14}) => List.generate(
  paragraphs,
  (index) => '第$index段：青山依旧，故事$chapter继续。${'春风拂过书页，少年沿着山道向前走去。' * 3}',
).join('\n\n');

Future<void> settleReader(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pumpAndSettle();
}

dynamic address(WidgetTester tester) =>
    tester.widget<ReaderPageView>(find.byType(ReaderPageView)).currentPageId;

void noLoadingCard(WidgetTester tester) {
  expect(find.text('正在加载章节...'), findsNothing);
  expect(find.text('翻页进入下一章'), findsNothing);
  expect(find.text('翻页返回上一章'), findsNothing);
  expect(tester.takeException(), isNull);
}

Future<Book> openReader(
  WidgetTester tester,
  String mode, {
  List<Chapter>? chapters,
  Future<String?> Function(Chapter)? loader,
  double scale = 1,
  Book? book,
  Key? readerKey,
  bool resume = true,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  final settings = ReaderSettingsRepository();
  final current = (await settings.load()).settings;
  await settings.save(
    current.copyWith(
      pageMode: true,
      pageAnimation: mode,
      commentBubbles: false,
    ),
  );
  final selectedBook =
      book ??
      Book(
        bookId: 'navigation_${_sequence++}',
        bookName: '阅读衔接测试',
        author: '测试',
      );
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [readerRouteObserver],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ReaderScreen(
        key: readerKey,
        book: selectedBook,
        resumeSavedPosition: resume,
        chapters:
            chapters ??
            List.generate(
              3,
              (index) => Chapter(
                itemId: 'chapter-$index',
                title: '第${index + 1}章',
                content: chapterText(index),
              ),
            ),
        chapterContentLoader: loader,
      ),
    ),
  );
  for (var attempt = 0; attempt < 30; attempt++) {
    await settleReader(tester);
    if (find.byType(ReaderPageView).evaluate().isNotEmpty) break;
  }
  expect(find.byType(ReaderPageView), findsOneWidget);
  expect(tester.takeException(), isNull);
  return selectedBook;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  testWidgets(
    'resume follows chapter ID after insertion; explicit open does not',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final book = Book(
        bookId: 'resume-reordered',
        bookName: '续读',
        author: '测试',
      );
      final chapters = [
        Chapter(itemId: 'new', title: '新插入章', content: chapterText(0)),
        Chapter(itemId: 'saved', title: '已读章', content: chapterText(1)),
      ];
      await ReaderPositionService().save(
        book.bookId,
        const ReadingPosition(chapterId: 'saved', paragraphIndex: 5),
      );
      await openReader(tester, 'none', chapters: chapters, book: book);
      expect(address(tester).chapterIndex, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
      await openReader(
        tester,
        'none',
        chapters: chapters,
        book: book,
        resume: false,
      );
      expect(address(tester).chapterIndex, 0);
      expect(address(tester).pageIndex, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
    },
  );

  for (final mode in ['cover', 'simulation', 'slide', 'fade', 'none']) {
    testWidgets(
      '$mode crosses real chapter pages in both directions without a loading card',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await openReader(tester, mode);
        final view = tester.state<ReaderPageViewState>(
          find.byType(ReaderPageView),
        );
        final pageCount = address(tester).layout.pages.length as int;
        for (var page = 1; page < pageCount; page++) {
          view.turnToNextPage();
          await settleReader(tester);
          expect(address(tester).chapterIndex, 0);
          expect(address(tester).pageIndex, page);
          noLoadingCard(tester);
        }
        view.turnToNextPage();
        await tester.pump();
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 40));
          noLoadingCard(tester);
        }
        await settleReader(tester);
        expect(address(tester).chapterIndex, 1);
        expect(address(tester).pageIndex, 0);
        view.turnToPreviousPage();
        await settleReader(tester);
        expect(address(tester).chapterIndex, 0);
        expect(address(tester).pageIndex, pageCount - 1);
        noLoadingCard(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await settleReader(tester);
      },
    );
  }

  testWidgets(
    'slow next chapter keeps current content and coalesces foreground with prefetch',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final next = Completer<String?>();
      var requests = 0;
      await openReader(
        tester,
        'simulation',
        chapters: [
          Chapter(
            itemId: 'first',
            title: '第一章',
            content: chapterText(0, paragraphs: 1),
          ),
          Chapter(itemId: 'second', title: '第二章'),
        ],
        loader: (chapter) {
          requests++;
          return next.future;
        },
      );
      final view = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      view.turnToNextPage();
      view.turnToNextPage();
      await tester.pump(const Duration(milliseconds: 400));
      expect(address(tester).chapterIndex, 0);
      expect(requests, 1);
      noLoadingCard(tester);
      next.complete(chapterText(1, paragraphs: 1));
      await settleReader(tester);
      await settleReader(tester);
      expect(address(tester).chapterIndex, 1);
      noLoadingCard(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
    },
  );

  testWidgets('failed next chapter retains content and allows explicit retry', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var available = false;
    var requests = 0;
    await openReader(
      tester,
      'none',
      chapters: [
        Chapter(
          itemId: 'offline-first',
          title: '第一章',
          content: chapterText(0, paragraphs: 1),
        ),
        Chapter(itemId: 'offline-next', title: '第二章'),
      ],
      loader: (_) async {
        requests++;
        return available ? chapterText(1, paragraphs: 1) : null;
      },
    );
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    view.turnToNextPage();
    await settleReader(tester);
    expect(address(tester).chapterIndex, 0);
    expect(find.textContaining('当前阅读位置已保留'), findsOneWidget);
    final previousRequests = requests;
    available = true;
    await tester.tap(find.text('重试'));
    await settleReader(tester);
    await settleReader(tester);
    expect(requests, previousRequests + 1);
    expect(address(tester).chapterIndex, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settleReader(tester);
  });

  testWidgets(
    'large system text scales render without overflow and resume the same original anchor',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chapters = [
        Chapter(
          itemId: 'anchor',
          title: '第一章',
          content: chapterText(0, paragraphs: 35),
        ),
      ];
      final book = await openReader(tester, 'slide', chapters: chapters);
      final view = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      for (var index = 0; index < 3; index++) {
        view.turnToNextPage();
        await settleReader(tester);
      }
      final before = address(tester);
      final saved = before.page.position('anchor') as ReadingPosition;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
      expect(
        (await ReaderPositionService().load(book.bookId))?.toJson(),
        saved.toJson(),
      );

      await openReader(
        tester,
        'slide',
        chapters: chapters,
        book: book,
        scale: 1.4,
        readerKey: const ValueKey('reopen'),
      );
      final after = address(tester);
      expect(after.layout.pageFor(saved), after.pageIndex);
      noLoadingCard(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await settleReader(tester);
    },
  );
}
