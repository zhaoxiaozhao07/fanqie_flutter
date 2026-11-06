import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/models/reader_illustration.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/widgets/reader_comment_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReaderLayout layout(
  double scale, {
  double width = 400,
  bool comments = true,
  double chapterEndHeight = 0,
  int columns = 1,
}) => ReaderLayout(
  size: Size(width, 760),
  bodyStyle: const TextStyle(fontSize: 18, height: 1.8, letterSpacing: 0.5),
  titleStyle: const TextStyle(
    fontSize: 22,
    height: 1.4,
    fontWeight: FontWeight.bold,
  ),
  textScaler: TextScaler.linear(scale),
  horizontalPadding: 20,
  paragraphSpacing: 14,
  inlineCommentSize: comments
      ? ReaderCommentBubble.sizeFor(TextScaler.linear(scale))
      : Size.zero,
  chapterEndHeight: chapterEndHeight,
  columns: columns,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('theme colors do not invalidate pagination metrics or cached pages', () {
    final original = layout(1);
    final dark = ReaderLayout(
      size: original.size,
      bodyStyle: original.bodyStyle.copyWith(color: Colors.white),
      titleStyle: original.titleStyle.copyWith(color: Colors.white),
      textScaler: original.textScaler,
      horizontalPadding: original.horizontalPadding,
      paragraphSpacing: original.paragraphSpacing,
      inlineCommentSize: original.inlineCommentSize,
    );
    final cache = ReaderPaginationCache();
    ReaderChapterPages prepare(ReaderLayout value) => cache.paginate(
      chapterId: 'theme',
      title: '章节',
      content: '正文内容。' * 300,
      layout: value,
      indent: true,
    );
    expect(identical(prepare(original), prepare(dark)), true);
  });

  for (final scale in [1.0, 1.4, 2.0]) {
    test('scaled $scale chapter ending fits without losing source text', () {
      for (final content in [
        '青山依旧，故事继续。👨‍👩‍👧‍👦' * 250,
        '${'春风拂过书页。' * 200}\n\n终章。👨‍👩‍👧‍👦',
        '${'春风拂过书页。' * 200}\n\n${'最后一段。' * 30}\n\n',
      ]) {
        final pages = ReaderPaginationCache().paginate(
          chapterId: 'chapter-end',
          title: '第一章',
          content: content,
          layout: layout(scale, width: 320, chapterEndHeight: 130),
          indent: true,
        );
        expect(pages.pages.length, greaterThan(2));
        expect(pages.pages.last.chapterEndHeight, 130);
        expect(
          pages.pages
              .take(pages.pages.length - 1)
              .every((page) => page.chapterEndHeight == 0),
          isTrue,
        );
        for (final page in pages.pages) {
          final height =
              page.fragments.fold<double>(
                0,
                (sum, fragment) => sum + fragment.height,
              ) +
              (page.fragments.length - 1) * 14;
          expect(page.oversized, false);
          expect(height, lessThanOrEqualTo(page.availableHeight + .01));
        }
        for (var p = 0; p < pages.sourceParagraphs.length; p++) {
          final text = pages.pages
              .expand((page) => page.fragments)
              .where((fragment) => fragment.paragraphIndex == p)
              .map(
                (fragment) => fragment.startOffset == 0
                    ? fragment.text.substring(2)
                    : fragment.text,
              )
              .join();
          expect(text, pages.sourceParagraphs[p]);
        }
      }
    });

    test('scaled $scale pages fit and retain every source character', () {
      final paragraphs = [
        '夜幕降临，繁星点缀在浩瀚的天际。' * 150,
        '重复段落，不能反向匹配到第一段。',
        '重复段落，不能反向匹配到第一段。',
        'English words and 👨‍👩‍👧‍👦 family emojis，标点与空格都保留。' * 20,
      ];
      final pages = ReaderPaginationCache().paginate(
        chapterId: 'test',
        title: '第一章 长段落测试',
        content: paragraphs.join('\n\n'),
        layout: layout(scale),
        indent: true,
      );
      expect(pages.pages.length, greaterThan(2));
      for (final page in pages.pages) {
        final height =
            page.fragments.fold<double>(
              0,
              (sum, fragment) => sum + fragment.height,
            ) +
            (page.fragments.length - 1) * 14;
        expect(height, lessThanOrEqualTo(page.availableHeight + 0.01));
      }
      for (var index = 0; index < paragraphs.length; index++) {
        final fragments = pages.pages
            .expand((page) => page.fragments)
            .where((fragment) => fragment.paragraphIndex == index)
            .toList();
        expect(fragments.first.startOffset, 0);
        expect(fragments.last.endOffset, paragraphs[index].length);
        expect(
          fragments
              .map(
                (fragment) => fragment.startOffset == 0
                    ? fragment.text.substring(2)
                    : fragment.text,
              )
              .join(),
          paragraphs[index],
        );
        var offset = 0;
        final boundaries = <int>{0};
        for (final character in paragraphs[index].characters) {
          offset += character.length;
          boundaries.add(offset);
        }
        for (final fragment in fragments) {
          expect(boundaries.contains(fragment.startOffset), isTrue);
          expect(boundaries.contains(fragment.endOffset), isTrue);
          if (fragment.startOffset > 0) {
            expect(fragment.text.startsWith('\u3000\u3000'), isFalse);
          }
        }
      }
    });
  }

  test('a final illustration reserves space above the chapter ending', () {
    const content = '图前文字。';
    const image = ReaderIllustration(
      id: 'last-image',
      asset: 'images/test.png',
      width: 100,
      height: 2000,
      paragraphIndex: 0,
      characterOffset: content.length,
    );
    final pages = ReaderPaginationCache().paginate(
      chapterId: 'image-end',
      title: '插图章节',
      content: content,
      layout: layout(2, chapterEndHeight: 130),
      indent: false,
      illustrations: const [image],
    );
    final last = pages.pages.last;
    expect(last.chapterEndHeight, 130);
    expect(last.fragments.last.image?.id, image.id);
    expect(last.fragments.last.height, lessThanOrEqualTo(last.availableHeight));
    expect(
      pages.pages
          .expand((page) => page.fragments)
          .where((fragment) => fragment.image == null)
          .map((fragment) => fragment.text)
          .join(),
      content,
    );
  });

  test('reflow finds the page containing the same source anchor', () {
    final cache = ReaderPaginationCache();
    final content = List.generate(
      35,
      (index) => '第$index段。${'春风拂过书页。' * 20}',
    ).join('\n\n');
    final old = cache.paginate(
      chapterId: 'anchor',
      title: '测试',
      content: content,
      layout: layout(1),
      indent: true,
    );
    final anchor = old.pages[3].position('anchor');
    final larger = cache.paginate(
      chapterId: 'anchor',
      title: '测试',
      content: content,
      layout: layout(1.4, width: 320),
      indent: true,
    );
    final page = larger.pages[larger.pageFor(anchor)];
    expect(
      page.fragments.any(
        (fragment) =>
            fragment.paragraphIndex == anchor.paragraphIndex &&
            fragment.startOffset <= anchor.characterOffset &&
            fragment.endOffset > anchor.characterOffset,
      ),
      isTrue,
    );
  });

  test('layout cache is bounded and reuses a prepared chapter', () {
    final cache = ReaderPaginationCache(capacity: 3);
    ReaderChapterPages prepare(String id) => cache.paginate(
      chapterId: id,
      title: id,
      content: '测试正文' * 50,
      layout: layout(1),
      indent: true,
    );
    final first = prepare('first');
    expect(identical(first, prepare('first')), isTrue);
    for (var index = 0; index < 8; index++) {
      prepare('$index');
    }
    expect(cache.length, 3);
    expect(identical(first, prepare('first')), isFalse);
  });

  test(
    'position writes are ordered and support old or invalid records',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = ReaderPositionService();
      final first = const ReadingPosition(
        chapterId: 'first',
        paragraphIndex: 3,
        characterOffset: 40,
      );
      final latest = const ReadingPosition(
        chapterId: 'last',
        paragraphIndex: 6,
        characterOffset: 80,
        viewportFraction: 0.2,
      );
      final writes = [
        service.save('book', first),
        service.save('book', latest),
      ];
      await Future.wait(writes);
      final restored = await service.load('book');
      expect(restored?.toJson(), latest.toJson());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reader_position_book',
        '{"chapter_id":"old","paragraph_index":2}',
      );
      expect((await service.load('book'))?.characterOffset, 0);
      await prefs.setString('reader_position_book', 'broken');
      expect(await service.load('book'), isNull);
    },
  );
  test('dual column fills both columns and keeps fragment continuity', () {
    final content = List.generate(
      60,
      (i) => '双栏验证第$i段，这是一段足够长的正文，用来填满左右两栏并检验跨栏连续性。',
    ).join('\n\n');
    ReaderChapterPages prepare(int columns) => ReaderPaginationCache().paginate(
      chapterId: 'dual',
      title: '双栏',
      content: content,
      layout: layout(1, width: 840, columns: columns),
      indent: true,
    );
    final single = prepare(1);
    final dual = prepare(2);
    // 双栏不减少每页总容量（栏宽减半、两栏并排），页数与单栏相当；
    // 除末页外每页都应占满两栏。
    expect(
      dual.pages.length,
      inInclusiveRange(single.pages.length - 1, single.pages.length + 3),
    );
    expect(dual.pages.length, greaterThan(1));
    for (final page in dual.pages.take(dual.pages.length - 1)) {
      expect(page.columnSpans.length, 2);
      expect(page.columnSpans.first, greaterThan(0));
      expect(page.columnSpans.last, greaterThan(0));
    }
    for (final page in dual.pages) {
      expect(page.columnSpans.length, inInclusiveRange(1, 2));
      expect(page.columnSpans.reduce((a, b) => a + b), page.fragments.length);
    }
    // 跨页跨栏的原文片段保持连续：上一片尾 = 下一片头。
    final all = dual.pages.expand((p) => p.fragments).toList();
    for (var i = 1; i < all.length; i++) {
      final previous = all[i - 1];
      final next = all[i];
      if (previous.image != null || next.image != null) continue;
      expect(
        next.startOffset == (previous.paragraphIndex == next.paragraphIndex
            ? previous.endOffset
            : 0),
        true,
        reason: 'fragment $i offset gap',
      );
    }
    // 重新排版后锚点定位仍能找到正确的双栏页。
    final anchor = ReadingPosition(
      chapterId: 'dual',
      paragraphIndex: 30,
      characterOffset: 5,
    );
    final page = dual.pageFor(anchor);
    expect(
      dual.pages[page].fragments.any(
        (f) =>
            f.paragraphIndex > 30 ||
            (f.paragraphIndex == 30 && f.endOffset > 5),
      ),
      true,
    );
  });
}
