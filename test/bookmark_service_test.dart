import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Bookmark & ReadingNote Model Tests', () {
    test('Bookmark serialization and deserialization', () {
      final now = DateTime.now();
      final bm = Bookmark(
        id: 'bm_1',
        bookId: 'book_123',
        chapterIndex: 5,
        chapterTitle: '第6章 逆天改命',
        paragraphIndex: 3,
        contentPreview: '少年负手而立，眼神淡漠如冰。',
        createdAt: now,
      );

      final jsonMap = bm.toJson();
      final fromJson = Bookmark.fromJson(jsonMap);

      expect(fromJson.id, 'bm_1');
      expect(fromJson.bookId, 'book_123');
      expect(fromJson.chapterIndex, 5);
      expect(fromJson.chapterTitle, '第6章 逆天改命');
      expect(fromJson.paragraphIndex, 3);
      expect(fromJson.contentPreview, '少年负手而立，眼神淡漠如冰。');
    });

    test('ReadingNote serialization and deserialization', () {
      final now = DateTime.now();
      final note = ReadingNote(
        id: 'note_1',
        bookId: 'book_123',
        chapterIndex: 2,
        chapterTitle: '第3章 宗门大比',
        paragraphIndex: 1,
        text: '三十年河东，三十年河西，莫欺少年穷！',
        note: '经典反抗命运名场面，气势拉满！',
        createdAt: now,
      );

      final jsonMap = note.toJson();
      final fromJson = ReadingNote.fromJson(jsonMap);

      expect(fromJson.id, 'note_1');
      expect(fromJson.text, '三十年河东，三十年河西，莫欺少年穷！');
      expect(fromJson.note, '经典反抗命运名场面，气势拉满！');
      expect(fromJson.chapterIndex, 2);
    });
  });

  group('BookmarkService Operations Tests', () {
    test('Add bookmark, query, and remove', () async {
      final service = BookmarkService();
      await service.initialize();

      // 初始应为空
      var list = await service.getBookmarks('test_book_1');
      expect(list.isEmpty, true);
      expect(await service.isChapterBookmarked('test_book_1', 0), false);

      // 添加书签
      final added = await service.addBookmark(
        bookId: 'test_book_1',
        chapterIndex: 0,
        chapterTitle: '第1章 初入江湖',
        contentPreview: '秋风萧瑟，长街寂静。',
      );

      expect(added.chapterIndex, 0);
      expect(await service.isChapterBookmarked('test_book_1', 0), true);
      list = await service.getBookmarks('test_book_1');
      expect(list.length, 1);
      expect(list.first.chapterTitle, '第1章 初入江湖');

      // 移除书签
      await service.removeBookmarkByChapter('test_book_1', 0);
      expect(await service.isChapterBookmarked('test_book_1', 0), false);
      list = await service.getBookmarks('test_book_1');
      expect(list.isEmpty, true);
    });

    test('Add reading note, query and remove', () async {
      final service = BookmarkService();
      await service.initialize();

      final note = await service.addNote(
        bookId: 'test_book_2',
        chapterIndex: 1,
        chapterTitle: '第2章 风云际会',
        paragraphIndex: 4,
        text: '天道不仁，以万物为刍狗。',
        note: '很有哲理的一句话',
      );

      expect(note.text, '天道不仁，以万物为刍狗。');
      var notes = await service.getNotes('test_book_2');
      expect(notes.length, 1);
      expect(notes.first.note, '很有哲理的一句话');

      await service.removeNote(note.id, 'test_book_2');
      notes = await service.getNotes('test_book_2');
      expect(notes.isEmpty, true);
    });
  });
}
