import 'dart:math' as math;

import 'package:flutter/material.dart';

/// PageView 负责位移；正文独立缓存，动画只更新合成图层。
class ReaderPageTransition extends StatelessWidget {
  final PageController controller;
  final int pageIndex;
  final double width;
  final String mode;
  final bool isDark;
  final Widget child;

  const ReaderPageTransition({
    super.key,
    required this.controller,
    required this.pageIndex,
    required this.width,
    required this.mode,
    this.isDark = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final page = RepaintBoundary(child: child);

    // 原生滑动不额外缩放正文，避免文字在拖动中反复栅格化、忽大忽小。
    if (mode == 'slide') return page;

    return AnimatedBuilder(
      animation: controller,
      child: page,
      builder: (context, staticPage) {
        final position =
            controller.hasClients && controller.position.haveDimensions
            ? controller.page ?? controller.initialPage.toDouble()
            : controller.initialPage.toDouble();
        final delta = pageIndex - position;

        if (mode == 'fade') {
          // 抵消 PageView 的位移，让两页在同一位置交融，不再附带抖动的视差。
          return Transform.translate(
            offset: Offset(-delta * width, 0),
            child: Opacity(
              opacity: Curves.easeInOut.transform(
                (1.0 - delta.abs()).clamp(0.0, 1.0),
              ),
              child: staticPage,
            ),
          );
        }

        final incoming = delta.clamp(0.0, 1.0);
        final shadowOpacity = math.sin(incoming * math.pi).clamp(0.0, 1.0);

        // 保持整个动画的组件树不变，起止帧也不拆装正文或改变裁剪层级。
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: Offset(-incoming * width, 0),
                child: staticPage,
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 12,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: shadowOpacity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withValues(
                              alpha: isDark ? 0.16 : 0.12,
                            ),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
