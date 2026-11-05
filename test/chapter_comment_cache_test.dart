import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chapter_comment_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chapter-comment-cache-');
  });
  tearDown(() async => directory.delete(recursive: true));

  ApiService service(ChapterCommentGateway gateway) {
    final api = ApiService(
      mobileGateway: gateway,
      commentDocuments: () async => directory,
    );
    addTearDown(api.dispose);
    return api;
  }

  Future<void> legacyCache(List<String> ids) async {
    final file = File(
      '${directory.path}/offline_books/book/comments/chapter_chapter_comments.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(
        chapterCommentPage(
          ids,
          hasMore: true,
          cursor: '${ids.length}',
        ).toJson(),
      ),
    );
  }

  Future<void> waitForCachedSize(int size) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final files = await directory
          .list(recursive: true)
          .where((file) => file is File && file.path.endsWith('.json'))
          .toList();
      for (final file in files.cast<File>()) {
        final json = jsonDecode(await file.readAsString()) as Map;
        if ((json['comments'] as List?)?.length == size) return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Missing cached page with $size comments');
  }

  test('a count=1 probe cannot replace the full first-page cache', () async {
    var offline = false;
    final gateway = ChapterCommentGateway((offset, count) async {
      if (offline) return null;
      return chapterCommentPage(
        List.generate(count == 1 ? 1 : 15, (i) => '$i'),
        cursor: count == 1 ? '1' : '15',
        hasMore: count == 1,
      );
    });
    final api = service(gateway);
    await api.getChapterComments('book', 'chapter', preferCache: false);
    await waitForCachedSize(15);
    await api.getChapterComments(
      'book',
      'chapter',
      count: 1,
      preferCache: false,
    );
    await waitForCachedSize(1);
    offline = true;
    final cached = await api.getChapterComments(
      'book',
      'chapter',
      preferCache: false,
    );
    expect(cached?.comments.length, 15);
    expect(cached?.total, 15);
  });

  test(
    'an undersized legacy cache must not win over the requested full page',
    () async {
      await legacyCache(['0']);
      final api = service(
        ChapterCommentGateway(
          (offset, count) async =>
              chapterCommentPage(List.generate(15, (i) => '$i'), cursor: '15'),
        ),
      );
      final page = await api.getChapterComments('book', 'chapter');
      expect(page?.comments.length, 15);
    },
  );

  test(
    'offline fallback still exposes legacy comments and their next offset',
    () async {
      await legacyCache(['0', '1']);
      final api = service(ChapterCommentGateway((_, _) async => null));
      final page = await api.getChapterComments(
        'book',
        'chapter',
        preferCache: false,
      );
      expect(page?.comments.length, 2);
      expect(page?.total, 15);
      expect(page?.hasMore, true);
      expect(page?.cursor, '2');
    },
  );

  test(
    'out-of-order preview and full-page responses retain both caches',
    () async {
      final preview = Completer<CommentPageData?>();
      var offline = false;
      final api = service(
        ChapterCommentGateway((_, count) {
          if (offline) return Future.value(null);
          return count == 1
              ? preview.future
              : Future.value(
                  chapterCommentPage(List.generate(15, (i) => '$i')),
                );
        }),
      );
      final pending = api.getChapterComments(
        'book',
        'chapter',
        count: 1,
        preferCache: false,
      );
      await api.getChapterComments('book', 'chapter', preferCache: false);
      preview.complete(chapterCommentPage(['0'], cursor: '1', hasMore: true));
      await pending;
      offline = true;
      expect(
        (await api.getChapterComments(
          'book',
          'chapter',
          preferCache: false,
        ))?.comments.length,
        15,
      );
      expect(
        (await api.getChapterComments(
          'book',
          'chapter',
          count: 1,
          preferCache: false,
        ))?.comments.length,
        1,
      );
    },
  );

  test(
    'fresh complete page replaces a legacy preview without deleting it',
    () async {
      await legacyCache(['0']);
      var offline = false;
      final gateway = ChapterCommentGateway(
        (_, _) async =>
            offline ? null : chapterCommentPage(List.generate(15, (i) => '$i')),
      );
      final api = service(gateway);
      expect(
        (await api.getChapterComments('book', 'chapter'))?.comments.length,
        15,
      );
      offline = true;
      expect(
        (await api.getChapterComments(
          'book',
          'chapter',
          preferCache: false,
        ))?.comments.length,
        15,
      );
      expect(
        await File(
          '${directory.path}/offline_books/book/comments/chapter_chapter_comments.json',
        ).exists(),
        true,
      );
    },
  );

  test('offline count queries can use a cached full page', () async {
    var offline = false;
    final api = service(
      ChapterCommentGateway(
        (_, _) async =>
            offline ? null : chapterCommentPage(List.generate(15, (i) => '$i')),
      ),
    );
    await api.getChapterComments('book', 'chapter', preferCache: false);
    offline = true;
    expect(
      (await api.getChapterComments(
        'book',
        'chapter',
        count: 1,
        preferCache: false,
      ))?.total,
      15,
    );
  });

  test('a preview is only a fallback, never a full-page cache hit', () async {
    var offline = false;
    final gateway = ChapterCommentGateway((_, count) async {
      if (offline) return null;
      return chapterCommentPage(
        List.generate(count == 1 ? 1 : 15, (i) => '$i'),
        cursor: count == 1 ? '1' : '15',
        hasMore: count == 1,
      );
    });
    final api = service(gateway);
    await api.getChapterComments(
      'book',
      'chapter',
      count: 1,
      preferCache: false,
    );
    offline = true;
    final partial = await api.getChapterComments('book', 'chapter');
    expect(partial?.comments.length, 1);
    expect(partial?.cursor, '1');
    offline = false;
    final fresh = await api.getChapterComments('book', 'chapter');
    expect(fresh?.comments.length, 15);
    expect(gateway.requests.map((request) => request.count), [1, 20, 20]);
  });

  test(
    'a failed next page does not fall back to the first-page cache',
    () async {
      final api = service(
        ChapterCommentGateway(
          (offset, _) async => offset == 0
              ? chapterCommentPage(['0'], cursor: '50', hasMore: true)
              : null,
        ),
      );
      await api.getChapterComments('book', 'chapter', preferCache: false);
      expect(
        await api.getChapterComments('book', 'chapter', offset: 50),
        isNull,
      );
    },
  );

  test(
    'a corrupt size-specific page can fall back to valid legacy data',
    () async {
      await legacyCache(['0']);
      await File(
        '${directory.path}/offline_books/book/comments/chapter_chapter_comments_20.json',
      ).writeAsString('{corrupt');
      final api = service(ChapterCommentGateway((_, _) async => null));
      expect(
        (await api.getChapterComments(
          'book',
          'chapter',
          preferCache: false,
        ))?.comments.length,
        1,
      );
    },
  );

  test('a terminal v3.3.3 single-comment cache still refreshes online', () async {
    final old = File(
      '${directory.path}/offline_books/book/comments/chapter_chapter_comments_20.json',
    );
    await old.parent.create(recursive: true);
    await old.writeAsString(
      jsonEncode(chapterCommentPage(['old'], total: 1, cursor: '1').toJson()),
    );
    final gateway = ChapterCommentGateway(
      (_, _) async => chapterCommentPage(
        List.generate(6, (i) => '$i'),
        total: 6,
        cursor: '{"post_next_offset":400}',
      ),
    );
    final page = await service(gateway).getChapterComments('book', 'chapter');
    expect(page?.total, 6);
    expect(page?.comments, hasLength(6));
    expect(gateway.requests, hasLength(1));
    expect(await old.exists(), true);
  });

  test('legacy fallback cannot downgrade a complete feed cache', () async {
    var degraded = false;
    final api = service(
      ChapterCommentGateway(
        (_, _) async => degraded
            ? CommentPageData(
                comments: [chapterComment('old')],
                total: 1,
                cursor: '1',
                warning: '仅显示旧版章评',
                isLegacySource: true,
              )
            : chapterCommentPage(
                List.generate(6, (i) => '$i'),
                total: 6,
                cursor: '{"post_next_offset":400}',
              ),
      ),
    );
    await api.getChapterComments('book', 'chapter', preferCache: false);
    degraded = true;
    final cached = await api.getChapterComments(
      'book',
      'chapter',
      preferCache: false,
    );
    expect(cached?.total, 6);
    expect(cached?.comments, hasLength(6));
    expect(cached?.isLegacySource, false);
    expect(cached?.warning, contains('离线缓存'));
    final disk = File(
      '${directory.path}/offline_books/book/comments/chapter_chapter_discussion_v2_20.json',
    );
    expect((jsonDecode(await disk.readAsString()) as Map)['total'], 6);
  });

  test(
    'opaque continuations neither read nor replace the first-page cache',
    () async {
      var calls = 0;
      final gateway = ChapterCommentGateway(
        (_, _) async => ++calls == 1
            ? chapterCommentPage(['first'], total: 6)
            : chapterCommentPage(['second'], total: 6, cursor: 'end'),
      );
      final api = service(gateway);
      await api.getChapterComments('book', 'chapter', preferCache: false);
      const cursor = '{"post_next_offset":200}';
      await api.getChapterComments('book', 'chapter', cursor: cursor);
      expect(gateway.requests.last.cursor, cursor);
      final disk = File(
        '${directory.path}/offline_books/book/comments/chapter_chapter_discussion_v2_20.json',
      );
      expect((jsonDecode(await disk.readAsString()) as Map)['cursor'], '');
      expect(
        (jsonDecode(await disk.readAsString()) as Map)['comments'][0]['id'],
        'first',
      );
    },
  );

  test(
    'failed opaque continuation cannot fall back to cached first page',
    () async {
      var offline = false;
      final api = service(
        ChapterCommentGateway(
          (_, _) async => offline ? null : chapterCommentPage(['first']),
        ),
      );
      await api.getChapterComments('book', 'chapter', preferCache: false);
      offline = true;
      expect(
        await api.getChapterComments(
          'book',
          'chapter',
          cursor: '{"post_next_offset":200}',
        ),
        isNull,
      );
    },
  );

  test(
    'legacy-only online fallback remains available offline with warning',
    () async {
      var offline = false;
      final api = service(
        ChapterCommentGateway(
          (_, _) async => offline
              ? null
              : CommentPageData(
                  comments: [chapterComment('old')],
                  total: 1,
                  isLegacySource: true,
                ),
        ),
      );
      await api.getChapterComments('book', 'chapter', preferCache: false);
      offline = true;
      final page = await api.getChapterComments(
        'book',
        'chapter',
        preferCache: false,
      );
      expect(page?.comments, hasLength(1));
      expect(page?.isLegacySource, true);
      expect(page?.warning, contains('旧版离线章评'));
    },
  );
}
