import 'dart:math' as math;
import '../services/note_anchor_resolver.dart';
import '../services/reader_text.dart';

class ReaderSelectionPart {
  final int chapter, paragraph, start, end;
  final String source;
  const ReaderSelectionPart(
    this.chapter,
    this.paragraph,
    this.start,
    this.end,
    this.source,
  );
}

class ReadingSelection {
  final int chapter, firstParagraph, lastParagraph, start, end;
  final String text, prefix, suffix, chapterHash;
  const ReadingSelection._(
    this.chapter,
    this.firstParagraph,
    this.lastParagraph,
    this.start,
    this.end,
    this.text,
    this.prefix,
    this.suffix,
    this.chapterHash,
  );
  factory ReadingSelection.capture(
    List<ReaderSelectionPart> parts,
    List<String> paragraphs,
  ) {
    if (parts.isEmpty) throw const FormatException('请选择原文');
    final ordered = [...parts]
      ..sort((a, b) {
        final p = a.paragraph.compareTo(b.paragraph);
        return p != 0 ? p : a.start.compareTo(b.start);
      });
    final chapter = ordered.first.chapter;
    final merged = <ReaderSelectionPart>[];
    for (final part in ordered) {
      if (part.chapter != chapter) {
        throw const FormatException('跨章选区仅复制；批注请分章选择');
      }
      if (part.paragraph < 0 ||
          part.paragraph >= paragraphs.length ||
          part.source != paragraphs[part.paragraph].trim() ||
          part.start < 0 ||
          part.end <= part.start ||
          part.end > part.source.length ||
          ReaderText.safeOffset(part.source, part.start) != part.start ||
          ReaderText.safeOffset(part.source, part.end) != part.end) {
        throw const FormatException('原文已变化或字素范围无效，请重新选择');
      }
      if (merged.isNotEmpty && merged.last.paragraph == part.paragraph) {
        final last = merged.removeLast();
        if (part.start > last.end) {
          throw const FormatException('选区存在未覆盖原文，暂仅支持复制');
        }
        merged.add(
          ReaderSelectionPart(
            chapter,
            part.paragraph,
            last.start,
            math.max(last.end, part.end),
            part.source,
          ),
        );
      } else {
        merged.add(part);
      }
    }
    final first = merged.first, last = merged.last;
    final byParagraph = {for (final part in merged) part.paragraph: part};
    for (var p = first.paragraph; p <= last.paragraph; p++) {
      final source = paragraphs[p].trim();
      if (source.isEmpty) {
        continue; // An image is not fabricated into source text.
      }
      final part = byParagraph[p];
      if (part == null ||
          (p != first.paragraph && part.start != 0) ||
          (p != last.paragraph && part.end != source.length)) {
        throw const FormatException('选区不连续；请完整选择中间原文后再批注');
      }
    }
    final text = NoteAnchorResolver.quotation(
      paragraphs,
      first.paragraph,
      first.start,
      last.paragraph,
      last.end,
    );
    if (text == null || text.isEmpty || text.length > 20000) {
      throw const FormatException('批注选区最多 20000 个字符；可分段批注或先复制');
    }
    final before = ReaderText.safeOffset(
      first.source,
      math.max(0, first.start - 24),
    );
    final after = ReaderText.safeOffset(
      last.source,
      math.min(last.source.length, last.end + 24),
    );
    return ReadingSelection._(
      chapter,
      first.paragraph,
      last.paragraph,
      first.start,
      last.end,
      text,
      first.source.substring(before, first.start),
      last.source.substring(last.end, after),
      NoteAnchorResolver.digest(paragraphs),
    );
  }
}
