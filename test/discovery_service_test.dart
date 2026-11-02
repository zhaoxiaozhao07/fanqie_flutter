import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/discovery.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';

http.Response response(Object data, {int code = 0}) => http.Response(
  jsonEncode({'code': code, 'data': data}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('category names, IDs and groups come from the current server', () async {
    final engine = FanqieBackendEngine(
      client: MockClient((request) async {
        expect(request.url.path, '/api/author/book/category_list/v0/');
        expect(request.url.queryParameters['gender'], '0');
        expect(request.headers.containsKey('Cookie'), isFalse);
        return response([
          {'category_id': 1317, 'name': '新分类', 'label': '主题'},
          {'category_id': 8, 'name': '科幻末世', 'label': '主分类'},
          {'category_id': 8, 'name': '不能覆盖', 'label': '其他'},
          {'category_id': 838, 'name': '无后宫', 'label': '情节'},
          {'category_id': -1, 'name': '非法'},
          {'category_id': 1, 'name': ''},
          'invalid',
        ]);
      }),
    );
    addTearDown(engine.dispose);
    final catalog = await engine.getCategories(gender: 2);
    expect(catalog.isCached, false);
    expect(catalog.categories.map((c) => c.id), [1317, 8, 838]);
    expect(catalog.categories[1].name, '科幻末世');
    expect(catalog.categories[1].group, '主分类');
  });

  test('metadata cache is explicit and isolated per audience', () async {
    var online = true;
    final engine = FanqieBackendEngine(
      client: MockClient(
        (_) async => online
            ? response([
                {'category_id': 12, 'name': '历史', 'label': '主题'},
              ])
            : http.Response('unavailable', 503),
      ),
    );
    addTearDown(engine.dispose);
    await engine.getCategories(gender: 1);
    online = false;
    final cached = await engine.getCategories(gender: 1);
    expect(cached.isCached, true);
    expect(cached.categories.single.id, 12);
    await expectLater(
      engine.getCategories(gender: 2),
      throwsA(isA<FanqieApiException>()),
    );
  });

  test(
    'all five word-count values and audience mappings stay aligned',
    () async {
      var calls = 0;
      final engine = FanqieBackendEngine(
        client: MockClient((request) async {
          final p = request.url.queryParameters;
          expect(p['word_count'], '${calls % 5}');
          expect(p['gender'], calls < 5 ? '-1' : '0');
          expect(p['category_id'], '-1');
          expect(p['page_index'], '1');
          expect(p['creation_status'], '0');
          expect(p['sort'], '2');
          calls++;
          return response({
            'book_list': [],
            'has_more': true,
            'total_count': 0,
          });
        }),
      );
      addTearDown(engine.dispose);
      for (final gender in [0, 2]) {
        for (var words = 0; words < 5; words++) {
          final page = await engine.discoverBooks(
            gender: gender,
            wordCount: words,
            creationStatus: 0,
            sort: 2,
            page: 2,
          );
          expect(page.books, isEmpty);
          expect(page.hasMore, false);
        }
      }
      expect(calls, 10);
      await expectLater(
        engine.discoverBooks(wordCount: 5),
        throwsArgumentError,
      );
      expect(calls, 10);
      expect(LibraryFilters.wordCounts[0], '30万以下');
      expect(LibraryFilters.wordCounts[4], '200万以上');
    },
  );

  test('successful empty page never falls back to keyword search', () async {
    final paths = <String>[];
    final engine = FanqieBackendEngine(
      client: MockClient((request) async {
        paths.add(request.url.path);
        return response({'book_list': [], 'has_more': false});
      }),
    );
    addTearDown(engine.dispose);
    final page = await engine.discoverBooks(categoryId: 517);
    expect(page.books, isEmpty);
    expect(paths, ['/api/author/library/book_list/v0/']);
  });

  test(
    'HTTP success with business failure is an error, not an empty result',
    () async {
      var calls = 0;
      final engine = FanqieBackendEngine(
        client: MockClient((_) async {
          calls++;
          return response({}, code: -1);
        }),
      );
      addTearDown(engine.dispose);
      await expectLater(
        engine.discoverBooks(),
        throwsA(isA<FanqieApiException>()),
      );
      expect(calls, 1);
      await expectLater(
        engine.searchBooks('测试'),
        throwsA(isA<FanqieApiException>()),
      );
    },
  );

  test(
    'server pagination and real metadata are preserved; no invented score',
    () async {
      final engine = FanqieBackendEngine(
        client: MockClient(
          (_) async => response({
            'book_list': [
              {
                'book_id': '1',
                'book_name': '第一本',
                'word_count': '130.0万字',
                'creation_status': 1,
              },
              {'book_id': '1', 'book_name': '重复'},
              {'book_name': '无 ID'},
            ],
            'has_more': false,
            'total_count': 1,
          }),
        ),
      );
      addTearDown(engine.dispose);
      final page = await engine.discoverBooks();
      expect(page.books.single.wordNumber, 1300000);
      expect(page.books.single.score, isNull);
      expect(page.books.single.category, isNull);
      expect(page.hasMore, false);
      expect(page.total, 1);
    },
  );

  test('disposing an engine cannot close a different screen client', () async {
    final first = FanqieBackendEngine(
      client: MockClient((_) async => response({})),
    );
    final second = FanqieBackendEngine(
      client: MockClient(
        (_) async => response({'book_list': [], 'has_more': false}),
      ),
    );
    first.dispose();
    addTearDown(second.dispose);
    expect((await second.discoverBooks()).books, isEmpty);
  });

  test(
    'failed mobile content never returns or downloads a web preview',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'fanqie-preview-regression-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final cache = ReaderCacheService(documents: () async => dir);
      var requests = 0;
      final engine = FanqieBackendEngine(
        cache: cache,
        chapterLoader: (_) async => null,
        client: MockClient((_) async {
          requests++;
          return http.Response('web preview', 200);
        }),
      );
      addTearDown(engine.dispose);
      final id = 'preview_${DateTime.now().microsecondsSinceEpoch}';
      expect(await engine.getChapterContent(id, bookId: 'regression'), isNull);
      expect(requests, 0);
      expect(await cache.read('regression', id), isNull);
      await expectLater(
        engine.downloadChapters(
          bookId: 'regression',
          chapters: [Chapter(itemId: id, title: '预览不能下载', order: 1)],
        ),
        throwsStateError,
      );
      expect(
        await (await engine.getOfflineChapterFile('regression', id)).exists(),
        false,
      );
      expect(requests, 0);
    },
  );

  test(
    'complete mobile content is cached and local short chapters stay readable',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'fanqie-complete-regression-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final cache = ReaderCacheService(documents: () async => dir);
      var calls = 0;
      final content = '这是真实完整的章节内容。' * 20;
      final engine = FanqieBackendEngine(
        cache: cache,
        chapterLoader: (_) async {
          calls++;
          return content;
        },
      );
      addTearDown(engine.dispose);
      final id = 'complete_${DateTime.now().microsecondsSinceEpoch}';
      expect(await engine.getChapterContent(id, bookId: 'regression'), content);
      expect(await engine.getChapterContent(id, bookId: 'regression'), content);
      expect(calls, 1);
      expect(ReaderCacheService.isReadable('短章正文'), true);
    },
  );
}
