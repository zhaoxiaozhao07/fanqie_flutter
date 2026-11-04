import 'package:characters/characters.dart';

import '../models/reading_position.dart';

/// Shared canonical paragraphs for display, search, speech and annotations.
/// Offsets are UTF-16 offsets in trimmed source paragraphs, not indented spans.
class ReaderText {
  /// Stored only for a real image-only EPUB chapter; never spoken or searched.
  static const imageOnlyMarker = '\uFFFC';

  static List<String> paragraphs(String raw, {String? chapterTitle}) {
    if (raw.trim() == imageOnlyMarker) return const [''];
    final result = <String>[];
    final title = _normalize(chapterTitle ?? '');
    var first = true;
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (first) {
        first = false;
        final normalized = _normalize(text);
        // A short sentence that merely occurs in the title is still body text.
        if (title.isNotEmpty && normalized == title) {
          continue;
        }
        final bareHeading = RegExp(
          r'^第[0-9一二三四五六七八九十百千万零两]+[章卷回节集]$',
        ).hasMatch(normalized);
        if (bareHeading && title.startsWith(normalized)) continue;
      }
      result.add(text);
    }
    return result;
  }

  /// Convert an offset in an extracted/split chapter into the same paragraph
  /// coordinates used by the reader, without inserting image paths into text.
  static ReadingPosition positionInRaw(
    String raw,
    int offset, {
    String? chapterTitle,
  }) {
    final title = _normalize(chapterTitle ?? '');
    var rawStart = 0, index = 0, previousLength = 0;
    var first = true;
    for (final line in raw.split('\n')) {
      final text = line.trim();
      final lineStart = rawStart;
      rawStart += line.length + 1;
      if (text.isEmpty) continue;
      if (first) {
        first = false;
        final normalized = _normalize(text);
        if (title.isNotEmpty &&
            (normalized == title ||
                (RegExp(
                      r'^第[0-9一二三四五六七八九十百千万零两]+[章卷回节集]$',
                    ).hasMatch(normalized) &&
                    title.startsWith(normalized)))) {
          continue;
        }
      }
      final trimStart = lineStart + line.length - line.trimLeft().length;
      if (offset <= trimStart + text.length) {
        return ReadingPosition(
          chapterId: '',
          paragraphIndex: index,
          characterOffset: safeOffset(
            text,
            (offset - trimStart).clamp(0, text.length),
          ),
        );
      }
      previousLength = text.length;
      index++;
    }
    return ReadingPosition(
      chapterId: '',
      paragraphIndex: index == 0 ? 0 : index - 1,
      characterOffset: previousLength,
    );
  }

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '').toLowerCase();

  static int safeOffset(String text, int requested) {
    final target = requested.clamp(0, text.length);
    var offset = 0;
    for (final character in text.characters) {
      if (offset + character.length > target) break;
      offset += character.length;
      if (offset == target) break;
    }
    return offset;
  }

  static String display(String raw, {String? chapterTitle}) => paragraphs(
    raw,
    chapterTitle: chapterTitle,
  ).map((paragraph) => '\u3000\u3000$paragraph').join('\n\n');

  static ReadingPosition positionForOffset(
    String chapterId,
    String canonicalText,
    int offset,
  ) {
    final parts = canonicalText.split('\n\n');
    var remaining = offset.clamp(0, canonicalText.length);
    for (var index = 0; index < parts.length; index++) {
      if (remaining <= parts[index].length || index == parts.length - 1) {
        return ReadingPosition(
          chapterId: chapterId,
          paragraphIndex: index,
          characterOffset: remaining.clamp(0, parts[index].length),
        );
      }
      remaining = (remaining - parts[index].length - 2).clamp(
        0,
        canonicalText.length,
      );
    }
    return ReadingPosition(chapterId: chapterId);
  }

  static int offsetForPosition(String canonicalText, ReadingPosition position) {
    final parts = canonicalText.split('\n\n');
    final paragraph = position.paragraphIndex.clamp(0, parts.length - 1);
    var offset = 0;
    for (var index = 0; index < paragraph; index++) {
      offset += parts[index].length + 2;
    }
    return offset + safeOffset(parts[paragraph], position.characterOffset);
  }
}
