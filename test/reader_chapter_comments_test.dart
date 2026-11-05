import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/paragraph_comment_sheet.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_navigation_test.dart' as fixture;

const _native = MethodChannel('com.fanqie.fanqie_flutter/download');

class _CommentApi extends ApiService {
  final Future<CommentPageData?> Function(String) load;
  final List<String> requests = [];
  final List<bool> cachePreferences = [];

  _CommentApi(this.load);

  @override
  Future<ChapterCommentStats?> getChapterCommentStats(
    String itemId, {
    String? bookId,
    bool preferCache = true,
  }) async => null;

  @override
  Future<CommentPageData?> getChapterComments(
    String bookId,
    String itemId, {
    int offset = 0,
    int count = 20,
    String cursor = '',
    bool preferCache = true,
  }) {
    requests.add(itemId);
    cachePreferences.add(preferCache);
    return load(itemId);
  }
}

Future<void> _open(
  WidgetTester tester,
  String mode,
  _CommentApi api, {
  bool pure = false,
  double scale = 1,
  double width = 400,
  String content = '青山依旧，故事继续。',
  List<Chapter>? chapters,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ReaderScreen(
        book: Book(
          bookId: 'chapter-comments-$mode',
          bookName: '章末评论测试',
          author: '测试',
        ),
        chapters:
            chapters ??
            [Chapter(itemId: 'first', title: '第一章', content: content)],
        apiService: api,
        resumeSavedPosition: false,
        initialSettings: ReaderSettingsRecord(
          ReaderSettings(
            pageMode: mode != 'scroll',
            pageAnimation: mode == 'scroll' ? 'none' : mode,
            commentBubbles: false,
            pureMode: pure,
          ),
        ),
      ),
    ),
  );
  await fixture.settleReader(tester);
  await fixture.settleReader(tester);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await fixture.settleReader(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  for (final mode in [
    'scroll',
    'cover',
    'simulation',
    'slide',
    'fade',
    'none',
  ]) {
    testWidgets('$mode shows real chapter comments independently of bubbles', (
      tester,
    ) async {
      final api = _CommentApi((_) async => const CommentPageData(total: 23));
      await _open(tester, mode, api);
      final entry = find.text('本章评论 (23条讨论)');
      expect(find.text('本章完'), findsOneWidget);
      expect(entry, findsOneWidget);
      final before = mode == 'scroll' ? null : fixture.address(tester);
      await tester.tap(entry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final sheet = tester.widget<ParagraphCommentSheet>(
        find.byType(ParagraphCommentSheet),
      );
      expect(sheet.isChapterComment, true);
      expect(sheet.paraIndex, isNull);
      expect(sheet.chapterId, 'first');
      if (before != null) expect(fixture.address(tester), before);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  for (final mode in ['scroll', 'simulation', 'none']) {
    testWidgets(
      '$mode hides zero counts and fills late counts without a jump',
      (tester) async {
        final count = Completer<CommentPageData?>();
        final api = _CommentApi((_) => count.future);
        await _open(tester, mode, api);
        expect(find.textContaining('本章评论'), findsNothing);
        final before = mode == 'scroll' ? null : fixture.address(tester);
        final body = find.textContaining('青山依旧', findRichText: true).first;
        final bounds = tester.getRect(body);
        count.complete(const CommentPageData(total: 42));
        await fixture.settleReader(tester);
        expect(find.text('本章评论 (42条讨论)'), findsOneWidget);
        expect(tester.getRect(body), bounds);
        if (before != null) {
          expect(fixture.address(tester), before);
          expect(fixture.address(tester).layout, same(before.layout));
        }
        expect(api.requests, ['first']);
        expect(api.cachePreferences, [false]);
        expect(tester.takeException(), isNull);
        await _close(tester);
      },
    );

    testWidgets('$mode leaves empty chapter comments hidden', (tester) async {
      final api = _CommentApi((_) async => const CommentPageData());
      await _open(tester, mode, api);
      expect(find.text('本章完'), findsOneWidget);
      expect(find.textContaining('本章评论'), findsNothing);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  testWidgets('leaving pure reading loads previously skipped chapter counts', (
    tester,
  ) async {
    final api = _CommentApi((_) async => const CommentPageData(total: 7));
    await _open(tester, 'none', api, pure: true);
    expect(api.requests, isEmpty);
    expect(find.text('本章完'), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
    await fixture.settleReader(tester);
    await tester.tap(find.byTooltip('更多选项'));
    await fixture.settleReader(tester);
    await tester.tap(find.text('退出纯净阅读'));
    await fixture.settleReader(tester);
    expect(api.requests, ['first']);
    expect(find.text('本章评论 (7条讨论)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  for (final mode in ['simulation', 'none']) {
    testWidgets('$mode puts chapter comments only after all body pages', (
      tester,
    ) async {
      final api = _CommentApi(
        (id) async => CommentPageData(total: id == 'first' ? 11 : 22),
      );
      await _open(
        tester,
        mode,
        api,
        chapters: [
          Chapter(
            itemId: 'first',
            title: '第一章',
            content: fixture.chapterText(0, paragraphs: 20),
          ),
          Chapter(itemId: 'second', title: '第二章', content: '第二章正文。'),
        ],
      );
      final view = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final pages = fixture.address(tester).layout.pages;
      expect(pages.length, greaterThan(2));
      for (var index = 0; index < pages.length - 1; index++) {
        expect(fixture.address(tester).page.chapterEndHeight, 0);
        expect(find.text('本章评论 (11条讨论)').hitTestable(), findsNothing);
        view.turnToNextPage();
        await fixture.settleReader(tester);
      }
      expect(fixture.address(tester).page.chapterEndHeight, greaterThan(0));
      expect(find.text('本章评论 (11条讨论)').hitTestable(), findsOneWidget);
      view.turnToNextPage();
      await fixture.settleReader(tester);
      expect(fixture.address(tester).chapterIndex, 1);
      expect(find.text('本章评论 (22条讨论)').hitTestable(), findsOneWidget);
      view.turnToPreviousPage();
      await fixture.settleReader(tester);
      expect(fixture.address(tester).chapterIndex, 0);
      expect(fixture.address(tester).pageIndex, pages.length - 1);
      expect(find.text('本章评论 (11条讨论)').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  for (final mode in ['cover', 'simulation']) {
    testWidgets('$mode defers late chapter counts until the turn finishes', (
      tester,
    ) async {
      final count = Completer<CommentPageData?>();
      final api = _CommentApi((_) => count.future);
      await _open(
        tester,
        mode,
        api,
        content: fixture.chapterText(0, paragraphs: 20),
      );
      final view = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final layout = fixture.address(tester).layout;
      for (var index = 1; index < layout.pages.length - 1; index++) {
        view.turnToNextPage();
        await fixture.settleReader(tester);
      }
      view.turnToNextPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(view.isBusy, true);
      count.complete(const CommentPageData(total: 73));
      await tester.pump();
      expect(find.text('本章评论 (73条讨论)'), findsNothing);
      await fixture.settleReader(tester);
      expect(view.isBusy, false);
      expect(fixture.address(tester).layout, same(layout));
      expect(fixture.address(tester).pageIndex, layout.pages.length - 1);
      expect(find.text('本章评论 (73条讨论)').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _close(tester);
    });
  }

  testWidgets('narrow 2x reader fits both the final body and chapter entry', (
    tester,
  ) async {
    final api = _CommentApi((_) async => const CommentPageData(total: 999999));
    await _open(
      tester,
      'none',
      api,
      scale: 2,
      width: 320,
      content: fixture.chapterText(0, paragraphs: 12),
    );
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    final layout = fixture.address(tester).layout;
    for (var index = 1; index < layout.pages.length; index++) {
      view.turnToNextPage();
      await fixture.settleReader(tester);
      expect(tester.takeException(), isNull);
    }
    final entry = find.text('本章评论 (999999条讨论)').hitTestable();
    expect(entry, findsOneWidget);
    expect(
      tester.getRect(entry).bottom,
      lessThan(tester.getRect(find.byType(ReaderPageView)).bottom),
    );
    final fragment = layout.pages.last.fragments.last;
    final body = find.textContaining(fragment.text, findRichText: true).first;
    expect(tester.getRect(body).bottom, lessThan(tester.getRect(entry).top));
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}
