import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 四角纸张翻折。正文与纸背快照独立缓存，拖拽只更新裁剪、变换和窄幅光影。
class SimulationPageTurn extends StatefulWidget {
  final int totalPages;
  final int currentPageIndex;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Object? pageSetKey;
  final Object? contentVersion;
  final Listenable? pageContentChanges;
  final Widget? nextChapterPreview;
  final Widget? previousChapterPreview;
  final ValueChanged<int> onPageChanged;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final VoidCallback? onCenterTap;
  final Color backgroundColor;
  final bool isDark;
  final DateTime Function()? lastBubbleTapTimeGetter;
  final bool Function()? isSelectionActive;
  final VoidCallback? onDismissSelection;
  final VoidCallback? onTurnStarted;
  final VoidCallback? onInteractionEnded;
  final ValueChanged<bool>? onTurnRequested;
  final double previousTapFraction;
  final double nextTapFraction;

  const SimulationPageTurn({
    super.key,
    required this.totalPages,
    required this.currentPageIndex,
    required this.pageBuilder,
    this.pageSetKey,
    this.contentVersion,
    this.pageContentChanges,
    this.nextChapterPreview,
    this.previousChapterPreview,
    required this.onPageChanged,
    this.onPreviousChapter,
    this.onNextChapter,
    this.onCenterTap,
    required this.backgroundColor,
    this.isDark = false,
    this.lastBubbleTapTimeGetter,
    this.isSelectionActive,
    this.onDismissSelection,
    this.onTurnStarted,
    this.onInteractionEnded,
    this.onTurnRequested,
    this.previousTapFraction = 0.28,
    this.nextTapFraction = 0.72,
  });

  @override
  State<SimulationPageTurn> createState() => SimulationPageTurnState();
}

