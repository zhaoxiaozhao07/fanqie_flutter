import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/bookmark.dart';
import '../models/chapter.dart';
import '../models/reading_position.dart';
import 'api_service.dart';
import 'bookmark_service.dart';
import 'note_anchor_resolver.dart';
import 'reader_text.dart';
import 'reader_cache_service.dart';
import 'offline_library_service.dart';

class NoteSourcePreview {
  final String source;
  final ReadingPosition position;
  const NoteSourcePreview(this.source, this.position);
}

enum NoteLibrarySort { newest, oldest, bookAndChapter }

class IndexedReadingNote {
  final Book book;
  final ReadingNote note;
  final String searchText;
  IndexedReadingNote(this.book, this.note)
    : searchText =
          '${book.bookName}\n${book.author}\n${note.chapterTitle}\n'
                  '${note.text}\n${note.note}\n${note.tags.join(' ')}'
              .toLowerCase();
  String get key => '${note.bookId}/${note.id}';
}

class NoteLibrarySnapshot {
  final List<IndexedReadingNote> entries;
  final Map<String, Book> books;
  final List<String> warnings;
  const NoteLibrarySnapshot({
    this.entries = const [],
    this.books = const {},
    this.warnings = const [],
  });
}

class NoteLibraryLocation {
  final Book book;
  final List<Chapter> chapters;
  final ReadingPosition position;
  final int chapterIndex;
  const NoteLibraryLocation(
    this.book,
    this.chapters,
    this.position,
    this.chapterIndex,
  );
}

class NoteLocateCancelled implements Exception {
  const NoteLocateCancelled();
}

/// Derived local index: no duplicated note store, no automatic network fetch.
class NoteLibraryService {
  static final _instance = NoteLibraryService._();
  factory NoteLibraryService() => _instance;
  NoteLibraryService._() : _api = ApiService();
  @visibleForTesting
  NoteLibraryService.forTesting({required ApiService api}) : _api = api;
  final ApiService _api;
  final _cache = <String, (String, List<ReadingNote>)>{};

  Future<NoteLibrarySnapshot> load() async {
    await BookmarkService().flush();
    final prefs = await SharedPreferences.getInstance();
    final books = <String, Book>{};
    final warnings = <String>[];
    try {
      final registry =
          jsonDecode(prefs.getString(BookmarkService.noteBooksKey) ?? '{}')
              as Map;
      for (final entry in registry.entries) {
        final book = Book.fromSearchJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (book.bookId != entry.key) throw const FormatException('书籍身份不一致');
        books[book.bookId] = book;
      }
    } catch (_) {
      warnings.add('书籍名称索引不可读，已保留原数据；缺失名称将显示书籍 ID。');
    }
    for (final key in [
      'reading_history_v1',
      'download_history',
      'bookshelf_books_v1',
    ]) {
      try {
        for (final raw in jsonDecode(prefs.getString(key) ?? '[]') as List) {
          final book = Book.fromSearchJson(
            Map<String, dynamic>.from(raw as Map),
          );
          if (book.bookId.isNotEmpty) books[book.bookId] = book;
        }
      } catch (_) {
        // A damaged unrelated shelf/history must not hide valid notes.
      }
    }
    final ids = [
      for (final key in prefs.getKeys())
        if (key.startsWith('notes_') && key.length > 6) key.substring(6),
    ]..sort();
    final idSet = ids.toSet();
    _cache.removeWhere((id, _) => !idSet.contains(id));
    final entries = <IndexedReadingNote>[];
    final noteBooks = <String, Book>{};
    for (final id in ids) {
      final raw = prefs.getString('notes_$id') ?? '';
      try {
        final cached = _cache[id];
        final notes = cached != null && cached.$1 == raw
            ? cached.$2
            : raw.length > 50000
            ? await compute(_parseNoteBook, (id, raw))
            : _parseNoteBook((id, raw));
        _cache[id] = (raw, notes);
        if (notes.isEmpty) continue;
        final book =
            books[id] ?? Book(bookId: id, bookName: '书籍 $id', author: '未知作者');
        noteBooks[id] = book;
        for (final note in notes) {
          entries.add(IndexedReadingNote(book, note));
        }
      } catch (_) {
        warnings.add('书籍 $id 的笔记不可读或版本不支持，原记录已保留。');
      }
    }
    entries.sort((a, b) => b.note.updatedAt.compareTo(a.note.updatedAt));
    return NoteLibrarySnapshot(
      entries: List.unmodifiable(entries),
      books: Map.unmodifiable(noteBooks),
      warnings: List.unmodifiable(warnings),
    );
  }

  static List<IndexedReadingNote> filter(
    NoteLibrarySnapshot snapshot, {
    String query = '',
    String bookId = '',
    String tag = '',
    int colorIndex = -1,
    NoteLibrarySort sort = NoteLibrarySort.newest,
  }) {
    final needle = query.trim().toLowerCase();
    final entries = snapshot.entries
        .where(
          (entry) =>
              (bookId.isEmpty || entry.note.bookId == bookId) &&
              (tag.isEmpty || entry.note.tags.contains(tag)) &&
              (colorIndex < 0 || entry.note.colorIndex == colorIndex) &&
              (needle.isEmpty || entry.searchText.contains(needle)),
        )
        .toList();
    entries.sort((a, b) {
      if (sort == NoteLibrarySort.bookAndChapter) {
        final book = a.book.bookName.compareTo(b.book.bookName);
        if (book != 0) return book;
        final chapter = a.note.chapterIndex.compareTo(b.note.chapterIndex);
        if (chapter != 0) return chapter;
        final paragraph = a.note.paragraphIndex.compareTo(
          b.note.paragraphIndex,
        );
        if (paragraph != 0) return paragraph;
        return a.note.startOffset.compareTo(b.note.startOffset);
      }
      return sort == NoteLibrarySort.oldest
          ? a.note.createdAt.compareTo(b.note.createdAt)
          : b.note.updatedAt.compareTo(a.note.updatedAt);
    });
    return entries;
  }

