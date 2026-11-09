import 'package:characters/characters.dart';
import 'reader_text.dart';

/// Retreat only: typography must never move a character past the measured
/// page's capacity or split a grapheme. Tiny/oversized pages still make progress.
class ReaderTypography {
  static const _opening = '（([｛{【《〈「『“‘〔〖〘〚';
  static const _closing = '）)]｝}】》〉」』”’〕〗〙〛，。、；：？！,.!?;:％%';

  static int safePageEnd(String text, int proposed, {int minimum = 0}) {
    var end = ReaderText.safeOffset(text, proposed.clamp(0, text.length));
    final lower = ReaderText.safeOffset(text, minimum.clamp(0, end));
    if (end == text.length) return end;
    // Long runs of punctuation cannot starve a page.
    for (var attempts = 0; attempts < 8 && end > lower; attempts++) {
      final before = text.substring(0, end).characters.last;
      final after = text.substring(end).characters.first;
      if (!_opening.contains(before) && !_closing.contains(after)) break;
      final next = end - before.length;
      if (next <= lower) break;
      end = next;
    }
    return end;
  }
}
