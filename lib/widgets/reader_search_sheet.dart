import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chapter.dart';
import '../models/reader_theme.dart';
import '../services/reader_search_service.dart';
import '../services/desktop_shortcut_preferences.dart';

/// The mounted (possibly offstage) panel retains its query and result stream.
class ReaderSearchController {
  _ReaderSearchSheetState? _state;

  bool get hasQueryFocus => _state?._queryFocus.hasFocus ?? false;
  void focus() => _state?._focusQuery();
  void cancelOpen() => _state?._cancelOpen();
  Future<void> next({bool backwards = false}) async {
    await _state?._openRelative(backwards: backwards);
  }
}

class ReaderSearchSheet extends StatefulWidget {
  final String bookId;
  final List<Chapter> chapters;
  final int chapterIndex;
  final Map<String, String> canonicalMemory;
  final ReaderTheme theme;
  final ReaderSearchController? controller;
  final Future<bool> Function(ReaderSearchHit)? onOpenHit;
  final VoidCallback? onClose;
  final VoidCallback? onCancelOpen;
  final void Function(
    List<ReaderSearchHit> hits,
    ReaderSearchHit? active,
    bool showAll,
  )?
  onHighlightsChanged;

  const ReaderSearchSheet({
    super.key,
    required this.bookId,
    required this.chapters,
    required this.chapterIndex,
    required this.canonicalMemory,
    required this.theme,
    this.controller,
    this.onOpenHit,
    this.onClose,
    this.onCancelOpen,
    this.onHighlightsChanged,
  });

