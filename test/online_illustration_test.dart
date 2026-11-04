import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/book_image_fetcher.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/epub_chapter_content.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'epub_image_fixture.dart';

const imageUrl =
    'https://p3-reading-sign.fqnovelpic.com/picture.png?sign=a%2Bb';
const illustratedHtml =
    '<h1>第一章</h1><p>第一章</p>'
    '<p>图片前文<img src="$imageUrl" alt="人物图"/>图片后文</p>'
    '<img src="$imageUrl"/><p>下一段</p>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderCacheService cache;
  late FanqieBackendEngine engine;
  var contentCalls = 0, imageCalls = 0;
  var failContent = false, failImage = false;
  var source = illustratedHtml;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('online-images-');
    cache = ReaderCacheService(documents: () async => root);
    contentCalls = imageCalls = 0;
    failContent = failImage = false;
    source = illustratedHtml;
    engine = FanqieBackendEngine(
      cache: cache,
      chapterDocumentLoader: (_) async {
        contentCalls++;
        return failContent ? null : OnlineChapter.parse(source);
      },
      client: MockClient((request) async {
        imageCalls++;
        expect(request.url.toString(), imageUrl);
        return failImage
            ? http.Response('<html>error${'!' * 200}</html>', 200)
            : http.Response.bytes(imagePng(), 200);
      }),
    );
  });
  tearDown(() async {
    engine.dispose();
    await root.delete(recursive: true);
  });

  test(
    'HTML keeps inline and outside-p images without changing canonical text',
    () {
      final document = OnlineChapter.parse(illustratedHtml);
      expect(document.text, '图片前文图片后文\n\n下一段');
      expect(document.images.map((i) => i.offset), [4, 10]);
      expect(document.images.first.source, imageUrl);
      expect(document.images.first.alt, '人物图');
      final escaped = OnlineChapter.parse(
        '<p>  前文<br/>第二行<img data-src="//p3-novel.byteimg.com/a?x=1&amp;y=2" '
        'src="placeholder"/>后文  </p>',
      );
      expect(escaped.images.single.source, '//p3-novel.byteimg.com/a?x=1&y=2');
      final position = ReaderText.positionInRaw(
        escaped.text,
        escaped.images.single.offset,
      );
      expect((position.paragraphIndex, position.characterOffset), (1, 3));
      expect(escaped.text, '前文\n第二行后文');
    },
  );

  test(
    'official copyright divider tokens are decoration, not failed network images',
    () {
      final document = OnlineChapter.parse(
        r'<p>版权信息<img src="$bdCopyrightDivider"/></p>',
      );
      expect(document.text, '版权信息');
      expect(document.images, isEmpty);
    },
  );

  test(
    'image-only and short complete chapters are not treated as empty previews',
    () async {
      source = '<h1>插画</h1><p><img src="$imageUrl"/></p>';
      final text = await engine.getChapterContent('picture', bookId: 'book');
      expect(text, ReaderText.imageOnlyMarker);
      await engine.repairChapterImages('book', 'picture', text!);
      expect(
        (await engine.onlineImages.read('book', 'picture', text)).single.asset,
        isNotNull,
      );
      expect(ReaderText.paragraphs(text), ['']);
      source = '<p>终。</p>';
      expect(await engine.getChapterContent('short', bookId: 'book'), '终。');
    },
  );

  test(
    'homepage download persists images; fresh reader works with zero network',
    () async {
      final chapters = [Chapter(itemId: 'one', title: '第一章')];
      await engine.downloadChapters(bookId: 'book', chapters: chapters);
      final text = (await cache.read('book', 'one'))!;
      final images = await engine.onlineImages.read(
        'book',
        'one',
        text,
        title: '第一章',
      );
      expect(images.length, 2);
      expect(images.every((i) => i.asset != null && i.error == null), true);
      expect(images.map((i) => (i.paragraphIndex, i.characterOffset)), [
        (0, 4),
        (1, 0),
      ]);
      final file = File(
        '${root.path}/offline_books/book/${images.first.asset}',
      );
      expect(await file.exists(), true);
      final calls = (contentCalls, imageCalls);
      failContent = failImage = true;
      await cache.trim(0, includePinned: true);
      final fresh = FanqieBackendEngine(
        cache: cache,
        chapterDocumentLoader: (_) async => throw StateError('offline'),
        client: MockClient((_) async => throw StateError('offline')),
      );
      addTearDown(fresh.dispose);
      expect(await fresh.getChapterContent('one', bookId: 'book'), text);
      await fresh.repairChapterImages('book', 'one', text);
      expect((contentCalls, imageCalls), calls);
      expect(
        (await fresh.onlineImages.read('book', 'one', text)).first.asset,
        images.first.asset,
      );
    },
  );

  test(
    'legacy downloaded text is repaired in place, even after shelf deletion/re-add',
    () async {
      final text = OnlineChapter.parse(source).text;
      final permanent = await engine.getOfflineChapterFile('book', 'one');
      await permanent.writeAsString(text);
      // Also leave a stripped temporary cache: repair must bypass both layers.
      await cache.write('book', 'one', text);
      await ReaderPositionService().save(
        'book',
        const ReadingPosition(
          chapterId: 'one',
          paragraphIndex: 0,
          characterOffset: 5,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bookmarks_book', 'unchanged annotations');
      final before = {for (final k in prefs.getKeys()) k: prefs.get(k)};
      final shelf = BookshelfService();
      await shelf.reload();
      final book = Book(bookId: 'book', bookName: '首页书籍', author: '测试');
      await shelf.addToBookshelf(book);
      await shelf.removeFromBookshelf('book');
      await shelf.addToBookshelf(book);
      expect(await engine.getChapterContent('one', bookId: 'book'), text);
      expect(contentCalls, 0);
      await engine.downloadChapters(
        bookId: 'book',
        chapters: [Chapter(itemId: 'one', title: '第一章')],
      );
      expect(contentCalls, 1);
      expect(await permanent.readAsString(), text);
      for (final e in before.entries) {
        expect(prefs.get(e.key), e.value);
      }
      expect(
        (await engine.onlineImages.read(
          'book',
          'one',
          text,
        )).every((i) => i.asset != null),
        true,
      );
    },
  );

  test(
    'mismatched legacy edition is never overwritten or given wrong image anchors',
    () async {
      const text = '用户原有章节，与线上版本不同';
      final file = await engine.getOfflineChapterFile('book', 'one');
      await file.writeAsString(text);
      await expectLater(
        engine.repairChapterImages('book', 'one', text),
        throwsFormatException,
      );
      expect(await file.readAsString(), text);
      expect(await engine.onlineImages.read('book', 'one', text), isEmpty);
      expect(imageCalls, 0);
    },
  );

  test(
    'failed images do not report successful download; retry heals corrupt/missing files',
    () async {
      final chapters = [Chapter(itemId: 'one', title: '第一章')];
      failImage = true;
      await expectLater(
        engine.downloadChapters(bookId: 'book', chapters: chapters),
        throwsStateError,
      );
      final text = (await cache.read('book', 'one'))!;
      expect(
        (await engine.onlineImages.read('book', 'one', text)).first.error,
        isNotNull,
      );
      failImage = false;
      await engine.downloadChapters(bookId: 'book', chapters: chapters);
      var images = await engine.onlineImages.read('book', 'one', text);
      final asset = File(
        '${root.path}/offline_books/book/${images.first.asset}',
      );
      for (final corrupt in [true, false]) {
        if (corrupt) {
          await asset.writeAsString('HTML error page${'x' * 200}');
        } else {
          await asset.delete();
        }
        await engine.repairChapterImages('book', 'one', text);
        images = await engine.onlineImages.read('book', 'one', text);
        expect(images.every((i) => i.error == null), true);
        expect(await asset.readAsBytes(), imagePng());
      }
    },
  );

  test(
    'plain chapters record image schema, avoiding repeated migration fetches',
    () async {
      source = '<p>只有正文，不含插图。</p>';
      final text = (await engine.getChapterContent('plain', bookId: 'book'))!;
      await engine.repairChapterImages('book', 'plain', text);
      await engine.repairChapterImages('book', 'plain', text);
      expect(contentCalls, 1);
      expect(imageCalls, 0);
      expect(await engine.onlineImages.hasSources('book', 'plain', text), true);
    },
  );

  test(
    'temporary quota accounts for image metadata/assets, never explicit downloads',
    () async {
      final text = (await engine.getChapterContent('one', bookId: 'book'))!;
      await engine.repairChapterImages('book', 'one', text);
      expect(
        await cache.temporaryBytes(),
        greaterThan(utf8.encode(text).length),
      );
      expect(await cache.cachedChapterKeys('book'), {'one'});
      expect(await cache.trim(0, includePinned: true), 0);
      expect(await cache.temporaryBytes(), 0);
      expect(await engine.onlineImages.hasSources('book', 'one', text), false);
    },
  );

  test(
    'EPUB chapter export retains picture order; TXT/speech/search stay plain',
    () async {
      final text = (await engine.getChapterContent('one', bookId: 'book'))!;
      await engine.repairChapterImages('book', 'one', text);
      final images = await engine.onlineImages.read('book', 'one', text);
      final xhtml = epubChapterContent(text, '第一章', images);
      expect(xhtml.indexOf('图片前文'), lessThan(xhtml.indexOf('<img')));
      expect(xhtml.indexOf('<img'), lessThan(xhtml.indexOf('图片后文')));
      expect('<img'.allMatches(xhtml).length, 2);
      expect(text, isNot(contains('https:')));
      expect(text, isNot(contains('online_')));
      final epub = await imageEpub(
        root,
        [xhtml],
        resources: {
          for (final image in images) 'OPS/Text/${image.asset}': imagePng(),
        },
      );
      final imported = await LocalBookService.forTesting(
        documents: () async => root,
      ).importLocalFile(epub);
      expect(imported.chapters.single.illustrations.length, images.length);
      final restored = await File(
        '${root.path}/offline_books/${imported.book.bookId}/${imported.chapters.single.itemId}.txt',
      ).readAsString();
      expect(ReaderText.paragraphs(restored).join('\n\n'), text);
    },
  );

  test(
    'expired image signatures refresh from full chapter without changing text',
    () async {
      const expired = 'https://p3-novel.byteimg.com/picture.png?sign=expired';
      const renewed = 'https://p3-novel.byteimg.com/picture.png?sign=renewed';
      var calls = 0;
      final renewing = FanqieBackendEngine(
        cache: cache,
        chapterDocumentLoader: (_) async => OnlineChapter.parse(
          '<p>原正文<img src="${++calls == 1 ? expired : renewed}"/>不变</p>',
        ),
        client: MockClient(
          (request) async => request.url.queryParameters['sign'] == 'expired'
              ? http.Response('expired', 403)
              : http.Response.bytes(imagePng(), 200),
        ),
      );
      addTearDown(renewing.dispose);
      final text = (await renewing.getChapterContent('one', bookId: 'renew'))!;
      await renewing.repairChapterImages('renew', 'one', text);
      expect(calls, 2);
      expect(await cache.read('renew', 'one'), text);
      expect(
        (await renewing.onlineImages.read('renew', 'one', text)).single.asset,
        isNotNull,
      );
    },
  );

  test(
    'image fetch rejects unsafe URLs and redirects, oversized/corrupt payloads',
    () async {
      for (final source in [
        'http://127.0.0.1/x',
        'file:///tmp/a',
        'https://byteimg.com.evil.test/x',
      ]) {
        var calls = 0;
        final fetcher = BookImageFetcher(
          MockClient((_) async {
            calls++;
            return http.Response.bytes(imagePng(), 200);
          }),
        );
        await expectLater(fetcher.fetch(source), throwsFormatException);
        expect(calls, 0);
      }
      final redirected = BookImageFetcher(
        MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'http://127.0.0.1/x'},
          ),
        ),
      );
      await expectLater(redirected.fetch(imageUrl), throwsFormatException);
      await expectLater(
        BookImageFetcher.validate(imagePng(width: 16001, height: 1)),
        throwsFormatException,
      );
    },
  );
}
