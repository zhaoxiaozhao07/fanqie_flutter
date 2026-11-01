import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'reader_page_transition.dart';
import 'simulation_page_turn.dart';

class ReaderPageItem {
  final Object id;
  final WidgetBuilder builder;

  const ReaderPageItem({required this.id, required this.builder});
}

/// 模式只决定合成效果，章节与普通页面共用同一个翻页入口和收尾流程。
class ReaderPageView extends StatefulWidget {
  final List<ReaderPageItem> pages;
  final Object currentPageId;
  final Object contentVersion;
  final String mode;
  final Color backgroundColor;
  final bool isDark;
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

  const ReaderPageView({
    super.key,
    required this.pages,
    required this.currentPageId,
    required this.contentVersion,
    required this.mode,
    required this.backgroundColor,
    required this.isDark,
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
  double _overscroll = 0;
  bool _pendingConfiguration = false;
  int _pageSetVersion = 0;
  int _controllerRevision = 0;
  bool _awaitingCommit = false;

  bool get isBusy =>
      _animating ||
      _awaitingCommit ||
      (_mode == 'simulation'
          ? _simulationKey.currentState?.isTurning ?? false
          : _controller.hasClients &&
                _controller.position.isScrollingNotifier.value);

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
    final samePages =
        _pages.length == widget.pages.length &&
        List.generate(
          _pages.length,
          (i) => _pages[i].id == widget.pages[i].id,
        ).every((equal) => equal);
    if (!samePages || target != _index || _mode != widget.mode) {
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
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void turnToNextPage() => _turn(forward: true);
  void turnToPreviousPage() => _turn(forward: false);
  void clearQueuedTurns() {
    _queuedDirection = null;
    _simulationKey.currentState?.clearQueuedTurns();
  }

  void _turn({required bool forward}) {
    if (widget.selection.value != null) {
      widget.onDismissSelection();
      return;
    }
    if (isBusy) {
      _queuedDirection = forward;
      return;
    }
    if (_mode == 'simulation') {
      if (forward) {
        _simulationKey.currentState?.turnToNextPage();
      } else {
        _simulationKey.currentState?.turnToPreviousPage();
      }
      return;
    }
    if (!_controller.hasClients) return;
    final target = _index + (forward ? 1 : -1);
    if (target < 0) {
      widget.onPreviousBoundary();
    } else if (target >= _pages.length) {
      widget.onNextBoundary();
    } else {
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
          duration: const Duration(milliseconds: 260),
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
    if (changed) widget.onPageSettled(_pages[page]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _awaitingCommit = false;
      if (_pendingConfiguration) setState(_synchronize);
      widget.onInteractionEnded?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || isBusy) return;
        final queued = _queuedDirection;
        _queuedDirection = null;
        if (queued != null) _turn(forward: queued);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _tap(Offset position, double width) {
    if (DateTime.now().difference(widget.lastBubbleTap()) <
        const Duration(milliseconds: 400)) {
      return;
    }
    if (widget.selection.value != null) {
      widget.onDismissSelection();
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

  bool _scroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) return false;
    if (notification is ScrollStartNotification) {
      _overscroll = 0;
      if (notification.dragDetails != null) _queuedDirection = null;
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
        onPointerDown: (event) {
          _pointerStart = event.localPosition;
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
            widget.onUserPageTurn?.call();
          }
        },
        onPointerUp: (_) => _pointerStart = null,
        onPointerCancel: (_) => _pointerStart = null,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_mode == 'simulation') {
              return SimulationPageTurn(
                key: _simulationKey,
                totalPages: _pages.length,
                currentPageIndex: _index,
                pageSetKey: _pageSetVersion,
                contentVersion: _contentVersion,
                pageContentChanges: widget.pageContentChanges,
                backgroundColor: widget.backgroundColor,
                isDark: widget.isDark,
                isSelectionActive: () => widget.selection.value != null,
                onDismissSelection: widget.onDismissSelection,
                lastBubbleTapTimeGetter: widget.lastBubbleTap,
                previousTapFraction: widget.previousTapFraction,
                nextTapFraction: widget.nextTapFraction,
                reverseTapSides: widget.reverseTapSides,
                pageBuilder: (context, index) => _pages[index].builder(context),
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
              );
            }
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) =>
                  _tap(details.localPosition, constraints.maxWidth),
              child: NotificationListener<ScrollNotification>(
                onNotification: _scroll,
                child: PageView.builder(
                  key: ValueKey(_controllerRevision),
                  controller: _controller,
                  itemCount: _pages.length,
                  allowImplicitScrolling: true,
                  physics: widget.selection.value != null
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                  itemBuilder: (context, index) => ReaderPageTransition(
                    controller: _controller,
                    pageIndex: index,
                    width: constraints.maxWidth,
                    mode: _mode,
                    isDark: widget.isDark,
                    child: _pages[index].builder(context),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
