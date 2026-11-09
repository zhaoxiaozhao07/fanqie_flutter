import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../models/reader_settings.dart';

/// Physical viewport and columns are presentation only; canonical text anchors
/// and chapter IDs remain unchanged when the window or layout mode changes.
class DesktopReaderLayout {
  static const gutter = 24.0;
  final int columns;
  final double width;

  const DesktopReaderLayout(this.columns, this.width);

  factory DesktopReaderLayout.resolve(
    double availableWidth,
    ReaderSettings settings,
    TextScaler scaler, {
    bool immersive = false,
  }) {
    final minimumColumn = math.max(
      360.0,
      scaler.scale(settings.fontSize) * 14 + settings.horizontalPadding * 2,
    );
    final gap = settings.columnGap;
    final fits = (availableWidth - gap) / 2 >= minimumColumn;
    final wantsDouble =
        settings.pageMode &&
        settings.desktopColumns != 'single' &&
        (settings.desktopColumns == 'double' || availableWidth >= 1000);
    final preferredColumn = settings.lineCharacters == 0
        ? double.infinity
        : math.max(
            minimumColumn,
            scaler.scale(settings.fontSize) * settings.lineCharacters +
                settings.letterSpacing * settings.lineCharacters +
                settings.horizontalPadding * 2,
          );
    return wantsDouble && fits
        ? DesktopReaderLayout(
            2,
            math.min(availableWidth, preferredColumn * 2 + gap),
          )
        : DesktopReaderLayout(
            1,
            math.min(
              preferredColumn,
              immersive ? availableWidth : math.min(840.0, availableWidth),
            ),
          );
  }
}
