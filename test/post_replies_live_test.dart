import 'dart:io';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

// This endpoint reports code=100 with a 3–5s ban window for rapid paging.
// Respect that window in explicitly enabled live verification; production
// keeps its error/retry semantics and all protocol fields remain unchanged.
Future<CommentReplyPageData?> _paced(
  Future<CommentReplyPageData?> Function() request,
) async {
  // One bounded retry also covers an occasional ban/network failure. Do not
  // drop pages or loosen any completeness/cursor/content assertions.
  for (var attempt = 0; attempt < 2; attempt++) {
    await Future<void>.delayed(const Duration(seconds: 6));
    final page = await request();
    if (page != null) return page;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live forum post replies, nested threads and pagination',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final client = HttpClient();
      final api = ApiService(
        mobileGateway: FanqieMobileGateway(client: client),
      );
      try {
        const book = '7322304923511557182';
        const post = '7445567655278428707';
        var page = await _paced(() => api.getPostReplies(post, bookId: book));
        expect(page, isNotNull);
        expect(page!.total, greaterThanOrEqualTo(24));
        expect(page.hasMore, true);
        final total = page.total;
        final ids = <String>{};
        final cursors = <String>{};
        var pages = 0;
        while (page != null) {
          expect(page.total, total);
          expect(page.replies.every((r) => r.text.isNotEmpty), true);
          expect(page.replies.every((r) => r.parentCommentId == post), true);
          ids.addAll(page.replies.map((r) => r.replyId));
          pages++;
          if (!page.hasMore) break;
          expect(pages, lessThan(20));
          expect(cursors.add(page.cursor), true);
          final nextCursor = page.cursor;
          page = await _paced(
            () => api.getPostReplies(post, bookId: book, cursor: nextCursor),
          );
          expect(page, isNotNull);
        }
        expect(ids, hasLength(total));

        const heavyPost = '7358868244197392959';
        const parentComment = '7358848420923458366';
        CommentReplyPageData? nested = await _paced(
          () => api.getPostCommentReplies(
            heavyPost,
            parentComment,
            bookId: book,
            count: 3,
          ),
        );
        expect(nested, isNotNull);
        expect(nested!.total, greaterThanOrEqualTo(2));
        final nestedTotal = nested.total;
        final nestedIds = <String>{};
        final nestedCursors = <String>{};
        var nestedPages = 0;
        while (nested != null) {
          expect(nested.replies.every((r) => r.text.isNotEmpty), true);
          expect(
            nested.replies.every((r) => r.parentCommentId == parentComment),
            true,
          );
          nestedIds.addAll(nested.replies.map((r) => r.replyId));
          nestedPages++;
          if (!nested.hasMore) break;
          expect(nestedPages, lessThan(20));
          expect(nestedCursors.add(nested.cursor), true);
          final nextCursor = nested.cursor;
          nested = await _paced(
            () => api.getPostCommentReplies(
              heavyPost,
              parentComment,
              bookId: book,
              count: 3,
              cursor: nextCursor,
            ),
          );
          expect(nested, isNotNull);
        }
        expect(nestedIds, hasLength(nestedTotal));

        // The five posts in chapter 1521 currently have no child replies.
        final empty = await _paced(
          () => api.getPostReplies('7561614993045832254', bookId: book),
        );
        expect(empty?.replies, isEmpty);
        expect(empty?.total, 0);
        expect(empty?.hasMore, false);
        // Counts only: do not log readers' profiles or actual reply content.
        // ignore: avoid_print
        print(
          'LIVE_POST replies=$total pages=$pages '
          'nested=$nestedTotal nestedPages=$nestedPages chapter1521Empty=0',
        );
      } finally {
        api.dispose();
        client.close(force: true);
        HttpOverrides.global = previous;
      }
    },
    skip: !const bool.fromEnvironment('FANQIE_LIVE_API'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
