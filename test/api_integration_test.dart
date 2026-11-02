import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/font_decryptor.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

const _liveApi = bool.fromEnvironment('FANQIE_LIVE_API');

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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
    late HttpOverrides? previousOverrides;
    late Directory directory;

    setUp(() async {
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      directory = await Directory.systemTemp.createTemp('fanqie-live-api-');
      apiService = ApiService(
        engine: FanqieBackendEngine(
          cache: ReaderCacheService(documents: () async => directory),
        ),
      );
    });

    tearDown(() async {
      apiService.dispose();
      HttpOverrides.global = previousOverrides;
      await directory.delete(recursive: true);
    });

    test('1. Official category metadata', () async {
      for (final gender in [0, 1, 2]) {
        final catalog = await apiService.getCategories(gender: gender);
        expect(catalog.isCached, isFalse);
        expect(catalog.categories, isNotEmpty);
        if (gender == 1) {
          expect(
            catalog.categories.any((c) => c.id == 12 && c.name == '历史'),
            isTrue,
          );
        }
      }
    });

    test('2. GET /api/search via built-in engine', () async {
      final books = await apiService.searchBooks('部族荣光', offset: 0);
      expect(books, isNotEmpty);
      expect(books.first.bookName, contains('部族荣光'));
      expect(books.first.bookId, isNotEmpty);
    });

    test('3. Official library filters and pagination', () async {
      final first = await apiService.discoverBooks(
        categoryId: 7,
        gender: 1,
        creationStatus: 1,
        wordCount: 2,
      );
      expect(first.books, isNotEmpty);
      expect(
        first.books.every(
          (b) => b.wordNumber >= 500000 && b.wordNumber <= 1000000,
        ),
        isTrue,
      );
      expect(first.books.every((b) => b.creationStatus == '连载中'), isTrue);
      final second = await apiService.discoverBooks(
        categoryId: 7,
        gender: 1,
        creationStatus: 1,
        wordCount: 2,
        page: 2,
      );
      expect(second.books, isNotEmpty);
      expect(
        first.books
            .map((b) => b.bookId)
            .toSet()
            .intersection(second.books.map((b) => b.bookId).toSet()),
        isEmpty,
      );
    });

    test('4. GET /api/detail via built-in engine', () async {
      final detail = await apiService.getBookDetail('7069948840148732967');
      expect(detail, isNotNull);
      expect(detail!.bookId, equals('7069948840148732967'));
      expect(detail.bookName, contains('部族荣光'));
    });

    test('5. GET /api/directory & GET /api/book via built-in engine', () async {
      final dirChapters = await apiService.getBookDirectory(
        '7069948840148732967',
      );
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

      // This direct gateway probe cannot pass merely because an old disk cache
      // exists. A fresh process must negotiate a usable server key.
      final freshContent = await FanqieMobileGateway().fetchChapter(
        firstItemId,
      );
      expect(freshContent, isNotNull);
      expect(freshContent!.length, greaterThan(1500));
      final content = await apiService.getChapterContent(firstItemId);
      expect(content, isNotNull);
      expect(content!.length, greaterThan(20));

      // Second fetch hits local cache
      final cachedContent = await apiService.getChapterContent(firstItemId);
      expect(cachedContent, equals(content));

      // Probe an ID from the current directory, not a stale hard-coded chapter.
      final fullContent = await FanqieMobileGateway().fetchChapter(
        chapters[100].itemId,
      );
      expect(fullContent, isNotNull);
      expect(fullContent!.length, greaterThan(1500));
      expect(fullContent.contains('APP端专享/锁章章节'), isFalse);
    });

    test(
      '7. Offline book resources priority and persistent chapter cache',
      () async {
        const testBookId = 'test_offline_book_999';
        const testItemId = 'test_item_999';
        const mockContent =
            '这是测试的离线本地正文内容，阅读时必须优先读取本地已下载资源！这是测试章节的第二段内容，确保文本长度超过五十个字符以通过有效性检验。';

        final offlineFile = await apiService.engine.getOfflineChapterFile(
          testBookId,
          testItemId,
        );
        await offlineFile.writeAsString(mockContent);

        final isOffline = await apiService.isChapterOffline(
          testBookId,
          testItemId,
        );
        expect(isOffline, isTrue);

        final fetchedContent = await apiService.getChapterContent(
          testItemId,
          bookId: testBookId,
        );
        expect(fetchedContent, equals(mockContent));

        final offlineCount = await apiService.getOfflineChapterCount(
          testBookId,
        );
        expect(offlineCount, greaterThanOrEqualTo(1));
      },
    );

    test(
      '8. Current native paragraph stats, chapter comments and book reviews',
      () async {
        final chapters = await apiService.getBookChapters(
          '7069948840148732967',
        );
        final gateway = FanqieMobileGateway();
        final stats = await gateway.fetchChapterCommentStats(
          chapters.first.itemId,
        );
        expect(stats, isNotNull);
        final chapterComments = await gateway.fetchChapterComments(
          '7069948840148732967',
          chapters.first.itemId,
          count: 5,
        );
        expect(chapterComments, isNotNull);
        final reviews = await gateway.fetchBookReviews(
          '7069948840148732967',
          count: 5,
        );
        expect(reviews, isNotNull);
        expect(reviews!.comments, isNotEmpty);
      },
    );
  }, skip: !_liveApi);

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
