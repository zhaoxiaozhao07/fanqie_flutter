import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';

/// 书签与阅读划线笔记服务
class BookmarkService {
  static final BookmarkService _instance = BookmarkService._internal();
  factory BookmarkService() => _instance;
  BookmarkService._internal();

  SharedPreferences? _prefs;
  bool _initialized = false;

  final Map<String, List<Bookmark>> _bookmarksMap = {};
  final Map<String, List<ReadingNote>> _notesMap = {};

  /// 变更通知器
  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // =================== 书签功能 ===================

  Future<List<Bookmark>> getBookmarks(String bookId) async {
    if (_bookmarksMap.containsKey(bookId)) {
      return List.unmodifiable(_bookmarksMap[bookId]!);
    }
    final prefs = await _getPrefs();
    final raw = prefs.getString('bookmarks_$bookId');
    if (raw != null && raw.isNotEmpty) {
      try {
        final List<dynamic> list = json.decode(raw);
        final items = list.map((e) => Bookmark.fromJson(e as Map<String, dynamic>)).toList();
        _bookmarksMap[bookId] = items;
        return List.unmodifiable(items);
      } catch (_) {}
    }
    _bookmarksMap[bookId] = [];
    return [];
  }

  Future<bool> isChapterBookmarked(String bookId, int chapterIndex) async {
    final list = await getBookmarks(bookId);
    return list.any((b) => b.chapterIndex == chapterIndex);
  }

  Future<Bookmark> addBookmark({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    int paragraphIndex = 0,
    required String contentPreview,
  }) async {
    final bookmarks = List<Bookmark>.from(await getBookmarks(bookId));
    // 如果该章节已有书签，先移除旧书签更新为新位置
    bookmarks.removeWhere((b) => b.chapterIndex == chapterIndex);

    final newBookmark = Bookmark(
      id: '${bookId}_${chapterIndex}_${DateTime.now().millisecondsSinceEpoch}',
      bookId: bookId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      paragraphIndex: paragraphIndex,
      contentPreview: contentPreview.length > 80 ? '${contentPreview.substring(0, 80)}...' : contentPreview,
      createdAt: DateTime.now(),
    );

    bookmarks.insert(0, newBookmark);
    _bookmarksMap[bookId] = bookmarks;
    await _saveBookmarks(bookId, bookmarks);
    changeNotifier.value++;
    return newBookmark;
  }

  Future<void> removeBookmark(String bookmarkId, String bookId) async {
    final bookmarks = List<Bookmark>.from(await getBookmarks(bookId));
    bookmarks.removeWhere((b) => b.id == bookmarkId);
    _bookmarksMap[bookId] = bookmarks;
    await _saveBookmarks(bookId, bookmarks);
    changeNotifier.value++;
  }

  Future<void> removeBookmarkByChapter(String bookId, int chapterIndex) async {
    final bookmarks = List<Bookmark>.from(await getBookmarks(bookId));
    bookmarks.removeWhere((b) => b.chapterIndex == chapterIndex);
    _bookmarksMap[bookId] = bookmarks;
    await _saveBookmarks(bookId, bookmarks);
    changeNotifier.value++;
  }

  Future<void> _saveBookmarks(String bookId, List<Bookmark> list) async {
    final prefs = await _getPrefs();
    final raw = json.encode(list.map((e) => e.toJson()).toList());
    await prefs.setString('bookmarks_$bookId', raw);
  }

  // =================== 划线与笔记功能 ===================

  Future<List<ReadingNote>> getNotes(String bookId) async {
    if (_notesMap.containsKey(bookId)) {
      return List.unmodifiable(_notesMap[bookId]!);
    }
    final prefs = await _getPrefs();
    final raw = prefs.getString('notes_$bookId');
    if (raw != null && raw.isNotEmpty) {
      try {
        final List<dynamic> list = json.decode(raw);
        final items = list.map((e) => ReadingNote.fromJson(e as Map<String, dynamic>)).toList();
        _notesMap[bookId] = items;
        return List.unmodifiable(items);
      } catch (_) {}
    }
    _notesMap[bookId] = [];
    return [];
  }

  Future<ReadingNote> addNote({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    int paragraphIndex = 0,
    required String text,
    String note = '',
  }) async {
    final notes = List<ReadingNote>.from(await getNotes(bookId));
    // 避免同一段落重复划线同一文本
    notes.removeWhere((n) =>
        n.chapterIndex == chapterIndex &&
        n.paragraphIndex == paragraphIndex &&
        n.text.trim() == text.trim());

    final newNote = ReadingNote(
      id: '${bookId}_${chapterIndex}_p${paragraphIndex}_${DateTime.now().millisecondsSinceEpoch}',
      bookId: bookId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      paragraphIndex: paragraphIndex,
      text: text.trim(),
      note: note,
      createdAt: DateTime.now(),
    );

    notes.insert(0, newNote);
    _notesMap[bookId] = notes;
    await _saveNotes(bookId, notes);
    changeNotifier.value++;
    return newNote;
  }

  Future<void> removeNote(String noteId, String bookId) async {
    final notes = List<ReadingNote>.from(await getNotes(bookId));
    notes.removeWhere((n) => n.id == noteId);
    _notesMap[bookId] = notes;
    await _saveNotes(bookId, notes);
    changeNotifier.value++;
  }

  Future<void> removeNoteByText(String text, String bookId) async {
    final notes = List<ReadingNote>.from(await getNotes(bookId));
    notes.removeWhere((n) => n.text.trim() == text.trim());
    _notesMap[bookId] = notes;
    await _saveNotes(bookId, notes);
    changeNotifier.value++;
  }

  Future<void> removeNoteByParagraph({
    required String bookId,
    required int chapterIndex,
    required int paragraphIndex,
    required String text,
  }) async {
    final notes = List<ReadingNote>.from(await getNotes(bookId));
    final clean = text.trim();
    notes.removeWhere((n) =>
        n.chapterIndex == chapterIndex &&
        n.paragraphIndex == paragraphIndex &&
        (n.text.trim() == clean || n.text.contains(clean) || clean.contains(n.text.trim())));
    _notesMap[bookId] = notes;
    await _saveNotes(bookId, notes);
    changeNotifier.value++;
  }

  Future<void> _saveNotes(String bookId, List<ReadingNote> list) async {
    final prefs = await _getPrefs();
    final raw = json.encode(list.map((e) => e.toJson()).toList());
    await prefs.setString('notes_$bookId', raw);
  }
}
