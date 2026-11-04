import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/discovery.dart';
import 'package:fanqie_flutter/services/book_directory_parser.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> directoryData({int count = 3}) => {
  'allItemIds': [for (var i = 1; i <= count; i++) 'c$i'],
  'volumeNameList': ['第一卷', '第二卷'],
  'chapterListWithVolume': [
    [
      for (var i = 1; i <= count; i++)
        {'itemId': 'c$i', 'title': '第$i章 标题', 'realChapterOrder': '$i'},
    ],
  ],
};

http.Response directoryResponse({int count = 3}) => http.Response(
  jsonEncode({'code': 0, 'data': directoryData(count: count)}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderCacheService cache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('catalog-test-');
    cache = ReaderCacheService(documents: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  FanqieBackendEngine engine(
    Future<http.Response> Function(http.Request) response,
  ) {
    final value = FanqieBackendEngine(
      cache: cache,
      client: MockClient(response),
      chapterLoader: (_) async => '这是已经下载的完整正文。',
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'blocked/changed detail HTML never gates the independent directory API',
    () async {
      final paths = <String>[];
      final backend = engine((r) async {
        paths.add(r.url.path);
        if (r.url.path.startsWith('/page/')) {
          return http.Response('<html>verification required</html>', 200);
        }
        expect(r.url.path, '/api/reader/directory/detail');
        expect(r.url.queryParameters, {'bookId': 'book'});
        return directoryResponse();
      });
      expect(await backend.getBookDetail('book'), isNull);
      final chapters = await backend.getBookDirectory('book');
      expect(chapters.map((c) => c.itemId), ['c1', 'c2', 'c3']);
      expect(chapters.map((c) => c.order), [1, 2, 3]);
      expect(chapters.first.volumeTitle, '第一卷');
      expect(paths.where((p) => p.startsWith('/page/')).length, 1);
    },
  );

  test(
    'empty detail metadata is not a successful empty catalog cache',
    () async {
      final backend = engine(
        (r) async => r.url.path.startsWith('/page/')
            ? http.Response(
                'window.__INITIAL_STATE__ = ${jsonEncode({
                  'page': {'bookId': 'book', 'bookName': '测试书'},
                })};',
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              )
            : directoryResponse(),
      );
      expect(await backend.getBookDetail('book'), isNotNull);
      expect(await backend.getBookDirectory('book'), hasLength(3));
    },
  );

  test(
    'allItemIds order is authoritative and omitted title records do not drop chapters',
    () {
      final data = directoryData()..['allItemIds'] = ['c3', 'c1', 'c2', 'c4'];
      final chapters = parseBookDirectory(data);
      expect(chapters.map((c) => c.itemId), ['c3', 'c1', 'c2', 'c4']);
      expect(chapters.last.title, '第4章');
      expect(chapters.map((c) => c.order), [1, 2, 3, 4]);
      expect(
        () => parseBookDirectory({
          'allItemIds': ['', '../bad'],
        }),
        throwsFormatException,
      );
      expect(() => parseBookDirectory({}), throwsFormatException);
    },
  );

  test(
    'HTTP/business/empty failures are retryable, never saved as a successful directory',
    () async {
      for (final bad in [
        http.Response('forbidden', 403),
        http.Response('<html>challenge</html>', 200),
        http.Response('{"code":1,"data":{}}', 200),
        http.Response('{"code":0,"data":{"allItemIds":[]}}', 200),
      ]) {
        var healthy = false;
        final backend = engine(
          (r) async => r.url.path.startsWith('/page/')
              ? http.Response('unavailable', 503)
              : healthy
              ? directoryResponse()
              : bad,
        );
        await expectLater(
          backend.getBookDirectory('book'),
          throwsA(isA<FanqieApiException>()),
        );
        expect(await backend.directoryCache.readRemote('book'), isNull);
        healthy = true;
        expect(await backend.getBookDirectory('book'), hasLength(3));
        await Directory(
          '${root.path}/offline_books/book',
        ).delete(recursive: true);
      }
    },
  );

  test(
    'an empty/malformed legacy directory file cannot poison old or new books',
    () async {
      final backend = engine((_) async => directoryResponse());
      for (final raw in ['[]', '{', '[{"title":"没有ID"}]']) {
        final file = File('${root.path}/offline_books/book/directory.json');
        await file.parent.create(recursive: true);
        await file.writeAsString(raw);
        expect(
          await backend.getBookDirectory('book', refresh: true),
          hasLength(3),
        );
      }
    },
  );

  test(
    'saved complete catalog + downloaded text open with a fresh engine and no network',
    () async {
      final backend = engine((_) async => directoryResponse());
      final chapters = await backend.getBookDirectory('book');
      await backend.downloadChapters(
        bookId: 'book',
        chapters: chapters.take(1).toList(),
      );
      await cache.trim(0, includePinned: true);
      var calls = 0;
      final offline = engine((_) async {
        calls++;
        throw const SocketException('offline');
      });
      final saved = await offline.getBookDirectory('book');
      expect(saved.map((c) => c.itemId), [
        'c1',
        'c2',
        'c3',
      ]); // Not truncated to download range.
      expect(saved.map((c) => c.order), [1, 2, 3]);
      expect(
        await offline.getChapterContent('c1', bookId: 'book'),
        '这是已经下载的完整正文。',
      );
      expect(calls, 0);
    },
  );

  test(
    'download without a fetched full catalog saves an honest partial recovery directory',
    () async {
      final backend = engine(
        (_) async => throw const SocketException('offline'),
      );
      await backend.downloadChapters(
        bookId: 'partial',
        chapters: [Chapter(itemId: 'c9', title: '第九章', order: 9)],
      );
      final record = (await backend.directoryCache.readRemote('partial'))!;
      expect(record.complete, false);
      expect(record.chapters.single.order, 9);
      expect((await backend.getBookDirectory('partial')).single.itemId, 'c9');
      expect(backend.directoryWarning.value, contains('本地目录'));
    },
  );

  test(
    'deleting cached book then re-adding reacquires a catalog; book IDs stay isolated',
    () async {
      var calls = 0;
      final backend = engine((_) async {
        calls++;
        return directoryResponse();
      });
      await backend.getBookDirectory('old');
      await Directory('${root.path}/offline_books/old').delete(recursive: true);
      expect(await backend.getBookDirectory('old'), hasLength(3));
      expect(await backend.getBookDirectory('new'), hasLength(3));
      expect(calls, 3);
    },
  );

  test(
    'refresh gets newly published chapters and failed refresh preserves valid old data',
    () async {
      var count = 3, online = true;
      final backend = engine(
        (_) async =>
            online ? directoryResponse(count: count) : http.Response('', 503),
      );
      await backend.getBookDirectory('book');
      count = 4;
      expect(
        await backend.getBookDirectory('book', refresh: true),
        hasLength(4),
      );
      online = false;
      expect(
        await backend.getBookDirectory('book', refresh: true),
        hasLength(4),
      );
      expect(
        (await backend.directoryCache.readRemote('book'))!.chapters,
        hasLength(4),
      );
    },
  );

  test(
    'JSON failure falls back to balanced SSR parsing; quoted braces/spacing are safe',
    () async {
      final data = directoryData()
        ..['bookId'] = 'book'
        ..['bookName'] = '标题 }; 仍在字符串内';
      final backend = engine(
        (r) async => r.url.path.startsWith('/page/')
            ? http.Response(
                'window.__INITIAL_STATE__ = ${jsonEncode({'page': data})}; more;',
                200,
                headers: {'content-type': 'text/html; charset=utf-8'},
              )
            : http.Response('unavailable', 503),
      );
      expect(await backend.getBookDirectory('book'), hasLength(3));
    },
  );

  test(
    'concurrent reading/download retries coalesce into one directory request',
    () async {
      final gate = Completer<http.Response>();
      var requests = 0;
      final backend = engine((_) {
        requests++;
        return gate.future;
      });
      final a = backend.getBookDirectory('book');
      final b = backend.getBookDirectory('book');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 1);
      gate.complete(directoryResponse());
      expect(await a, hasLength(3));
      expect(await b, hasLength(3));
    },
  );

  test(
    'imported local books never query remote services or lose illustration metadata',
    () async {
      var calls = 0;
      final backend = engine((_) async {
        calls++;
        return directoryResponse();
      });
      final file = File('${root.path}/offline_books/local_book/directory.json');
      await file.parent.create(recursive: true);
      final text = jsonEncode([
        {
          'item_id': 'local_1',
          'title': '本地章',
          'illustrations': [
            {'id': 'pic', 'error': '缺图'},
          ],
        },
      ]);
      await file.writeAsString(text);
      expect(
        (await backend.getBookDirectory(
          'local_book',
        )).single.illustrations.single.id,
        'pic',
      );
      await expectLater(
        backend.getBookDirectory('local_missing'),
        throwsA(isA<FanqieApiException>()),
      );
      expect(calls, 0);
      expect(await file.readAsString(), text);
    },
  );
}
