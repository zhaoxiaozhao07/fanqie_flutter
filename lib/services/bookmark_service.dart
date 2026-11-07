import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';
import '../models/book.dart';
import 'reader_text.dart';
import 'reader_trash_service.dart';

class BookmarkService {
  static const noteBooksKey = 'reader_note_books_v1';
  static final BookmarkService _instance = BookmarkService._();
  factory BookmarkService() => _instance;
  BookmarkService._();
  SharedPreferences? _prefs;
  final Map<String, List<Bookmark>> _bookmarks = {};
  final Map<String, List<ReadingNote>> _notes = {};
  final Map<String, Future<void>> _writes = {};
  int _sequence = 0;
  final ValueNotifier<int> changeNotifier = ValueNotifier(0);

  Future<SharedPreferences> _getPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!identical(_prefs, prefs)) {
      _prefs = prefs;
      _bookmarks.clear();
      _notes.clear();
    }
    return prefs;
  }

  Future<void> initialize() async {
    await _getPrefs();
  }

  /// Keep names for notes whose book is later removed from the shelf. This is
  /// metadata only; canonical notes remain in their established per-book keys.
  Future<void> rememberBook(Book book) => _mutate(noteBooksKey, () async {
    final prefs = await _getPrefs();
    final raw = prefs.getString(noteBooksKey);
    Map<String, dynamic> books;
    try {
      books = raw == null
          ? {}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      throw StateError('笔记书籍名称索引损坏，原记录已保留');
    }
    final metadata = {
      'book_id': book.bookId,
      'book_name': book.bookName,
      'author': book.author,
      'thumb_url': book.thumbUrl,
      'category': book.category,
      'creation_status': book.creationStatus,
      'word_number': book.wordNumber,
      'serial_count': book.serialCount,
    };
    final previous = books[book.bookId];
    if (previous is Map &&
        metadata.entries.every((entry) => previous[entry.key] == entry.value)) {
      return;
    }
    books[book.bookId] = {
      ...metadata,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final encoded = jsonEncode(books);
    if (books.length > 10000 || utf8.encode(encoded).length > 4 * 1024 * 1024) {
      throw StateError('笔记书籍名称索引已达容量上限');
    }
    if (!await prefs.setString(noteBooksKey, encoded)) {
      throw StateError('笔记书籍名称索引保存失败');
    }
    changeNotifier.value++;
  });

  Future<void> flush() => Future.wait(_writes.values).then((_) {});
  void invalidate() {
    _bookmarks.clear();
    _notes.clear();
    _prefs = null;
    changeNotifier.value++;
  }

  Future<T> _mutate<T>(String bookId, Future<T> Function() action) {
    final operation = (_writes[bookId] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          if (bookId != noteBooksKey) {
            final prefs = await _getPrefs();
            for (final prefix in ['notes_', 'bookmarks_']) {
              final raw = prefs.getString('$prefix$bookId');
              if (raw == null) continue;
              try {
                final data = jsonDecode(raw);
                if (data is! List ||
                    data.any((e) => e is! Map) ||
                    (prefix == 'notes_' &&
                        data.any((e) => (e['version'] as num? ?? 1) > 3))) {
                  throw const FormatException('无效批注数据');
                }
                for (final item in data.cast<Map>()) {
                  if (item['book_id'] != bookId ||
                      (item['id']?.toString().isEmpty ?? true)) {
                    throw const FormatException('批注身份不正确');
                  }
                  if (prefix == 'notes_') {
                    final note = ReadingNote.fromJson(
                      Map<String, dynamic>.from(item),
                    );
                    if (note.text.isEmpty || !note.validAnchor) {
                      throw const FormatException('笔记范围损坏');
                    }
                  }
                }
              } catch (_) {
                throw StateError('批注存储损坏或版本过新，原记录已保留；请先备份恢复');
              }
            }
          }
          return action();
        });
    late final Future<void> complete;
    complete = operation
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() {
          if (identical(_writes[bookId], complete)) _writes.remove(bookId);
        });
    _writes[bookId] = complete;
    return operation;
  }

  List<Map<String, dynamic>> _decode(String? raw) {
    try {
      return (jsonDecode(raw ?? '[]') as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Bookmark>> getBookmarks(String bookId) async {
    final prefs = await _getPrefs();
    _bookmarks.putIfAbsent(
      bookId,
      () => _decode(
        prefs.getString('bookmarks_$bookId'),
      ).map(Bookmark.fromJson).toList(),
    );
    return List.unmodifiable(_bookmarks[bookId]!);
  }

  Future<List<ReadingNote>> getNotes(String bookId) async {
    final prefs = await _getPrefs();
    _notes.putIfAbsent(
      bookId,
      () => _decode(
        prefs.getString('notes_$bookId'),
      ).map(ReadingNote.fromJson).toList(),
    );
    return List.unmodifiable(_notes[bookId]!);
  }

  Future<bool> isChapterBookmarked(String bookId, int index) async =>
      (await getBookmarks(bookId)).any((item) => item.chapterIndex == index);
  Future<Bookmark?> bookmarkAt(
    String bookId,
    String chapterId,
    int chapterIndex,
    int paragraph,
    int offset,
  ) async {
    for (final item in await getBookmarks(bookId)) {
      if ((item.chapterId.isNotEmpty
              ? item.chapterId == chapterId
              : item.chapterIndex == chapterIndex) &&
          item.paragraphIndex == paragraph &&
          item.characterOffset == offset) {
        return item;
      }
    }
    return null;
  }

  Future<void> _saveBookmarks(String bookId, List<Bookmark> list) async {
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    if (list.length > 5000 || utf8.encode(raw).length > 8 * 1024 * 1024) {
      throw StateError('书签已达容量上限，请先导出备份');
    }
    final prefs = await _getPrefs();
    if (!await prefs.setString('bookmarks_$bookId', raw)) {
      throw StateError('书签保存失败');
    }
    _bookmarks[bookId] = list;
    changeNotifier.value++;
  }

  Future<void> _saveNotes(String bookId, List<ReadingNote> list) async {
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    if (list.length > 5000 || utf8.encode(raw).length > 8 * 1024 * 1024) {
      throw StateError('笔记已达容量上限，请先导出备份');
    }
    final prefs = await _getPrefs();
    if (!await prefs.setString('notes_$bookId', raw)) {
      throw StateError('笔记保存失败');
    }
    _notes[bookId] = list;
    changeNotifier.value++;
  }

  Future<Bookmark> addBookmark({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    String chapterId = '',
    int paragraphIndex = 0,
    int characterOffset = 0,
    required String contentPreview,
  }) => _mutate(bookId, () async {
    final list = List<Bookmark>.from(await getBookmarks(bookId));
    list.removeWhere(
      (item) =>
          item.chapterIndex == chapterIndex &&
          item.paragraphIndex == paragraphIndex &&
          item.characterOffset == characterOffset,
    );
    final item = Bookmark(
      id: '${bookId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      bookId: bookId,
      chapterIndex: chapterIndex,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      paragraphIndex: paragraphIndex,
      characterOffset: characterOffset,
      contentPreview: contentPreview.length > 80
          ? '${contentPreview.substring(0, ReaderText.safeOffset(contentPreview, 80))}…'
          : contentPreview,
      createdAt: DateTime.now(),
    );
    list.insert(0, item);
    await _saveBookmarks(bookId, list);
    return item;
  });
  Future<void> removeBookmark(String id, String bookId) =>
      deleteBookmarks(bookId, {id}).then((_) {});
  Future<ReaderTrashEntry?> deleteBookmarks(String bookId, Set<String> ids) =>
      _deleteBookmarks(bookId, (e) => ids.contains(e.id));
  Future<void> removeBookmarkByChapter(String bookId, int chapterIndex) =>
      _deleteBookmarks(
        bookId,
        (e) => e.chapterIndex == chapterIndex,
      ).then((_) {});
  Future<ReaderTrashEntry?> _deleteBookmarks(
    String bookId,
    bool Function(Bookmark) test,
  ) => _mutate(bookId, () async {
    final list = await getBookmarks(bookId);
    final removed = list.where(test).toList();
    if (removed.isEmpty) return null;
    final entry = await ReaderTrashService().stash(
      targetKey: 'bookmarks_$bookId',
      label: removed.first.chapterTitle,
      items: removed.map((e) => e.toJson()).toList(),
    );
    await _saveBookmarks(bookId, list.where((e) => !test(e)).toList());
    return entry;
  });
  Future<ReadingNote> addNote({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    String chapterId = '',
    int paragraphIndex = 0,
    int? endParagraphIndex,
    required String text,
    String note = '',
    int startOffset = -1,
    int endOffset = -1,
    String chapterHash = '',
    String prefix = '',
    String suffix = '',
    int colorIndex = 0,
    List<String> tags = const [],
  }) => _mutate(bookId, () async {
    if (text.trim().isEmpty) throw ArgumentError('摘录不能为空');
    if (text.length > 20000 ||
        (endParagraphIndex ?? paragraphIndex) < paragraphIndex ||
        ((endParagraphIndex ?? paragraphIndex) > paragraphIndex &&
            (startOffset < 0 || endOffset <= 0 || !text.contains('\n\n')))) {
      throw ArgumentError('跨段范围无效或超过 20000 个字符');
    }
    final list = List<ReadingNote>.from(await getNotes(bookId));
    list.removeWhere(
      (item) =>
          item.chapterIndex == chapterIndex &&
          item.paragraphIndex == paragraphIndex &&
          item.endParagraphIndex == (endParagraphIndex ?? paragraphIndex) &&
          (startOffset >= 0
              ? item.startOffset == startOffset && item.endOffset == endOffset
              : item.startOffset < 0 && item.text == text.trim()),
    );
    final item = ReadingNote(
      id: '${bookId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      bookId: bookId,
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      paragraphIndex: paragraphIndex,
      endParagraphIndex: endParagraphIndex,
      text: text.trim(),
      note: note,
      startOffset: startOffset,
      endOffset: endOffset,
      chapterHash: chapterHash,
      prefix: prefix,
      suffix: suffix,
      colorIndex: colorIndex.clamp(0, 3),
      tags: tags.take(10).toList(),
      createdAt: DateTime.now(),
    );
    if (!item.validAnchor) throw ArgumentError('摘录与原文范围不一致，未保存');
    list.insert(0, item);
    await _saveNotes(bookId, list);
    return item;
  });
  Future<void> updateNote(ReadingNote note) =>
      updateNoteWithUndo(note).then((_) {});
  Future<ReaderTrashEntry?> updateNoteWithUndo(
    ReadingNote note, {
    DateTime? expectedUpdatedAt,
  }) => _mutate(note.bookId, () async {
    final list = List<ReadingNote>.from(await getNotes(note.bookId));
    final index = list.indexWhere((e) => e.id == note.id);
    if (index < 0) throw StateError('笔记已不存在');
    final before = list[index];
    if (expectedUpdatedAt != null &&
        !before.updatedAt.isAtSameMomentAs(expectedUpdatedAt)) {
      throw StateError('笔记已更新，请刷新后重试；未覆盖较新的记录');
    }
    final next = before.edited(
      note: note.note,
      colorIndex: note.colorIndex,
      tags: note.tags,
    );
    final entry = await ReaderTrashService().stash(
      targetKey: 'notes_${note.bookId}',
      label: before.chapterTitle,
      items: [before.toJson()],
      expected: [next.toJson()],
    );
    list[index] = next;
    await _saveNotes(note.bookId, list);
    return entry;
  });
  Future<void> removeNote(String id, String bookId) =>
      deleteNotes(bookId, {id}).then((_) {});
  Future<ReaderTrashEntry?> deleteNotes(String bookId, Set<String> ids) =>
      _deleteNotes(bookId, (e) => ids.contains(e.id));
  Future<void> removeNoteByText(String text, String bookId) =>
      _deleteNotes(bookId, (e) => e.text.trim() == text.trim()).then((_) {});
  Future<void> removeNoteByParagraph({
    required String bookId,
    required int chapterIndex,
    required int paragraphIndex,
    required String text,
  }) => _deleteNotes(
    bookId,
    (e) =>
        e.chapterIndex == chapterIndex &&
        (paragraphIndex < 0 || e.paragraphIndex == paragraphIndex) &&
        e.text.trim() == text.trim(),
  ).then((_) {});

  Future<ReaderTrashEntry?> _deleteNotes(
    String bookId,
    bool Function(ReadingNote) test,
  ) => _mutate(bookId, () async {
    final list = await getNotes(bookId);
    final removed = list.where(test).toList();
    if (removed.isEmpty) return null;
    final entry = await ReaderTrashService().stash(
      targetKey: 'notes_$bookId',
      label: removed.first.chapterTitle,
      items: removed.map((e) => e.toJson()).toList(),
    );
    await _saveNotes(bookId, list.where((e) => !test(e)).toList());
    return entry;
  });

  Future<ReaderTrashEntry?> addTags(
    String bookId,
    Set<String> ids,
    List<String> tags,
  ) => _mutate(bookId, () async {
    final clean = tags
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (clean.isEmpty ||
        clean.length > 10 ||
        clean.any((e) => e.characters.length > 24)) {
      throw ArgumentError('标签须为 1–24 个字符，每条笔记最多 10 个');
    }
    final list = List<ReadingNote>.from(await getNotes(bookId));
    final before = list.where((e) => ids.contains(e.id)).toList();
    if (before.length != ids.length) throw StateError('选中的笔记已变化，请刷新后重试');
    final next = <ReadingNote>[];
    for (final note in before) {
      final merged = {...note.tags, ...clean}.toList();
      if (merged.length > 10) throw StateError('部分笔记合并后标签超过 10 个，未修改');
      next.add(
        note.edited(note: note.note, colorIndex: note.colorIndex, tags: merged),
      );
    }
    if (next.isEmpty) return null;
    final entry = await ReaderTrashService().stash(
      targetKey: 'notes_$bookId',
      label: '批量添加标签',
      items: before.map((e) => e.toJson()).toList(),
      expected: next.map((e) => e.toJson()).toList(),
    );
    final byId = {for (final note in next) note.id: note};
    await _saveNotes(bookId, list.map((e) => byId[e.id] ?? e).toList());
    return entry;
  });

  Future<void> restoreSnapshot(ReaderTrashEntry entry) {
    final notes = entry.targetKey.startsWith('notes_');
    final bookId = entry.targetKey.substring(notes ? 6 : 10);
    return _mutate(bookId, () async {
      final live = notes
          ? (await getNotes(bookId)).map((e) => e.toJson()).toList()
          : (await getBookmarks(bookId)).map((e) => e.toJson()).toList();
      final current = {for (final item in live) item['id'] as String: item};
      final before = {
        for (final item in entry.items) item['id'] as String: item,
      };
      for (final expected in entry.expected) {
        final id = expected['id'] as String;
        if (!readerJsonEquals(current[id], expected) &&
            !readerJsonEquals(current[id], before[id])) {
          throw StateError('此笔记已有后续修改，不能覆盖；可从回收站查看旧版本');
        }
      }
      for (final item in entry.items) {
        final id = item['id'] as String;
        if (entry.expected.isEmpty &&
            current[id] != null &&
            !readerJsonEquals(current[id], item)) {
          throw StateError('已有同名记录且内容不同，未覆盖');
        }
        current[id] = Map<String, dynamic>.from(item);
      }
      if (notes) {
        await _saveNotes(
          bookId,
          current.values.map(ReadingNote.fromJson).toList(),
        );
      } else {
        await _saveBookmarks(
          bookId,
          current.values.map(Bookmark.fromJson).toList(),
        );
      }
    });
  }
}
