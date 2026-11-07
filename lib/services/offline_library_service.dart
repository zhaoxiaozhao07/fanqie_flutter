import 'dart:convert';
import 'dart:io';
import '../models/book.dart';
import '../models/chapter.dart';
import 'app_storage.dart';
import 'book_directory_cache.dart';
import 'bookmark_service.dart';
import 'reader_cache_service.dart';
import 'reader_search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineLibraryBook {
  final Book book;
  final List<Chapter> chapters;
  const OfflineLibraryBook(this.book, this.chapters);
}

class OfflineLibraryHit {
  final OfflineLibraryBook source;
  final ReaderSearchHit hit;
  const OfflineLibraryHit(this.source, this.hit);
}

class OfflineLibrarySearchUpdate {
  final List<OfflineLibraryHit> hits;
  final int searchedBooks, totalBooks, searchedChapters;
  final bool done, limited;
  final List<String> warnings;
  const OfflineLibrarySearchUpdate({
    this.hits = const [],
    this.searchedBooks = 0,
    this.totalBooks = 0,
    this.searchedChapters = 0,
    this.done = false,
    this.limited = false,
    this.warnings = const [],
  });
}

/// No API dependency: inventory, catalogs and text all come from local files.
class OfflineLibraryService {
  final ReaderCacheService cache;
  final int maxResults;
  OfflineLibraryService({ReaderCacheService? cache, this.maxResults = 500})
    : cache = cache ?? ReaderCacheService(documents: AppStorage.documents);
  int _generation = 0;
  ReaderSearchService? _scanner;
  void cancel() {
    _generation++;
    _scanner?.cancel();
  }

  Future<List<Chapter>?> chaptersFor(String bookId) async {
    final directory = BookDirectoryCache(cache);
    return await directory.readLocal(bookId) ??
        (await directory.readRemote(bookId))?.chapters;
  }

  Future<List<Book>> inventory() async {
    final prefs = await SharedPreferences.getInstance();
    final metadata = <String, Book>{};
    for (final key in [
      'bookshelf_books_v1',
      'reading_history_v1',
      'download_history',
    ]) {
      try {
        for (final raw in jsonDecode(prefs.getString(key) ?? '[]') as List) {
          final book = Book.fromSearchJson(
            Map<String, dynamic>.from(raw as Map),
          );
          if (book.bookId.isNotEmpty) metadata[book.bookId] = book;
        }
      } catch (_) {}
    }
    try {
      for (final raw
          in (jsonDecode(prefs.getString(BookmarkService.noteBooksKey) ?? '{}')
                  as Map)
              .values) {
        final book = Book.fromSearchJson(Map<String, dynamic>.from(raw as Map));
        metadata.putIfAbsent(book.bookId, () => book);
      }
    } catch (_) {}
    final root = await cache.documents();
    final ids = <String>{};
    for (final name in ['offline_books', 'reader_cache_v2']) {
      final directory = Directory('${root.path}/$name');
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final id = entity.uri.pathSegments.where((e) => e.isNotEmpty).last;
        if (!RegExp(r'^[a-zA-Z0-9_-]{1,180}$').hasMatch(id)) continue;
        ids.add(id);
        if (ids.length > 10000) throw const FormatException('离线书籍目录超限');
      }
    }
    final books = ids
        .map(
          (id) =>
              metadata[id] ??
              Book(bookId: id, bookName: '缓存书籍 $id', author: '未知作者'),
        )
        .toList();
    books.sort((a, b) => a.bookName.compareTo(b.bookName));
    return books;
  }

  Stream<OfflineLibrarySearchUpdate> search(String query) {
    final generation = ++_generation;
    _scanner?.cancel();
    return _search(query, generation);
  }

  Stream<OfflineLibrarySearchUpdate> _search(
    String query,
    int generation,
  ) async* {
    if (query.trim().isEmpty) {
      yield const OfflineLibrarySearchUpdate(done: true);
      return;
    }
    final books = await inventory();
    if (generation != _generation) return;
    final hits = <OfflineLibraryHit>[], warnings = <String>[];
    var searched = 0, chapters = 0;
    yield OfflineLibrarySearchUpdate(totalBooks: books.length);
    for (final book in books) {
      if (generation != _generation) return;
      final directory = await chaptersFor(book.bookId);
      if (generation != _generation) return;
      if (directory == null) {
        if (warnings.length < 10) {
          warnings.add('${book.bookName}：目录缺失或损坏，未猜测章节顺序');
        }
        searched++;
        continue;
      }
      final source = OfflineLibraryBook(book, List.unmodifiable(directory));
      final remaining = maxResults - hits.length;
      if (remaining <= 0) break;
      final scanner = _scanner = ReaderSearchService(
        cache: cache,
        maxResults: remaining,
      );
      final previousChapters = chapters;
      await for (final update in scanner.search(
        bookId: book.bookId,
        chapters: directory,
        query: query,
      )) {
        if (generation != _generation) return;
        hits.addAll(update.hits.map((hit) => OfflineLibraryHit(source, hit)));
        chapters = previousChapters + update.searchedChapters;
        yield OfflineLibrarySearchUpdate(
          hits: List.unmodifiable(hits),
          searchedBooks: searched,
          totalBooks: books.length,
          searchedChapters: chapters,
          warnings: List.unmodifiable(warnings),
          limited: update.limited,
        );
        if (update.limited || hits.length >= maxResults) {
          yield OfflineLibrarySearchUpdate(
            hits: List.unmodifiable(hits),
            searchedBooks: searched + 1,
            totalBooks: books.length,
            searchedChapters: chapters,
            done: true,
            limited: true,
            warnings: List.unmodifiable(warnings),
          );
          return;
        }
      }
      searched++;
    }
    yield OfflineLibrarySearchUpdate(
      hits: List.unmodifiable(hits),
      searchedBooks: searched,
      totalBooks: books.length,
      searchedChapters: chapters,
      done: true,
      limited: hits.length >= maxResults,
      warnings: List.unmodifiable(warnings),
    );
  }
}
