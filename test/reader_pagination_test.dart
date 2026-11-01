import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/widgets/reader_comment_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReaderLayout layout(double scale, {double width = 400, bool comments = true}) =>
    ReaderLayout(
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
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scale in [1.0, 1.4, 2.0]) {
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
}
