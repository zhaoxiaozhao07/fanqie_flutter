import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chapter.dart';
import '../models/reader_theme.dart';
import '../services/reader_search_service.dart';

class ReaderSearchSheet extends StatefulWidget {
  final String bookId;
  final List<Chapter> chapters;
  final int chapterIndex;
  final Map<String, String> canonicalMemory;
  final ReaderTheme theme;

  const ReaderSearchSheet({
    super.key,
    required this.bookId,
    required this.chapters,
    required this.chapterIndex,
    required this.canonicalMemory,
    required this.theme,
  });

  @override
  State<ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<ReaderSearchSheet> {
  final _query = TextEditingController();
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

  void _invalidate() {
    _generation++;
    _debounce?.cancel();
    _service.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _changed() {
    _invalidate();
    setState(() {
      _hits.clear();
      _searched = 0;
      _searching = false;
      _cancelled = false;
      _limited = false;
      _error = null;
    });
    if (_query.text.trim().isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 200), _search);
    }
  }

  void _search() {
    _invalidate();
    if (_query.text.trim().isEmpty) return;
    final generation = _generation;
    setState(() {
      _hits.clear();
      _searching = true;
      _searched = 0;
      _cancelled = false;
      _limited = false;
      _error = null;
    });
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
    _invalidate();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.theme.wrap(
    Material(
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
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _query,
                autofocus: true,
                maxLength: 128,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: '输入正文关键词',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => _changed(),
                onSubmitted: (_) => _search(),
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
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: _hits.length,
                      itemBuilder: (context, index) {
                        final hit = _hits[index];
                        return ListTile(
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
                          onTap: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            Navigator.pop(context, hit);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
