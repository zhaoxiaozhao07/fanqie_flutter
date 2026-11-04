import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_search_service.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_text.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import 'epub_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalBookService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('epub-image-test-');
    service = LocalBookService.forTesting(documents: () async => root);
  });
  tearDown(() => root.delete(recursive: true));
  Future<String> body(String book, Chapter chapter) => File(
    '${root.path}/offline_books/$book/${chapter.itemId}.txt',
  ).readAsString();

  test(
    'old heading-only image chapter preserves shifted text chapter IDs on upgrade',
    () async {
      final source = await imageEpub(root, [
        '<h1>图集</h1><img src="../Images/图%201.png"/>',
        '<p>真实正文</p>',
      ]);
      final initial = await service.importLocalFile(source);
      final folder = '${root.path}/offline_books/${initial.book.bookId}';
      final textChapter = initial.chapters.last;
      final oldTextId = textChapter.itemId.replaceFirst(RegExp(r'_c1$'), '_c2');
      await File(
        '$folder/${textChapter.itemId}.txt',
      ).rename('$folder/$oldTextId.txt');
      await File('$folder/${textChapter.itemId}.txt').writeAsString('图集');
      await File('$folder/${initial.chapters.first.itemId}.txt').delete();
      final oldChapters = [
        Chapter(itemId: textChapter.itemId, title: '图集', order: 1),
        Chapter(itemId: oldTextId, title: textChapter.title, order: 2),
      ];
      await File(
        '$folder/directory.json',
      ).writeAsString(jsonEncode(oldChapters.map((c) => c.toJson()).toList()));
      final metadataFile = File('$folder/metadata.json');
      final metadata = (jsonDecode(await metadataFile.readAsString()) as Map)
        ..remove('illustrations_version');
      await metadataFile.writeAsString(jsonEncode(metadata));
      await Directory('$folder/images').delete(recursive: true);
      await ReaderPositionService().save(
        initial.book.bookId,
        ReadingPosition(chapterId: oldTextId, characterOffset: 2),
      );
      final upgraded = await service.importLocalFile(source);
      expect(
        upgraded.chapters.map((c) => c.itemId),
        oldChapters.map((c) => c.itemId),
      );
      expect(upgraded.chapters.first.illustrations.single.asset, isNotNull);
      expect(await body(upgraded.book.bookId, upgraded.chapters.first), '图集');
      expect(await body(upgraded.book.bookId, upgraded.chapters.last), '真实正文');
      expect(
        (await ReaderPositionService().load(initial.book.bookId))!.chapterId,
        oldTextId,
      );
    },
  );

  test(
    'adjacent image navigation anchors do not duplicate or swallow pictures',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(
          root,
          [
            '<img id="a" src="../Images/图%201.png" alt="甲图"/>'
                '<img id="b" src="../Images/图%201.png" alt="乙图"/>',
          ],
          navigation:
              '<html><nav epub:type="toc"><ol><li><a href="Text/0.xhtml#a">甲</a></li>'
              '<li><a href="Text/0.xhtml#b">乙</a></li></ol></nav></html>',
        ),
      );
      expect(result.chapters.map((c) => c.title), ['甲', '乙']);
      expect(result.chapters.map((c) => c.illustrations.single.alt), [
        '甲图',
        '乙图',
      ]);
    },
  );

  test(
    'inline and block images preserve text, order, URI escapes and asset deduplication',
    () async {
      final file = await imageEpub(root, [
        '<p>前文<img src="../Images/%E5%9B%BE%201.png" alt="示意图"/>后文</p>'
            '<img src="../Images/图%201.png"/><p>下一段</p>',
      ]);
      final result = await service.importLocalFile(file);
      final chapter = result.chapters.single;
      expect(await body(result.book.bookId, chapter), '前文后文\n\n下一段');
      expect(chapter.illustrations.length, 2);
      expect(
        chapter.illustrations.map((e) => (e.paragraphIndex, e.characterOffset)),
        [(0, 2), (1, 0)],
      );
      expect(
        chapter.illustrations.first.asset,
        chapter.illustrations.last.asset,
      );
      expect(chapter.illustrations.first.alt, '示意图');
      final folder = Directory(
        '${root.path}/offline_books/${result.book.bookId}/images',
      );
      expect(await folder.list().length, 1);
      final again = await service.importLocalFile(file);
      expect(again.alreadyExists, true);
      expect(again.chapters.single.illustrations.length, 2);
    },
  );

  test('title removal does not shift image or text anchors', () async {
    final result = await service.importLocalFile(
      await imageEpub(
        root,
        ['<h1>第一章</h1><p>前<img src="../Images/图%201.png"/>后</p>'],
        labels: ['第一章'],
      ),
    );
    final chapter = result.chapters.single;
    expect(
      ReaderText.paragraphs(
        await body(result.book.bookId, chapter),
        chapterTitle: chapter.title,
      ),
      ['前后'],
    );
    expect(chapter.illustrations.single.paragraphIndex, 0);
    expect(chapter.illustrations.single.characterOffset, 1);
  });

  test(
    'image-only spine documents become real image chapters, not fake prose',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(root, [
          '<img src="../Images/图%201.png"/><img src="../Images/图%201.png"/>',
          '<p>正文</p>',
        ]),
      );
      expect(result.chapters.length, 3);
      expect(
        result.chapters.take(2).every((c) => c.illustrations.length == 1),
        true,
      );
      expect(result.chapters.last.itemId, endsWith('_c1'));
      for (final c in result.chapters.take(2)) {
        final raw = await body(result.book.bookId, c);
        expect(raw, ReaderText.imageOnlyMarker);
        expect(ReaderText.paragraphs(raw).join('').trim(), isEmpty);
      }
      final search = ReaderSearchService(
        cache: ReaderCacheService(documents: () async => root),
      );
      final updates = await search
          .search(
            bookId: result.book.bookId,
            chapters: result.chapters,
            query: 'images/',
          )
          .toList();
      expect(updates.expand((e) => e.hits), isEmpty);
    },
  );

  test(
    'missing, remote and escaping images retain explicit blocks without replacing text',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(root, [
          '<p>正文保留</p><img src="https://example.invalid/tracker.png"/>'
              '<img src="../../../../private.png"/><img src="../Images/missing.png"/>',
        ]),
      );
      expect(await body(result.book.bookId, result.chapters.single), '正文保留');
      expect(result.chapters.single.illustrations.length, 3);
      expect(
        result.chapters.single.illustrations.every(
          (e) => e.error != null && e.asset == null,
        ),
        true,
      );
    },
  );

  test(
    'SVG-wrapped bitmaps and vector figures are saved without external references',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(root, [
          '<p>图前</p><svg viewBox="0 0 64 48"><image xlink:href="../Images/图%201.png" width="64" height="48"/></svg>'
              '<svg width="80" height="60"><rect width="80" height="60" fill="red"/></svg><p>图后</p>',
        ]),
      );
      final pictures = result.chapters.single.illustrations;
      expect(pictures.length, 2);
      expect(
        pictures.every((e) => e.error == null && e.asset!.endsWith('.svg')),
        true,
      );
      final svg = await File(
        '${root.path}/offline_books/${result.book.bookId}/${pictures.first.asset}',
      ).readAsString();
      expect(svg, contains('data:image/png;base64,'));
      expect(svg, isNot(contains('../Images/')));
      expect(
        await body(result.book.bookId, result.chapters.single),
        '图前\n\n图后',
      );
    },
  );

  test(
    'unsafe SVG and enormous raster dimensions do not execute or allocate images',
    () async {
      final huge = imagePng();
      ByteData.sublistView(huge).setUint32(16, 50000);
      final result = await service.importLocalFile(
        await imageEpub(
          root,
          [
            '<p>安全正文</p><svg><script>bad()</script></svg><img src="../Images/huge.png"/>',
          ],
          resources: {'OPS/Images/huge.png': huge},
        ),
      );
      expect(
        result.chapters.single.illustrations.every((e) => e.error != null),
        true,
      );
      expect(await body(result.book.bookId, result.chapters.single), '安全正文');
    },
  );

  test(
    'encrypted image is explicit while encrypted text remains rejected',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(
          root,
          ['<p>正文</p><img src="../Images/图%201.png"/>'],
          encryption:
              '<encryption><CipherReference URI="OPS/Images/图%201.png"/></encryption>',
        ),
      );
      expect(result.chapters.single.illustrations.single.error, contains('加密'));
    },
  );

  test(
    'navigation fragment splits keep their corresponding illustrations',
    () async {
      final result = await service.importLocalFile(
        await imageEpub(
          root,
          [
            '<h1 id="a">甲</h1><img src="../Images/图%201.png"/><p>甲正文</p>'
                '<h1 id="b">乙</h1><img src="../Images/图%201.png"/><p>乙正文</p>',
          ],
          navigation:
              '<html><nav epub:type="toc"><ol><li><a href="Text/0.xhtml#a">甲</a></li>'
              '<li><a href="Text/0.xhtml#b">乙</a></li></ol></nav></html>',
        ),
      );
      expect(result.chapters.map((c) => c.title), ['甲', '乙']);
      expect(result.chapters.map((c) => c.illustrations.length), [1, 1]);
      expect(await body(result.book.bookId, result.chapters.first), '甲\n\n甲正文');
      expect(await body(result.book.bookId, result.chapters.last), '乙\n\n乙正文');
    },
  );

  test(
    'reimport upgrades image-less v2 books without touching text IDs or reading data',
    () async {
      final source = await imageEpub(root, [
        '<p>第一段<img src="../Images/图%201.png"/>后半段</p>',
        '<p>第二章正文</p>',
      ]);
      final initial = await service.importLocalFile(source);
      final dir = Directory(
        '${root.path}/offline_books/${initial.book.bookId}',
      );
      final originals = {
        for (final c in initial.chapters)
          c.itemId: await body(initial.book.bookId, c),
      };
      final metadataFile = File('${dir.path}/metadata.json');
      final metadata = jsonDecode(await metadataFile.readAsString()) as Map;
      metadata.remove('illustrations_version');
      await metadataFile.writeAsString(jsonEncode(metadata));
      final dataFile = File('${dir.path}/directory.json');
      final data = jsonDecode(await dataFile.readAsString()) as List;
      for (final c in data) {
        (c as Map).remove('illustrations');
      }
      await dataFile.writeAsString(jsonEncode(data));
      await Directory('${dir.path}/images').delete(recursive: true);
      await ReaderPositionService().save(
        initial.book.bookId,
        ReadingPosition(
          chapterId: initial.chapters.last.itemId,
          characterOffset: 3,
        ),
      );
      final bookmark = await BookmarkService().addBookmark(
        bookId: initial.book.bookId,
        chapterIndex: 1,
        chapterTitle: '第二章',
        chapterId: initial.chapters.last.itemId,
        paragraphIndex: 0,
        characterOffset: 3,
        contentPreview: '第二章正文',
      );
      final note = await BookmarkService().addNote(
        bookId: initial.book.bookId,
        chapterId: initial.chapters.last.itemId,
        chapterIndex: 1,
        chapterTitle: initial.chapters.last.title,
        text: '正文',
        startOffset: 3,
        endOffset: 5,
        chapterHash: NoteAnchorResolver.digest(['第二章正文']),
      );
      final upgraded = await service.importLocalFile(source);
      expect(upgraded.book.bookId, initial.book.bookId);
      expect(
        upgraded.chapters.map((c) => c.itemId),
        initial.chapters.map((c) => c.itemId),
      );
      expect(upgraded.chapters.first.illustrations.length, 1);
      for (final c in upgraded.chapters) {
        expect(await body(upgraded.book.bookId, c), originals[c.itemId]);
      }
      expect(
        (await ReaderPositionService().load(
          initial.book.bookId,
        ))!.characterOffset,
        3,
      );
      expect(
        await BookmarkService().getBookmarks(initial.book.bookId),
        contains(bookmark),
      );
      final notes = await BookmarkService().getNotes(initial.book.bookId);
      expect(notes.single.id, note.id);
      expect((notes.single.startOffset, notes.single.endOffset), (3, 5));
      expect(await File('${dir.path}/source.original').exists(), true);
      expect(
        (jsonDecode(await metadataFile.readAsString())
            as Map)['illustrations_version'],
        1,
      );
    },
  );

  test(
    'changed old text is never overwritten during an illustration upgrade',
    () async {
      final source = await imageEpub(root, [
        '<p>原正文</p><img src="../Images/图%201.png"/>',
      ]);
      final initial = await service.importLocalFile(source);
      final dir = Directory(
        '${root.path}/offline_books/${initial.book.bookId}',
      );
      final file = File('${dir.path}/metadata.json');
      final metadata = jsonDecode(await file.readAsString()) as Map
        ..remove('illustrations_version');
      await file.writeAsString(jsonEncode(metadata));
      final text = File('${dir.path}/${initial.chapters.single.itemId}.txt');
      await text.writeAsString('用户编辑后的正文');
      await expectLater(service.importLocalFile(source), throwsFormatException);
      expect(await text.readAsString(), '用户编辑后的正文');
    },
  );
}
