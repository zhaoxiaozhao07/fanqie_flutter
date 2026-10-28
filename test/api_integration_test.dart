import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/font_decryptor.dart';
import 'package:fanqie_flutter/services/download_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
  });

  group('FontDecryptor & Builtin Backend Engine Tests', () {
    test('FontDecryptor correctly decodes encrypted library characters', () {
      final decrypted = FontDecryptor.decryptLibText('');
      expect(decrypted, equals('神通者'));
    });

    test('FontDecryptor correctly parses HTML to text paragraphs', () {
      const html = '<p>第一段测试内容</p><p>第二段测试内容</p>';
      final text = FontDecryptor.decryptHtmlToText(html);
      expect(text, equals('第一段测试内容\n\n第二段测试内容'));
    });
  });

  group('ApiService Built-in Backend Endpoints Tests', () {
    late ApiService apiService;

    setUp(() {
      apiService = ApiService();
    });

    tearDown(() {
      apiService.dispose();
    });

    test('1. checkHealth (Built-in engine always ready)', () async {
      final healthy = await apiService.checkHealth();
      expect(healthy, isTrue);
    });

    test('2. GET /api/search via built-in engine', () async {
      final books = await apiService.searchBooks('部族荣光', offset: 0);
      expect(books, isNotEmpty);
      expect(books.first.bookName, contains('部族荣光'));
      expect(books.first.bookId, isNotEmpty);
    });

    test('3. GET /api/discover via built-in library API & ranking fallback', () async {
      final rankingBooks = await apiService.discoverBooks(
        bdtype: '巅峰榜',
        gender: 1,
        isRanking: true,
        page: 1,
      );
      expect(rankingBooks, isNotEmpty);

      final categoryBooks = await apiService.discoverBooks(
        type: 7,
        gender: 1,
        isRanking: false,
        creationStatus: 1,
        wordCount: 3,
        sort: 0,
        page: 1,
      );
      expect(categoryBooks, isNotEmpty);
    });

    test('4. GET /api/detail via built-in engine', () async {
      final detail = await apiService.getBookDetail('7069948840148732967');
      expect(detail, isNotNull);
      expect(detail!.bookId, equals('7069948840148732967'));
      expect(detail.bookName, contains('部族荣光'));
    });

    test('5. GET /api/directory & GET /api/book via built-in engine', () async {
      final dirChapters = await apiService.getBookDirectory('7069948840148732967');
      expect(dirChapters, isNotEmpty);
      expect(dirChapters.first.itemId, isNotEmpty);

      final fullBook = await apiService.getBookFull('7069948840148732967');
      expect(fullBook, isNotNull);

      final chapters = await apiService.getBookChapters('7069948840148732967');
      expect(chapters, isNotEmpty);
    });

    test('6. GET chapter content via built-in engine and local cache', () async {
      final chapters = await apiService.getBookChapters('7069948840148732967');
      expect(chapters, isNotEmpty);
      final firstItemId = chapters.first.itemId;

      final content = await apiService.getChapterContent(firstItemId);
      expect(content, isNotNull);
      expect(content!.length, greaterThan(20));

      // Second fetch hits local cache
      final cachedContent = await apiService.getChapterContent(firstItemId);
      expect(cachedContent, equals(content));
    });
  });

  group('DownloadService Background Download Tests', () {
    test('DownloadService task management and non-blocking download', () async {
      final downloadService = DownloadService();
      final testBook = Book(
        bookId: 'test_book_123',
        bookName: '测试小说',
        author: '测试作者',
        creationStatus: '完结',
        wordNumber: 10000,
      );
      final testChapters = [
        Chapter(itemId: 'ch_1', title: '第1章', order: 1),
        Chapter(itemId: 'ch_2', title: '第2章', order: 2),
      ];

      final task = downloadService.startBackgroundDownload(
        book: testBook,
        chapters: testChapters,
        format: 'TXT',
      );

      expect(task, isNotNull);
      expect(task.book.bookId, equals('test_book_123'));
      expect(downloadService.isDownloading('test_book_123'), isTrue);

      downloadService.cancelDownload('test_book_123');
      expect(task.status, equals(DownloadTaskStatus.cancelled));
      expect(downloadService.isDownloading('test_book_123'), isFalse);
    });
  });
}
