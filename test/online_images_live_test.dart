import 'dart:io';

import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/book_image_fetcher.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live homepage book downloads actual CDN cover and all chapter pictures, then reopens offline',
    () async {
      SharedPreferences.setMockInitialValues({});
      final old = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final root = await Directory.systemTemp.createTemp('online-live-');
      final client = http.Client();
      final cache = ReaderCacheService(documents: () async => root);
      final engine = FanqieBackendEngine(cache: cache);
      final api = ApiService(engine: engine);
      try {
        const bookId = '7187335930057854011'; // 图解山海经: public illustrated book.
        final book = await api.getBookDetail(bookId);
        expect(book, isNotNull);
        final cover = await BookImageFetcher(client).fetch(book!.thumbUrl!);
        expect(cover.bytes.length, greaterThan(100));
        final chapters = await api.getBookDirectory(bookId);
        final chapter = chapters.firstWhere((c) => c.title == '序言');
        await engine.downloadChapters(bookId: bookId, chapters: [chapter]);
        final text = (await cache.read(bookId, chapter.itemId))!;
        expect(text.length, greaterThan(1000));
        final images = await engine.onlineImages.read(
          bookId,
          chapter.itemId,
          text,
        );
        expect(images.length, greaterThanOrEqualTo(3));
        for (final image in images) {
          expect(image.error, isNull);
          expect(image.asset, isNotNull);
          final file = File(
            '${root.path}/offline_books/$bookId/${image.asset}',
          );
          await BookImageFetcher.validate(await file.readAsBytes());
        }
        await cache.trim(0, includePinned: true);
        final offline = FanqieBackendEngine(
          cache: cache,
          chapterDocumentLoader: (_) async =>
              throw const SocketException('offline'),
          client: MockClient(
            (_) async => throw const SocketException('offline'),
          ),
        );
        try {
          expect(
            await offline.getChapterContent(chapter.itemId, bookId: bookId),
            text,
          );
          await offline.repairChapterImages(bookId, chapter.itemId, text);
          expect(
            (await offline.onlineImages.read(
              bookId,
              chapter.itemId,
              text,
            )).length,
            images.length,
          );
        } finally {
          offline.dispose();
        }
      } finally {
        api.dispose();
        client.close();
        HttpOverrides.global = old;
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('FANQIE_LIVE_API'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