  @override
  State<ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<ReaderSearchSheet> {
  final _query = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'reader-search-query');
  final _resultsScroll = ScrollController();
  final _service = ReaderSearchService();
  final _hits = <ReaderSearchHit>[];
  StreamSubscription<ReaderSearchUpdate>? _subscription;
  Timer? _debounce;
  int _generation = 0;
  bool _chapterOnly = true;
  bool _caseSensitive = false;
  bool _searching = false;
  bool _cancelled = false;
  bool _limited = false;
  int _searched = 0;
  String? _error;
  String _searchedQuery = '';
  int _selected = -1;
  int _openGeneration = 0;
  int _openingIndex = -1;
  bool _showAll = true;
  void _publish() => widget.onHighlightsChanged?.call(
    List.unmodifiable(_hits),
    _selected >= 0 && _selected < _hits.length ? _hits[_selected] : null,
    _showAll,
  );

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(ReaderSearchSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._state = null;
      widget.controller?._state = this;
    }
  }

  bool get _composing =>
      _query.value.composing.isValid && !_query.value.composing.isCollapsed;

  void _focusQuery() {
    _queryFocus.requestFocus();
    if (!_composing) {
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    }
  }

  Future<void> _openRelative({bool backwards = false}) async {
    if (_hits.isEmpty || _composing) return;
    final selected = _openingIndex >= 0 ? _openingIndex : _selected;
    final index = selected < 0
        ? (backwards ? _hits.length - 1 : 0)
        : (selected + (backwards ? -1 : 1)) % _hits.length;
    await _openHit(index);
  }

  Future<void> _openHit(int index) async {
    final hit = _hits[index];
    final generation = _generation;
    final opening = ++_openGeneration;
    _openingIndex = index;
    final open = widget.onOpenHit;
    if (open == null) {
      FocusManager.instance.primaryFocus?.unfocus();
      Navigator.pop(context, hit);
      return;
    }
    bool opened;
    try {
      opened = await open(hit);
    } catch (_) {
      opened = false;
    }
    if (!mounted || generation != _generation || opening != _openGeneration) {
      return;
    }
    _openingIndex = -1;
    if (!opened) return;
    setState(() => _selected = index);
    _publish();
    if (_resultsScroll.hasClients) {
      final position = _resultsScroll.position;
      final top = index * _resultHeight;
      if (top < position.pixels ||
          top + _resultHeight > position.pixels + position.viewportDimension) {
        _resultsScroll.jumpTo(
          (top - position.viewportDimension / 3).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
      }
    }
  }

  double get _resultHeight =>
      88 * MediaQuery.textScalerOf(context).scale(14) / 14;

  void _invalidate() {
    _cancelOpen();
    _generation++;
    _debounce?.cancel();
    _service.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _cancelOpen() {
    if (_openingIndex < 0) return;
    _openingIndex = -1;
    _openGeneration++;
    widget.onCancelOpen?.call();
  }

  void _changed() {
    _invalidate();
    setState(() {
      _hits.clear();
      _selected = -1;
      _searched = 0;
      _searching = false;
      _cancelled = false;
      _limited = false;
      _error = null;
    });
    _publish();
    if (_query.text.trim().isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 200), _search);
    }
  }

  void _search() {
    if (_composing) return;
    _invalidate();
    if (_query.text.trim().isEmpty) return;
    final generation = _generation;
    setState(() {
      _hits.clear();
      _selected = -1;
      _searchedQuery = _query.text.trim();
      _searching = true;
      _searched = 0;
      _cancelled = false;
      _limited = false;
      _error = null;
    });
    _publish();
    _subscription = _service
        .search(
          bookId: widget.bookId,
          chapters: widget.chapters,
          query: _query.text,
          onlyChapterIndex: _chapterOnly ? widget.chapterIndex : null,
          canonicalMemory: widget.canonicalMemory,
          caseSensitive: _caseSensitive,
        )
        .listen(
          (update) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _hits.addAll(update.hits);
              _searched = update.searchedChapters;
              _limited = update.limited;
              if (update.done) _searching = false;
            });
            _publish();
          },
          onError: (Object error) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _searching = false;
              _error = error is FormatException ? error.message : '缓存读取失败，请重试';
            });
          },
        );
  }

  void _cancel() {
    _invalidate();
    setState(() {
      _searching = false;
      _cancelled = true;
    });
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    // Disposal belongs to the route; do not call an ancestor's setState here.
    _openingIndex = -1;
    _invalidate();
    _query.dispose();
    _queryFocus.dispose();
    _resultsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.theme.wrap(
    Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || _composing) {
          return KeyEventResult.ignored;
        }
        final keys = HardwareKeyboard.instance;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          (widget.onClose ?? () => Navigator.pop(context))();
          return KeyEventResult.handled;
        }
        final mapped = DesktopShortcutPreferences().match(event);
        if (mapped == 'findNext' ||
            mapped == 'findPrevious' ||
            (event.logicalKey == LogicalKeyboardKey.f3 &&
                !keys.isAltPressed &&
                !keys.isMetaPressed &&
                !keys.isControlPressed)) {
          unawaited(
            _openRelative(
              backwards:
                  mapped == 'findPrevious' ||
                  (event.logicalKey == LogicalKeyboardKey.f3 &&
                      keys.isShiftPressed),
            ),
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Material(
        color: widget.theme.backgroundColor,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '正文搜索',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _searching ? '取消搜索' : '重新搜索',
                      onPressed: _searching ? _cancel : _search,
                      icon: Icon(
                        _searching ? Icons.stop_circle_outlined : Icons.refresh,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭搜索',
                      onPressed: widget.onClose ?? () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const ValueKey('reader-search-query'),
                  controller: _query,
                  focusNode: _queryFocus,
                  autofocus: true,
                  maxLength: 128,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '输入正文关键词',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => _changed(),
                  onSubmitted: (_) {
                    if (_composing) return;
                    if (!_searching &&
                        _searchedQuery == _query.text.trim() &&
                        _hits.isNotEmpty) {
                      unawaited(_openRelative());
                    } else {
                      _search();
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('本章'),
                      selected: _chapterOnly,
                      onSelected: (_) {
                        _chapterOnly = true;
                        _changed();
                      },
                    ),
                    ChoiceChip(
                      label: const Text('已缓存正文'),
                      selected: !_chapterOnly,
                      onSelected: (_) {
                        _chapterOnly = false;
                        _changed();
                      },
                    ),
                    FilterChip(
                      label: const Text('高亮全部匹配'),
                      selected: _showAll,
                      onSelected: (value) {
                        setState(() => _showAll = value);
                        _publish();
                      },
                    ),
                    FilterChip(
                      label: const Text('区分大小写'),
                      selected: _caseSensitive,
                      onSelected: (value) {
                        _caseSensitive = value;
                        _changed();
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error ??
                      (_query.text.trim().isEmpty
                          ? '只搜索本章或本地缓存，不会为搜索下载全书。'
                          : '${_cancelled ? '已取消 · ' : ''}已搜索本地 $_searched/${widget.chapters.length} 章 · ${_hits.length} 处匹配'
                                '${_limited ? '（达到显示上限，请缩小关键词范围）' : ''}'),
                  style: TextStyle(
                    color: widget.theme.secondaryColor,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_searching) const LinearProgressIndicator(minHeight: 2),
              if (widget.onOpenHit != null)
                Row(
                  children: [
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _hits.isEmpty
                            ? 'Enter 跳转 · ⌘G 下一处'
                            : '${_selected + 1} / ${_hits.length} 处匹配',
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.theme.secondaryColor,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '上一处匹配（⌘⇧G）',
                      onPressed: _hits.isEmpty
                          ? null
                          : () => _openRelative(backwards: true),
                      icon: const Icon(Icons.keyboard_arrow_up),
                    ),
                    IconButton(
                      tooltip: '下一处匹配（⌘G）',
                      onPressed: _hits.isEmpty ? null : _openRelative,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ],
                ),
              Expanded(
                child: _hits.isEmpty
                    ? Center(
                        child: Text(
                          _searching
                              ? '正在搜索本地正文…'
                              : _query.text.trim().isEmpty
                              ? '搜索结果会显示在这里'
                              : _searched == 0
                              ? '没有可搜索的本地正文，请先加载或下载章节'
                              : '本地搜索范围内未找到匹配',
                          style: TextStyle(color: widget.theme.secondaryColor),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('reader-search-results'),
                        controller: _resultsScroll,
                        itemExtent: _resultHeight,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: _hits.length,
                        itemBuilder: (context, index) {
                          final hit = _hits[index];
                          return ListTile(
                            key: ValueKey('reader-search-hit-$index'),
                            selected: index == _selected,
                            selectedTileColor: widget.theme.highlightColor,
                            title: Text(
                              '${hit.chapterTitle} · 第 ${hit.position.paragraphIndex + 1} 段',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: hit.snippet.substring(
                                      0,
                                      hit.snippetStart,
                                    ),
                                  ),
                                  TextSpan(
                                    text: hit.snippet.substring(
                                      hit.snippetStart,
                                      hit.snippetEnd,
                                    ),
                                    style: TextStyle(
                                      backgroundColor:
                                          widget.theme.highlightColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(
                                    text: hit.snippet.substring(hit.snippetEnd),
                                  ),
                                ],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _openHit(index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
