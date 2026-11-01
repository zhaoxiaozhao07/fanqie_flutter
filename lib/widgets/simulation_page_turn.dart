import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 真实仿真翻页组件
/// 支持四个角（右上、右下、左上、左下）随手指拖拽实时弯曲折叠翻页，
/// 严格满足折纸几何学、Sutherland-Hodgman 无闪烁凸多边形裁剪、
/// 翻页背面镜像反转文字展示与立体光影渲染。
class SimulationPageTurn extends StatefulWidget {
  final int totalPages;
  final int currentPageIndex;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Widget? nextChapterPreview;
  final Widget? previousChapterPreview;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final VoidCallback? onCenterTap;
  final Color backgroundColor;
  final bool isDark;
  final DateTime Function()? lastBubbleTapTimeGetter;

  const SimulationPageTurn({
    super.key,
    required this.totalPages,
    required this.currentPageIndex,
    required this.pageBuilder,
    this.nextChapterPreview,
    this.previousChapterPreview,
    required this.onPageChanged,
    this.onPreviousChapter,
    this.onNextChapter,
    this.onCenterTap,
    required this.backgroundColor,
    this.isDark = false,
    this.lastBubbleTapTimeGetter,
  });

  @override
  State<SimulationPageTurn> createState() => SimulationPageTurnState();
}

enum _TurnCorner {
  topRight,
  bottomRight,
  topLeft,
  bottomLeft,
}

