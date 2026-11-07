import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/bookmark.dart';
import 'reader_text.dart';

class ResolvedNote {
  final ReadingNote note;
  final int paragraphIndex, start, end;
  final bool relocated;
  const ResolvedNote(
    this.note,
    this.paragraphIndex,
    this.start,
    this.end, {
    this.relocated = false,
  });
}

class NoteAnchorResolver {
  static String digest(List<String> paragraphs) => sha256
      .convert(utf8.encode(paragraphs.map((p) => p.trim()).join('\n\n')))
      .toString();

  static ResolvedNote? resolve(
    ReadingNote note,
    List<String> paragraphs, {
    String? chapterHash,
  }) {
    if (note.isSpanning) {
      return resolveAll(
        note,
        paragraphs,
        chapterHash: chapterHash,
      )?.firstOrNull;
    }
    final index = note.paragraphIndex;
    final hash = chapterHash ?? digest(paragraphs);
    if (note.chapterHash.isNotEmpty &&
        note.chapterHash == hash &&
        index >= 0 &&
        index < paragraphs.length &&
        note.startOffset >= 0 &&
        note.endOffset > note.startOffset &&
        note.endOffset <= paragraphs[index].trim().length &&
        paragraphs[index].trim().substring(note.startOffset, note.endOffset) ==
            note.text) {
      return ResolvedNote(note, index, note.startOffset, note.endOffset);
    }
    if (note.text.isEmpty) return null;
    final candidates = <ResolvedNote>[];
    for (var i = 0; i < paragraphs.length; i++) {
      final text = paragraphs[i].trim();
      var start = text.indexOf(note.text);
      while (start >= 0) {
        final end = start + note.text.length;
        if ((note.prefix.isEmpty ||
                text.substring(0, start).endsWith(note.prefix)) &&
            (note.suffix.isEmpty ||
                text.substring(end).startsWith(note.suffix))) {
          candidates.add(ResolvedNote(note, i, start, end, relocated: true));
        }
        start = text.indexOf(note.text, start + 1);
      }
    }
    // Never guess which identical quotation was selected after a content edit.
    return candidates.length == 1 ? candidates.single : null;
  }

  static String? quotation(
    List<String> paragraphs,
    int first,
    int start,
    int last,
    int end,
  ) {
    if (first < 0 || last < first || last >= paragraphs.length) return null;
    final a = paragraphs[first].trim(), b = paragraphs[last].trim();
    if (start < 0 ||
        start > a.length ||
        end < 0 ||
        end > b.length ||
        ReaderText.safeOffset(a, start) != start ||
        ReaderText.safeOffset(b, end) != end ||
        (first == last && end <= start)) {
      return null;
    }
    if (first == last) return a.substring(start, end);
    return [
      a.substring(start),
      ...paragraphs.sublist(first + 1, last).map((e) => e.trim()),
      b.substring(0, end),
    ].join('\n\n');
  }

  static List<ResolvedNote>? resolveAll(
    ReadingNote note,
    List<String> paragraphs, {
    String? chapterHash,
  }) {
    if (!note.isSpanning) {
      final resolved = resolve(note, paragraphs, chapterHash: chapterHash);
      return resolved == null ? null : [resolved];
    }
    if (!note.validAnchor || note.text.length > 20000) return null;
    final hash = chapterHash ?? digest(paragraphs);
    List<ResolvedNote> expand(
      int first,
      int start,
      int last,
      int end,
      bool relocated,
    ) => List.unmodifiable([
      for (var p = first; p <= last; p++)
        if ((p == last ? end : paragraphs[p].trim().length) >
            (p == first ? start : 0))
          ResolvedNote(
            note,
            p,
            p == first ? start : 0,
            p == last ? end : paragraphs[p].trim().length,
            relocated: relocated,
          ),
    ]);
    final exact = quotation(
      paragraphs,
      note.paragraphIndex,
      note.startOffset,
      note.endParagraphIndex,
      note.endOffset,
    );
    if (note.chapterHash.isNotEmpty &&
        hash == note.chapterHash &&
        exact == note.text) {
      return expand(
        note.paragraphIndex,
        note.startOffset,
        note.endParagraphIndex,
        note.endOffset,
        false,
      );
    }
    final source = paragraphs.map((e) => e.trim()).toList();
    final flat = source.join('\n\n');
    final starts = <int>[];
    var offset = 0;
    for (final paragraph in source) {
      starts.add(offset);
      offset += paragraph.length + 2;
    }
    (int, int)? position(int offset) {
      for (var i = 0; i < source.length; i++) {
        if (offset >= starts[i] && offset <= starts[i] + source[i].length) {
          return (i, offset - starts[i]);
        }
      }
      return null;
    }

    List<ResolvedNote>? candidate;
    var at = flat.indexOf(note.text);
    while (at >= 0) {
      final end = at + note.text.length;
      if ((note.prefix.isEmpty ||
              flat.substring(0, at).endsWith(note.prefix)) &&
          (note.suffix.isEmpty ||
              flat.substring(end).startsWith(note.suffix))) {
        final a = position(at), b = position(end);
        if (a != null &&
            b != null &&
            quotation(source, a.$1, a.$2, b.$1, b.$2) == note.text) {
          if (candidate != null) return null;
          candidate = expand(a.$1, a.$2, b.$1, b.$2, true);
        }
      }
      at = flat.indexOf(note.text, at + 1);
    }
    return candidate;
  }
}
