import 'package:flutter_test/flutter_test.dart';
import 'package:fanqie_flutter/services/cover_cache_service.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'epub_image_fixture.dart';
import 'package:flutter/material.dart';
import 'package:fanqie_flutter/widgets/book_cover_widget.dart';

void main() {
  testWidgets(
    'small download cover placeholder fits large text without overflow',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const Scaffold(
              body: SizedBox(
                width: 36,
                height: 48,
                child: BookCoverWidget(
                  bookId: 'small_placeholder',
                  bookName: '很长的书籍标题',
                  iconSize: 18,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('CoverCacheService Tests', () {
    test('Local cover file check and caching', () async {
      final service = CoverCacheService();
      const testBookId = 'test_cover_book_123';

      final file = await service.getCoverFile(testBookId);
      expect(file, isNotNull);
      expect(file.path, contains('offline_books'));
      expect(file.path, contains('cover.jpg'));

      // Write mock bytes
      final bytes = imagePng();
      await file.writeAsBytes(bytes);

      final hasCover = await service.hasLocalCover(testBookId);
      expect(hasCover, isTrue);

      // Clean up
      if (await file.exists()) {
        await file.delete();
      }
    });
  });

  test(
    'HTML poison cover is refetched and replaced by a decodable bitmap',
    () async {
      final root = await Directory.systemTemp.createTemp('cover-repair-');
      addTearDown(() => root.delete(recursive: true));
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response.bytes(imagePng(), 200);
      });
      addTearDown(client.close);
      final service = CoverCacheService.forTesting(
        documents: () async => root,
        client: client,
      );
      final file = await service.getCoverFile('book');
      await file.writeAsString('<html>${'bad cached response' * 20}</html>');
      expect(await service.hasLocalCover('book'), false);
      expect(
        await service.cacheNetworkCover(
          'book',
          'https://p3-novel.byteimg.com/cover.png',
        ),
        isNotNull,
      );
      expect(await file.readAsBytes(), imagePng());
      expect(await service.hasLocalCover('book'), true);
      await service.cacheNetworkCover(
        'book',
        'https://p3-novel.byteimg.com/cover.png',
      );
      expect(calls, 1);
    },
  );
}
