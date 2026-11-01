import 'dart:io';

import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_navigation_history.dart';
import 'package:fanqie_flutter/services/reader_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderCacheService cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('reader_search_');
    cache = ReaderCacheService(documents: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'searches cached text only and retains exact repeated-word offsets',
    () async {
      await cache.write('book', 'a', '第一章\n甲乙甲乙。');
      final updates = await ReaderSearchService(cache: cache)
          .search(
            bookId: 'book',
            chapters: [
              Chapter(itemId: 'a', title: '第一章'),
              Chapter(itemId: 'missing', title: '第二章'),
            ],
            query: '甲',
          )
          .toList();
      final hits = updates.expand((value) => value.hits).toList();
      expect(hits.map((hit) => hit.position.characterOffset), [0, 2]);
      expect(updates.last.searchedChapters, 1);
      expect(updates.last.totalChapters, 2);
      expect(await cache.read('book', 'missing'), isNull);
    },
  );

  test(
    'canonical memory is not normalized twice and regex punctuation is literal',
    () async {
      final updates = await ReaderSearchService(cache: cache)
          .search(
            bookId: 'book',
            chapters: [Chapter(itemId: 'a', title: '第一章 少年')],
            canonicalMemory: {'a': '\u3000\u3000第一章\n\n\u3000\u3000[a] [a]'},
            query: '[a]',
          )
          .toList();
      final hits = updates.expand((value) => value.hits).toList();
      expect(hits.length, 2);
      expect(hits.first.position.paragraphIndex, 1);
      expect(hits.last.position.characterOffset, 4);
    },
  );

  test('Unicode highlighting includes a complete emoji grapheme', () async {
    final updates = await ReaderSearchService(cache: cache)
        .search(
          bookId: 'book',
          chapters: [Chapter(itemId: 'a', title: '章节', content: '甲👩🏽‍💻乙')],
          query: '👩',
        )
        .toList();
    final hit = updates.expand((value) => value.hits).single;
    expect(hit.quote, '👩🏽‍💻');
    expect(hit.position.characterOffset, 1);
    expect(hit.snippet.substring(hit.snippetStart, hit.snippetEnd), hit.quote);
  });

  test('a search can be cancelled before its stream starts', () async {
    final service = ReaderSearchService(cache: cache);
    final stream = service.search(
      bookId: 'book',
      chapters: [Chapter(itemId: 'a', title: '章节', content: '关键词')],
      query: '关键词',
    );
    service.cancel();
    expect(await stream.toList(), isEmpty);
  });

  test(
    'new queries supersede old streams and cap result counts explicitly',
    () async {
      final service = ReaderSearchService(cache: cache, maxResults: 2);
      final chapters = [Chapter(itemId: 'a', title: '章节', content: '旧旧旧新新新')];
      final old = service.search(
        bookId: 'book',
        chapters: chapters,
        query: '旧',
      );
      final latest = service.search(
        bookId: 'book',
        chapters: chapters,
        query: '新',
      );
      expect(await old.toList(), isEmpty);
      final updates = await latest.toList();
      expect(updates.expand((value) => value.hits).length, 2);
      expect(updates.last.limited, true);
      expect(updates.last.done, true);
    },
  );

  test(
    'large chapters use isolate scanning and still report original offsets',
    () async {
      final updates = await ReaderSearchService(cache: cache)
          .search(
            bookId: 'book',
            chapters: [
              Chapter(itemId: 'a', title: '章节', content: '${'甲' * 60000}目标'),
            ],
            query: '目标',
          )
          .toList();
      expect(
        updates.expand((value) => value.hits).single.position.characterOffset,
        60000,
      );
    },
  );

  test(
    'jump history is bounded, deduplicated and removes only successful returns',
    () {
      final history = ReaderNavigationHistory(capacity: 3);
      ReadingPosition p(int n) =>
          ReadingPosition(chapterId: 'c$n', characterOffset: n);
      for (var n = 0; n < 5; n++) {
        history.record(p(n), p(n + 1));
      }
      expect(history.length, 3);
      expect(history.previous!.chapterId, 'c4');
      history.returnedTo(p(0));
      expect(history.length, 3);
      history.returnedTo(p(4));
      expect(history.previous!.chapterId, 'c3');
      history.record(p(3), p(3));
      expect(history.length, 2);
      history.clear();
      expect(history.canGoBack, false);
    },
  );
}
