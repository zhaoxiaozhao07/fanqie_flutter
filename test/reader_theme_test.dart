import 'package:fanqie_flutter/models/reader_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  test('appended palettes provide readable roles and explicit brightness', () {
    expect(ReaderTheme.presets, hasLength(9));
    for (var i = 5; i < 9; i++) {
      final theme = ReaderTheme.presets[i];
      expect(
        theme.systemBrightness,
        i == 8 ? Brightness.dark : Brightness.light,
      );
      expect(
        contrast(theme.textColor, theme.backgroundColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(theme.secondaryColor, theme.backgroundColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(theme.textColor, theme.highlightColor),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(theme.secondaryColor, theme.highlightColor),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  for (final (background, foreground) in [
    (0xFFFFFFFF, 0xFF767676), // 4.542:1, just above the body threshold.
    (0xFF767676, 0xFFFFFFFF),
    (0xFFFFFFFF, 0xFF000000),
    (0xFF000000, 0xFFFFFFFF),
    (0xFF25221F, 0xFFCCC2B3),
  ]) {
    test(
      'custom $background/$foreground keeps secondary and highlight readable',
      () {
        final theme = ReaderTheme.presets[1].withColors(
          background: background,
          text: foreground,
        );
        expect(theme.backgroundColor.toARGB32(), background);
        expect(theme.textColor.toARGB32(), foreground);
        expect(theme.contrastRatio, greaterThanOrEqualTo(4.5));
        expect(
          contrast(theme.secondaryColor, theme.backgroundColor),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.textColor, theme.highlightColor),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.secondaryColor, theme.highlightColor),
          greaterThanOrEqualTo(4.5),
        );
      },
    );
  }

  for (final theme in ReaderTheme.presets) {
    test(
      '${theme.name} body, secondary text and highlighted text meet 4.5:1',
      () {
        expect(
          contrast(theme.textColor, theme.backgroundColor),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.secondaryColor, theme.backgroundColor),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.textColor, theme.highlightColor),
          greaterThanOrEqualTo(4.5),
        );
        expect(theme.materialTheme.brightness, theme.systemBrightness);
      },
    );
  }
}
