import 'dart:async';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chapter_comment_sheet_test.dart' show openChapterComments, pumpComments;
import 'helpers/chapter_comment_fixtures.dart';

typedef _Load =
    Future<CommentReplyPageData?> Function(
      String kind,
      String id,
      String cursor,
    );

class _Api extends ChapterCommentApi {
  final _Load replies;
  final calls = <({String kind, String id, String cursor})>[];
  _Api(List<CommentItem> comments, this.replies)
    : super(
        (_) async =>
            CommentPageData(comments: comments, total: comments.length),
      );
  Future<CommentReplyPageData?> loadReply(
    String kind,
    String id,
    String cursor,
  ) {
    calls.add((kind: kind, id: id, cursor: cursor));
    return replies(kind, id, cursor);
  }

  @override
  Future<CommentReplyPageData?> getPostReplies(
    String postId, {
    String bookId = '',
    String cursor = '',
    int count = 20,
  }) => loadReply('post', postId, cursor);
  @override
  Future<CommentReplyPageData?> getPostCommentReplies(
    String postId,
    String commentId, {
    String bookId = '',
    String cursor = '',
    int count = 20,
  }) => loadReply('nested:$postId', commentId, cursor);
  @override
  Future<CommentReplyPageData?> getCommentReplies(
    String commentId, {
    String cursor = '',
    int count = 20,
  }) => loadReply('chapter', commentId, cursor);
}

const _post = CommentItem(
  id: 'post',
  discussionPostId: 'post',
  bookId: 'book',
  chapterId: 'chapter',
  userName: '书友',
  text: '帖子正文',
  replyCount: 24,
);

CommentReplyItem _reply(String id, {int replyCount = 0}) => CommentReplyItem(
  replyId: id,
  parentCommentId: 'post',
  userName: '回复书友',
  text: '回复-$id',
  replyCount: replyCount,
);

