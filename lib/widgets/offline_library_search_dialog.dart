import 'dart:async';
import 'package:flutter/material.dart';
import '../services/offline_library_service.dart';
import '../services/reader_settings_repository.dart';
import '../services/reader_text.dart';
import '../screens/reader_screen.dart';
import 'book_page_route.dart';

class OfflineLibrarySearchDialog extends StatefulWidget {
  final OfflineLibraryService? service;
  const OfflineLibrarySearchDialog({super.key, this.service});
  @override
  State<OfflineLibrarySearchDialog> createState() =>
      _OfflineLibrarySearchDialogState();
}

class _OfflineLibrarySearchDialogState
    extends State<OfflineLibrarySearchDialog> {
  late final _service = widget.service ?? OfflineLibraryService();
  final _query = TextEditingController();
  final _focus = FocusNode();
  StreamSubscription<OfflineLibrarySearchUpdate>? _subscription;
  Timer? _debounce;
  OfflineLibrarySearchUpdate _update = const OfflineLibrarySearchUpdate(
    done: true,
  );
  bool _opening = false;
  int _generation = 0;
  String? _error;
  bool get _composing =>
      _query.value.composing.isValid && !_query.value.composing.isCollapsed;
  void _changed(String _) {
    _cancel();
    _debounce?.cancel();
    if (_composing) return;
    _debounce = Timer(const Duration(milliseconds: 200), _search);
  }

  void _cancel() {
    _generation++;
    _service.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _search() {
    if (_composing) return;
    _cancel();
    final generation = _generation;
    setState(() {
      _error = null;
      _update = const OfflineLibrarySearchUpdate();
    });
    _subscription = _service
        .search(_query.text)
        .listen(
          (update) {
            if (mounted && generation == _generation) {
              setState(() => _update = update);
            }
          },
          onError: (_) {
            if (mounted && generation == _generation) {
              setState(() {
                _error = '本地搜索未完成，原文与进度未改变';
                _update = const OfflineLibrarySearchUpdate(done: true);
              });
            }
          },
        );
  }

  Future<void> _open(OfflineLibraryHit entry) async {
    final generation = ++_generation;
    setState(() => _opening = true);
    try {
      final index = entry.hit.chapterIndex, source = entry.source;
      final chapter = source.chapters[index];
      final raw =
          chapter.content ??
          await _service.cache.read(source.book.bookId, chapter.itemId);
      if (raw == null) throw const FormatException('缓存已清理，请重新下载或导入');
      // Revalidate the exact source before touching reading progress.
      final paragraphs = ReaderText.paragraphs(
        raw,
        chapterTitle: chapter.title,
      );
      final position = entry.hit.position;
      if (position.paragraphIndex >= paragraphs.length ||
          entry.hit.endOffset > paragraphs[position.paragraphIndex].length ||
          paragraphs[position.paragraphIndex].substring(
                position.characterOffset,
                entry.hit.endOffset,
              ) !=
              entry.hit.quote) {
        throw const FormatException('原文已变化，请重新搜索；未跳转');
      }
      final settings = await ReaderSettingsRepository().load(
        source.book.bookId,
      );
      if (!mounted || generation != _generation) return;
      final ready = [...source.chapters]
        ..[index] = chapter.copyWithContent(raw);
      await Navigator.of(context).push(
        BookPageRoute(
          builder: (_) => ReaderScreen(
            book: source.book,
            chapters: ready,
            initialChapterIndex: index,
            initialPosition: position,
            resumeSavedPosition: false,
            initialSettings: settings,
            offlineOnly: true,
            chapterContentLoader: (chapter) =>
                _service.cache.read(source.book.bookId, chapter.itemId),
          ),
        ),
      );
      if (mounted) _focus.requestFocus();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : '无法打开缓存原文，进度保留',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _cancel();
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('搜索所有离线正文'),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height < 650 ? 280 : 480,
      child: Column(
        children: [
          const Text('仅搜索本地完整正文，不联网；缺少目录的缓存会跳过。打开结果也仅使用缓存章节。'),
          TextField(
            key: const ValueKey('offline-library-query'),
            controller: _query,
            focusNode: _focus,
            autofocus: true,
            maxLength: 128,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '输入原文关键词',
            ),
            onChanged: _changed,
            onSubmitted: (_) {
              _debounce?.cancel();
              _search();
            },
          ),
          if (!_update.done) const LinearProgressIndicator(minHeight: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  _error ??
                      '${_update.hits.length} 处 · ${_update.searchedBooks}/${_update.totalBooks} 本 · 检查 ${_update.searchedChapters} 章${_update.limited ? '（达到结果上限）' : ''}',
                ),
              ),
              if (!_update.done)
                TextButton(
                  onPressed: () {
                    _cancel();
                    setState(
                      () => _update = OfflineLibrarySearchUpdate(
                        hits: _update.hits,
                        done: true,
                        warnings: _update.warnings,
                      ),
                    );
                  },
                  child: const Text('取消搜索'),
                ),
            ],
          ),
          if (_update.warnings.isNotEmpty)
            Text(
              _update.warnings.join('\n'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _update.hits.length,
              itemBuilder: (context, index) {
                final entry = _update.hits[index];
                return ListTile(
                  key: ValueKey('offline-library-hit-$index'),
                  title: Text(
                    '${entry.source.book.bookName} · ${entry.hit.chapterTitle}',
                  ),
                  subtitle: Text(
                    entry.hit.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _opening ? null : () => _open(entry),
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
