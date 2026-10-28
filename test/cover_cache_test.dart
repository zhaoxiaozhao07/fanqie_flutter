import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fanqie_flutter/services/cover_cache_service.dart';

void main() {
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
      final bytes = List<int>.generate(200, (i) => i % 256);
      await file.writeAsBytes(bytes);

      final hasCover = await service.hasLocalCover(testBookId);
      expect(hasCover, isTrue);

      // Clean up
      if (await file.exists()) {
        await file.delete();
      }
    });
  });
}
