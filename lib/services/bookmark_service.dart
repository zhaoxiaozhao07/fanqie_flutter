import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';
import 'reader_text.dart';

class BookmarkService {
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
        .then((_) => action());
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
    final prefs = await _getPrefs();
    if (!await prefs.setString(
      'bookmarks_$bookId',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    )) {
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
      _mutate(bookId, () async {
        final list = List<Bookmark>.from(await getBookmarks(bookId))
          ..removeWhere((e) => e.id == id);
        await _saveBookmarks(bookId, list);
      });
  Future<void> removeBookmarkByChapter(String bookId, int chapterIndex) =>
      _mutate(bookId, () async {
        final list = List<Bookmark>.from(await getBookmarks(bookId))
          ..removeWhere((e) => e.chapterIndex == chapterIndex);
        await _saveBookmarks(bookId, list);
      });
  Future<ReadingNote> addNote({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    String chapterId = '',
    int paragraphIndex = 0,
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
    final list = List<ReadingNote>.from(await getNotes(bookId));
    list.removeWhere(
      (item) =>
          item.chapterIndex == chapterIndex &&
          item.paragraphIndex == paragraphIndex &&
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
    list.insert(0, item);
    await _saveNotes(bookId, list);
    return item;
  });
  Future<void> updateNote(ReadingNote note) => _mutate(note.bookId, () async {
    final list = List<ReadingNote>.from(await getNotes(note.bookId));
    final index = list.indexWhere((e) => e.id == note.id);
    if (index < 0) throw StateError('笔记已不存在');
    list[index] = note;
    await _saveNotes(note.bookId, list);
  });
  Future<void> removeNote(String id, String bookId) =>
      _mutate(bookId, () async {
        final list = List<ReadingNote>.from(await getNotes(bookId))
          ..removeWhere((e) => e.id == id);
        await _saveNotes(bookId, list);
      });
  Future<void> removeNoteByText(String text, String bookId) =>
      _mutate(bookId, () async {
        final list = List<ReadingNote>.from(await getNotes(bookId))
          ..removeWhere((e) => e.text.trim() == text.trim());
        await _saveNotes(bookId, list);
      });
  Future<void> removeNoteByParagraph({
    required String bookId,
    required int chapterIndex,
    required int paragraphIndex,
    required String text,
  }) => _mutate(bookId, () async {
    final list = List<ReadingNote>.from(await getNotes(bookId))
      ..removeWhere(
        (e) =>
            e.chapterIndex == chapterIndex &&
            (paragraphIndex < 0 || e.paragraphIndex == paragraphIndex) &&
            e.text.trim() == text.trim(),
      );
    await _saveNotes(bookId, list);
  });
}
