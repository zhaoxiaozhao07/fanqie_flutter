import 'dart:async';
import 'dart:math' as math;

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
  final ValueChanged<Offset> onBlankTap;
  final Widget child;

  const DesktopReaderSelection({
    super.key,
    required this.controller,
    required this.singleSelectionMenu,
    this.multipleSelectionMenu,
    required this.onBlankTap,
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
  Widget build(BuildContext context) => Actions(
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
        _blankHadSelection = widget.controller.hasSelection;
        _blankPointerStart =
            event.buttons == kPrimaryButton && _textPointer != event.pointer
            ? event.position
            : null;
      },
      onPointerMove: (event) {
        final start = _blankPointerStart;
        if (start != null && (event.position - start).distance > kTouchSlop) {
          _blankPointerStart = null;
        }
      },
      onPointerCancel: (_) {
        _blankPointerStart = null;
        _textPointer = null;
      },
      onPointerUp: (event) {
        if (_blankPointerStart != null && !_blankHadSelection) {
          widget.onBlankTap(event.position);
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
          return TextSelectionToolbar(
            anchorAbove: anchors.primaryAnchor,
            anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF232326),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('desktop-copy-paragraphs'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () async {
                        await widget.controller.copy();
                        dismiss();
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制'),
                    ),
                    const Text(
                      '跨段选区仅支持复制',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
        child: _DesktopSelectionScope(owner: this, child: widget.child),
      ),
    ),
  );
}

class _DesktopSelectionScope extends InheritedWidget {
  final _DesktopReaderSelectionState owner;
  const _DesktopSelectionScope({required this.owner, required super.child});
  @override
  bool updateShouldNotify(_DesktopSelectionScope oldWidget) =>
      owner != oldWidget.owner;
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
        child: Text.rich(widget.span, style: widget.style),
      ),
    ),
  );
}
