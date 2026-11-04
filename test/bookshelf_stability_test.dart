import 'dart:async';
import 'dart:convert';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Book book(String id, {String status = '连载中'}) =>
    Book(bookId: id, bookName: id, author: '测试', creationStatus: status);
List<Chapter> chapters(int count) => [
  for (var i = 0; i < count; i++) Chapter(itemId: 'c$i', title: '章$i'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'slow update merges into latest ID, preserving progress, covers and membership',
    () async {
      final gate = Completer<List<Chapter>>();
      final requested = Completer<void>();
      final service = BookshelfService.forTesting(
        directoryLoader: (id) async {
          if (id == 'a') {
            requested.complete();
            return gate.future;
          }
          return chapters(10);
        },
      );
      await service.addToBookshelf(book('a'), totalChapters: 10);
      await service.addToBookshelf(book('b'), totalChapters: 10);
      final check = service.checkBookshelfUpdates();
      await requested.future;
      await service.updateReadingProgress('a', 4, '阅读到第五章');
      final time = service.getBook('a')!.lastReadTime;
      await service.updateCover('a', 'https://cover/a.png');
      await service.removeFromBookshelf('b');
      await service.addToBookshelf(book('c'), totalChapters: 10);
      gate.complete(chapters(12));
      await check;
      expect(service.books.map((b) => b.bookId).toSet(), {'a', 'c'});
      expect(service.getBook('a')!.lastReadChapterIndex, 4);
      expect(service.getBook('a')!.lastReadTime, time);
      expect(service.getBook('a')!.thumbUrl, 'https://cover/a.png');
      expect(service.getBook('a')!.hasUpdate, true);
      expect(service.getBook('c')!.latestRemoteChapters, isNull);
    },
  );

  test(
    'removing an earlier array entry cannot make a delayed response overwrite another book',
    () async {
      final gate = Completer<List<Chapter>>();
      final requested = Completer<void>();
      final service = BookshelfService.forTesting(
        directoryLoader: (id) async {
          if (id == 'b') {
            requested.complete();
            return gate.future;
          }
          return chapters(10);
        },
      );
      for (final id in ['a', 'b', 'c']) {
        await service.addToBookshelf(book(id), totalChapters: 10);
      }
      final check = service.checkBookshelfUpdates();
      await requested.future;
      await service.removeFromBookshelf('a');
      gate.complete(chapters(12));
      await check;
      expect(service.books.map((b) => b.bookId).toSet(), {'b', 'c'});
      expect(service.books.length, 2);
      expect(service.getBook('b')!.latestRemoteChapters, 12);
      expect(service.getBook('c')!.latestRemoteChapters, 10);
    },
  );

  test(
    'remove/re-add invalidates an in-flight response for the previous membership',
    () async {
      final gate = Completer<List<Chapter>>();
      final entered = Completer<void>();
      final service = BookshelfService.forTesting(
        directoryLoader: (_) {
          entered.complete();
          return gate.future;
        },
      );
      await service.addToBookshelf(book('a'), totalChapters: 10);
      final request = service.checkBookshelfUpdates();
      await entered.future;
      await service.removeFromBookshelf('a');
      await service.addToBookshelf(book('a'), totalChapters: 4);
      gate.complete(chapters(20));
      await request;
      expect(service.getBook('a')!.totalChapters, 4);
      expect(service.getBook('a')!.latestRemoteChapters, isNull);
    },
  );

  test(
    'checks coalesce/throttle and unchanged badges never start a notification loop',
    () async {
      var now = DateTime(2026);
      var calls = 0, notifications = 0;
      final service = BookshelfService.forTesting(
        clock: () => now,
        directoryLoader: (_) async {
          calls++;
          return chapters(12);
        },
      );
      await service.addToBookshelf(book('a'), totalChapters: 10);
      service.changeNotifier.addListener(() {
        notifications++;
        unawaited(service.checkBookshelfUpdates());
      });
      final a = service.checkBookshelfUpdates();
      final b = service.checkBookshelfUpdates(force: true);
      expect(identical(a, b), true);
      await a;
      await service.checkBookshelfUpdates();
      expect(calls, 1);
      expect(notifications, 1);
      await service.checkBookshelfUpdates(force: true);
      expect(calls, 2);
      expect(notifications, 1); // lastCheckedTime alone is not a visual change.
      now = now.add(const Duration(minutes: 31));
      await service.checkBookshelfUpdates();
      expect(calls, 3);
      expect(notifications, 1);
    },
  );

  test(
    'unknown catalog count establishes a baseline, not hundreds of false updates',
    () async {
      final calls = <String>[];
      final service = BookshelfService.forTesting(
        directoryLoader: (id) async {
          calls.add(id);
          return chapters(100);
        },
      );
      await service.addToBookshelf(
        book('new'),
        chapterIndex: 0,
        chapterTitle: '第一章',
      );
      await service.addToBookshelf(book('finished', status: '完结'));
      await service.addToBookshelf(book('finished2', status: '已完结'));
      await service.addToBookshelf(book('local_import'));
      expect(await service.checkBookshelfUpdates(), isEmpty);
      expect(calls, ['new']);
      expect(service.getBook('new')!.totalChapters, 100);
      expect(service.getBook('new')!.hasUpdate, false);
    },
  );

  test(
    'reload supersedes checks, and equal-time books have deterministic ordering',
    () async {
      final gate = Completer<List<Chapter>>();
      final entered = Completer<void>();
      final service = BookshelfService.forTesting(
        directoryLoader: (_) {
          entered.complete();
          return gate.future;
        },
      );
      await service.addToBookshelf(book('old'), totalChapters: 10);
      final check = service.checkBookshelfUpdates();
      await entered.future;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'bookshelf_books_v1',
        jsonEncode([
          for (final id in ['z', 'a'])
            {
              'book_id': id,
              'book_name': id,
              'author': '测试',
              'added_time': '2026-01-01T00:00:00.000',
            },
        ]),
      );
      await service.reload();
      gate.complete(chapters(100));
      await check;
      expect(service.books.map((b) => b.bookId), ['a', 'z']);
    },
  );

  test(
    'legacy duplicate IDs are repaired without discarding the newer progress',
    () async {
      SharedPreferences.setMockInitialValues({
        'bookshelf_books_v1': jsonEncode([
          {
            'book_id': 'a',
            'book_name': '原书',
            'added_time': '2026-01-01',
            'last_read_time': '2026-02-01',
            'last_read_chapter_index': 5,
            'thumb_url': 'https://cover/a',
          },
          {'book_id': 'b', 'book_name': '另一本', 'added_time': '2026-01-01'},
          {
            'book_id': 'a',
            'book_name': '原书',
            'added_time': '2026-01-01',
            'last_read_time': '2026-01-10',
            'last_read_chapter_index': 1,
          },
        ]),
      });
      final service = BookshelfService.forTesting();
      await service.initialize();
      expect(service.books.map((b) => b.bookId).toSet(), {'a', 'b'});
      expect(service.books.length, 2);
      expect(service.getBook('a')!.lastReadChapterIndex, 5);
      expect(service.getBook('a')!.thumbUrl, 'https://cover/a');
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('bookshelf_books_v1')!), hasLength(2));
    },
  );
}