  Future<NoteLibraryLocation> locate(
    IndexedReadingNote entry, {
    bool Function()? isCancelled,
  }) async {
    void check() {
      if (isCancelled?.call() == true) throw const NoteLocateCancelled();
    }

    check();
    final chapters = await _api.getBookChapters(entry.note.bookId);
    check();
    final note = entry.note;
    final candidates = [
      for (var i = 0; i < chapters.length; i++)
        if (note.chapterId.isNotEmpty
            ? chapters[i].itemId == note.chapterId
            : chapters[i].title == note.chapterTitle)
          i,
    ];
    final index = candidates.length == 1
        ? candidates.single
        : note.chapterId.isEmpty &&
              note.chapterTitle.isEmpty &&
              note.chapterIndex >= 0 &&
              note.chapterIndex < chapters.length
        ? note.chapterIndex
        : null;
    if (index == null) {
      throw const FormatException('原书目录缺失或章节身份已变化，笔记未改变。');
    }
    final chapter = chapters[index];
    final raw =
        chapter.content ??
        await _api.getChapterContent(chapter.itemId, bookId: note.bookId);
    check();
    if (raw == null || !ReaderCacheService.isReadable(raw)) {
      throw const FormatException('原文暂不可用，请重新导入原书或重试。');
    }
    final paragraphs = ReaderText.paragraphs(raw, chapterTitle: chapter.title);
    final resolved = NoteAnchorResolver.resolve(note, paragraphs);
    if (resolved == null) {
      throw const FormatException('原文已变化或引用不唯一，未跳转，也未改写笔记。');
    }
    final ready = List<Chapter>.from(chapters);
    ready[index] = chapter.copyWithContent(raw);
    return NoteLibraryLocation(
      entry.book,
      ready,
      ReadingPosition(
        chapterId: chapter.itemId,
        paragraphIndex: resolved.paragraphIndex,
        characterOffset: resolved.start,
      ),
      index,
    );
  }

  /// Preview never fetches the network, changes a progress anchor, or repairs
  /// a note. Missing/ambiguous cached text is reported, not silently guessed.
  Future<NoteSourcePreview> preview(IndexedReadingNote entry) async {
    final offline = OfflineLibraryService(cache: _api.engine.readerCache);
    final note = entry.note;
    final chapters = await offline.chaptersFor(note.bookId) ?? [];
    final candidates = chapters
        .where(
          (chapter) => note.chapterId.isNotEmpty
              ? chapter.itemId == note.chapterId
              : chapter.title == note.chapterTitle,
        )
        .toList();
    final chapter = candidates.length == 1 ? candidates.single : null;
    final id = chapter?.itemId ?? note.chapterId;
    if (id.isEmpty) throw const FormatException('本地目录不足，无法安全预览；可尝试定位原文');
    final raw = chapter?.content ?? await offline.cache.read(note.bookId, id);
    if (raw == null) throw const FormatException('原文未缓存；预览不会自动联网');
    final paragraphs = ReaderText.paragraphs(
      raw,
      chapterTitle: chapter?.title ?? note.chapterTitle,
    );
    final ranges = NoteAnchorResolver.resolveAll(note, paragraphs);
    if (ranges == null || ranges.isEmpty) {
      throw const FormatException('原文已变化或引用不唯一，预览未猜测位置');
    }
    final resolved = ranges.first;
    final first = (resolved.paragraphIndex - 1).clamp(0, paragraphs.length - 1);
    final last = (ranges.last.paragraphIndex + 1).clamp(
      first,
      paragraphs.length - 1,
    );
    final source = paragraphs.sublist(first, last + 1).join('\n\n');
    // A preview is bounded even when an imported paragraph is very long.
    final preview = source.length <= 12000
        ? source
        : '${note.prefix}\n${note.text}\n${note.suffix}\n（段落较长，定位原文可查看完整内容）';
    return NoteSourcePreview(
      preview,
      ReadingPosition(
        chapterId: id,
        paragraphIndex: resolved.paragraphIndex,
        characterOffset: resolved.start,
      ),
    );
  }
}

List<ReadingNote> _parseNoteBook((String, String) request) {
  final raw = jsonDecode(request.$2);
  if (raw is! List ||
      raw.length > 5000 ||
      utf8.encode(request.$2).length > 8 * 1024 * 1024) {
    throw const FormatException('笔记数量或体积超限');
  }
  final notes = <ReadingNote>[];
  final ids = <String>{};
  for (final value in raw) {
    final json = Map<String, dynamic>.from(value as Map);
    if ((json['version'] as num? ?? 1) > 3) {
      throw const FormatException('笔记版本不支持');
    }
    final note = ReadingNote.fromJson(json);
    if (note.bookId != request.$1 ||
        note.id.isEmpty ||
        note.text.isEmpty ||
        !ids.add(note.id) ||
        !note.validAnchor) {
      throw const FormatException('笔记身份或原文范围不正确');
    }
    notes.add(note);
  }
  return List.unmodifiable(notes);
}
