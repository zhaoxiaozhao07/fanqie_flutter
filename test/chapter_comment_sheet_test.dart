import 'dart:async';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/widgets/paragraph_comment_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chapter_comment_fixtures.dart';

Future<void> pumpComments(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> openChapterComments(
  WidgetTester tester,
  ChapterCommentApi api,
) async {
  addTearDown(api.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ParagraphCommentSheet(
          bookId: 'book',
          chapterId: 'chapter',
          paraText: '',
          chapterTitle: '第一章',
          isChapterComment: true,
          backgroundColor: Colors.white,
          textColor: Colors.black,
          secondaryColor: Colors.grey,
          highlightColor: Colors.amber,
          apiService: api,
        ),
      ),
    ),
  );
  await pumpComments(tester);
}

int visibleListCount(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).semanticChildCount!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mixed chapter feed paginates opaque cursors and retains all six',
    (tester) async {
      const cursor = '{"post_next_offset":200,"comment_next_offset":1}';
      final api = ChapterCommentApi((r) async {
        if (r.cursor.isEmpty) {
          return chapterCommentPage(
            ['0'],
            total: 6,
            cursor: cursor,
            hasMore: true,
          );
        }
        expect(r.cursor, cursor);
        return CommentPageData(
          total: 6,
          cursor: '{"post_next_offset":400}',
          comments: List.generate(
            5,
            (i) => CommentItem(
              id: '${i + 1}',
              discussionPostId: '${i + 1}',
              bookId: 'book',
              chapterId: 'chapter',
              userName: '书友',
              text: '帖子-${i + 1}',
            ),
          ),
        );
      });
      await openChapterComments(tester, api);
      expect(api.requests.map((r) => r.cursor), ['', cursor]);
      expect(visibleListCount(tester), 6);
      expect(find.text('已加载 6 / 6 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stalled opaque cursor retains data and offers retry', (
    tester,
  ) async {
    const cursor = '{"post_next_offset":200}';
    final api = ChapterCommentApi(
      (_) async => chapterCommentPage(['0'], cursor: cursor, hasMore: true),
    );
    await openChapterComments(tester, api);
    await pumpComments(tester, frames: 20);
    expect(api.requests, hasLength(2));
    expect(find.text('后续评论分页未推进，请重试'), findsOneWidget);
    expect(find.text('评论-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'posts keep distinct identity and do not use chapter reply endpoint',
    (tester) async {
      final api = ChapterCommentApi(
        (_) async => CommentPageData(
          total: 2,
          warning: '完整章节讨论暂不可用，当前显示离线缓存',
          comments: [
            chapterComment('same'),
            const CommentItem(
              id: 'same',
              discussionPostId: 'same',
              bookId: 'book',
              chapterId: 'chapter',
              userName: '书友',
              text: '书圈正文',
              replyCount: 2,
            ),
          ],
        ),
      );
      await openChapterComments(tester, api);
      expect(visibleListCount(tester), 2);
      expect(find.text('书圈正文'), findsOneWidget);
      expect(find.text('帖子含 2 条回复（暂不支持展开）'), findsOneWidget);
      expect(find.text('查看 2 条回复'), findsNothing);
      expect(
        find.byKey(const ValueKey('chapter-discussion-warning')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chapter list requests a fresh full page, not the count preview',
    (tester) async {
      final api = ChapterCommentApi(
        (request) async => chapterCommentPage(
          List.generate(request.preferCache ? 1 : 15, (i) => '$i'),
        ),
      );
      await openChapterComments(tester, api);
      expect(api.requests.single.count, 20);
      expect(api.requests.single.preferCache, false);
      expect(visibleListCount(tester), 15);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one or two comments auto-load the next page without scrolling', (
    tester,
  ) async {
    final api = ChapterCommentApi(
      (request) async => switch (request.offset) {
        0 => chapterCommentPage(['0'], cursor: '1', hasMore: true, total: 6),
        1 => chapterCommentPage(
          ['1', '2'],
          cursor: '3',
          hasMore: true,
          total: 6,
        ),
        3 => chapterCommentPage(['3', '4', '5'], cursor: '6', total: 6),
        _ => throw StateError('Unexpected offset ${request.offset}'),
      },
    );
    await openChapterComments(tester, api);
    expect(api.requests.map((r) => r.offset), [0, 1, 3]);
    expect(visibleListCount(tester), 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chapter pagination honors the server offset and deduplicates IDs',
    (tester) async {
      final api = ChapterCommentApi(
        (request) async => request.offset == 0
            ? chapterCommentPage(
                ['0', '0'],
                cursor: '50',
                hasMore: true,
                total: 2,
              )
            : chapterCommentPage(['0', '1'], cursor: '100', total: 2),
      );
      await openChapterComments(tester, api);
      expect(api.requests.map((request) => request.offset), [0, 50]);
      expect(visibleListCount(tester), 2);
      expect(find.text('评论-0'), findsOneWidget);
      expect(find.text('评论-1'), findsOneWidget);
      expect(find.text('已加载 2 / 2 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed next page retains comments and retries the same offset', (
    tester,
  ) async {
    var attempts = 0;
    final api = ChapterCommentApi((request) async {
      if (request.offset == 0) {
        return chapterCommentPage(['0'], cursor: '50', hasMore: true, total: 2);
      }
      attempts++;
      return attempts == 1
          ? null
          : chapterCommentPage(['1'], cursor: '100', total: 2);
    });
    await openChapterComments(tester, api);
    expect(find.text('评论-0'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-more-comments')), findsOneWidget);
    await pumpComments(tester, frames: 20);
    expect(api.requests.map((request) => request.offset), [0, 50]);
    await tester.tap(find.byKey(const ValueKey('retry-more-comments')));
    await pumpComments(tester);
    expect(api.requests.map((request) => request.offset), [0, 50, 50]);
    expect(visibleListCount(tester), 2);
    expect(find.byKey(const ValueKey('retry-more-comments')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stalled duplicate pages stop auto-loading and offer a retry', (
    tester,
  ) async {
    final api = ChapterCommentApi(
      (request) async => chapterCommentPage(['0'], cursor: '1', hasMore: true),
    );
    await openChapterComments(tester, api);
    await pumpComments(tester, frames: 30);
    expect(api.requests.map((request) => request.offset), [0, 1]);
    expect(find.text('评论-0'), findsOneWidget);
    expect(find.text('后续评论分页未推进，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an empty filtered page with a next cursor still loads comments',
    (tester) async {
      final api = ChapterCommentApi(
        (request) async => request.offset == 0
            ? chapterCommentPage([], cursor: '50', hasMore: true, total: 1)
            : chapterCommentPage(['0'], cursor: '100', total: 1),
      );
      await openChapterComments(tester, api);
      expect(api.requests.map((request) => request.offset), [0, 50]);
      expect(find.text('评论-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh ignores the previous in-flight next page', (
    tester,
  ) async {
    final oldPage = Completer<CommentPageData?>();
    var initialCalls = 0;
    final api = ChapterCommentApi((request) {
      if (request.offset != 0) return oldPage.future;
      initialCalls++;
      return Future.value(
        initialCalls == 1
            ? chapterCommentPage(['old'], cursor: '1', hasMore: true, total: 2)
            : chapterCommentPage(['fresh'], total: 1),
      );
    });
    await openChapterComments(tester, api);
    expect(api.requests.map((request) => request.offset), [0, 1]);
    await tester.tap(find.byTooltip('刷新本章评论'));
    await pumpComments(tester);
    oldPage.complete(chapterCommentPage(['late'], cursor: '2', total: 2));
    await pumpComments(tester);
    expect(find.text('评论-fresh'), findsOneWidget);
    expect(find.text('评论-late'), findsNothing);
    expect(find.text('评论-old'), findsNothing);
    expect(visibleListCount(tester), 1);
    expect(api.requests.map((request) => request.offset), [0, 1, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing an open sheet does not dispose an injected service', (
    tester,
  ) async {
    final pending = Completer<CommentPageData?>();
    final api = ChapterCommentApi((_) => pending.future);
    await openChapterComments(tester, api);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(api.disposed, false);
    pending.complete(chapterCommentPage(['late']));
    await pumpComments(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('advancing duplicate pages cannot auto-load forever', (
    tester,
  ) async {
    final api = ChapterCommentApi(
      (request) async => chapterCommentPage(
        ['0'],
        cursor: '${request.offset + 1}',
        hasMore: true,
      ),
    );
    await openChapterComments(tester, api);
    await pumpComments(tester, frames: 30);
    expect(api.requests.map((request) => request.offset), [0, 1, 2, 3]);
    expect(find.text('评论-0'), findsOneWidget);
    expect(find.text('连续分页未返回新评论，请重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px doubled text fits chapter count, refresh, and retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ChapterCommentApi(
      (request) async => request.offset == 0
          ? chapterCommentPage(['0'], cursor: '1', hasMore: true, total: 999999)
          : null,
    );
    await openChapterComments(tester, api);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: app.home,
      ),
    );
    await pumpComments(tester);
    expect(find.byTooltip('刷新本章评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
