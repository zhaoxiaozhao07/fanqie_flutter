import 'dart:io';

import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live chapter 1521 lists six discussions, protects tiny probes and caches',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final client = HttpClient();
      final root = await Directory.systemTemp.createTemp('discussion-live-');
      final api = ApiService(
        mobileGateway: FanqieMobileGateway(client: client),
        commentDocuments: () async => root,
      );
      try {
        const book = '7322304923511557182';
        const chapter = '7561721731426026009';
        final full = await api.getChapterComments(
          book,
          chapter,
          preferCache: false,
        );
        expect(full, isNotNull);
        expect(full!.warning, isNull);
        expect(full.isLegacySource, false);
        expect(full.total, 6);
        expect(full.comments, hasLength(6));
        expect(full.comments.where((c) => !c.isDiscussionPost), hasLength(1));
        expect(full.comments.where((c) => c.isDiscussionPost), hasLength(5));
        expect(full.hasMore, false);
        expect(full.comments.every((c) => c.text.isNotEmpty), true);
        expect(
          full.comments.every((c) => !c.text.contains('"skeleton"')),
          true,
        );

        var page = await api.getChapterComments(
          book,
          chapter,
          count: 1,
          preferCache: false,
        );
        final seen = <String>{};
        final cursors = <String>{};
        var pages = 0;
        while (page != null) {
          expect(page.warning, isNull);
          expect(page.total, 6);
          seen.addAll(page.comments.map((c) => c.identityKey));
          pages++;
          if (!page.hasMore) break;
          expect(pages, lessThan(20));
          expect(page.cursor, isNotEmpty);
          expect(cursors.add(page.cursor), true);
          page = await api.getChapterComments(
            book,
            chapter,
            cursor: page.cursor,
            count: 1,
            preferCache: false,
          );
          expect(page, isNotNull);
        }
        expect(seen, full.comments.map((c) => c.identityKey).toSet());
        // Even a terminal feed cursor must continue that source, never return
        // the cached first page or restart at legacy offset zero.
        final terminal = await api.getChapterComments(
          book,
          chapter,
          cursor: full.cursor,
          preferCache: false,
        );
        expect(terminal?.comments, isEmpty);
        expect(terminal?.hasMore, false);

        // Verify genuine nonterminal pagination on the same book's first
        // chapter, rather than claiming a six-item terminal page is multi-page.
        final directory = await api.getBookDirectory(book);
        expect(directory, isNotEmpty);
        final first = await api.getChapterComments(
          book,
          directory.first.itemId,
          preferCache: false,
        );
        expect(first, isNotNull);
        expect(first!.warning, isNull);
        expect(first.hasMore, true);
        final second = await api.getChapterComments(
          book,
          directory.first.itemId,
          cursor: first.cursor,
          preferCache: false,
        );
        expect(second, isNotNull);
        expect(second!.warning, isNull);
        expect(second.cursor, isNot(first.cursor));
        expect(second.comments, isNotEmpty);
        expect(second.total, first.total);
        expect(second.hasMore, false);
        expect({
          ...first.comments.map((c) => c.identityKey),
          ...second.comments.map((c) => c.identityKey),
        }, hasLength(first.total));
        // A count preview or continuation must not replace the full-page cache.
        client.close(force: true);
        final offline = await api.getChapterComments(
          book,
          chapter,
          preferCache: false,
        );
        expect(offline?.comments, hasLength(6));
        expect(offline?.total, 6);
        expect(offline?.warning, contains('离线缓存'));
        // Only counts are logged, not readers' profiles or content.
        // ignore: avoid_print
        print(
          'LIVE_1521 total=6 legacy=1 posts=5 probePages=$pages offline=6; '
          'MULTIPAGE total=${first.total} first=${first.comments.length} '
          'second=${second.comments.length}',
        );
      } finally {
        api.dispose();
        client.close(force: true);
        HttpOverrides.global = previous;
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('FANQIE_LIVE_API'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
