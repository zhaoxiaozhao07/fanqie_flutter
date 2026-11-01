import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/safe_zip_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalBookService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local_import_v2_');
    service = LocalBookService.forTesting(documents: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> epub(
    Map<String, String> files, {
    String name = 'book.epub',
  }) async {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return File(
      '${root.path}/$name',
    ).writeAsBytes(ZipEncoder().encode(archive));
  }

  Map<String, String> bookFiles({bool fragments = false}) => {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>',
    'OPS/package.opf': '''
<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>顺序测试</dc:title><dc:creator>测试作者</dc:creator></metadata>
<manifest><item id="two" href="Text/2.xhtml" media-type="application/xhtml+xml"/>
<item id="ten" href="Text/10.xhtml" media-type="application/xhtml+xml"/>
<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="two"/><itemref idref="ten"/></spine></package>''',
    'OPS/nav.xhtml': fragments
        ? '''
<html><body><nav epub:type="toc"><ol><li><span>第一卷</span><ol>
<li><a href="Text/2.xhtml#a">片段甲</a></li><li><a href="Text/2.xhtml#b">片段乙</a></li>
</ol></li><li><a href="Text/10.xhtml">最后一章</a></li></ol></nav></body></html>'''
        : '''
<html><body><nav epub:type="toc"><ol><li><span>第一卷</span><ol>
<li><a href="Text/2.xhtml">先读</a></li><li><a href="Text/10.xhtml">后读</a></li>
</ol></li></ol></nav></body></html>''',
    'OPS/Text/2.xhtml': fragments
        ? '<html><body><h1 id="a">片段甲</h1><p>甲正文</p><h1 id="b">片段乙</h1><p>乙正文</p></body></html>'
        : '<html><head><title>不应混入正文的头部</title></head><body><p>先读正文 &amp; 实体</p><script>恶意脚本不应出现</script></body></html>',
    'OPS/Text/10.xhtml': '<html><body><p>后读正文</p></body></html>',
  };

  test(
    'preview is staged; identical file reuses identity and preserves progress',
    () async {
      final source = await File(
        '${root.path}/短篇.txt',
      ).writeAsString('第一章 开篇\n这是正文。\n第二章 结尾\n终。');
      final preview = await service.prepare(source);
      expect(await preview.destination.exists(), false);
      expect(preview.chapters.length, 2);
      final first = await service.commit(preview);
      await preview.dispose();
      await ReaderPositionService().save(
        first.book.bookId,
        ReadingPosition(
          chapterId: first.chapters.last.itemId,
          characterOffset: 1,
        ),
      );
      final again = await service.importLocalFile(source);
      expect(again.alreadyExists, true);
      expect(again.book.bookId, first.book.bookId);
      expect(
        (await ReaderPositionService().load(
          first.book.bookId,
        ))!.characterOffset,
        1,
      );
      expect(
        await File('${preview.destination.path}/source.original').exists(),
        true,
      );
    },
  );

  test(
    'same filename with different content never overwrites the other book',
    () async {
      await Directory('${root.path}/a').create();
      await Directory('${root.path}/b').create();
      final a = await File('${root.path}/a/同名.txt').writeAsString('第一章\n内容甲');
      final b = await File('${root.path}/b/同名.txt').writeAsString('第一章\n内容乙');
      final one = await service.importLocalFile(a);
      final two = await service.importLocalFile(b);
      expect(one.book.bookId, isNot(two.book.bookId));
      expect(
        await File(
          '${root.path}/offline_books/${one.book.bookId}/${one.chapters.first.itemId}.txt',
        ).readAsString(),
        '内容甲',
      );
    },
  );

  test(
    'UTF-16 BOM and surrogate pairs decode without replacement characters',
    () async {
      const text = '第一章\n你好 😀';
      final data = ByteData(2 + text.codeUnits.length * 2)
        ..setUint16(0, 0xfeff, Endian.little);
      for (var i = 0; i < text.codeUnits.length; i++) {
        data.setUint16(2 + i * 2, text.codeUnits[i], Endian.little);
      }
      final source = await File(
        '${root.path}/utf16.txt',
      ).writeAsBytes(data.buffer.asUint8List());
      final preview = await service.prepare(source);
      expect(preview.encoding, 'UTF-16LE');
      expect(preview.sample, contains('你好 😀'));
      await preview.dispose();
      expect(await preview.destination.exists(), false);
    },
  );

  test(
    'EPUB follows OPF spine, extracts navigation volumes, excludes head/script',
    () async {
      final result = await service.importLocalFile(await epub(bookFiles()));
      expect(result.book.bookName, '顺序测试');
      expect(result.book.author, '测试作者');
      expect(result.chapters.map((c) => c.title), ['先读', '后读']);
      expect(result.chapters.first.volumeTitle, '第一卷');
      final text = await File(
        '${root.path}/offline_books/${result.book.bookId}/${result.chapters.first.itemId}.txt',
      ).readAsString();
      expect(text, contains('先读正文 & 实体'));
      expect(text, isNot(contains('头部')));
      expect(text, isNot(contains('恶意脚本')));
    },
  );

  test(
    'multiple navigation anchors inside one spine file become ordered chapters',
    () async {
      final result = await service.importLocalFile(
        await epub(bookFiles(fragments: true)),
      );
      expect(result.chapters.map((c) => c.title), ['片段甲', '片段乙', '最后一章']);
      expect(result.chapters[1].volumeTitle, '第一卷');
    },
  );

  test(
    'encrypted text, missing resources and empty EPUB never create placeholder books',
    () async {
      final files = bookFiles();
      files['META-INF/encryption.xml'] =
          '<encryption><EncryptedData><CipherData><CipherReference URI="OPS/Text/2.xhtml"/></CipherData></EncryptedData></encryption>';
      await expectLater(
        service.importLocalFile(await epub(files, name: 'encrypted.epub')),
        throwsFormatException,
      );
      final broken = bookFiles()..remove('OPS/Text/2.xhtml');
      await expectLater(
        service.importLocalFile(await epub(broken, name: 'broken.epub')),
        throwsFormatException,
      );
      final empty = bookFiles()
        ..['OPS/Text/2.xhtml'] = '<html><body></body></html>'
        ..['OPS/Text/10.xhtml'] = '<html><body></body></html>';
      await expectLater(
        service.importLocalFile(await epub(empty, name: 'empty.epub')),
        throwsFormatException,
      );
      final stages = Directory('${root.path}/import_staging');
      expect(await stages.list().toList(), isEmpty);
    },
  );

  test('cancelled preview leaves no partial book', () async {
    final source = await File('${root.path}/cancel.txt').writeAsString(
      List.generate(1000, (i) => '第${i + 1}章\n这是正文$i。').join('\n'),
    );
    final token = LocalImportToken();
    await expectLater(
      service.prepare(
        source,
        token: token,
        onProgress: (message) {
          if (message.startsWith('已解析')) token.cancel();
        },
      ),
      throwsA(isA<LocalImportCancelled>()),
    );
    expect(
      await Directory('${root.path}/import_staging').list().toList(),
      isEmpty,
    );
  });

  test(
    'safe legacy adoption keeps chapter IDs and only commits on confirmation',
    () async {
      final source = await File(
        '${root.path}/旧版.txt',
      ).writeAsString('第一章\n旧版正文');
      final legacy = Directory('${root.path}/offline_books/local_txt_42');
      await legacy.create(recursive: true);
      await File('${legacy.path}/old-chapter.txt').writeAsString('旧版正文');
      await File('${legacy.path}/directory.json').writeAsString(
        jsonEncode([Chapter(itemId: 'old-chapter', title: '第一章').toJson()]),
      );
      await BookshelfService().addToBookshelf(
        Book(bookId: 'local_txt_42', bookName: '旧版', author: '本地导入'),
        totalChapters: 1,
      );
      await ReaderPositionService().save(
        'local_txt_42',
        const ReadingPosition(chapterId: 'old-chapter', characterOffset: 2),
      );
      final preview = await service.prepare(source);
      expect(preview.book.bookId, 'local_txt_42');
      expect(await File('${legacy.path}/metadata.json').exists(), false);
      final result = await service.commit(preview);
      await preview.dispose();
      expect(result.chapters.first.itemId, 'old-chapter');
      expect(
        (await ReaderPositionService().load('local_txt_42'))!.characterOffset,
        2,
      );
      expect(
        (await service.importLocalFile(source)).book.bookId,
        'local_txt_42',
      );
    },
  );

  test('ZIP path traversal and forged inflated sizes are rejected', () async {
    final traversal = await epub({'../escape.txt': 'bad'}, name: 'unsafe.epub');
    await expectLater(SafeZipReader.open(traversal), throwsFormatException);
    final source = await epub({
      'text.txt': 'x' * 100000,
    }, name: 'oversized.zip');
    final bytes = await source.readAsBytes();
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset + 46 < bytes.length; offset++) {
      if (data.getUint32(offset, Endian.little) == 0x02014b50) {
        data.setUint32(offset + 24, 16, Endian.little);
        break;
      }
    }
    await source.writeAsBytes(bytes);
    final zip = await SafeZipReader.open(source);
    await expectLater(
      zip.read('text.txt', maxBytes: 1024),
      throwsFormatException,
    );
  });
}
