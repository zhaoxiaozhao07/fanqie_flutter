import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 气泡只占段尾的内联空间，分页测量与实际渲染使用同一尺寸。
class ReaderCommentBubble extends StatelessWidget {
  static const countStyle = TextStyle(
    fontSize: 10,
    height: 1.1,
    fontWeight: FontWeight.w600,
    fontFamily: 'Roboto',
    letterSpacing: 0,
    wordSpacing: 0,
  );

  final int count;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onTap;
  final VoidCallback onTapDown;

  const ReaderCommentBubble({
    super.key,
    required this.count,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
    required this.onTapDown,
  });

  static Size sizeFor(TextScaler scaler, {int count = 9999}) {
    final painter = TextPainter(
      text: TextSpan(text: count > 999 ? '999+' : '$count', style: countStyle),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    try {
      return Size(
        (6 + 8 + 12 + 2 + painter.width).ceilToDouble(),
        math.max(24, painter.height + 4).ceilToDouble(),
      );
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          label: '段评 $count 条',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => onTapDown(),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 12,
                    color: foregroundColor,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    count > 999 ? '999+' : '$count',
                    style: countStyle.copyWith(color: foregroundColor),
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
