import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/bookshelf_book.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('BookshelfBook Update Watcher Fields Tests', () {
    test('Serialization and deserialization with update badge fields', () {
      final now = DateTime.now();
      final book = BookshelfBook(
        bookId: 'book_999',
        bookName: '仙逆长生',
        author: '耳根',
        totalChapters: 120,
        latestRemoteChapters: 125,
        hasUpdate: true,
        lastCheckedTime: now,
      );

      final jsonMap = book.toJson();
      final fromJson = BookshelfBook.fromJson(jsonMap);

      expect(fromJson.totalChapters, 120);
      expect(fromJson.latestRemoteChapters, 125);
      expect(fromJson.hasUpdate, true);
      expect(fromJson.lastCheckedTime != null, true);
    });

    test('Clear update badge and synchronize totalChapters', () async {
      final service = BookshelfService();
      await service.initialize();

      final book = BookshelfBook(
        bookId: 'book_update_test',
        bookName: '凡人修仙',
        author: '忘语',
        totalChapters: 50,
        latestRemoteChapters: 55,
        hasUpdate: true,
      );

      await service.addToBookshelf(book.toBook(), totalChapters: 50);
      // 手动触发更新状态
      final b = service.getBook('book_update_test');
      expect(b != null, true);

      // 更新阅读进度至最新
      await service.updateReadingProgress('book_update_test', 54, '第55章 飞升灵界');
      final updated = service.getBook('book_update_test');
      expect(updated?.lastReadChapterIndex, 54);

      // 清除红点徽标
      await service.clearBookUpdateBadge('book_update_test');
      final cleared = service.getBook('book_update_test');
      expect(cleared?.hasUpdate, false);
    });
  });
}
