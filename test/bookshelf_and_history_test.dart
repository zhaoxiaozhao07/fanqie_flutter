import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/reading_history_service.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('BookshelfService Tests', () {
    test('Add, toggle, update reading progress, and sort by latest read', () async {
      final service = BookshelfService();
      await service.initialize();

      final book1 = Book(bookId: 'b1', bookName: 'Book One', author: 'Author 1');
      final book2 = Book(bookId: 'b2', bookName: 'Book Two', author: 'Author 2');

      // 1. Add book 1
      await service.addToBookshelf(book1);
      expect(service.isInBookshelf('b1'), isTrue);
      expect(service.isInBookshelf('b2'), isFalse);

      // 2. Toggle book 2 (adds)
      final added = await service.toggleBookshelf(book2);
      expect(added, isTrue);
      expect(service.isInBookshelf('b2'), isTrue);

      // 3. Update reading progress for book 1 -> makes book 1 latest read
      await service.updateReadingProgress('b1', 5, '第6章 觉醒');
      final books = service.books;
      expect(books.first.bookId, equals('b1'));
      expect(books.first.lastReadChapterTitle, equals('第6章 觉醒'));

      // 4. Batch remove
      await service.removeMultiple(['b1', 'b2']);
      expect(service.isInBookshelf('b1'), isFalse);
      expect(service.isInBookshelf('b2'), isFalse);
    });
  });

  group('ReadingHistoryService Tests', () {
    test('Record reading and sort descending', () async {
      final service = ReadingHistoryService();
      await service.initialize();

      final book1 = Book(bookId: 'h1', bookName: 'History One', author: 'Author A');
      final book2 = Book(bookId: 'h2', bookName: 'History Two', author: 'Author B');

      await service.recordReading(book: book1, chapterIndex: 0, chapterTitle: '第一章');
      await service.recordReading(book: book2, chapterIndex: 3, chapterTitle: '第四章');

      final list = await service.getHistoryList();
      expect(list.length, equals(2));
      expect(list.first.bookId, equals('h2')); // Most recent first

      await service.deleteHistories(['h2']);
      final remaining = await service.getHistoryList();
      expect(remaining.length, equals(1));
      expect(remaining.first.bookId, equals('h1'));

      await service.clearAll();
      final empty = await service.getHistoryList();
      expect(empty, isEmpty);
    });
  });
}