CommentReplyPageData _page(
  List<CommentReplyItem> replies, {
  String cursor = '',
  bool hasMore = false,
}) => CommentReplyPageData(
  replies: replies,
  cursor: cursor,
  hasMore: hasMore,
  total: 24,
);

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await pumpComments(tester, frames: 2);
  await tester.tap(finder);
  await pumpComments(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'post replies expand via post API and load opaque next page without duplicates',
    (tester) async {
      const cursor = '{"offset":20,"session_id":"fixture"}';
      final api = _Api(
        [_post],
        (_, _, token) async => token.isEmpty
            ? _page([_reply('a'), _reply('b')], cursor: cursor, hasMore: true)
            : _page([_reply('b'), _reply('c')]),
      );
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-post:post');
      expect(find.text('回复-a'), findsOneWidget);
      await _tap(tester, 'more-replies-post:post');
      expect(find.text('回复-b'), findsOneWidget);
      expect(find.text('回复-c'), findsOneWidget);
      expect(api.calls.map((c) => c.kind), ['post', 'post']);
      expect(api.calls.map((c) => c.cursor), ['', cursor]);
      expect(
        find.byKey(const ValueKey('more-replies-post:post')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initial failure shows retry, not an empty successful thread', (
    tester,
  ) async {
    var attempts = 0;
    final api = _Api([
      _post,
    ], (_, _, _) async => ++attempts == 1 ? null : _page([_reply('a')]));
    await openChapterComments(tester, api);
    await _tap(tester, 'toggle-replies-post:post');
    expect(find.text('暂无可见回复'), findsNothing);
    await _tap(tester, 'retry-replies-post:post');
    expect(find.text('回复-a'), findsOneWidget);
    expect(api.calls.map((c) => c.cursor), ['', '']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed continuation retains replies and retries the same cursor',
    (tester) async {
      var attempts = 0;
      final api = _Api([_post], (_, _, cursor) async {
        if (cursor.isEmpty) {
          return _page([_reply('a')], cursor: 'next', hasMore: true);
        }
        return ++attempts == 1 ? null : _page([_reply('b')]);
      });
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-post:post');
      await _tap(tester, 'more-replies-post:post');
      expect(find.text('回复-a'), findsOneWidget);
      await _tap(tester, 'retry-replies-post:post');
      expect(find.text('回复-b'), findsOneWidget);
      expect(api.calls.map((c) => c.cursor), ['', 'next', 'next']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapse and re-expand cannot attach an older in-flight result',
    (tester) async {
      final pending = Completer<CommentReplyPageData?>();
      var calls = 0;
      final api = _Api(
        [_post],
        (_, _, _) => ++calls == 1
            ? pending.future
            : Future.value(_page([_reply('fresh')])),
      );
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-post:post');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _tap(tester, 'toggle-replies-post:post');
      await _tap(tester, 'toggle-replies-post:post');
      pending.complete(_page([_reply('old')]));
      await pumpComments(tester);
      expect(find.text('回复-fresh'), findsOneWidget);
      expect(find.text('回复-old'), findsNothing);
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh invalidates pending reply threads', (tester) async {
    final pending = Completer<CommentReplyPageData?>();
    final api = _Api([_post], (_, _, _) => pending.future);
    await openChapterComments(tester, api);
    await _tap(tester, 'toggle-replies-post:post');
    await tester.tap(find.byTooltip('刷新本章评论'));
    await pumpComments(tester);
    pending.complete(_page([_reply('late')]));
    await pumpComments(tester);
    expect(find.text('回复-late'), findsNothing);
    expect(find.byKey(const ValueKey('replies-post:post')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'chapter comments and posts with equal IDs do not share threads',
    (tester) async {
      const chapter = CommentItem(
        id: 'post',
        bookId: 'book',
        chapterId: 'chapter',
        userName: '章评书友',
        text: '普通章评',
        replyCount: 1,
      );
      final api = _Api([
        chapter,
        _post,
      ], (kind, _, _) async => _page([_reply(kind)]));
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-comment:post');
      await _tap(tester, 'toggle-replies-post:post');
      expect(api.calls.map((c) => c.kind), ['chapter', 'post']);
      expect(find.text('回复-chapter'), findsOneWidget);
      expect(find.text('回复-post'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'post comment nested replies retain parent post and comment IDs',
    (tester) async {
      final api = _Api(
        [_post],
        (kind, _, _) async => kind == 'post'
            ? _page([_reply('root', replyCount: 2)])
            : _page([_reply('child')]),
      );
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-post:post');
      await _tap(tester, 'toggle-replies-post-comment:post:root');
      expect(find.text('回复-child'), findsOneWidget);
      expect(api.calls.last.kind, 'nested:post');
      expect(api.calls.last.id, 'root');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stalled reply cursors retain data and provide explicit retry', (
    tester,
  ) async {
    final api = _Api(
      [_post],
      (_, _, cursor) async =>
          _page([_reply('a')], cursor: 'next', hasMore: true),
    );
    await openChapterComments(tester, api);
    await _tap(tester, 'toggle-replies-post:post');
    await _tap(tester, 'more-replies-post:post');
    expect(find.text('回复-a'), findsOneWidget);
    expect(find.text('回复分页未推进，请重试'), findsOneWidget);
    expect(api.calls, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a sheet ignores late reply results', (tester) async {
    final pending = Completer<CommentReplyPageData?>();
    final api = _Api([_post], (_, _, _) => pending.future);
    await openChapterComments(tester, api);
    await _tap(tester, 'toggle-replies-post:post');
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_page([_reply('late')]));
    await pumpComments(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'nested threads with equal comment IDs are isolated by parent post',
    (tester) async {
      const other = CommentItem(
        id: 'other',
        discussionPostId: 'other',
        bookId: 'book',
        chapterId: 'chapter',
        userName: '书友',
        text: '另一条帖子',
        replyCount: 1,
      );
      final api = _Api(
        [_post, other],
        (kind, _, _) async => kind == 'post'
            ? _page([_reply('same-root', replyCount: 1)])
            : _page([_reply(kind)]),
      );
      await openChapterComments(tester, api);
      await _tap(tester, 'toggle-replies-post:post');
      await _tap(tester, 'toggle-replies-post:other');
      await _tap(tester, 'toggle-replies-post-comment:post:same-root');
      await _tap(tester, 'toggle-replies-post-comment:other:same-root');
      expect(api.calls.map((c) => c.kind), [
        'post',
        'post',
        'nested:post',
        'nested:other',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('320px doubled text fits reply author, time, likes and retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api(
      [_post],
      (_, _, cursor) async => cursor.isEmpty
          ? _page(
              [
                const CommentReplyItem(
                  replyId: 'large',
                  parentCommentId: 'post',
                  userName: '很长的书友名字很长的书友名字',
                  text: '双倍字号回复内容',
                  isAuthor: true,
                  createTime: 1700000000,
                  diggCount: 123456789012345,
                  replyToUserName: '另一位书友',
                ),
              ],
              cursor: 'next',
              hasMore: true,
            )
          : null,
    );
    await openChapterComments(tester, api);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    await tester.pumpWidget(
      MaterialApp(
        home: app.home,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
      ),
    );
    await pumpComments(tester);
    await _tap(tester, 'toggle-replies-post:post');
    expect(find.text('回复 @另一位书友'), findsOneWidget);
    await _tap(tester, 'more-replies-post:post');
    expect(
      find.byKey(const ValueKey('retry-replies-post:post')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
