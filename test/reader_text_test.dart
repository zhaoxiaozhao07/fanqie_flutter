import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/reader_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only exact duplicate headings are removed, not similar body text', () {
    expect(ReaderText.paragraphs('第1章 少年\n正文', chapterTitle: '第1章 少年'), ['正文']);
    expect(ReaderText.paragraphs('少年。\n前行。', chapterTitle: '第1章 少年'), [
      '少年。',
      '前行。',
    ]);
    expect(ReaderText.paragraphs('第一章写到这里。\n继续。'), ['第一章写到这里。', '继续。']);
  });
  test('display indentation does not change canonical paragraph offsets', () {
    const text = '第一段\n\n第二段文本';
    final shown = ReaderText.display(text);
    expect(ReaderText.paragraphs(shown), ReaderText.paragraphs(text));
    final position = ReaderText.positionForOffset('chapter', text, 7);
    expect(position.paragraphIndex, 1);
    expect(position.characterOffset, 2);
    expect(ReaderText.offsetForPosition(text, position), 7);
  });
  test('invalid offsets clamp to complete graphemes', () {
    const text = '甲👩🏽‍💻乙';
    expect(ReaderText.safeOffset(text, 2), 1);
    expect(ReaderText.safeOffset(text, -5), 0);
    expect(ReaderText.safeOffset(text, 999), text.length);
    expect(
      ReaderText.offsetForPosition(
        text,
        const ReadingPosition(chapterId: 'c', characterOffset: 3),
      ),
      1,
    );
  });
}
