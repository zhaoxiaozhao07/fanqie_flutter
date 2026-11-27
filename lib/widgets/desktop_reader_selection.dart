import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services/reader_text.dart';

/// A range in canonical text, never in the synthetic indentation or a bubble.
class DesktopReaderSelectionSegment {
  final int chapterIndex, paragraphIndex, start, end;
  final String source;

  const DesktopReaderSelectionSegment({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.source,
    required this.start,
    required this.end,
  });

  String get text => source.substring(start, end);
}

class DesktopReaderSelectionController extends ChangeNotifier {
  final Set<_DesktopReaderSelectionState> _areas = {};
  _DesktopReaderSelectionState? _active;
  bool _closed = false, _notificationPending = false;
  // 按下时落在交互控件（段评气泡、章节评论、插图）上的指针。
  // 这类按压的抬起绝不能被当成阅读面空白点击，否则会误翻页。
  final Set<int> _interactivePresses = {};

  void _markInteractivePress(int pointer) => _interactivePresses.add(pointer);

  bool _consumeInteractivePress(int pointer) =>
      _interactivePresses.remove(pointer);

  List<DesktopReaderSelectionSegment> get segments =>
      _active?._segments() ?? const [];
  bool get hasSelection => segments.isNotEmpty;

  String get selectedText {
    final ranges = segments;
    final text = StringBuffer();
    DesktopReaderSelectionSegment? previous;
    for (final range in ranges) {
      if (previous != null &&
          (range.chapterIndex != previous.chapterIndex ||
              range.paragraphIndex != previous.paragraphIndex)) {
        text.write('\n\n');
      }
      text.write(range.text);
      previous = range;
    }
    return text.toString();
  }