class SimulationPageTurnState extends State<SimulationPageTurn>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late CurvedAnimation _curvedAnim;
  Animation<Offset>? _dragAnimation;

  // 翻页状态
  bool _isDragging = false;
  bool _isForward = true; // true: 下一页; false: 上一页
  _TurnCorner _corner = _TurnCorner.bottomRight;
  Offset? _cornerPos; // 原始角点 C
  Offset? _dragPos; // 当前手指拖拽点 A
  Size _viewSize = Size.zero;

  // 触控判定
  Offset? _downPos;
  DateTime _downTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(() {
        if (_dragAnimation != null) {
          setState(() {
            _dragPos = _dragAnimation!.value;
          });
        }
      });
    _curvedAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _curvedAnim.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// 外部调用：平滑翻到上一页
  void turnToPreviousPage() {
    if (_animController.isAnimating || _isDragging) return;
    if (widget.currentPageIndex <= 0) {
      widget.onPreviousChapter?.call();
      return;
    }
    _startAutoTurn(forward: false, fromTop: false);
  }

  /// 外部调用：平滑翻到下一页
  void turnToNextPage() {
    if (_animController.isAnimating || _isDragging) return;
    if (widget.currentPageIndex >= widget.totalPages - 1) {
      widget.onNextChapter?.call();
      return;
    }
    _startAutoTurn(forward: true, fromTop: false);
  }

  void _startAutoTurn({required bool forward, required bool fromTop}) {
    final w = _viewSize.width > 0 ? _viewSize.width : MediaQuery.of(context).size.width;
    final h = _viewSize.height > 0 ? _viewSize.height : MediaQuery.of(context).size.height;

    _isForward = forward;
    _isDragging = false;
    if (forward) {
      _corner = fromTop ? _TurnCorner.topRight : _TurnCorner.bottomRight;
      _cornerPos = fromTop ? Offset(w, 0) : Offset(w, h);
      _dragPos = _cornerPos! - Offset(4.0, fromTop ? -4.0 : 4.0);

      // 折痕为中垂线 Mx = (Cx + Ax)/2，Ax 须移动至 -w * 1.2 以使折痕完全移出左边界
      final endPos = fromTop ? Offset(-w * 1.25, 0) : Offset(-w * 1.25, h);
      _runAnimation(from: _dragPos!, to: endPos, completePageTurn: true);
    } else {
      _corner = fromTop ? _TurnCorner.topLeft : _TurnCorner.bottomLeft;
      _cornerPos = fromTop ? const Offset(0, 0) : Offset(0, h);
      _dragPos = _cornerPos! + Offset(4.0, fromTop ? 4.0 : -4.0);

      // 折痕为中垂线 Mx = Ax/2，Ax 须移动至 w * 2.25 以使折痕完全移出右边界
      final endPos = fromTop ? Offset(w * 2.25, 0) : Offset(w * 2.25, h);
      _runAnimation(from: _dragPos!, to: endPos, completePageTurn: true);
    }
  }

  void _runAnimation({
    required Offset from,
    required Offset to,
    required bool completePageTurn,
  }) {
    _animController.reset();
    _dragAnimation = Tween<Offset>(begin: from, end: to).animate(_curvedAnim);

    _animController.forward().then((_) {
      if (!mounted) return;
      if (completePageTurn) {
        final targetIndex = _isForward
            ? widget.currentPageIndex + 1
            : widget.currentPageIndex - 1;
        if (targetIndex >= 0 && targetIndex < widget.totalPages) {
          widget.onPageChanged(targetIndex);
        } else if (_isForward) {
          widget.onNextChapter?.call();
        } else {
          widget.onPreviousChapter?.call();
        }
      }
      setState(() {
        _isDragging = false;
        _dragPos = null;
        _cornerPos = null;
      });
    });
  }

  void _onPointerDown(PointerDownEvent event, BoxConstraints constraints) {
    if (_animController.isAnimating) {
      _animController.stop();
    }
    _downPos = event.localPosition;
    _downTime = DateTime.now();
    _isDragging = false;
  }

  void _onPointerMove(PointerMoveEvent event, BoxConstraints constraints) {
    if (_downPos == null) return;
    final pos = event.localPosition;
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;

    final moveDist = (pos - _downPos!).distance;
    if (!_isDragging) {
      if (moveDist < 4.0) return;

      // 屏幕中央留给呼出菜单
      if (_downPos!.dx > w * 0.28 && _downPos!.dx < w * 0.72) {
        return;
      }

      if (_downPos!.dx >= w * 0.5) {
        _isForward = true;
        if (_downPos!.dy < h * 0.5) {
          _corner = _TurnCorner.topRight;
          _cornerPos = Offset(w, 0);
        } else {
          _corner = _TurnCorner.bottomRight;
          _cornerPos = Offset(w, h);
        }
      } else {
        _isForward = false;
        if (_downPos!.dy < h * 0.5) {
          _corner = _TurnCorner.topLeft;
          _cornerPos = const Offset(0, 0);
        } else {
          _corner = _TurnCorner.bottomLeft;
          _cornerPos = Offset(0, h);
        }
      }
      _isDragging = true;
    }

    if (!_isDragging || _cornerPos == null) return;

    double clampedX = pos.dx;
    double clampedY = pos.dy;

    if (_isForward) {
      clampedX = clampedX.clamp(-w * 0.35, w);
      if (_corner == _TurnCorner.bottomRight) {
        clampedY = clampedY.clamp(0.0, h + 20.0);
        final distToOrigin = (Offset(clampedX, clampedY) - Offset(0, h)).distance;
        if (distToOrigin > w) {
          final dir = (Offset(clampedX, clampedY) - Offset(0, h)) / distToOrigin;
          final adjusted = Offset(0, h) + dir * w;
          clampedX = adjusted.dx;
          clampedY = adjusted.dy;
        }
      } else {
        clampedY = clampedY.clamp(-20.0, h);
        final distToOrigin = (Offset(clampedX, clampedY) - Offset(0, 0)).distance;
        if (distToOrigin > w) {
          final dir = (Offset(clampedX, clampedY) - Offset(0, 0)) / distToOrigin;
          final adjusted = Offset(0, 0) + dir * w;
          clampedX = adjusted.dx;
          clampedY = adjusted.dy;
        }
      }
    } else {
      clampedX = clampedX.clamp(0.0, w * 1.35);
      if (_corner == _TurnCorner.bottomLeft) {
        clampedY = clampedY.clamp(0.0, h + 20.0);
        final distToOrigin = (Offset(clampedX, clampedY) - Offset(w, h)).distance;
        if (distToOrigin > w) {
          final dir = (Offset(clampedX, clampedY) - Offset(w, h)) / distToOrigin;
          final adjusted = Offset(w, h) + dir * w;
          clampedX = adjusted.dx;
          clampedY = adjusted.dy;
        }
      } else {
        clampedY = clampedY.clamp(-20.0, h);
        final distToOrigin = (Offset(clampedX, clampedY) - Offset(w, 0)).distance;
        if (distToOrigin > w) {
          final dir = (Offset(clampedX, clampedY) - Offset(w, 0)) / distToOrigin;
          final adjusted = Offset(w, 0) + dir * w;
          clampedX = adjusted.dx;
          clampedY = adjusted.dy;
        }
      }
    }

    setState(() {
      _dragPos = Offset(clampedX, clampedY);
    });
  }

  void _onPointerUp(PointerUpEvent event, BoxConstraints constraints) {
    if (_downPos == null) return;
    final pos = event.localPosition;
    final w = constraints.maxWidth;
    final h = constraints.maxHeight;

    if (!_isDragging) {
      final tapDist = (pos - _downPos!).distance;
      if (tapDist < 12.0 && DateTime.now().difference(_downTime).inMilliseconds < 500) {
        _handleTapAt(pos, constraints);
      }
      _downPos = null;
      return;
    }

    if (_dragPos == null || _cornerPos == null) {
      _isDragging = false;
      _downPos = null;
      return;
    }

    final currentPos = _dragPos!;
    if (_isForward) {
      final draggedDistance = _cornerPos!.dx - currentPos.dx;
      final shouldTurn = draggedDistance > w * 0.18;

      if (shouldTurn) {
        final targetY = _corner == _TurnCorner.topRight ? 0.0 : h;
        _runAnimation(from: currentPos, to: Offset(-w * 1.25, targetY), completePageTurn: true);
      } else {
        _runAnimation(from: currentPos, to: _cornerPos!, completePageTurn: false);
      }
    } else {
      final draggedDistance = currentPos.dx - _cornerPos!.dx;
      final shouldTurn = draggedDistance > w * 0.18;

      if (shouldTurn) {
        final targetY = _corner == _TurnCorner.topLeft ? 0.0 : h;
        _runAnimation(from: currentPos, to: Offset(w * 2.25, targetY), completePageTurn: true);
      } else {
        _runAnimation(from: currentPos, to: _cornerPos!, completePageTurn: false);
      }
    }
    _downPos = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_isDragging && _dragPos != null && _cornerPos != null) {
      _runAnimation(from: _dragPos!, to: _cornerPos!, completePageTurn: false);
    }
    _isDragging = false;
    _downPos = null;
  }

  void _handleTapAt(Offset pos, BoxConstraints constraints) {
    if (widget.lastBubbleTapTimeGetter != null) {
      final lastTap = widget.lastBubbleTapTimeGetter!();
      if (DateTime.now().difference(lastTap) < const Duration(milliseconds: 400)) {
        return;
      }
    }

    final w = constraints.maxWidth;
    final h = constraints.maxHeight;
    final fromTop = pos.dy < h * 0.5;

    if (pos.dx < w * 0.28) {
      if (widget.currentPageIndex > 0) {
        _startAutoTurn(forward: false, fromTop: fromTop);
      } else {
        widget.onPreviousChapter?.call();
      }
    } else if (pos.dx > w * 0.72) {
      if (widget.currentPageIndex < widget.totalPages - 1) {
        _startAutoTurn(forward: true, fromTop: fromTop);
      } else {
        widget.onNextChapter?.call();
      }
    } else {
      widget.onCenterTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        _viewSize = Size(w, h);

        final isCurling = (_isDragging || _animController.isAnimating) &&
            _dragPos != null &&
            _cornerPos != null &&
            (_dragPos! - _cornerPos!).distance > 2.0;

        // 未发生翻折静止状态：直接渲染当前页，保证 100% 准确呈现当前页正文
        if (!isCurling) {
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _onPointerDown(e, constraints),
            onPointerMove: (e) => _onPointerMove(e, constraints),
            onPointerUp: (e) => _onPointerUp(e, constraints),
            onPointerCancel: _onPointerCancel,
            child: SizedBox(
              width: w,
              height: h,
              child: widget.pageBuilder(context, widget.currentPageIndex),
            ),
          );
        }

        final corner = _cornerPos ?? Offset.zero;
        final drag = _dragPos ?? Offset.zero;

        final curlGeometry = _computeCurlGeometry(
          corner: corner,
          drag: drag,
          viewWidth: w,
          viewHeight: h,
        );

        if (curlGeometry == null) {
          return Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _onPointerDown(e, constraints),
            onPointerMove: (e) => _onPointerMove(e, constraints),
            onPointerUp: (e) => _onPointerUp(e, constraints),
            onPointerCancel: _onPointerCancel,
            child: SizedBox(
              width: w,
              height: h,
              child: widget.pageBuilder(context, widget.currentPageIndex),
            ),
          );
        }

        final int bottomPageIndex;
        final int topPageIndex;

        if (_isForward) {
          topPageIndex = widget.currentPageIndex;
          bottomPageIndex = widget.currentPageIndex + 1;
        } else {
          topPageIndex = widget.currentPageIndex - 1;
          bottomPageIndex = widget.currentPageIndex;
        }

        final topPageWidget = topPageIndex >= 0 && topPageIndex < widget.totalPages
            ? widget.pageBuilder(context, topPageIndex)
            : (topPageIndex < 0 && widget.previousChapterPreview != null
                ? widget.previousChapterPreview!
                : widget.pageBuilder(context, widget.currentPageIndex));

        final bottomPageWidget = bottomPageIndex >= 0 && bottomPageIndex < widget.totalPages
            ? widget.pageBuilder(context, bottomPageIndex)
            : (bottomPageIndex >= widget.totalPages && widget.nextChapterPreview != null
                ? widget.nextChapterPreview!
                : Container(color: widget.backgroundColor));

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _onPointerDown(e, constraints),
          onPointerMove: (e) => _onPointerMove(e, constraints),
          onPointerUp: (e) => _onPointerUp(e, constraints),
          onPointerCancel: _onPointerCancel,
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 底层页（露出的下一页或当前页）
                bottomPageWidget,

                // 1.1 底层页落影（被翻起书页投射在底页上的柔和暗影，营造悬浮立体深度）
                CustomPaint(
                  painter: _DropShadowPainter(
                    p1: curlGeometry.p1,
                    p2: curlGeometry.p2,
                    normal: curlGeometry.normal,
                    isDark: widget.isDark,
                  ),
                ),

                // 2. 当前页正面（未被折起部分，通过精确 Sutherland-Hodgman 算法裁剪）
                ClipPath(
                  clipper: _PolygonClipper(curlGeometry.frontPolygon),
                  child: topPageWidget,
                ),

                // 3. 当前页翻转背面（彻底消除重影：不透明纸质底色 + 淡墨反向微显 + 脊线高光暗影）
                ClipPath(
                  clipper: _PolygonClipper(curlGeometry.backPolygon),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 3.1 彻底遮盖底页的不透明纸质底色（彻底消灭两页文字叠加造成的重影！！）
                      ColoredBox(color: widget.backgroundColor),

                        // 3.2 纸背温润纸质微色调
                        ColoredBox(
                          color: (widget.isDark ? Colors.white10 : const Color(0xFFE8DFC8))
                              .withValues(alpha: widget.isDark ? 0.06 : 0.20),
                        ),

                        // 3.3 真实对称反射矩阵：当前页正文字符完全水平翻转（镜像），以透光微墨呈现
                        Opacity(
                          opacity: widget.isDark ? 0.22 : 0.16,
                          child: Transform(
                            transform: curlGeometry.reflectionMatrix,
                            child: topPageWidget,
                          ),
                        ),

                        // 3.4 沿折痕脊线的立体卷曲高光与凹折暗影（展现自然拱起弯曲）
                        CustomPaint(
                          painter: _SpineLightPainter(
                            p1: curlGeometry.p1,
                            p2: curlGeometry.p2,
                            normal: curlGeometry.normal,
                            isDark: widget.isDark,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 计算机图形学 Sutherland-Hodgman 凸多边形严谨裁剪算法
  /// 保证绝不产生自相交折点，绝不丢失交点，彻底消灭拉拽闪烁
  _CurlGeometry? _computeCurlGeometry({
    required Offset corner,
    required Offset drag,
    required double viewWidth,
    required double viewHeight,
  }) {
    final diff = drag - corner;
    final dist = diff.distance;
    if (dist < 1.0) return null;

    final mid = (corner + drag) / 2.0;
    final nx = diff.dx;
    final ny = diff.dy;
    final len = math.sqrt(nx * nx + ny * ny);
    if (len < 1e-4) return null;
    final ux = nx / len;
    final uy = ny / len;

    // 屏幕顺时针 4 个顶点
    final rectCorners = [
      const Offset(0, 0),
      Offset(viewWidth, 0),
      Offset(viewWidth, viewHeight),
      Offset(0, viewHeight),
    ];

    double eval(Offset p) => nx * (p.dx - mid.dx) + ny * (p.dy - mid.dy);

    final frontPolygon = <Offset>[];
    final curledPolygon = <Offset>[];
    final lineIntersections = <Offset>[];

    // Sutherland-Hodgman 顺时针边割循环
    for (int i = 0; i < 4; i++) {
      final s = rectCorners[i];
      final e = rectCorners[(i + 1) % 4];
      final valS = eval(s);
      final valE = eval(e);

      final isSInsideFront = valS >= 0;
      final isEInsideFront = valE >= 0;

      if (isSInsideFront && isEInsideFront) {
        frontPolygon.add(e);
      } else if (isSInsideFront && !isEInsideFront) {
        final t = valS / (valS - valE);
        final ip = s + (e - s) * t;
        frontPolygon.add(ip);
        curledPolygon.add(ip);
        lineIntersections.add(ip);
      } else if (!isSInsideFront && !isEInsideFront) {
        curledPolygon.add(e);
      } else if (!isSInsideFront && isEInsideFront) {
        final t = valS / (valS - valE);
        final ip = s + (e - s) * t;
        curledPolygon.add(ip);
        frontPolygon.add(ip);
        frontPolygon.add(e);
        lineIntersections.add(ip);
      }
    }

    if (lineIntersections.length < 2) return null;
    final p1 = lineIntersections[0];
    final p2 = lineIntersections[1];

    // 计算对称反射矩阵：点关于折痕直线的反射变换
    final reflectionMatrix = Matrix4.identity();
    reflectionMatrix.setEntry(0, 0, 1.0 - 2.0 * ux * ux);
    reflectionMatrix.setEntry(0, 1, -2.0 * ux * uy);
    reflectionMatrix.setEntry(0, 3, 2.0 * ux * (ux * mid.dx + uy * mid.dy));

    reflectionMatrix.setEntry(1, 0, -2.0 * ux * uy);
    reflectionMatrix.setEntry(1, 1, 1.0 - 2.0 * uy * uy);
    reflectionMatrix.setEntry(1, 3, 2.0 * uy * (ux * mid.dx + uy * mid.dy));

    // 计算翻折背面的多边形：将被翻起的凸多边形顶点映射至反射侧
    final backPolygon = <Offset>[];
    for (final p in curledPolygon) {
      final distToLine = (p - mid).dx * ux + (p - mid).dy * uy;
      final reflected = p - Offset(2.0 * distToLine * ux, 2.0 * distToLine * uy);
      backPolygon.add(reflected);
    }

    return _CurlGeometry(
      p1: p1,
      p2: p2,
      normal: Offset(ux, uy),
      frontPolygon: frontPolygon,
      backPolygon: backPolygon,
      reflectionMatrix: reflectionMatrix,
    );
  }
}

class _CurlGeometry {
  final Offset p1;
  final Offset p2;
  final Offset normal;
  final List<Offset> frontPolygon;
  final List<Offset> backPolygon;
  final Matrix4 reflectionMatrix;

  const _CurlGeometry({
    required this.p1,
    required this.p2,
    required this.normal,
    required this.frontPolygon,
    required this.backPolygon,
    required this.reflectionMatrix,
  });
}

class _PolygonClipper extends CustomClipper<Path> {
  final List<Offset> polygon;

  const _PolygonClipper(this.polygon);

  @override
  Path getClip(Size size) {
    final path = Path();
    if (polygon.isEmpty) {
      path.addRect(Offset.zero & size);
      return path;
    }
    path.moveTo(polygon[0].dx, polygon[0].dy);
    for (int i = 1; i < polygon.length; i++) {
      path.lineTo(polygon[i].dx, polygon[i].dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _PolygonClipper oldClipper) => true;
}

/// 底层页落影
class _DropShadowPainter extends CustomPainter {
  final Offset p1;
  final Offset p2;
  final Offset normal;
  final bool isDark;

  const _DropShadowPainter({
    required this.p1,
    required this.p2,
    required this.normal,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const shadowWidth = 32.0;
    final lineVector = p2 - p1;
    final lineLen = lineVector.distance;
    if (lineLen < 1.0) return;

    final shadowDir = -normal;

    final path = Path();
    path.moveTo(p1.dx, p1.dy);
    path.lineTo(p2.dx, p2.dy);
    path.lineTo(p2.dx + shadowDir.dx * shadowWidth, p2.dy + shadowDir.dy * shadowWidth);
    path.lineTo(p1.dx + shadowDir.dx * shadowWidth, p1.dy + shadowDir.dy * shadowWidth);
    path.close();

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.black.withValues(alpha: isDark ? 0.38 : 0.22),
          Colors.black.withValues(alpha: isDark ? 0.15 : 0.08),
          Colors.transparent,
        ],
      ).createShader(path.getBounds());

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DropShadowPainter oldDelegate) => true;
}

/// 脊线立体卷曲高光与暗影
class _SpineLightPainter extends CustomPainter {
  final Offset p1;
  final Offset p2;
  final Offset normal;
  final bool isDark;

  const _SpineLightPainter({
    required this.p1,
    required this.p2,
    required this.normal,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const spineWidth = 26.0;
    final path = Path();
    path.moveTo(p1.dx, p1.dy);
    path.lineTo(p2.dx, p2.dy);
    path.lineTo(p2.dx + normal.dx * spineWidth, p2.dy + normal.dy * spineWidth);
    path.lineTo(p1.dx + normal.dx * spineWidth, p1.dy + normal.dy * spineWidth);
    path.close();

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.black.withValues(alpha: isDark ? 0.32 : 0.18),
          (isDark ? Colors.white12 : Colors.white).withValues(alpha: 0.28),
          Colors.transparent,
        ],
        stops: const [0.0, 0.35, 1.0],
      ).createShader(path.getBounds());

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SpineLightPainter oldDelegate) => true;
}
