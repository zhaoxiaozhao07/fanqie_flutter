import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Keep the clock, battery and progress together at the safe lower-right edge.
/// A loose Flexible in the outer Row would leave unused width after the group.
class ReaderStatusBar extends StatelessWidget {
  final String chapterLabel;
  final String clockLabel;
  final String clockSemantics;
  final String progressLabel;
  final String progressSemantics;
  final Color backgroundColor;
  final Color textColor;

  const ReaderStatusBar({
    super.key,
    required this.chapterLabel,
    required this.clockLabel,
    required this.clockSemantics,
    required this.progressLabel,
    required this.progressSemantics,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('reader-status-bar'),
    height: math.max(22, MediaQuery.textScalerOf(context).scale(10) * 1.4 + 4),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    color: backgroundColor,
    child: LayoutBuilder(
      builder: (context, bounds) {
        final style = TextStyle(fontSize: 10, height: 1.2, color: textColor);
        return Row(
          children: [
            Expanded(
              child: Text(
                chapterLabel,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: bounds.maxWidth * .72),
              child: FittedBox(
                key: const ValueKey('reader-status-info'),
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      clockLabel,
                      style: style,
                      semanticsLabel: clockSemantics,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      progressLabel,
                      style: style,
                      semanticsLabel: progressSemantics,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
