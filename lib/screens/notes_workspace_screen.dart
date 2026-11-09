import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/bookmark.dart';
import '../services/bookmark_service.dart';
import '../services/note_library_service.dart';
import '../services/reader_export_service.dart';
import '../services/reader_settings_repository.dart';
import '../widgets/book_page_route.dart';
import '../widgets/note_editor_dialog.dart';
import '../widgets/reader_undo.dart';
import '../widgets/reader_trash_dialog.dart';
import '../widgets/reader_text_input_dialog.dart';
import '../services/reader_trash_service.dart';
import '../services/reader_system_service.dart';
import 'reader_screen.dart';

class NotesWorkspaceScreen extends StatefulWidget {
  final bool isActive;
  final NoteLibraryService? service;
  const NotesWorkspaceScreen({super.key, this.isActive = true, this.service});
  @override
  State<NotesWorkspaceScreen> createState() => NotesWorkspaceScreenState();
}

class NotesWorkspaceScreenState extends State<NotesWorkspaceScreen> {
  final _query = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'notes-workspace-search');
  final _scroll = ScrollController();
  final _bookmarks = BookmarkService();
  late final _library = widget.service ?? NoteLibraryService();
  NoteLibrarySnapshot _snapshot = const NoteLibrarySnapshot();
  List<IndexedReadingNote> _filtered = [];
  Timer? _debounce;
  bool _dirty = true, _loading = false, _exporting = false;
  int _loadGeneration = 0, _locateGeneration = 0;
  String _bookId = '', _tag = '';
  String? _opening, _mutating, _error;
  int _color = -1;
  NoteLibrarySort _sort = NoteLibrarySort.newest;
  final _selected = <String>{};
  bool _selecting = false;
  String? _previewKey, _previewText;
  int _previewGeneration = 0;
  double? _restoredOffset;
  bool _workspaceDirty = false;
  Timer? _stateTimer;
  Future<void>? _stateWrites;
  int _workspaceGeneration = 0;
  static const _workspaceKey = 'reader_notes_workspace_v1';

  bool get _composing =>
      _query.value.composing.isValid && !_query.value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _bookmarks.changeNotifier.addListener(_changed);
    _scroll.addListener(_stateChanged);
    ReaderSystemService.registerSaveParticipant(this, _saveWorkspace);
    unawaited(
      _restoreWorkspace().then((_) {
        if (mounted && widget.isActive) return _load();
      }),
    );
  }

  @override
  void didUpdateWidget(NotesWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive) {
      _cancelLocate();
    } else if (!oldWidget.isActive && _dirty) {
      unawaited(_load());
    }
  }

  void focusSearch() {
    _queryFocus.requestFocus();
    if (!_composing) {
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    }
  }

  void _changed() {
    _dirty = true;
    if (widget.isActive) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() => _loading = true);
    try {
      final snapshot = await _library.load();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _snapshot = snapshot;
        _dirty = false;
        _error = null;
        if (!_snapshot.books.containsKey(_bookId)) _bookId = '';
        if (!_snapshot.entries.any((entry) => entry.note.tags.contains(_tag))) {
          _tag = '';
        }
        _filter();
      });
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = '笔记索引暂不可读，原笔记未被删除。');
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _filter() {
    _filtered = NoteLibraryService.filter(
      _snapshot,
      query: _query.text,
      bookId: _bookId,
      tag: _tag,
      colorIndex: _color,
      sort: _sort,
    );
    final visible = _filtered.map((entry) => entry.key).toSet();
    _selected.removeWhere((key) => !visible.contains(key));
    if (_restoredOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _restoredOffset != null) {
          _scroll.jumpTo(
            _restoredOffset!.clamp(0, _scroll.position.maxScrollExtent),
          );
          _restoredOffset = null;
        }
      });
    }
  }

  void _filterChanged(VoidCallback action) {
    _cancelLocate();
    _previewGeneration++;
    _previewKey = null;
    _previewText = null;
    setState(() {
      action();
      _filter();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _stateChanged();
  }

  void _queryChanged(String _) {
    _cancelLocate();
    _debounce?.cancel();
    if (_composing) return;
    _stateChanged();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted && !_composing) {
        setState(_filter);
        _stateChanged();
      }
    });
  }

  void _cancelLocate() {
    _locateGeneration++;
    if (_opening != null && mounted) setState(() => _opening = null);
  }

  Future<void> _open(IndexedReadingNote entry) async {
    final generation = ++_locateGeneration;
    setState(() => _opening = entry.key);
    try {
      final location = await _library.locate(
        entry,
        isCancelled: () =>
            !mounted || !widget.isActive || generation != _locateGeneration,
      );
      final settings = await ReaderSettingsRepository().load(entry.book.bookId);
      if (!mounted || !widget.isActive || generation != _locateGeneration) {
        return;
      }
      setState(() => _opening = null);
      await Navigator.of(context).push(
        BookPageRoute(
          builder: (_) => ReaderScreen(
            book: location.book,
            chapters: location.chapters,
            initialChapterIndex: location.chapterIndex,
            initialPosition: location.position,
            resumeSavedPosition: false,
            initialSettings: settings,
          ),
        ),
      );
    } on NoteLocateCancelled {
      // A late directory/content response must not open a stale note.
    } catch (error) {
      if (mounted && generation == _locateGeneration) {
        _message(
          error is FormatException ? error.message : '原文加载失败，笔记与阅读进度未改变。',
        );
      }
    } finally {
      if (mounted && generation == _locateGeneration) {
        setState(() => _opening = null);
      }
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _edit(ReadingNote note) async {
    if (_mutating != null || _exporting) return;
    final edit = await showDialog<NoteEditData>(
      context: context,
      builder: (_) => NoteEditorDialog(
        quote: note.text,
        initialNote: note.note,
        initialColor: note.colorIndex,
        initialTags: note.tags,
      ),
    );
    if (!mounted || edit == null) return;
    setState(() => _mutating = note.id);
    try {
      final undo = await _bookmarks.updateNoteWithUndo(
        note.edited(
          note: edit.note,
          colorIndex: edit.colorIndex,
          tags: edit.tags,
        ),
        expectedUpdatedAt: note.updatedAt,
      );
      if (mounted && undo != null) showReaderUndo(context, '笔记已更新', [undo]);
    } catch (_) {
      if (mounted) _message('笔记未能更新，请重试；原记录仍保留。');
    } finally {
      if (mounted) setState(() => _mutating = null);
    }
  }

  Future<void> _delete(ReadingNote note) async {
    if (_mutating != null || _exporting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条笔记？'),
        content: Text(note.text, maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _mutating = note.id);
    try {
      final undo = await _bookmarks.deleteNotes(note.bookId, {note.id});
      if (mounted && undo != null) showReaderUndo(context, '笔记已移入回收站', [undo]);
    } catch (_) {
      if (mounted) _message('删除未成功，原笔记仍保留。');
    } finally {
      if (mounted) setState(() => _mutating = null);
    }
  }

  Future<void> _restoreWorkspace() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_workspaceKey);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map;
      if (json['version'] != 1) return;
      if (!mounted) return;
      final query = json['query'];
      if (query is String && query.length <= 128) _query.text = query;
      _bookId = json['book'] is String ? json['book'] : '';
      _tag = json['tag'] is String ? json['tag'] : '';
      _color = json['color'] is int ? (json['color'] as int).clamp(-1, 3) : -1;
      _sort = NoteLibrarySort.values.firstWhere(
        (e) => e.name == json['sort'],
        orElse: () => NoteLibrarySort.newest,
      );
      final offset = json['offset'];
      if (offset is num && offset.isFinite && offset >= 0) {
        _restoredOffset = offset.toDouble();
      }
    } catch (_) {
      /* Preserve damaged UI preferences without hiding notes. */
    }
  }

  void _stateChanged() {
    _workspaceDirty = true;
    _workspaceGeneration++;
    _stateTimer?.cancel();
    _stateTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_saveWorkspace().catchError((_) {})),
    );
  }

  Future<void> _saveWorkspace() {
    if (!_workspaceDirty) return _stateWrites ?? Future.value();
    final generation = _workspaceGeneration;
    final state = {
      'version': 1,
      'query': _query.text,
      'book': _bookId,
      'tag': _tag,
      'color': _color,
      'sort': _sort.name,
      'offset': _scroll.hasClients ? _scroll.offset : _restoredOffset ?? 0,
    };
    late final Future<void> pending;
    pending = (_stateWrites ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          if (!await (await SharedPreferences.getInstance()).setString(
            _workspaceKey,
            jsonEncode(state),
          )) {
            throw StateError('笔记工作台状态未保存');
          }
          if (generation == _workspaceGeneration) _workspaceDirty = false;
        })
        .whenComplete(() {
          if (identical(_stateWrites, pending)) _stateWrites = null;
        });
    _stateWrites = pending;
    return pending;
  }

  Future<void> _preview(IndexedReadingNote entry) async {
    final generation = ++_previewGeneration;
    setState(() {
      _previewKey = entry.key;
      _previewText = '正在读取缓存原文…';
    });
    String text;
    try {
      text = (await _library.preview(entry)).source;
    } catch (e) {
      text = e is FormatException ? e.message : '本地原文不可读，摘录仍保留';
    }
    if (!mounted || generation != _previewGeneration) return;
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => _previewText = text);
    } else {
      setState(() {
        _previewKey = null;
        _previewText = null;
      });
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${entry.book.bookName} · ${entry.note.chapterTitle}'),
          content: SizedBox(
            width: 500,
            height: MediaQuery.sizeOf(context).height * .5,
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _bulk({required bool deleting}) async {
    if (_mutating != null || _exporting || _selected.isEmpty) return;
    final selected = _filtered.where((e) => _selected.contains(e.key)).toList();
    List<String> tags = [];
    if (deleting) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('移入回收站 ${selected.length} 条笔记？'),
          content: const Text('原书与阅读位置不会删除；可以撤销或在 30 天内恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移入回收站'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    } else {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => ReaderTextInputDialog(
          title: '为 ${selected.length} 条笔记添加标签',
          hint: '用逗号分隔；保留已有标签',
          maxLength: 240,
          action: '添加',
        ),
      );
      if (value == null) return;
      tags = value
          .split(RegExp('[,，]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (!mounted) return;
    setState(() => _mutating = 'batch');
    final groups = <String, Set<String>>{};
    for (final entry in selected) {
      groups.putIfAbsent(entry.note.bookId, () => {}).add(entry.note.id);
    }
    final undo = <ReaderTrashEntry>[];
    var completed = 0;
    String? failure;
    try {
      for (final group in groups.entries) {
        final entry = deleting
            ? await _bookmarks.deleteNotes(group.key, group.value)
            : await _bookmarks.addTags(group.key, group.value, tags);
        if (entry != null) undo.add(entry);
        completed += group.value.length;
      }
    } catch (_) {
      failure = '部分未完成，未覆盖后续修改';
    }
    if (mounted) {
      setState(() {
        _mutating = null;
        _selected.clear();
        _selecting = false;
      });
      final message =
          '已${deleting ? '移入回收站' : '添加标签'} $completed 条${failure == null ? '' : '；$failure'}';
      if (undo.isNotEmpty) {
        showReaderUndo(context, message, undo);
      } else {
        _message('操作未保存，请检查标签或存储后重试');
      }
    }
  }

  Future<void> _export(bool markdown) async {
    if (_filtered.isEmpty || _exporting) return;
    final entries = List<IndexedReadingNote>.unmodifiable(_filtered);
    setState(() => _exporting = true);
    File? file;
    try {
      await _bookmarks.flush();
      final exporter = ReaderExportService();
      file = await exporter.exportNoteLibrary(entries, markdown: markdown);
      final location = await exporter.saveToDownloads(file);
      if (mounted) {
        _message(
          location == null
              ? '已取消导出，原笔记未改变。'
              : '已导出 ${entries.length} 条笔记到 $location',
        );
      }
    } catch (_) {
      if (mounted) _message('导出失败，请检查存储空间。原笔记未改变。');
    } finally {
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    _locateGeneration++;
    _debounce?.cancel();
    _previewGeneration++;
    _stateTimer?.cancel();
    unawaited(_saveWorkspace().catchError((_) {}));
    ReaderSystemService.registerSaveParticipant(this, null);
    _scroll.removeListener(_stateChanged);
    _scroll.dispose();
    _bookmarks.changeNotifier.removeListener(_changed);
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Widget _choice<T>(
    String key,
    String label,
    double width,
    T value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T> changed,
  ) => SizedBox(
    width: width,
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: ValueKey(key),
          value: value,
          isExpanded: true,
          items: items,
          onChanged: _exporting
              ? null
              : (value) {
                  if (value != null) _filterChanged(() => changed(value));
                },
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final books = _snapshot.books.values.toList()
      ..sort((a, b) => a.bookName.compareTo(b.bookName));
    final tags =
        _snapshot.entries.expand((entry) => entry.note.tags).toSet().toList()
          ..sort();
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            !_composing &&
            _opening != null) {
          _cancelLocate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('笔记工作台'),
          actions: [
            IconButton(
              tooltip: '回收站与修改历史',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const ReaderTrashDialog(),
              ),
              icon: const Icon(Icons.restore_from_trash_outlined),
            ),
            IconButton(
              tooltip: '批量选择笔记',
              onPressed: _mutating != null
                  ? null
                  : () => setState(() {
                      _selecting = !_selecting;
                      _selected.clear();
                    }),
              icon: Icon(_selecting ? Icons.close : Icons.checklist),
            ),
            IconButton(
              tooltip: '刷新笔记索引',
              onPressed: _exporting ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            PopupMenuButton<bool>(
              tooltip: '导出当前筛选结果',
              enabled: !_exporting && _filtered.isNotEmpty,
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: true, child: Text('导出 Markdown')),
                PopupMenuItem(value: false, child: Text('导出 JSON（含原文锚点）')),
              ],
              icon: const Icon(Icons.ios_share),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                key: const ValueKey('notes-workspace-query'),
                controller: _query,
                focusNode: _queryFocus,
                maxLength: 128,
                decoration: const InputDecoration(
                  hintText: '搜索书名、摘录、笔记、章节或标签',
                  prefixIcon: Icon(Icons.search),
                  counterText: '',
                ),
                onChanged: _queryChanged,
                onSubmitted: (_) {
                  _debounce?.cancel();
                  if (!_composing) setState(_filter);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _choice('notes-workspace-book', '书籍', 220, _bookId, [
                      const DropdownMenuItem(value: '', child: Text('全部书籍')),
                      for (final book in books)
                        DropdownMenuItem(
                          value: book.bookId,
                          child: Text(
                            book.bookName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ], (value) => _bookId = value),
                    _choice('notes-workspace-tag', '标签', 170, _tag, [
                      const DropdownMenuItem(value: '', child: Text('全部标签')),
                      for (final tag in tags)
                        DropdownMenuItem(
                          value: tag,
                          child: Text('#$tag', overflow: TextOverflow.ellipsis),
                        ),
                    ], (value) => _tag = value),
                    _choice('notes-workspace-color', '划线颜色', 140, _color, [
                      for (final entry in const {
                        -1: '全部颜色',
                        0: '黄色',
                        1: '绿色',
                        2: '蓝色',
                        3: '粉色',
                      }.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ], (value) => _color = value),
                    _choice('notes-workspace-sort', '排序', 180, _sort, [
                      for (final entry in const {
                        NoteLibrarySort.newest: '最近更新',
                        NoteLibrarySort.oldest: '最早摘录',
                        NoteLibrarySort.bookAndChapter: '书名与章节',
                      }.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ], (value) => _sort = value),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ??
                          '${books.length} 本书 · ${_snapshot.entries.length} 条笔记 · 显示 ${_filtered.length} 条',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_opening != null)
                    TextButton.icon(
                      onPressed: _cancelLocate,
                      icon: const Icon(Icons.close),
                      label: const Text('取消定位'),
                    ),
                ],
              ),
            ),
            if (_snapshot.warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  _snapshot.warnings.join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_loading || _exporting || _opening != null)
              const LinearProgressIndicator(minHeight: 2),
            if (_selecting)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('已选 ${_selected.length} 条'),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == _filtered.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(_filtered.map((e) => e.key));
                      }
                    }),
                    child: const Text('全选 / 取消'),
                  ),
                  TextButton(
                    onPressed: _selected.isEmpty || _mutating != null
                        ? null
                        : () => _bulk(deleting: false),
                    child: const Text('批量加标签'),
                  ),
                  TextButton(
                    onPressed: _selected.isEmpty || _mutating != null
                        ? null
                        : () => _bulk(deleting: true),
                    child: const Text('移入回收站'),
                  ),
                ],
              ),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(child: Text(_loading ? '正在读取本地笔记…' : '暂无匹配笔记'))
                  : Row(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            key: const ValueKey('notes-workspace-list'),
                            controller: _scroll,
                            itemCount: _filtered.length,
                            itemBuilder: (_, index) => _card(_filtered[index]),
                          ),
                        ),
                        if (_previewKey != null &&
                            MediaQuery.sizeOf(context).width >= 1000)
                          SizedBox(
                            width: 360,
                            child: Card(
                              child: Column(
                                children: [
                                  ListTile(
                                    title: const Text('缓存原文预览'),
                                    trailing: IconButton(
                                      tooltip: '关闭预览',
                                      onPressed: () => setState(() {
                                        _previewGeneration++;
                                        _previewKey = null;
                                        _previewText = null;
                                      }),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                                  Expanded(
                                    child: SingleChildScrollView(
                                      padding: const EdgeInsets.all(16),
                                      child: SelectableText(_previewText ?? ''),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(IndexedReadingNote entry) {
    final note = entry.note;
    const colors = [
      Color(0xFFCC9A16),
      Color(0xFF45986A),
      Color(0xFF467DAE),
      Color(0xFFE59ABC),
    ];
    return Card(
      key: ValueKey('workspace-note-${entry.key}'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: colors[note.colorIndex], width: 3),
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selecting)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('选择此笔记'),
                value: _selected.contains(entry.key),
                onChanged: (_) => setState(() {
                  if (!_selected.add(entry.key)) _selected.remove(entry.key);
                }),
              ),
            Text(
              '${entry.book.bookName} · ${note.chapterTitle}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(note.text, maxLines: 4, overflow: TextOverflow.ellipsis),
            if (note.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  note.note,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (note.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in note.tags)
                      ActionChip(
                        label: Text('#$tag'),
                        onPressed: _exporting
                            ? null
                            : () => _filterChanged(() => _tag = tag),
                      ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _preview(entry),
                  icon: const Icon(Icons.preview_outlined, size: 18),
                  label: const Text('原文预览'),
                ),
                TextButton.icon(
                  key: ValueKey('workspace-locate-${entry.key}'),
                  onPressed: _exporting ? null : () => _open(entry),
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('定位原文'),
                ),
                IconButton(
                  tooltip: '编辑笔记',
                  onPressed: _mutating != null || _exporting
                      ? null
                      : () => _edit(note),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: '删除笔记',
                  onPressed: _mutating != null || _exporting
                      ? null
                      : () => _delete(note),
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  tooltip: '复制摘录',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: note.text)),
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