class SimulationPageTurnState extends State<SimulationPageTurn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  Animation<Offset>? _dragAnimation;
  final ValueNotifier<_CurlGeometry?> _geometry = ValueNotifier(null);
  final GlobalKey _frontPageKey = GlobalKey();
  final Map<int, Widget> _pageWidgets = {};
  ui.Image? _backImage;
  ui.Image? _preparedBackImage;
  bool _snapshotDirty = true;
  bool _snapshotPending = false;
  bool _snapshotSelectionActive = false;

  bool _isDragging = false;
  bool _isForward = true;
  int? _turnSourceIndex;
  int? _turnTargetIndex;
  int _animationGeneration = 0;
  Offset? _cornerPos;
  Offset? _dragPos;
  Size _viewSize = Size.zero;

  bool _touchPending = false;
  bool _gestureBlocked = false;
  bool? _queuedDirection;
  bool? _boundaryDirection;
  double _boundaryTravel = 0;
  bool _pointerCancelled = false;
  bool _awaitingCommit = false;
  Offset? _downPos;
  Offset? _dragOrigin;
  Offset? _logicalDragPos;

  bool get _isTurning => _turnSourceIndex != null;
  bool get isTurning => _isTurning;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimationTick);
    widget.pageContentChanges?.addListener(_invalidateSnapshot);
  }

  @override
  void didUpdateWidget(covariant SimulationPageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageContentChanges != widget.pageContentChanges) {
      oldWidget.pageContentChanges?.removeListener(_invalidateSnapshot);
      widget.pageContentChanges?.addListener(_invalidateSnapshot);
    }
    final selectionActive = widget.isSelectionActive?.call() == true;
    if (oldWidget.pageSetKey != widget.pageSetKey ||
        oldWidget.contentVersion != widget.contentVersion ||
        oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.currentPageIndex != widget.currentPageIndex) {
      _pageWidgets.clear();
      _invalidateSnapshot();
    }
    if (_snapshotSelectionActive != selectionActive) _invalidateSnapshot();
    _snapshotSelectionActive = selectionActive;
    if (oldWidget.pageSetKey != widget.pageSetKey ||
        oldWidget.totalPages != widget.totalPages ||
        oldWidget.currentPageIndex != widget.currentPageIndex ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      _resetTurn(
        // 待决手势尚未翻页；静默预加载改变页窗口时不能丢掉按下位置。
        preservePendingTouch:
            (_touchPending && !_isTurning) ||
            (oldWidget.pageSetKey == widget.pageSetKey && _awaitingCommit),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageWidgets.clear();
    _invalidateSnapshot();
  }

  @override
  void dispose() {
    _animController.removeListener(_onAnimationTick);
    widget.pageContentChanges?.removeListener(_invalidateSnapshot);
    _animController.dispose();
    _geometry.dispose();
    _preparedBackImage?.dispose();
    super.dispose();
  }

  void _onAnimationTick() {
    final animation = _dragAnimation;
    if (animation != null) _updateDragPosition(animation.value);
  }

  /// 外部调用（包括音量键）不会打断尚未完成的翻页。
  void turnToPreviousPage() => _turnPage(forward: false);

  void turnToNextPage() => _turnPage(forward: true);

  void _turnPage({required bool forward, bool fromTop = false}) {
    if (widget.isSelectionActive?.call() == true) {
      widget.onDismissSelection?.call();
      return;
    }
    if (_isTurning || _touchPending || _awaitingCommit) {
      _queuedDirection = forward;
      return;
    }
    if (_viewSize.isEmpty) return;
    final target = widget.currentPageIndex + (forward ? 1 : -1);
    if (target < 0) {
      widget.onPreviousChapter?.call();
    } else if (target >= widget.totalPages) {
      widget.onNextChapter?.call();
    } else {
      _beginTurn(forward: forward, fromTop: fromTop);
      final corner = _cornerPos!;
      final start = corner + Offset(forward ? -4 : 4, fromTop ? 4 : -4);
      _runAnimation(
        from: start,
        to: _completedDragPosition,
        completePageTurn: true,
      );
    }
  }

  void _beginTurn({required bool forward, required bool fromTop}) {
    widget.onTurnStarted?.call();
    _isForward = forward;
    _cornerPos = Offset(
      forward ? _viewSize.width : 0,
      fromTop ? 0 : _viewSize.height,
    );
    // 始终翻起当前页。向后翻时不能把上一页当作正面，否则起手就跳页。
    // 纸背在静止帧预热。手指起拖时不再同步创建高 DPI 全屏截图。
    _backImage = _snapshotDirty ? null : _preparedBackImage;
    setState(() {
      _turnSourceIndex = widget.currentPageIndex;
      _turnTargetIndex = widget.currentPageIndex + (forward ? 1 : -1);
    });
  }

  Offset get _completedDragPosition => Offset(
    _isForward ? -_viewSize.width * 1.04 : _viewSize.width * 2.04,
    _cornerPos!.dy,
  );

  void _invalidateSnapshot() {
    _snapshotDirty = true;
    _scheduleBackImage();
  }

  void _scheduleBackImage() {
    if (!mounted || !_snapshotDirty || _snapshotPending || _isTurning) return;
    _snapshotPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _snapshotPending = false;
      if (!mounted || _isTurning || !_snapshotDirty) return;
      final boundary = _frontPageKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary ||
          !boundary.attached ||
          !boundary.hasSize ||
          (kDebugMode && boundary.debugNeedsPaint)) {
        return;
      }
      final oldImage = _preparedBackImage;
      _preparedBackImage = boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1.0, 1.5),
      );
      _snapshotDirty = false;
      if (oldImage != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => oldImage.dispose());
      }
    });
  }

  void _updateDragPosition(Offset position) {
    _dragPos = position;
    final corner = _cornerPos;
    if (corner == null) return;
    _geometry.value = _computeCurlGeometry(
      corner: corner,
      drag: position,
      size: _viewSize,
    );
  }

  Future<void> _runAnimation({
    required Offset from,
    required Offset to,
    required bool completePageTurn,
    Offset? releaseVelocity,
  }) async {
    final generation = ++_animationGeneration;
    _isDragging = false;
    final distance = (to - from).distance;
    final remaining = (distance / (_viewSize.width * 2)).clamp(0.0, 1.0);
    if (releaseVelocity == null) {
      _animController.duration = const Duration(milliseconds: 300);
      _dragAnimation = Tween<Offset>(
        begin: from,
        end: to,
      ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_animController);
    } else {
      final direction = distance < 0.01 ? Offset.zero : (to - from) / distance;
      final speed =
          releaseVelocity.dx * direction.dx + releaseVelocity.dy * direction.dy;
      final milliseconds = distance < 1
          ? 1
          : speed > 350
          ? (distance / speed * 1100).clamp(70.0, 260.0).round()
          : (260 * math.sqrt(remaining)).clamp(90.0, 260.0).round();
      _animController.duration = Duration(milliseconds: milliseconds);
      _dragAnimation = _ReleaseTween(
        begin: from,
        end: to,
        velocity: releaseVelocity,
        seconds: milliseconds / 1000,
      ).animate(_animController);
    }
    _updateDragPosition(from);

    try {
      await _animController.forward(from: 0).orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _animationGeneration) return;

    final target = _turnTargetIndex;
    setState(() => _resetTurn(preservePendingTouch: true));
    _awaitingCommit = completePageTurn;
    _drainQueuedTurn();
    if (!completePageTurn || target == null) {
      widget.onInteractionEnded?.call();
      return;
    }
    if (target >= 0 && target < widget.totalPages) {
      widget.onPageChanged(target);
    } else if (_isForward) {
      widget.onNextChapter?.call();
    } else {
      widget.onPreviousChapter?.call();
    }
  }

  void _resetTurn({bool preservePendingTouch = false}) {
    ++_animationGeneration;
    _dragAnimation = null;
    _animController.stop();
    _isDragging = false;
    _turnSourceIndex = null;
    _turnTargetIndex = null;
    _cornerPos = null;
    _dragPos = null;
    _dragOrigin = null;
    _logicalDragPos = null;
    if (!preservePendingTouch) {
      _touchPending = false;
      _downPos = null;
    }
    _geometry.value = null;
    _backImage = null;
  }

  bool get _wasBubbleTapped {
    final lastTap = widget.lastBubbleTapTimeGetter?.call();
    return lastTap != null &&
        DateTime.now().difference(lastTap) < const Duration(milliseconds: 400);
  }

  void _drainQueuedTurn() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _awaitingCommit = false;
      if (_isTurning || _touchPending) return;
      final direction = _queuedDirection;
      _queuedDirection = null;
      if (direction != null) _turnPage(forward: direction);
    });
  }

  void _onDragDown(DragDownDetails details) {
    _pointerCancelled = false;
    _touchPending = true;
    _gestureBlocked =
        _isDragging ||
        _awaitingCommit ||
        widget.isSelectionActive?.call() == true;
    _boundaryDirection = null;
    _boundaryTravel = 0;
    _downPos = details.localPosition;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_gestureBlocked || _downPos == null) return;
    final movement = details.localPosition - _downPos!;
    if (_boundaryDirection != null) {
      _boundaryTravel = movement.dx * (_boundaryDirection! ? -1 : 1);
      return;
    }
    if (!_isDragging) {
      if (_wasBubbleTapped || widget.isSelectionActive?.call() == true) {
        _gestureBlocked = true;
        return;
      }
      if (movement.dx == 0) return;
      _queuedDirection = null;
      if (_isTurning) {
        // 横向手势赢得竞技场后才接管收尾，不抢占长按选词或气泡点击。
        ++_animationGeneration;
        _animController.stop();
        _dragAnimation = null;
        widget.onTurnStarted?.call();
        _dragOrigin = _dragSpacePosition(_dragPos!);
      } else {
        final forward = movement.dx < 0;
        final target = widget.currentPageIndex + (forward ? 1 : -1);
        final preview = forward
            ? widget.nextChapterPreview
            : widget.previousChapterPreview;
        if ((target < 0 || target >= widget.totalPages) && preview == null) {
          _boundaryDirection = forward;
          _boundaryTravel = movement.dx.abs();
          return;
        }
        _beginTurn(
          forward: forward,
          fromTop: _downPos!.dy < _viewSize.height * 0.5,
        );
        _dragOrigin = _cornerPos;
      }
      _isDragging = true;
    }

    // 折痕位于纸角与拖点的中点：纸角移动两倍，折痕才与手指 1:1。
    // 去除以书脊为圆心的径向限位，斜拖和靠近边缘时不会突然黏住。
    _logicalDragPos = _dragOrigin! + movement * 2;
    _updateDragPosition(_constrainDragPosition(_logicalDragPos!));
  }

  Offset _dragSpacePosition(Offset position) {
    final corner = _cornerPos!;
    final progress = ((position.dx - corner.dx).abs() / (_viewSize.width * 2))
        .clamp(0.0, 1.0);
    return Offset(
      position.dx,
      corner.dy + (position.dy - corner.dy) / math.max(0.01, 1 - progress),
    );
  }

  Offset _constrainDragPosition(Offset position) {
    final corner = _cornerPos!;
    final w = _viewSize.width;
    final h = _viewSize.height;
    final x = position.dx.clamp(_isForward ? -w : 0.0, _isForward ? w : w * 2);
    final travel = (x - corner.dx).abs();
    final progress = (travel / (w * 2)).clamp(0.0, 1.0);
    final bendLimit = math.min(h * 0.4, travel * 0.8);
    final bend = (position.dy - corner.dy).clamp(
      corner.dy == 0 ? 0.0 : -bendLimit,
      corner.dy == 0 ? bendLimit : 0.0,
    );
    return Offset(x, corner.dy + bend * (1 - progress));
  }

  void _onDragEnd(DragEndDetails details) {
    if (_pointerCancelled) {
      _onDragCancel();
      return;
    }
    _touchPending = false;
    _downPos = null;
    if (!_isDragging) {
      final boundary = _boundaryDirection;
      _boundaryDirection = null;
      final velocity = details.velocity.pixelsPerSecond.dx;
      final directedVelocity = velocity * (boundary == true ? -1 : 1);
      if (!_gestureBlocked &&
          boundary != null &&
          (directedVelocity > 350 ||
              (_boundaryTravel > _viewSize.width * 0.18 &&
                  directedVelocity > -350))) {
        if (boundary) {
          widget.onNextChapter?.call();
        } else {
          widget.onPreviousChapter?.call();
        }
      }
      _drainQueuedTurn();
      return;
    }

    final drag = _dragPos!;
    final distance = (drag.dx - _cornerPos!.dx).abs() / 2;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final directedVelocity = velocity * (_isForward ? -1 : 1);
    final shouldTurn =
        directedVelocity > 350 ||
        (distance > _viewSize.width * 0.18 && directedVelocity > -350);
    _runAnimation(
      from: drag,
      to: shouldTurn ? _completedDragPosition : _cornerPos!,
      completePageTurn: shouldTurn,
      // 对限位后的真实纸角求速度，斜拖松手也不会突然改变折痕方向。
      releaseVelocity:
          (_constrainDragPosition(
                _logicalDragPos! + details.velocity.pixelsPerSecond * 0.002,
              ) -
              drag) /
          0.001,
    );
  }

  void _onDragCancel() {
    _touchPending = false;
    _downPos = null;
    _boundaryDirection = null;
    if (_isDragging && _dragPos != null && _cornerPos != null) {
      _runAnimation(
        from: _dragPos!,
        to: _cornerPos!,
        completePageTurn: false,
        releaseVelocity: Offset.zero,
      );
    } else {
      _drainQueuedTurn();
    }
  }

  void _handleTapAt(Offset position) {
    _touchPending = false;
    if (_wasBubbleTapped) return;
    if (widget.isSelectionActive?.call() == true) {
      widget.onDismissSelection?.call();
      return;
    }
    final w = _viewSize.width;
    if (position.dx < w * widget.previousTapFraction ||
        position.dx > w * widget.nextTapFraction) {
      final forward = position.dx > w * widget.nextTapFraction;
      if (widget.onTurnRequested != null) {
        widget.onTurnRequested!(forward);
      } else {
        _turnPage(
          forward: forward,
          fromTop: position.dy < _viewSize.height * 0.5,
        );
      }
    } else {
      widget.onCenterTap?.call();
    }
  }

  void clearQueuedTurns() => _queuedDirection = null;

  Widget _buildCachedPage(BuildContext context, int index) {
    if (index >= 0 && index < widget.totalPages) {
      return _pageWidgets.putIfAbsent(
        index,
        () => widget.pageBuilder(context, index),
      );
    }
    return (index < 0
            ? widget.previousChapterPreview
            : widget.nextChapterPreview) ??
        ColoredBox(color: widget.backgroundColor);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_viewSize != constraints.biggest) {
          if (_isTurning) _resetTurn();
          _viewSize = constraints.biggest;
          _pageWidgets.clear();
          _invalidateSnapshot();
        }
        _scheduleBackImage();
        final sourceIndex = _turnSourceIndex ?? widget.currentPageIndex;
        _pageWidgets.removeWhere((index, _) => (index - sourceIndex).abs() > 1);
        final frontPage = RepaintBoundary(
          key: _frontPageKey,
          child: _buildCachedPage(context, sourceIndex),
        );
        final backPage = RepaintBoundary(
          child: RawImage(
            image: _backImage,
            fit: BoxFit.fill,
            color: Colors.white.withValues(alpha: widget.isDark ? 0.10 : 0.12),
            colorBlendMode: BlendMode.modulate,
            filterQuality: FilterQuality.low,
          ),
        );

        return Listener(
          onPointerCancel: (_) => _pointerCancelled = true,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragDown: _onDragDown,
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
            onTapUp: (details) => _handleTapAt(details.localPosition),
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ExcludeSemantics(
                    child: IgnorePointer(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // 只预排版相邻两页；静止时不绘制，不增加整屏 GPU 开销。
                          for (final index in [
                            sourceIndex - 1,
                            sourceIndex + 1,
                          ])
                            Offstage(
                              key: ValueKey(index),
                              offstage: index != _turnTargetIndex,
                              child: RepaintBoundary(
                                child: _buildCachedPage(context, index),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _geometry,
                    child: frontPage,
                    builder: (context, staticFrontPage) {
                      final geometry = _geometry.value;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          CustomPaint(
                            painter: _FoldShadowPainter(
                              geometry: geometry,
                              isDark: widget.isDark,
                              isSpine: false,
                            ),
                          ),
                          ClipPath(
                            clipper: _PolygonClipper(geometry?.frontPolygon),
                            child: IgnorePointer(
                              ignoring: _isTurning,
                              child: staticFrontPage,
                            ),
                          ),
                          ExcludeSemantics(
                            child: IgnorePointer(
                              child: ClipPath(
                                clipper: _PolygonClipper(
                                  geometry?.backPolygon ?? const [],
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ColoredBox(
                                      color: Color.lerp(
                                        widget.backgroundColor,
                                        widget.isDark
                                            ? Colors.white
                                            : const Color(0xFFE8DFC8),
                                        widget.isDark ? 0.04 : 0.18,
                                      )!,
                                    ),
                                    Transform(
                                      transform:
                                          geometry?.reflectionMatrix ??
                                          Matrix4.identity(),
                                      child: backPage,
                                    ),
                                    CustomPaint(
                                      painter: _FoldShadowPainter(
                                        geometry: geometry,
                                        isDark: widget.isDark,
                                        isSpine: true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 二维 Hermite 收尾：零速度松手不突兀加速，横纵动量同时接续，终点静止。
class _ReleaseTween extends Animatable<Offset> {
  final Offset begin;
  final Offset end;
  late final Offset tangent;

  _ReleaseTween({
    required this.begin,
    required this.end,
    required Offset velocity,
    required double seconds,
  }) {
    double bounded(double distance, double speed) {
      if (distance.abs() < 0.01) return 0;
      final slope = (speed * seconds / distance).clamp(-1.0, 3.0);
      return slope * distance;
    }

    tangent = Offset(
      bounded(end.dx - begin.dx, velocity.dx),
      bounded(end.dy - begin.dy, velocity.dy),
    );
  }

  @override
  Offset transform(double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return begin * (2 * t3 - 3 * t2 + 1) +
        tangent * (t3 - 2 * t2 + t) +
        end * (-2 * t3 + 3 * t2);
  }
}

/// 折痕不与视口相交时依然返回真实多边形，不能退回原页。
_CurlGeometry? _computeCurlGeometry({
  required Offset corner,
  required Offset drag,
  required Size size,
}) {
  final diff = drag - corner;
  final distance = diff.distance;
  if (distance < 0.01) return null;
  final normal = diff / distance;
  final mid = (corner + drag) / 2;
  final rect = [
    Offset.zero,
    Offset(size.width, 0),
    Offset(size.width, size.height),
    Offset(0, size.height),
  ];
  double eval(Offset point) {
    final relative = point - mid;
    return normal.dx * relative.dx + normal.dy * relative.dy;
  }

  final front = <Offset>[];
  final curled = <Offset>[];
  final intersections = <Offset>[];
  for (var i = 0; i < rect.length; i++) {
    final start = rect[i];
    final end = rect[(i + 1) % rect.length];
    final startValue = eval(start);
    final endValue = eval(end);
    final startInside = startValue >= 0;
    final endInside = endValue >= 0;
    if (startInside != endInside) {
      final intersection =
          start + (end - start) * (startValue / (startValue - endValue));
      front.add(intersection);
      curled.add(intersection);
      if (intersections.every((p) => (p - intersection).distance > 0.01)) {
        intersections.add(intersection);
      }
    }
    (endInside ? front : curled).add(end);
  }

  final reflectionMatrix = Matrix4.identity()
    ..setEntry(0, 0, 1 - 2 * normal.dx * normal.dx)
    ..setEntry(0, 1, -2 * normal.dx * normal.dy)
    ..setEntry(1, 0, -2 * normal.dx * normal.dy)
    ..setEntry(1, 1, 1 - 2 * normal.dy * normal.dy);
  final translation = 2 * (normal.dx * mid.dx + normal.dy * mid.dy);
  reflectionMatrix
    ..setEntry(0, 3, normal.dx * translation)
    ..setEntry(1, 3, normal.dy * translation);

  final back = curled.map((point) {
    final distanceToLine = eval(point);
    return point - normal * (2 * distanceToLine);
  }).toList();
  final progress = (diff.dx.abs() / (size.width * 2)).clamp(0.0, 1.0);
  return _CurlGeometry(
    p1: intersections.length >= 2 ? intersections.first : null,
    p2: intersections.length >= 2 ? intersections.last : null,
    normal: normal,
    frontPolygon: front,
    backPolygon: back,
    reflectionMatrix: reflectionMatrix,
    shadowWidth: (distance * 0.12).clamp(0.0, 10.0),
    shadowStrength: math.sin(progress * math.pi).clamp(0.0, 1.0),
  );
}

class _CurlGeometry {
  final Offset? p1;
  final Offset? p2;
  final Offset normal;
  final List<Offset> frontPolygon;
  final List<Offset> backPolygon;
  final Matrix4 reflectionMatrix;
  final double shadowWidth;
  final double shadowStrength;

  const _CurlGeometry({
    required this.p1,
    required this.p2,
    required this.normal,
    required this.frontPolygon,
    required this.backPolygon,
    required this.reflectionMatrix,
    required this.shadowWidth,
    required this.shadowStrength,
  });
}

class _PolygonClipper extends CustomClipper<Path> {
  // null 是静止整页；空多边形是真正的空裁剪区域，绝不能绘制整页。
  final List<Offset>? polygon;

  const _PolygonClipper(this.polygon);

  @override
  Path getClip(Size size) {
    final points = polygon;
    if (points == null) return Path()..addRect(Offset.zero & size);
    if (points.length < 3) return Path();
    return Path()..addPolygon(points, true);
  }

  @override
  bool shouldReclip(covariant _PolygonClipper oldClipper) =>
      !identical(polygon, oldClipper.polygon);
}

/// 光影始终沿折痕法线渐变，宽度最多 10px，不随长条包围盒拉伸。
class _FoldShadowPainter extends CustomPainter {
  final _CurlGeometry? geometry;
  final bool isDark;
  final bool isSpine;

  const _FoldShadowPainter({
    required this.geometry,
    required this.isDark,
    required this.isSpine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fold = geometry;
    if (fold == null ||
        fold.p1 == null ||
        fold.p2 == null ||
        fold.shadowWidth < 0.01 ||
        (fold.p2! - fold.p1!).distance < 0.01) {
      return;
    }
    final width = isSpine ? fold.shadowWidth * 0.7 : fold.shadowWidth;
    final direction = isSpine ? fold.normal : -fold.normal;
    final offset = direction * width;
    final path = Path()
      ..addPolygon([
        fold.p1!,
        fold.p2!,
        fold.p2! + offset,
        fold.p1! + offset,
      ], true);
    final alpha = (isDark ? 0.18 : 0.13) * fold.shadowStrength;
    final colors = isSpine
        ? [
            Colors.black.withValues(alpha: alpha * 0.7),
            Colors.white.withValues(alpha: alpha * 0.45),
            Colors.transparent,
          ]
        : [
            Colors.black.withValues(alpha: alpha),
            Colors.black.withValues(alpha: alpha * 0.3),
            Colors.transparent,
          ];
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          fold.p1!,
          fold.p1! + offset,
          colors,
          const [0, 0.4, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _FoldShadowPainter oldDelegate) =>
      !identical(geometry, oldDelegate.geometry) ||
      isDark != oldDelegate.isDark ||
      isSpine != oldDelegate.isSpine;
}
