import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/services/source_service.dart';
import 'package:fanqie_flutter/services/api_service.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
  });

  group('SourceService Tests', () {
    test('SourceService has correct default URL and no legacy endpoints', () async {
      final service = SourceService();
      await service.initialize();

      expect(service.currentActiveUrl, equals('http://192.168.10.158:8000'));
      for (final src in service.sources) {
        expect(src.baseUrl.contains('yydjtc'), isFalse);
        expect(src.baseUrl.contains('vv9v'), isFalse);
        expect(src.baseUrl.contains('shusan'), isFalse);
      }
    });

    test('SourceService checkSource succeeds on local backend', () async {
      final service = SourceService();
      await service.initialize();

      final target = service.sources.firstWhere(
        (s) => s.baseUrl == 'http://192.168.10.158:8000',
      );
      final checked = await service.checkSource(target);
      expect(checked.isWorking, isTrue);
      expect(checked.latency, isNotNull);
    });
  });

  group('ApiService FastAPI Endpoints Tests', () {
    late ApiService apiService;

    setUp(() {
      apiService = ApiService();
    });

    tearDown(() {
      apiService.dispose();
    });

    test('1. GET /health', () async {
      final healthy = await apiService.checkHealth();
      expect(healthy, isTrue);
    });

    test('2. GET /api/search', () async {
      final books = await apiService.searchBooks('剑来', offset: 0);
      expect(books, isNotEmpty);
      expect(books.first.bookName, isNotEmpty);
      expect(books.first.bookId, isNotEmpty);
    });

    test('3. GET /api/discover (ranking mode & filter mode)', () async {
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

    test('4. GET /api/detail', () async {
      var searchResult = await apiService.searchBooks('剑来');
      if (searchResult.isEmpty) {
        searchResult = await apiService.discoverBooks(page: 1);
      }
      expect(searchResult, isNotEmpty);
      final bookId = searchResult.first.bookId;

      final detail = await apiService.getBookDetail(bookId);
      expect(detail, isNotNull);
      expect(detail!.bookId, equals(bookId));
      expect(detail.bookName, isNotEmpty);
    });

    test('5. GET /api/directory & GET /api/book', () async {
      var searchResult = await apiService.searchBooks('剑来');
      if (searchResult.isEmpty) {
        searchResult = await apiService.discoverBooks(page: 1);
      }
      expect(searchResult, isNotEmpty);
      final bookId = searchResult.first.bookId;

      final dirChapters = await apiService.getBookDirectory(bookId);
      expect(dirChapters, isNotEmpty);
      expect(dirChapters.first.itemId, isNotEmpty);

      final fullBook = await apiService.getBookFull(bookId);
      expect(fullBook, isNotNull);

      final chapters = await apiService.getBookChapters(bookId);
      expect(chapters, isNotEmpty);
    });

    test('6. GET /api/ios/content & GET /api/content', () async {
      var searchResult = await apiService.searchBooks('剑来');
      if (searchResult.isEmpty) {
        searchResult = await apiService.discoverBooks(page: 1);
      }
      expect(searchResult, isNotEmpty);
      final bookId = searchResult.first.bookId;

      final chapters = await apiService.getBookChapters(bookId);
      expect(chapters, isNotEmpty);
      final firstItemId = chapters.first.itemId;

      final iosContent = await apiService.getIosChapterContent(firstItemId);
      expect(iosContent, isNotNull);
      expect(iosContent!, isNotEmpty);

      final normalContent = await apiService.getNormalChapterContent(firstItemId);
      expect(normalContent, isNotNull);
      expect(normalContent!, isNotEmpty);

      final content = await apiService.getChapterContent(firstItemId);
      expect(content, isNotNull);
      expect(content!, isNotEmpty);
    });
  });
}
