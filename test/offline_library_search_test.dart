import 'dart:convert';
import 'dart:io';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/book_directory_cache.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/offline_library_service.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderCacheService cache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('offline-library-search-');
    cache = ReaderCacheService(documents: () async => root);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      BookmarkService.noteBooksKey,
      jsonEncode({
        for (final id in ['a', 'b'])
          id: Book(bookId: id, bookName: '书籍$id', author: '作者').toJson(),
      }),
    );
    for (final id in ['a', 'b']) {
      await BookDirectoryCache(cache).save(id, [
        Chapter(itemId: 'c1', title: '第一章'),
        Chapter(itemId: 'c2', title: '第二章'),
        Chapter(itemId: 'notCached', title: '未缓存章'),
      ], complete: true);
      await cache.write(id, 'c1', '第一章\n前文关键词后文。\n下一段关键词。');
      await cache.write(id, 'c2', '第二章\n另一个关键词。');
    }
  });
  tearDown(() => root.delete(recursive: true));
  test(
    'all cached books accumulate incremental hits with canonical source coordinates',
    () async {
      final service = OfflineLibraryService(cache: cache);
      final updates = await service.search('关键词').toList();
      final finalUpdate = updates.last;
      expect(finalUpdate.done, true);
      expect(finalUpdate.hits.length, 6);
      expect(finalUpdate.searchedBooks, 2);
      expect(finalUpdate.searchedChapters, 4);
      expect(finalUpdate.hits.first.source.book.bookName, '书籍a');
      expect(finalUpdate.hits.first.hit.position.characterOffset, 2);
      expect(finalUpdate.hits.first.hit.position.paragraphIndex, 0);
      expect(finalUpdate.hits.first.hit.position.chapterId, 'c1');
      expect(finalUpdate.hits.first.hit.quote, '关键词');
      expect(
        updates.map((e) => e.hits.length).toList(),
        orderedEquals(updates.map((e) => e.hits.length).toList()..sort()),
      );
    },
  );
  test('global result cap and cancellation prevent stale deliveries', () async {
    final service = OfflineLibraryService(cache: cache, maxResults: 3);
    final updates = await service.search('关键词').toList();
    expect(updates.last.hits.length, 3);
    expect(updates.last.limited, true);
    final partial = await service.search('关键词').take(1).toList();
    service.cancel();
    expect(partial.length, 1);
    expect((await service.search('').toList()).single.done, true);
  });
  test(
    'missing/corrupt catalogs are reported, never invented or overwritten',
    () async {
      final file = File('${root.path}/offline_books/b/directory.remote.json');
      await file.writeAsString('{broken');
      final finalUpdate = (await OfflineLibraryService(
        cache: cache,
      ).search('关键词').toList()).last;
      expect(finalUpdate.hits.length, 3);
      expect(finalUpdate.warnings.single, contains('目录缺失或损坏'));
      expect(await file.readAsString(), '{broken');
    },
  );
}
