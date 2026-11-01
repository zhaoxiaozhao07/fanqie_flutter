import 'package:fanqie_flutter/models/reader_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
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
