import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chapter.dart';
import '../models/reader_theme.dart';

/// A virtualized, non-modal desktop directory. Its query and scroll state
/// survive docking, window resizing and entering/exiting reading immersion.
class DesktopReaderDirectory extends StatefulWidget {
  final List<Chapter> chapters;
  final ValueListenable<int> activeIndex;
  final ReaderTheme theme;
  final bool visible;
  final ValueChanged<int> onOpenChapter;
  final VoidCallback onClose;
  final VoidCallback onJump;
  final VoidCallback onAnnotations;

  const DesktopReaderDirectory({
    super.key,
    required this.chapters,
    required this.activeIndex,
    required this.theme,
    this.visible = true,
    required this.onOpenChapter,
    required this.onClose,
    required this.onJump,
    required this.onAnnotations,
  });

  @override
  State<DesktopReaderDirectory> createState() => _DesktopReaderDirectoryState();
}

class _DesktopReaderDirectoryState extends State<DesktopReaderDirectory> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'desktop-reader-directory');
  final _expanded = <String>{};
  final _groups = <String, List<int>>{};
  List<Object> _rows = [];
  Timer? _debounce;
  String _query = '';
  bool _reverse = false;
  bool _volumes = false;
  double _rowHeight = 48;

  @override
  void initState() {
    super.initState();
    _search.addListener(_searchChanged);
    _indexChapters();
    _rebuildRows();
    _revealCurrent();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.visible) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant DesktopReaderDirectory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chapters, widget.chapters)) {
      _indexChapters();
      _rebuildRows();
    }
    if (!oldWidget.visible && widget.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.visible) _focus.requestFocus();
      });
    }
  }

  void _indexChapters() {
    _groups.clear();
    var volume = '正文';
    final volumePattern = RegExp(r'(第.+卷[^\s]*)');
    for (var index = 0; index < widget.chapters.length; index++) {
      final chapter = widget.chapters[index];
      if (chapter.volumeTitle.trim().isNotEmpty) {
        volume = chapter.volumeTitle.trim();
      } else if (chapter.title.contains('卷')) {
        volume = volumePattern.firstMatch(chapter.title)?.group(1) ?? volume;
      }
      (_groups[volume] ??= []).add(index);
    }
    _expandCurrentVolume();
  }

  void _expandCurrentVolume() {
    for (final group in _groups.entries) {
      if (group.value.contains(widget.activeIndex.value)) {
        _expanded.add(group.key);
        break;
      }
    }
  }

  void _searchChanged() {
    _debounce?.cancel();
    // Do not filter provisional Pinyin or replace candidates during IME input.
    if (_search.value.composing.isValid &&
        !_search.value.composing.isCollapsed) {
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      final query = _search.text.trim().toLowerCase();
      if (query == _query) return;
      setState(() {
        _query = query;
        _rebuildRows();
      });
      _scrollToRow(0);
    });
  }

  void _rebuildRows() {
    Iterable<int> indices = Iterable<int>.generate(widget.chapters.length);
    if (_reverse) indices = indices.toList().reversed;
    if (_query.isNotEmpty) {
      final number = int.tryParse(_query);
      _rows = [
        for (final index in indices)
          if (number != null
              ? index + 1 == number
              : widget.chapters[index].title.toLowerCase().contains(_query))
            index,
      ];
    } else if (_volumes) {
      _rows = [
        for (final group
            in _reverse
                ? _groups.entries.toList().reversed
                : _groups.entries) ...[
          group.key,
          if (_expanded.contains(group.key))
            ...(_reverse ? group.value.reversed : group.value),
        ],
      ];
    } else {
      _rows = indices.toList();
    }
  }

  void _scrollToRow(int row) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(
        (math.max(0, row) * _rowHeight - _rowHeight * 2).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  void _revealCurrent() {
    _scrollToRow(_rows.indexOf(widget.activeIndex.value));
  }

  void _locateCurrent() {
    _search.clear();
    _debounce?.cancel();
    setState(() {
      _query = '';
      _expandCurrentVolume();
      _rebuildRows();
    });
    _focus.requestFocus();
    _revealCurrent();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _rowHeight =
        48 * math.max(1, MediaQuery.textScalerOf(context).scale(14) / 14);
    return widget.theme.wrap(
      Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              (_search.value.composing.isCollapsed ||
                  !_search.value.composing.isValid)) {
            widget.onClose();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Material(
          color: widget.theme.backgroundColor,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: widget.theme.secondaryColor.withValues(alpha: .18),
                ),
              ),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          '目录 · ${widget.chapters.length} 章',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭目录',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    key: const ValueKey('desktop-directory-search'),
                    controller: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '章节名称或序号',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _search,
                        builder: (_, value, _) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: '清空章节搜索',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: _search.clear,
                              ),
                      ),
                    ),
                    onSubmitted: (_) {
                      if (_search.value.composing.isValid &&
                          !_search.value.composing.isCollapsed) {
                        return;
                      }
                      _debounce?.cancel();
                      setState(() {
                        _query = _search.text.trim().toLowerCase();
                        _rebuildRows();
                      });
                      final matches = _rows.whereType<int>().toList();
                      if (matches.length == 1) {
                        widget.onOpenChapter(matches.single);
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '定位当前章节',
                        onPressed: _locateCurrent,
                        icon: const Icon(Icons.my_location, size: 20),
                      ),
                      IconButton(
                        tooltip: _volumes ? '列表平铺' : '按卷折叠',
                        isSelected: _volumes,
                        onPressed: () {
                          setState(() {
                            _volumes = !_volumes;
                            _expandCurrentVolume();
                            _rebuildRows();
                          });
                          _revealCurrent();
                        },
                        icon: const Icon(Icons.folder_outlined, size: 20),
                      ),
                      IconButton(
                        tooltip: _reverse ? '正序' : '倒序',
                        onPressed: () {
                          setState(() {
                            _reverse = !_reverse;
                            _rebuildRows();
                          });
                          _revealCurrent();
                        },
                        icon: Icon(
                          _reverse ? Icons.north : Icons.south,
                          size: 20,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '跳转章节（⌘J）',
                        onPressed: widget.onJump,
                        icon: const Icon(Icons.last_page, size: 20),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _rows.isEmpty
                      ? const Center(child: Text('没有匹配的章节'))
                      : ValueListenableBuilder<int>(
                          valueListenable: widget.activeIndex,
                          builder: (context, active, _) => ScrollConfiguration(
                            behavior: ScrollConfiguration.of(
                              context,
                            ).copyWith(scrollbars: false),
                            child: Scrollbar(
                              controller: _scroll,
                              thumbVisibility: true,
                              child: ListView.builder(
                                key: const ValueKey('desktop-directory-list'),
                                controller: _scroll,
                                padding: EdgeInsets.zero,
                                itemExtent: _rowHeight,
                                itemCount: _rows.length,
                                itemBuilder: (context, row) {
                                  final value = _rows[row];
                                  if (value is String) {
                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        '$value（${_groups[value]!.length}）',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: Icon(
                                        _expanded.contains(value)
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                      ),
                                      onTap: () => setState(() {
                                        _expanded.contains(value)
                                            ? _expanded.remove(value)
                                            : _expanded.add(value);
                                        _rebuildRows();
                                      }),
                                    );
                                  }
                                  final index = value as int;
                                  return ListTile(
                                    key: ValueKey('desktop-directory-$index'),
                                    dense: true,
                                    selected: index == active,
                                    selectedTileColor:
                                        widget.theme.highlightColor,
                                    contentPadding: EdgeInsets.only(
                                      left: _volumes && _query.isEmpty
                                          ? 28
                                          : 16,
                                      right: 16,
                                    ),
                                    title: Text(
                                      widget.chapters[index].title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: index == active
                                        ? const Icon(
                                            Icons.menu_book_outlined,
                                            size: 16,
                                          )
                                        : null,
                                    onTap: () => widget.onOpenChapter(index),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                ),
                const Divider(height: 1),
                SizedBox(
                  width: double.infinity,
                  child: TextButton.icon(
                    onPressed: widget.onAnnotations,
                    icon: const Icon(Icons.bookmarks_outlined, size: 18),
                    label: const Text('书签与笔记'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
