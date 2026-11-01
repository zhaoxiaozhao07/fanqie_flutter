import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 真实仿真翻页组件
/// 支持四个角（右上、右下、左上、左下）随手指拖拽实时弯曲折叠翻页，
/// 严格满足折纸几何学、背面镜像反转文字展示与立体光影渲染。
class SimulationPageTurn extends StatefulWidget {
  final int totalPages;
  final int currentPageIndex;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
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
  Animation<Offset>? _dragAnimation;

  // 翻页状态
  bool _isDragging = false;
  bool _isForward = true; // true: 下一页; false: 上一页
  _TurnCorner _corner = _TurnCorner.bottomRight;
  Offset? _cornerPos; // 原始角点 C
  Offset? _dragPos; // 当前手指拖拽点 A

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
  }

  @override
  void dispose() {
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
    final size = MediaQuery.of(context).size;
    final w = size.width;
    final h = size.height;

    _isForward = forward;
    if (forward) {
      _corner = fromTop ? _TurnCorner.topRight : _TurnCorner.bottomRight;
      _cornerPos = fromTop ? Offset(w, 0) : Offset(w, h);
      _dragPos = _cornerPos! - Offset(4.0, fromTop ? -4.0 : 4.0);

      final endPos = fromTop ? Offset(-w * 0.45, 0) : Offset(-w * 0.45, h);
      _runAnimation(from: _dragPos!, to: endPos, completePageTurn: true);
    } else {
      _corner = fromTop ? _TurnCorner.topLeft : _TurnCorner.bottomLeft;
      _cornerPos = fromTop ? const Offset(0, 0) : Offset(0, h);
      _dragPos = _cornerPos! + Offset(4.0, fromTop ? 4.0 : -4.0);

      final endPos = fromTop ? Offset(w * 1.45, 0) : Offset(w * 1.45, h);
      _runAnimation(from: _dragPos!, to: endPos, completePageTurn: true);
    }
  }

  void _runAnimation({
    required Offset from,
    required Offset to,
    required bool completePageTurn,
  }) {
    _animController.stop();
    _dragAnimation = Tween<Offset>(begin: from, end: to).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );

    _animController.forward(from: 0.0).then((_) {
      if (!mounted) return;
      if (completePageTurn) {
        if (_isForward) {
          if (widget.currentPageIndex < widget.totalPages - 1) {
            widget.onPageChanged(widget.currentPageIndex + 1);
          } else {
            widget.onNextChapter?.call();
          }
        } else {
          if (widget.currentPageIndex > 0) {
            widget.onPageChanged(widget.currentPageIndex - 1);
          } else {
            widget.onPreviousChapter?.call();
          }
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
      // 达到初始微滑动阈值（4px）即启动折角，极致灵敏零迟滞
      if (moveDist < 4.0) return;

      // 中间区域不启动翻页拖拽，留给点击呼出菜单
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
      // 未发生明显拖拽（位移 < 12px 且时间 < 500ms），按点击处理
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
        _runAnimation(from: currentPos, to: Offset(-w * 0.45, targetY), completePageTurn: true);
      } else {
        _runAnimation(from: currentPos, to: _cornerPos!, completePageTurn: false);
      }
    } else {
      final draggedDistance = currentPos.dx - _cornerPos!.dx;
      final shouldTurn = draggedDistance > w * 0.18;

      if (shouldTurn) {
        final targetY = _corner == _TurnCorner.topLeft ? 0.0 : h;
        _runAnimation(from: currentPos, to: Offset(w * 1.45, targetY), completePageTurn: true);
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

        final isCurling = (_isDragging || _animController.isAnimating) &&
            _dragPos != null &&
            _cornerPos != null &&
            (_dragPos! - _cornerPos!).distance > 2.0;

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

        final corner = _cornerPos!;
        final drag = _dragPos!;

        final curlGeometry = _computeCurlGeometry(
          corner: corner,
          drag: drag,
          viewWidth: w,
          viewHeight: h,
        );

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
            : widget.pageBuilder(context, widget.currentPageIndex);

        final bottomPageWidget = bottomPageIndex >= 0 && bottomPageIndex < widget.totalPages
            ? widget.pageBuilder(context, bottomPageIndex)
            : Container(color: widget.backgroundColor);

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
                // 1. 底层页（即将露出的那一页）
                bottomPageWidget,

                // 1.1 底层页落影
                if (curlGeometry != null)
                  CustomPaint(
                    painter: _DropShadowPainter(
                      p1: curlGeometry.p1,
                      p2: curlGeometry.p2,
                      normal: curlGeometry.normal,
                      isDark: widget.isDark,
                    ),
                  ),

                // 2. 当前页正面（未被折起部分）
                if (curlGeometry != null)
                  ClipPath(
                    clipper: _PolygonClipper(curlGeometry.frontPolygon),
                    child: topPageWidget,
                  )
                else
                  topPageWidget,

                // 3. 当前页翻转背面（文字镜像翻转 + 纸背半透质感 + 脊部高光暗影）
                if (curlGeometry != null)
                  ClipPath(
                    clipper: _PolygonClipper(curlGeometry.backPolygon),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 3.1 真实对称反射矩阵：当前页正文文字与排版完全镜像反转！
                        Transform(
                          transform: curlGeometry.reflectionMatrix,
                          child: topPageWidget,
                        ),

                        // 3.2 纸背微透墨迹层
                        Container(
                          color: widget.backgroundColor.withValues(
                            alpha: widget.isDark ? 0.92 : 0.88,
                          ),
                        ),

                        // 3.3 纸背温润质感底色
                        Container(
                          color: (widget.isDark ? Colors.black : const Color(0xFFE8DFC8))
                              .withValues(alpha: 0.12),
                        ),

                        // 3.4 沿折痕脊线的立体卷曲高光与暗影
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

  /// 核心折纸几何与反射矩阵求解
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

    // 屏幕 4 条边交点
    final K = nx * mid.dx + ny * mid.dy;
    final intersections = <Offset>[];

    // 顶边 y = 0
    if (nx.abs() > 1e-4) {
      final x = K / nx;
      if (x >= -0.5 && x <= viewWidth + 0.5) {
        intersections.add(Offset(x.clamp(0.0, viewWidth), 0.0));
      }
    }

    // 底边 y = viewHeight
    if (nx.abs() > 1e-4) {
      final x = (K - ny * viewHeight) / nx;
      if (x >= -0.5 && x <= viewWidth + 0.5) {
        intersections.add(Offset(x.clamp(0.0, viewWidth), viewHeight));
      }
    }

    // 左边 x = 0
    if (ny.abs() > 1e-4) {
      final y = K / ny;
      if (y >= -0.5 && y <= viewHeight + 0.5) {
        intersections.add(Offset(0.0, y.clamp(0.0, viewHeight)));
      }
    }

    // 右边 x = viewWidth
    if (ny.abs() > 1e-4) {
      final y = (K - nx * viewWidth) / ny;
      if (y >= -0.5 && y <= viewHeight + 0.5) {
        intersections.add(Offset(viewWidth, y.clamp(0.0, viewHeight)));
      }
    }

    final uniquePoints = <Offset>[];
    for (final p in intersections) {
      if (!uniquePoints.any((u) => (u - p).distance < 2.0)) {
        uniquePoints.add(p);
      }
    }

    if (uniquePoints.length < 2) return null;

    final p1 = uniquePoints[0];
    final p2 = uniquePoints[1];

    final corners = [
      const Offset(0, 0),
      Offset(viewWidth, 0),
      Offset(viewWidth, viewHeight),
      Offset(0, viewHeight),
    ];

    double eval(Offset p) => nx * (p.dx - mid.dx) + ny * (p.dy - mid.dy);

    final frontPoints = <Offset>[];
    final curledPoints = <Offset>[];

    for (int i = 0; i < 4; i++) {
      final cA = corners[i];
      final cB = corners[(i + 1) % 4];
      final valA = eval(cA);
      final valB = eval(cB);

      if (valA >= 0) {
        frontPoints.add(cA);
      } else {
        curledPoints.add(cA);
      }

      if ((valA > 0 && valB < 0) || (valA < 0 && valB > 0)) {
        final t = valA / (valA - valB);
        final ip = cA + (cB - cA) * t;
        frontPoints.add(ip);
        curledPoints.add(ip);
      }
    }

    final sortedFront = _sortPolygon(frontPoints);
    final sortedCurled = _sortPolygon(curledPoints);

    // 对称反射矩阵
    final reflectionMatrix = Matrix4.identity();
    reflectionMatrix.setEntry(0, 0, 1.0 - 2.0 * ux * ux);
    reflectionMatrix.setEntry(0, 1, -2.0 * ux * uy);
    reflectionMatrix.setEntry(0, 3, 2.0 * ux * (ux * mid.dx + uy * mid.dy));

    reflectionMatrix.setEntry(1, 0, -2.0 * ux * uy);
    reflectionMatrix.setEntry(1, 1, 1.0 - 2.0 * uy * uy);
    reflectionMatrix.setEntry(1, 3, 2.0 * uy * (ux * mid.dx + uy * mid.dy));

    // 计算被翻起区域反射到背面的顶点
    final backPoints = <Offset>[];
    for (final p in sortedCurled) {
      final distToLine = (p - mid).dx * ux + (p - mid).dy * uy;
      final reflected = p - Offset(2.0 * distToLine * ux, 2.0 * distToLine * uy);
      backPoints.add(reflected);
    }
    final sortedBack = _sortPolygon(backPoints);

    return _CurlGeometry(
      p1: p1,
      p2: p2,
      mid: mid,
      normal: Offset(ux, uy),
      frontPolygon: sortedFront,
      curledPolygon: sortedCurled,
      backPolygon: sortedBack,
      reflectionMatrix: reflectionMatrix,
    );
  }

  List<Offset> _sortPolygon(List<Offset> points) {
    if (points.length <= 2) return points;
    double cx = 0, cy = 0;
    for (final p in points) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= points.length;
    cy /= points.length;
    final center = Offset(cx, cy);

    final list = List<Offset>.from(points);
    list.sort((a, b) {
      final angleA = math.atan2(a.dy - center.dy, a.dx - center.dx);
      final angleB = math.atan2(b.dy - center.dy, b.dx - center.dx);
      return angleA.compareTo(angleB);
    });
    return list;
  }
}

class _CurlGeometry {
  final Offset p1;
  final Offset p2;
  final Offset mid;
  final Offset normal;
  final List<Offset> frontPolygon;
  final List<Offset> curledPolygon;
  final List<Offset> backPolygon;
  final Matrix4 reflectionMatrix;

  const _CurlGeometry({
    required this.p1,
    required this.p2,
    required this.mid,
    required this.normal,
    required this.frontPolygon,
    required this.curledPolygon,
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
