import 'dart:async';
import 'dart:io';
import 'package:fanqie_flutter/services/cover_cache_service.dart';
import 'package:fanqie_flutter/widgets/book_cover_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'epub_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CoverCacheService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover-stable-');
    service = CoverCacheService.forTesting(
      documents: () async => root,
      client: MockClient((_) async => http.Response.bytes(imagePng(), 200)),
    );
  });
  tearDown(() async {
    service.client!.close();
    await root.delete(recursive: true);
  });

  test(
    'validation revision is stable until the file changes, and missing files invalidate it',
    () async {
      final file = await service.getCoverFile('book');
      await file.writeAsBytes(imagePng());
      expect(await service.hasLocalCover('book'), true);
      final revision = service.coverRevision('book');
      for (var i = 0; i < 10; i++) {
        expect(await service.hasLocalCover('book'), true);
      }
      expect(service.coverRevision('book'), revision);
      await file.writeAsBytes(imagePng(width: 32));
      expect(await service.hasLocalCover('book'), true);
      expect(service.coverRevision('book'), greaterThan(revision));
      await file.delete();
      expect(await service.hasLocalCover('book'), false);
      expect(service.peekCover('book'), isNull);
    },
  );

  test('concurrent cover consumers share one download', () async {
    var calls = 0;
    final gate = Completer<http.Response>();
    service.client!.close();
    service.client = MockClient((_) {
      calls++;
      return gate.future;
    });
    final first = service.cacheNetworkCover(
      'book',
      'https://p3-novel.byteimg.com/cover.png',
    );
    final second = service.cacheNetworkCover(
      'book',
      'https://p3-novel.byteimg.com/cover.png',
    );
    expect(identical(first, second), true);
    gate.complete(http.Response.bytes(imagePng(), 200));
    expect(await first, isNotNull);
    expect(await second, isNotNull);
    expect(calls, 1);
  });

  testWidgets(
    'remount and URL refresh keep the warm decoded cover instead of evicting it',
    (tester) async {
      await tester.runAsync(() async {
        final file = await service.getCoverFile('book');
        await file.writeAsBytes(imagePng());
      });
      Widget cover(String url) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 86,
            height: 118,
            child: BookCoverWidget(
              bookId: 'book',
              bookName: '封面',
              thumbUrl: url,
              cacheService: service,
            ),
          ),
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      await tester.pumpWidget(cover('https://p3-novel.byteimg.com/first.png'));
      await settle();
      final first = tester
          .widget<RawImage>(find.byType(RawImage))
          .image!
          .clone();
      addTearDown(first.dispose);
      final provider = tester.widget<Image>(find.byType(Image)).image;
      await tester.pumpWidget(
        cover('https://p3-novel.byteimg.com/changed-signature.png'),
      );
      expect(
        find.byType(Image),
        findsOneWidget,
      ); // No intermediate placeholder.
      await settle();
      expect(tester.widget<Image>(find.byType(Image)).image, provider);
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(first),
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(cover('https://p3-novel.byteimg.com/first.png'));
      await settle();
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(first),
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
