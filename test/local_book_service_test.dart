import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('local_book_test_');
    await BookshelfService().initialize();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('LocalBookService TXT Parsing Tests', () {
    test('Parse TXT file with standard Chinese chapter markers', () async {
      final txtFile = File('${tempDir.path}/诛仙传.txt');
      const rawBookContent = '''
这是写在最前头的前言序语。

第一章 青云初见
天地不仁，以万物为刍狗。
少年张小凡背着药篓走在山道上。

第2章 龙首之约
清晨的朝霞洒落在玉清殿前的云海中。
两位长老相对而坐，品茶弈棋。

第三章 万剑归一
剑光如匹练横空，划破了千丈崖壁。
''';
      await txtFile.writeAsString(rawBookContent);

      final service = LocalBookService();
      final result = await service.importLocalTxt(txtFile);

      expect(result.book.bookName, '诛仙传');
      expect(result.book.author, '本地导入');
      expect(result.chapterCount, 4); // 序言 + 3章
      expect(result.chapters[0].title, '序言');
      expect(result.chapters[1].title, '第一章 青云初见');
      expect(result.chapters[2].title, '第2章 龙首之约');
      expect(result.chapters[3].title, '第三章 万剑归一');

      // 验证已自动入书架
      final inShelf = BookshelfService().isInBookshelf(result.book.bookId);
      expect(inShelf, true);
    });

    test('Parse plain TXT file without chapter markers into automatic chunks', () async {
      final txtFile = File('${tempDir.path}/散文短篇.txt');
      final longContent = '这是一篇没有传统章节标识的长文小说段落。' * 200; // 约 4200 字
      await txtFile.writeAsString(longContent);

      final service = LocalBookService();
      final result = await service.importLocalTxt(txtFile);

      expect(result.book.bookName, '散文短篇');
      expect(result.chapterCount >= 2, true);
      expect(result.chapters.first.title.contains('第 1 部分'), true);
    });
  });
}
