import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../services/reader_platform.dart';
import '../services/reader_scroll_input.dart';

import 'reader_page_transition.dart';
import 'simulation_page_turn.dart';

class ReaderPageItem {
  final Object id;
  final WidgetBuilder builder;

  const ReaderPageItem({required this.id, required this.builder});
}

/// 模式只决定合成效果，章节与普通页面共用同一个翻页入口和收尾流程。
class ReaderPageView extends StatefulWidget {
  static const desktopAnimationDuration = Duration(milliseconds: 320);
  final List<ReaderPageItem> pages;
  final Object currentPageId;
  final Object contentVersion;
  final String mode;
  final Color backgroundColor;
  final bool isDark;
  final Color? foregroundColor;
  final double desktopEdgeWidth;
  final ValueListenable<String?> selection;
  final Listenable? pageContentChanges;
  final ValueChanged<ReaderPageItem> onPageSettled;
  final VoidCallback onPreviousBoundary;
  final VoidCallback onNextBoundary;
  final VoidCallback onCenterTap;
  final VoidCallback onDismissSelection;
  final VoidCallback? onInteractionEnded;
  final DateTime Function() lastBubbleTap;
  final double previousTapFraction;
  final double nextTapFraction;
  final bool reverseTapSides;
  final VoidCallback? onUserPageTurn;
  final String semanticLabel;
  final double animationSpeed;
  final bool tapToTurn;

  const ReaderPageView({
    super.key,
    required this.pages,
    required this.currentPageId,
    required this.contentVersion,
    required this.mode,
    required this.backgroundColor,
    required this.isDark,
    this.foregroundColor,
    this.desktopEdgeWidth = 0,
    required this.selection,
    this.pageContentChanges,
    required this.onPageSettled,
    required this.onPreviousBoundary,
    required this.onNextBoundary,
    required this.onCenterTap,
    required this.onDismissSelection,
    required this.lastBubbleTap,
    this.onInteractionEnded,
    this.previousTapFraction = 0.28,
    this.nextTapFraction = 0.72,
    this.reverseTapSides = false,
    this.onUserPageTurn,
    this.semanticLabel = '小说阅读页',
    this.animationSpeed = 1,
    this.tapToTurn = true,
  });

  @override
  State<ReaderPageView> createState() => ReaderPageViewState();
}

class ReaderPageViewState extends State<ReaderPageView> {
  Offset? _pointerStart;
  bool _reportedPointer = false;
  final _simulationKey = GlobalKey<SimulationPageTurnState>();
  late PageController _controller;
  late List<ReaderPageItem> _pages;
  late String _mode;
  late Object _contentVersion;
  int _index = 0;
  bool _animating = false;
  bool? _queuedDirection;
  bool _queuedFromWheel = false;
  bool _wheelTurning = false;
  bool _wheelCanRepeat = false;
  double _overscroll = 0;
  bool _pendingConfiguration = false;
  int _pageSetVersion = 0;
  int _controllerRevision = 0;
  bool _synchronizingController = false;
  bool _awaitingCommit = false;
  bool _drainingCommit = false;
  int _commitGeneration = 0;
  Size? _pageViewport;
  static const _wheelQuietPeriod = Duration(milliseconds: 180);
  Timer? _wheelGestureEnd;
  bool _wheelGestureActive = false;
  Duration? _lastWheelTimestamp;
  bool? _wheelDirection;
  double _wheelLeadingDelta = 0;
  Duration? _acceptedWheelTimestamp;
  Timer? _wheelRepeatTimer;
  bool _wheelRepeatReady = false;

  Duration get _wheelRepeatInterval {
    if (_mode == 'none') return _wheelQuietPeriod;
    final duration = _mode == 'simulation'
        ? SimulationPageTurn.desktopAnimationDuration
        : ReaderPageView.desktopAnimationDuration;
    final micros =
        (duration.inMicroseconds / widget.animationSpeed.clamp(.6, 1.6))
            .round();
    return Duration(
      microseconds: micros < _wheelQuietPeriod.inMicroseconds
          ? _wheelQuietPeriod.inMicroseconds
          : micros,
    );
  }

  bool get _motionBusy =>
      _animating ||
      (_mode == 'simulation'
          ? _simulationKey.currentState?.isTurning ?? false
          : _controller.hasClients &&
                _controller.position.isScrollingNotifier.value);

