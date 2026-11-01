import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/bookmark.dart';

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
}