  Future<void> copy() async {
    final text = selectedText;
    if (text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
  }

  void clear() {
    for (final area in _areas.toList()) {
      area._region.currentState?.selectableRegion
        ?..hideToolbar()
        ..clearSelection();
    }
    _active = null;
    _notify();
  }

  void _notify() {
    if (_closed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notificationPending) return;
      _notificationPending = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notificationPending = false;
        if (!_closed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _areas.clear();
    _active = null;
    super.dispose();
  }
}

typedef DesktopSingleSelectionMenu =
    Widget Function(
      BuildContext context,
      TextSelectionToolbarAnchors anchors,
      DesktopReaderSelectionSegment range,
      VoidCallback dismiss,
    );
typedef DesktopMultipleSelectionMenu =
    Widget Function(
      BuildContext context,
      TextSelectionToolbarAnchors anchors,
      List<DesktopReaderSelectionSegment> ranges,
      VoidCallback dismiss,
    );

/// One region per visible spread (or virtualized scroll view). Text widgets
/// share a native mouse selection, but cached adjacent pages do not join it.
class DesktopReaderSelection extends StatefulWidget {
  final DesktopReaderSelectionController controller;
  final DesktopSingleSelectionMenu singleSelectionMenu;
  final DesktopMultipleSelectionMenu? multipleSelectionMenu;
  final ValueChanged<Offset>? onBlankTap;
  final void Function(Offset globalPosition, int pointer)? onTouchTap;
  final Widget child;

  const DesktopReaderSelection({
    super.key,
    required this.controller,
    required this.singleSelectionMenu,
    this.multipleSelectionMenu,
    this.onBlankTap,
    this.onTouchTap,
    required this.child,
  });

  @override
  State<DesktopReaderSelection> createState() => _DesktopReaderSelectionState();
}

class _DesktopReaderSelectionState extends State<DesktopReaderSelection> {
  final _region = GlobalKey<SelectionAreaState>();
  final Set<_DesktopSelectableParagraphState> _paragraphs = {};
  int? _textPointer;
  Offset? _blankPointerStart;
  bool _blankHadSelection = false;
  int? _touchPointer;
  Offset? _touchPointerStart;
  DateTime? _touchPointerDownAt;
  bool _touchHadSelection = false;

  @override
  void initState() {
    super.initState();
    widget.controller._areas.add(this);
  }

  @override
  void didUpdateWidget(DesktopReaderSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._areas.remove(this);
      widget.controller._areas.add(this);
    }
  }

  List<DesktopReaderSelectionSegment> _segments() {
    final ranges =
        [
          for (final paragraph in _paragraphs)
            if (paragraph._range() case final range?) range,
        ]..sort((a, b) {
          final chapter = a.chapterIndex.compareTo(b.chapterIndex);
          if (chapter != 0) return chapter;
          final paragraph = a.paragraphIndex.compareTo(b.paragraphIndex);
          return paragraph != 0 ? paragraph : a.start.compareTo(b.start);
        });
    final merged = <DesktopReaderSelectionSegment>[];
    for (final range in ranges) {
      final last = merged.lastOrNull;
      if (last != null &&
          last.chapterIndex == range.chapterIndex &&
          last.paragraphIndex == range.paragraphIndex &&
          last.source == range.source &&
          last.end >= range.start) {
        merged[merged.length - 1] = DesktopReaderSelectionSegment(
          chapterIndex: last.chapterIndex,
          paragraphIndex: last.paragraphIndex,
          source: last.source,
          start: last.start,
          end: math.max(last.end, range.end),
        );
      } else {
        merged.add(range);
      }
    }
    return List.unmodifiable(merged);
  }

  void _changed(SelectedContent? content) {
    if (content != null && content.plainText.isNotEmpty) {
      widget.controller._active = this;
    } else if (widget.controller._active == this) {
      widget.controller._active = null;
    }
    widget.controller._notify();
  }

  @override
  void dispose() {
    widget.controller._areas.remove(this);
    if (widget.controller._active == this) {
      widget.controller._active = null;
      widget.controller._notify();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DesktopReaderSelectionScope(
    controller: widget.controller,
    child: Actions(
      actions: {
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (_) {
            unawaited(widget.controller.copy());
            return null;
          },
        ),
      },
      child: Listener(
        onPointerDown: (event) {
          if (widget.onTouchTap != null &&
              event.kind != PointerDeviceKind.mouse) {
            // 移动端触屏统一追踪单指轻点，用于穿透 SelectionArea 触发翻页或呼出控制栏，
            // 同时避免长按跨段选词、滑动翻页、交互气泡与取消选区时误触发。
            _touchPointer = event.pointer;
            _touchPointerStart = event.position;
            _touchPointerDownAt = DateTime.now();
            _touchHadSelection = widget.controller.hasSelection;
          } else {
            _blankHadSelection = widget.controller.hasSelection;
            _blankPointerStart =
                event.buttons == kPrimaryButton && _textPointer != event.pointer
                ? event.position
                : null;
          }
        },
        onPointerMove: (event) {
          final start = _blankPointerStart;
          if (start != null && (event.position - start).distance > kTouchSlop) {
            _blankPointerStart = null;
          }
          if (event.pointer == _touchPointer && _touchPointerStart != null) {
            if ((event.position - _touchPointerStart!).distance > kTouchSlop) {
              _touchPointerStart = null;
            }
          }
        },
        onPointerCancel: (event) {
          widget.controller._consumeInteractivePress(event.pointer);
          _blankPointerStart = null;
          _textPointer = null;
          if (event.pointer == _touchPointer) {
            _touchPointer = null;
            _touchPointerStart = null;
            _touchPointerDownAt = null;
          }
        },
        onPointerUp: (event) {
          // 交互控件上的按压不视为阅读面空白点击：否则点击段评、章节评论
          // 或插图时会顺带触发翻页热区。
          final interactive = widget.controller._consumeInteractivePress(
            event.pointer,
          );
          if (widget.onTouchTap != null &&
              event.kind != PointerDeviceKind.mouse) {
            if (event.pointer == _touchPointer) {
              final start = _touchPointerStart;
              final downAt = _touchPointerDownAt;
              final hadSelection = _touchHadSelection;
              _touchPointer = null;
              _touchPointerStart = null;
              _touchPointerDownAt = null;
              _textPointer = null;
              final elapsed = downAt == null
                  ? Duration.zero
                  : DateTime.now().difference(downAt);
              if (!interactive &&
                  start != null &&
                  !hadSelection &&
                  !widget.controller.hasSelection &&
                  elapsed < const Duration(milliseconds: 350)) {
                widget.onTouchTap!(event.position, event.pointer);
              }
            }
            return;
          }
          if (!interactive &&
              _blankPointerStart != null &&
              !_blankHadSelection) {
            widget.onBlankTap?.call(event.position);
          }
          _blankPointerStart = null;
          _textPointer = null;
        },
        child: SelectionArea(
          key: _region,
          onSelectionChanged: _changed,
          contextMenuBuilder: (context, region) {
            final ranges = _segments();
            if (ranges.isEmpty) return const SizedBox.shrink();
            void dismiss() => widget.controller.clear();
            if (ranges.length == 1) {
              return widget.singleSelectionMenu(
                context,
                region.contextMenuAnchors,
                ranges.single,
                dismiss,
              );
            }
            final anchors = region.contextMenuAnchors;
            if (widget.multipleSelectionMenu != null) {
              return widget.multipleSelectionMenu!(
                context,
                anchors,
                ranges,
                dismiss,
              );
            }
            return AdaptiveSelectionBubbleToolbar(
              anchors: anchors,
              children: [
                TextButton.icon(
                  key: const ValueKey('desktop-copy-paragraphs'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    minimumSize: const Size(0, 38),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    await widget.controller.copy();
                    dismiss();
                  },
                  icon: const Icon(Icons.copy, size: 15),
                  label: const Text('复制', style: TextStyle(fontSize: 13)),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '跨段选区仅支持复制',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            );
          },
          child: _DesktopSelectionScope(owner: this, child: widget.child),
        ),
      ),
    ),
  );
}

/// 自适应屏幕尺寸的选区暗色浮动气泡工具栏。
///
/// 替代固定 44dp 高度的 Material [TextSelectionToolbar]，依据屏幕可用宽度与安全区
/// 自动单行或折行排布选项并按真实尺寸贴合选区上下定位，避免窄屏或大字号下末尾选项被裁切。
class AdaptiveSelectionBubbleToolbar extends StatelessWidget {
  final TextSelectionToolbarAnchors anchors;
  final List<Widget> children;
  final double screenPadding;
  final double contentDistanceAbove;
  final double contentDistanceBelow;

  const AdaptiveSelectionBubbleToolbar({
    super.key,
    required this.anchors,
    required this.children,
    this.screenPadding = 12.0,
    this.contentDistanceAbove = 10.0,
    this.contentDistanceBelow = 22.0,
  });

  @override
  Widget build(BuildContext context) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final leftInset = mediaPadding.left + screenPadding;
    final rightInset = mediaPadding.right + screenPadding;
    final topInset = mediaPadding.top + screenPadding;
    final bottomInset = mediaPadding.bottom + screenPadding;

    final anchorAbove =
        anchors.primaryAnchor - Offset(leftInset, topInset + contentDistanceAbove);
    final rawBelow = anchors.secondaryAnchor ?? anchors.primaryAnchor;
    final anchorBelow =
        rawBelow - Offset(leftInset, topInset - contentDistanceBelow);

    return Padding(
      padding: EdgeInsets.fromLTRB(leftInset, topInset, rightInset, bottomInset),
      child: CustomSingleChildLayout(
        delegate: _AdaptiveSelectionToolbarLayoutDelegate(
          anchorAbove: anchorAbove,
          anchorBelow: anchorBelow,
        ),
        child: Material(
          key: const ValueKey('adaptive-selection-bubble-toolbar'),
          color: const Color(0xFF232326),
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Wrap(
              alignment: WrapAlignment.center,
              runAlignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 4,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _AdaptiveSelectionToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchorAbove;
  final Offset anchorBelow;

  const _AdaptiveSelectionToolbarLayoutDelegate({
    required this.anchorAbove,
    required this.anchorBelow,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // 解除固定 44dp 高度限制，允许工具栏根据手机宽度自动折行并完整包裹所有选项。
    return BoxConstraints(
      minWidth: 0,
      maxWidth: math.max(120.0, constraints.maxWidth),
      minHeight: 0,
      maxHeight: math.max(44.0, constraints.maxHeight),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxX = math.max(0.0, size.width - childSize.width);
    final maxY = math.max(0.0, size.height - childSize.height);

    final fitsAbove = anchorAbove.dy - childSize.height >= 0;
    final fitsBelow = anchorBelow.dy + childSize.height <= size.height;

    final double y;
    final double anchorX;
    if (fitsAbove) {
      y = (anchorAbove.dy - childSize.height).clamp(0.0, maxY).toDouble();
      anchorX = anchorAbove.dx;
    } else if (fitsBelow) {
      y = anchorBelow.dy.clamp(0.0, maxY).toDouble();
      anchorX = anchorBelow.dx;
    } else {
      // 上下均空间紧张时，靠向剩余空间更充足的一侧并严格收敛在安全区内。
      final spaceAbove = anchorAbove.dy;
      final spaceBelow = size.height - anchorBelow.dy;
      if (spaceAbove >= spaceBelow) {
        y = 0.0;
        anchorX = anchorAbove.dx;
      } else {
        y = maxY;
        anchorX = anchorBelow.dx;
      }
    }

    final x = (anchorX - childSize.width / 2).clamp(0.0, maxX).toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_AdaptiveSelectionToolbarLayoutDelegate oldDelegate) {
    return anchorAbove != oldDelegate.anchorAbove ||
        anchorBelow != oldDelegate.anchorBelow;
  }
}

/// Exposes the active selection controller to interactive regions.
class DesktopReaderSelectionScope extends InheritedWidget {
  final DesktopReaderSelectionController controller;

  const DesktopReaderSelectionScope({
    super.key,
    required this.controller,
    required super.child,
  });

  @override
  bool updateShouldNotify(DesktopReaderSelectionScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Marks a subtree as interactive for the desktop reading surface.
///
/// The blank-tap detection runs on raw pointer events, so it also sees
/// presses that belong to buttons inside the reading text. Wrapping those
/// controls keeps a click on them (comment bubbles, chapter comments,
/// illustrations) from also turning the page.
class DesktopInteractiveRegion extends StatelessWidget {
  final Widget child;

  const DesktopInteractiveRegion({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<
      DesktopReaderSelectionScope
    >();
    if (scope == null) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) =>
          scope.controller._markInteractivePress(event.pointer),
      onPointerCancel: (event) =>
          scope.controller._consumeInteractivePress(event.pointer),
      child: child,
    );
  }
}

class _DesktopSelectionScope extends InheritedWidget {
  final _DesktopReaderSelectionState owner;
  const _DesktopSelectionScope({required this.owner, required super.child});
  @override
  bool updateShouldNotify(_DesktopSelectionScope oldWidget) =>
      owner != oldWidget.owner;
}

/// 追踪移动端翻页容器的当前活跃页标识，支持在 build 阶段安全同步最新页标识并在帧末通知已挂载页更新注册状态。
class ActivePageSelectionNotifier extends ChangeNotifier
    implements ValueListenable<Object?> {
  Object? _value;
  bool _disposed = false;
  bool _notifyScheduled = false;

  @override
  Object? get value => _value;

  void sync(Object? next) {
    if (_disposed || _value == next) return;
    _value = next;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 将当前活跃页直接桥接到外层 SelectionArea 的 SelectionRegistrar，
/// 绕过 PageView 内置 Scrollable 的 SelectionHandler 干扰，同时屏蔽相邻缓存页参与选区。
class ActivePageSelectionBridge extends StatelessWidget {
  final Object pageId;
  final ValueListenable<Object?> activePageId;
  final SelectionRegistrar? registrar;
  final Widget child;

  const ActivePageSelectionBridge({
    super.key,
    required this.pageId,
    required this.activePageId,
    required this.registrar,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: activePageId,
      builder: (context, activeId, child) {
        final targetRegistrar = registrar;
        if (targetRegistrar != null && activeId == pageId) {
          return SelectionRegistrarScope(
            registrar: targetRegistrar,
            child: child!,
          );
        }
        return SelectionContainer.disabled(child: child!);
      },
      child: child,
    );
  }
}

/// Ordinary pages cannot scroll vertically. Register their column directly
/// with the spread instead of the Scrollable selection handler, which resets
/// the original start edge when a drag crosses into another scrollable. Keep
/// the scroll view for overflow measurement; oversized pages retain native
/// selection auto-scroll.
class DesktopPageSelectionViewport extends StatefulWidget {
  final bool oversized;
  final Widget child;
  const DesktopPageSelectionViewport({
    super.key,
    required this.oversized,
    required this.child,
  });
  @override
  State<DesktopPageSelectionViewport> createState() =>
      _DesktopPageSelectionViewportState();
}

class _DesktopPageSelectionViewportState
    extends State<DesktopPageSelectionViewport> {
  final _delegate = _DesktopPageColumnDelegate();
  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    return SingleChildScrollView(
      physics: widget.oversized
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      child: !widget.oversized && registrar != null
          ? SelectionContainer(
              registrar: registrar,
              delegate: _delegate,
              child: widget.child,
            )
          : widget.child,
    );
  }
}

class _DesktopPageColumnDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    final bounds = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & containerSize,
    );
    Offset? edge;
    if (event.globalPosition.dx >= bounds.right) {
      edge = bounds.bottomRight + const Offset(1, 1);
    } else if (event.globalPosition.dx < bounds.left) {
      edge = bounds.topLeft - const Offset(1, 1);
    }
    // A point in another column is before/after the whole column, regardless
    // of its y-position. Delegate only that moving edge to the native text
    // handlers, keeping the original (possibly mid-paragraph) anchor intact.
    if (edge != null) {
      event = event.type == SelectionEventType.endEdgeUpdate
          ? SelectionEdgeUpdateEvent.forEnd(
              globalPosition: edge,
              granularity: event.granularity,
            )
          : SelectionEdgeUpdateEvent.forStart(
              globalPosition: edge,
              granularity: event.granularity,
            );
    }
    return super.handleSelectionEdgeUpdate(event);
  }
}

/// Only mounted paragraphs allocate selection listeners, not whole chapters.
class DesktopSelectableParagraph extends StatefulWidget {
  final Key? textKey;
  final TextSpan span;
  final TextStyle style;
  final int chapterIndex, paragraphIndex, sourceStart, sourceEnd;
  final String sourceParagraph;
  final double textWidthInset;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerMoveEvent) onPointerMove;
  final VoidCallback onPointerUp, onPointerCancel;

  const DesktopSelectableParagraph({
    super.key,
    this.textKey,
    required this.span,
    required this.style,
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.sourceParagraph,
    required this.sourceStart,
    required this.sourceEnd,
    required this.textWidthInset,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  @override
  State<DesktopSelectableParagraph> createState() =>
      _DesktopSelectableParagraphState();
}

class _DesktopSelectableParagraphState
    extends State<DesktopSelectableParagraph> {
  final _selection = SelectionListenerNotifier();
  _DesktopReaderSelectionState? _owner;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final owner = context
        .dependOnInheritedWidgetOfExactType<_DesktopSelectionScope>()
        ?.owner;
    if (owner == _owner) return;
    _owner?._paragraphs.remove(this);
    _owner = owner;
    _owner?._paragraphs.add(this);
  }

  DesktopReaderSelectionSegment? _range() {
    if (!_selection.registered ||
        _selection.selection.status != SelectionStatus.uncollapsed) {
      return null;
    }
    final range = _selection.selection.range;
    if (range == null) return null;
    final prefix =
        widget.span.toPlainText().length -
        (widget.sourceEnd - widget.sourceStart);
    var start = (math.min(range.startOffset, range.endOffset) - prefix).clamp(
      0,
      widget.sourceEnd - widget.sourceStart,
    );
    var end = (math.max(range.startOffset, range.endOffset) - prefix).clamp(
      0,
      widget.sourceEnd - widget.sourceStart,
    );
    start = ReaderText.safeOffset(
      widget.sourceParagraph,
      widget.sourceStart + start,
    );
    end = ReaderText.safeOffset(
      widget.sourceParagraph,
      widget.sourceStart + end,
    );
    final selected = widget.sourceParagraph.substring(start, end);
    start += selected.length - selected.trimLeft().length;
    end -= selected.length - selected.trimRight().length;
    if (end <= start) return null;
    return DesktopReaderSelectionSegment(
      chapterIndex: widget.chapterIndex,
      paragraphIndex: widget.paragraphIndex,
      source: widget.sourceParagraph,
      start: start,
      end: end,
    );
  }

  @override
  void dispose() {
    _owner?._paragraphs.remove(this);
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      _owner?._textPointer = event.pointer;
      widget.onPointerDown(event);
    },
    onPointerMove: widget.onPointerMove,
    onPointerUp: (_) => widget.onPointerUp(),
    onPointerCancel: (_) => widget.onPointerCancel(),
    child: Padding(
      padding: EdgeInsets.only(right: widget.textWidthInset),
      child: SelectionListener(
        selectionNotifier: _selection,
        child: Text.rich(widget.span, key: widget.textKey, style: widget.style),
      ),
    ),
  );
}