  bool get isBusy => _motionBusy || _awaitingCommit;
  bool get isWheelInteraction => _wheelTurning;
  bool get _inputBlocked => isBusy || _drainingCommit;

  Object get currentPageId {
    final index = _mode != 'simulation' && _controller.hasClients
        ? (_controller.page ?? _index.toDouble()).round()
        : _index;
    return _pages[index.clamp(0, _pages.length - 1)].id;
  }

  @override
  void initState() {
    super.initState();
    _pages = widget.pages;
    _mode = widget.mode;
    _contentVersion = widget.contentVersion;
    _index = _findCurrent();
    _controller = PageController(initialPage: _index, keepPage: false);
    widget.selection.addListener(_onSelectionChanged);
  }

  int _findCurrent() {
    final index = widget.pages.indexWhere(
      (page) => page.id == widget.currentPageId,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void didUpdateWidget(covariant ReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection.removeListener(_onSelectionChanged);
      widget.selection.addListener(_onSelectionChanged);
    }
    _synchronize();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  void _synchronize() {
    if (isBusy) {
      _pendingConfiguration = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pendingConfiguration && !isBusy) setState(_synchronize);
      });
      return;
    }
    final target = _findCurrent();
    var samePages = _pages.length == widget.pages.length;
    if (samePages) {
      for (var index = 0; index < _pages.length; index++) {
        if (_pages[index].id != widget.pages[index].id) {
          samePages = false;
          break;
        }
      }
    }
    final changeEngine =
        (_mode == 'simulation') != (widget.mode == 'simulation');
    final recreateController =
        changeEngine ||
        (widget.mode != 'simulation' &&
            !_controller.hasClients &&
            target != _controller.initialPage);
    final reposition = target != _index;
    if (recreateController) {
      final oldController = _controller;
      _controller = PageController(initialPage: target, keepPage: false);
      _controllerRevision++;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => oldController.dispose(),
      );
    }
    if (!samePages ||
        _contentVersion != widget.contentVersion ||
        _mode != widget.mode) {
      _pages = widget.pages;
    }
    if (!samePages) _pageSetVersion++;
    _index = target;
    _mode = widget.mode;
    _contentVersion = widget.contentVersion;
    _pendingConfiguration = false;
    if (!recreateController &&
        reposition &&
        _mode != 'simulation' &&
        _controller.hasClients) {
      // Prepending a cached chapter changes the index, not the visible page.
      // Reuse its keyed render subtree instead of detaching every page and
      // invalidating text/raster caches at each chapter boundary.
      _synchronizingController = true;
      try {
        _controller.jumpToPage(target);
      } finally {
        _synchronizingController = false;
      }
    }
  }

  @override
  void dispose() {
    _wheelGestureEnd?.cancel();
    _wheelRepeatTimer?.cancel();
    widget.selection.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void turnToNextPage({bool fromWheel = false}) =>
      _turn(forward: true, fromWheel: fromWheel);
  void turnToPreviousPage({bool fromWheel = false}) =>
      _turn(forward: false, fromWheel: fromWheel);
  void handleContentTap(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _tap(box.globalToLocal(globalPosition), box.size.width);
    }
  }

  void clearQueuedTurns() {
    _queuedDirection = null;
    _queuedFromWheel = false;
    _wheelCanRepeat = false;
    _simulationKey.currentState?.clearQueuedTurns();
  }

  void _turn({required bool forward, bool fromWheel = false}) {
    if (widget.selection.value != null) {
      widget.onDismissSelection();
      return;
    }
    if (!fromWheel) _wheelCanRepeat = false;
    if (_inputBlocked) {
      _queuedDirection = forward;
      _queuedFromWheel = fromWheel;
      return;
    }
    _queuedDirection = null;
    _queuedFromWheel = false;
    _wheelTurning = fromWheel;
    if (_mode == 'simulation') {
      if (forward) {
        _simulationKey.currentState?.turnToNextPage();
      } else {
        _simulationKey.currentState?.turnToPreviousPage();
      }
      final turning = _simulationKey.currentState?.isTurning == true;
      if (!turning) _wheelTurning = false;
      if (fromWheel) _wheelCanRepeat = turning;
      return;
    }
    if (!_controller.hasClients) return;
    final target = _index + (forward ? 1 : -1);
    if (target < 0) {
      widget.onPreviousBoundary();
    } else if (target >= _pages.length) {
      widget.onNextBoundary();
    } else {
      if (fromWheel) _wheelCanRepeat = true;
      _animate(target);
    }
  }

  Future<void> _animate(int target) async {
    final controller = _controller;
    _animating = true;
    try {
      if (_mode == 'none') {
        controller.jumpToPage(target);
      } else {
        await controller.animateToPage(
          target,
          duration: ReaderPlatform.isDesktop
              ? Duration(
                  microseconds:
                      (ReaderPageView.desktopAnimationDuration.inMicroseconds /
                              widget.animationSpeed.clamp(.6, 1.6))
                          .round(),
                )
              : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      if (mounted && identical(controller, _controller)) {
        _animating = false;
        if (!controller.position.isScrollingNotifier.value) {
          _finish((controller.page ?? target.toDouble()).round());
        }
      }
    }
  }

  void _finish(int page) {
    if (!mounted) return;
    page = page.clamp(0, _pages.length - 1);
    final changed = page != _index;
    _index = page;
    _awaitingCommit = true;
    _drainingCommit = true;
    final generation = ++_commitGeneration;
    try {
      if (changed) widget.onPageSettled(_pages[page]);
    } finally {
      // A callback/rebuild failure must never leave the input state latched.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _commitGeneration) return;
        _awaitingCommit = false;
        if (_pendingConfiguration) setState(_synchronize);
        widget.onInteractionEnded?.call();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || generation != _commitGeneration) return;
          _drainingCommit = false;
          if (isBusy) {
            _wheelTurning = false;
            return;
          }
          final queued = _queuedDirection;
          final fromWheel = _queuedFromWheel;
          _queuedDirection = null;
          _queuedFromWheel = false;
          _wheelTurning = false;
          if (queued != null) _turn(forward: queued, fromWheel: fromWheel);
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  void _tap(Offset position, double width) {
    if (DateTime.now().difference(widget.lastBubbleTap()) <
        const Duration(milliseconds: 400)) {
      return;
    }
    if (widget.selection.value != null) {
      widget.onDismissSelection();
    } else if (!widget.tapToTurn) {
      widget.onCenterTap();
    } else if (position.dx < width * widget.previousTapFraction) {
      widget.onUserPageTurn?.call();
      widget.reverseTapSides ? turnToNextPage() : turnToPreviousPage();
    } else if (position.dx > width * widget.nextTapFraction) {
      widget.onUserPageTurn?.call();
      widget.reverseTapSides ? turnToPreviousPage() : turnToNextPage();
    } else {
      widget.onCenterTap();
    }
  }

  void _wheel(PointerScrollEvent event) {
    // Small trailing signals belong to one gesture, not additional pages.
    // Windows mouse wheels and explicitly classified native Mac wheels can
    // keep producing full notches. Source time keeps delayed dispatch from
    // turning an old burst into new input; deltas never classify Mac devices.
    final timestamp = event.timeStamp;
    final previous = _lastWheelTimestamp;
    final hasTimeline =
        timestamp > Duration.zero && previous != null && timestamp >= previous;
    final continuing = hasTimeline
        ? timestamp - previous < _wheelQuietPeriod
        : _wheelGestureActive;
    final forward = event.scrollDelta.dy > 0;
    final magnitude = event.scrollDelta.dy.abs();
    final nativeDiscrete = ReaderScrollInput.takeDiscrete(event);
    final discreteMouse =
        event.kind == PointerDeviceKind.mouse &&
        (ReaderPlatform.isWindows || nativeDiscrete);
    final reversing =
        discreteMouse &&
        continuing &&
        _wheelDirection != null &&
        _wheelDirection != forward &&
        magnitude >= 24;
    final accepted = _acceptedWheelTimestamp;
    final sourceReady =
        timestamp > Duration.zero && accepted != null && timestamp >= accepted
        ? timestamp - accepted >= _wheelRepeatInterval
        : _wheelRepeatReady;
    final sustainedNotch =
        discreteMouse &&
        continuing &&
        !_motionBusy &&
        _wheelCanRepeat &&
        _wheelDirection == forward &&
        _wheelLeadingDelta >= 24 &&
        magnitude >= 24 &&
        magnitude >= _wheelLeadingDelta * .8 &&
        sourceReady;
    _lastWheelTimestamp = timestamp > Duration.zero ? timestamp : null;
    _wheelGestureActive = true;
    _wheelGestureEnd?.cancel();
    _wheelGestureEnd = Timer(_wheelQuietPeriod, () {
      _wheelGestureActive = false;
      _wheelGestureEnd = null;
    });
    if (widget.selection.value != null ||
        (continuing && !reversing && !sustainedNotch) ||
        (_inputBlocked && (!discreteMouse || !_wheelTurning))) {
      return;
    }
    _wheelDirection = forward;
    _wheelLeadingDelta = magnitude;
    _acceptedWheelTimestamp = timestamp > Duration.zero ? timestamp : null;
    _wheelRepeatReady = false;
    _wheelRepeatTimer?.cancel();
    _wheelRepeatTimer = Timer(_wheelRepeatInterval, () {
      _wheelRepeatReady = true;
      _wheelRepeatTimer = null;
    });
    _wheelCanRepeat = false;
    widget.onUserPageTurn?.call();
    _turn(forward: forward, fromWheel: true);
  }

  bool _scroll(ScrollNotification notification) {
    if (_synchronizingController) return false;
    if (notification.metrics.axis != Axis.horizontal) return false;
    if (notification is ScrollStartNotification) {
      _overscroll = 0;
      if (notification.dragDetails != null) {
        _queuedDirection = null;
        _queuedFromWheel = false;
        _wheelTurning = false;
        _wheelCanRepeat = false;
      }
    } else if (notification is OverscrollNotification) {
      _overscroll += notification.overscroll;
    } else if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;
      if (metrics.pixels < metrics.minScrollExtent - 24) _overscroll = -35;
      if (metrics.pixels > metrics.maxScrollExtent + 24) _overscroll = 35;
    } else if (notification is ScrollEndNotification && !_animating) {
      final overscroll = _overscroll;
      _overscroll = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients || isBusy) return;
        final page = (_controller.page ?? _index.toDouble()).round().clamp(
          0,
          _pages.length - 1,
        );
        _finish(page);
        if (overscroll < -25 && page == 0) {
          widget.onPreviousBoundary();
        } else if (overscroll > 25 && page == _pages.length - 1) {
          widget.onNextBoundary();
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: widget.semanticLabel,
      onIncrease: () {
        widget.onUserPageTurn?.call();
        turnToNextPage();
      },
      onDecrease: () {
        widget.onUserPageTurn?.call();
        turnToPreviousPage();
      },
      child: Listener(
        onPointerSignal: (event) {
          if (!ReaderPlatform.isDesktop ||
              event is! PointerScrollEvent ||
              widget.selection.value != null ||
              event.scrollDelta.dy.abs() < event.scrollDelta.dx.abs() ||
              event.scrollDelta.dy == 0) {
            return;
          }
          // Let a descendant scrollable consume the event first. Vertical
          // mouse wheels otherwise have no effect on horizontal PageView.
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            _wheel(event);
          });
        },
        onPointerDown: (event) {
          _pointerStart =
              ReaderPlatform.isDesktop && event.kind == PointerDeviceKind.mouse
              ? null
              : event.localPosition;
          _reportedPointer = false;
        },
        onPointerMove: (event) {
          final start = _pointerStart;
          if (start == null ||
              _reportedPointer ||
              widget.selection.value != null) {
            return;
          }
          final delta = event.localPosition - start;
          if (delta.dx.abs() > 8 && delta.dx.abs() > delta.dy.abs()) {
            _reportedPointer = true;
            _wheelTurning = false;
            _wheelCanRepeat = false;
            widget.onUserPageTurn?.call();
          }
        },
        onPointerUp: (_) => _pointerStart = null,
        onPointerCancel: (_) => _pointerStart = null,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Finish against the same physical page that started the turn.
            // Resizing PageView changes its scroll pixels; resizing a curl
            // cancels its animation. Scale the old viewport for this brief
            // interval, then apply the new layout using the source anchor.
            final viewport = isBusy
                ? _pageViewport ?? constraints.biggest
                : constraints.biggest;
            _pageViewport = viewport;
            final pages = _pages;
            final Widget page;
            if (_mode == 'simulation') {
              page = SimulationPageTurn(
                key: _simulationKey,
                animationDuration: ReaderPlatform.isDesktop
                    ? Duration(
                        microseconds:
                            (SimulationPageTurn
                                        .desktopAnimationDuration
                                        .inMicroseconds /
                                    widget.animationSpeed.clamp(.6, 1.6))
                                .round(),
                      )
                    : const Duration(milliseconds: 300),
                totalPages: _pages.length,
                currentPageIndex: _index,
                pageSetKey: _pageSetVersion,
                contentVersion: _contentVersion,
                pageContentChanges: widget.pageContentChanges,
                backgroundColor: widget.backgroundColor,
                isDark: widget.isDark,
                supportedDevices: ReaderPlatform.isDesktop
                    ? const {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.trackpad,
                      }
                    : null,
                isSelectionActive: () => widget.selection.value != null,
                onDismissSelection: widget.onDismissSelection,
                lastBubbleTapTimeGetter: widget.lastBubbleTap,
                previousTapFraction: widget.previousTapFraction,
                nextTapFraction: widget.nextTapFraction,
                reverseTapSides: widget.reverseTapSides,
                pageIdentity: (index) => pages[index].id,
                pageBuilder: (context, index) => pages[index].builder(context),
                onPageChanged: _finish,
                onInteractionEnded: () => _finish(_index),
                onTurnRequested: (forward) {
                  widget.onUserPageTurn?.call();
                  _turn(forward: forward);
                },
                onTurnStarted: clearQueuedTurns,
                onPreviousChapter: widget.onPreviousBoundary,
                onNextChapter: widget.onNextBoundary,
                onCenterTap: widget.onCenterTap,
                tapToTurn: widget.tapToTurn,
              );
            } else {
              page = GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) =>
                    _tap(details.localPosition, viewport.width),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scroll,
                  child: PageView.builder(
                    key: ValueKey(_controllerRevision),
                    controller: _controller,
                    itemCount: _pages.length,
                    findChildIndexCallback: (key) {
                      if (key is! ValueKey<Object>) return null;
                      final index = _pages.indexWhere(
                        (page) => page.id == key.value,
                      );
                      return index < 0 ? null : index;
                    },
                    allowImplicitScrolling: true,
                    physics: widget.selection.value != null
                        ? const NeverScrollableScrollPhysics()
                        : const BouncingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                    itemBuilder: (context, index) => KeyedSubtree(
                      key: ValueKey<Object>(_pages[index].id),
                      child: ReaderPageTransition(
                        controller: _controller,
                        pageIndex: index,
                        width: viewport.width,
                        mode: _mode,
                        isDark: widget.isDark,
                        child: _pages[index].builder(context),
                      ),
                    ),
                  ),
                ),
              );
            }
            return FittedBox(
              fit: BoxFit.fill,
              child: SizedBox.fromSize(
                size: viewport,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    page,
                    if (ReaderPlatform.isDesktop &&
                        widget.tapToTurn &&
                        widget.desktopEdgeWidth > 0)
                      for (final right in [false, true])
                        Align(
                          alignment: right
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: SizedBox(
                            width: widget.desktopEdgeWidth.clamp(
                              0,
                              viewport.width * .15,
                            ),
                            height: 88,
                            child: _ReaderPageEdge(
                              key: ValueKey(
                                right != widget.reverseTapSides
                                    ? 'reader-next-page-edge'
                                    : 'reader-previous-page-edge',
                              ),
                              forward: right != widget.reverseTapSides,
                              color:
                                  widget.foregroundColor ??
                                  (widget.isDark
                                      ? Colors.white70
                                      : Colors.black54),
                              onTap: () => _tap(
                                Offset(
                                  right ? viewport.width - 1 : 1,
                                  viewport.height / 2,
                                ),
                                viewport.width,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// An explicit mouse target lives only in the page's existing horizontal
/// padding. Text retains double-click/drag selection; the edge responds on
/// release immediately, without waiting for a possible second text click.
class _ReaderPageEdge extends StatefulWidget {
  final bool forward;
  final Color color;
  final VoidCallback onTap;

  const _ReaderPageEdge({
    super.key,
    required this.forward,
    required this.color,
    required this.onTap,
  });

  @override
  State<_ReaderPageEdge> createState() => _ReaderPageEdgeState();
}

class _ReaderPageEdgeState extends State<_ReaderPageEdge> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.forward ? '下一页' : '上一页',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        button: true,
        label: widget.forward ? '下一页' : '上一页',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Center(
            child: AnimatedOpacity(
              opacity: _hovered ? .85 : .18,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 100),
              child: Icon(
                widget.forward ? Icons.chevron_right : Icons.chevron_left,
                color: widget.color,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
