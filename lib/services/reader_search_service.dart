import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/reading_position.dart';
import 'reader_cache_service.dart';
import 'reader_text.dart';

class ReaderSearchHit {
  final int chapterIndex;
  final String chapterTitle;
  final ReadingPosition position;
  final int endOffset;
  final String quote;
  final String snippet;
  final int snippetStart;
  final int snippetEnd;

  const ReaderSearchHit({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.position,
    required this.endOffset,
    required this.quote,
    required this.snippet,
    required this.snippetStart,
    required this.snippetEnd,
  });
}

class ReaderSearchUpdate {
  final List<ReaderSearchHit> hits;
  final int searchedChapters;
  final int totalChapters;
  final bool done;
  final bool limited;
  const ReaderSearchUpdate({
    this.hits = const [],
    required this.searchedChapters,
    required this.totalChapters,
    this.done = false,
    this.limited = false,
  });
}

/// No ApiService/network dependency. Only embedded, in-memory, or disk-cached
/// text is searched. Large chapters are scanned in an isolate.
class ReaderSearchService {
  final ReaderCacheService cache;
  final int maxResults;
  int _generation = 0;
  ReaderSearchService({ReaderCacheService? cache, this.maxResults = 500})
    : assert(maxResults > 0),
      cache = cache ?? ReaderCacheService();

  void cancel() => _generation++;

  Stream<ReaderSearchUpdate> search({
    required String bookId,
    required List<Chapter> chapters,
    required String query,
    int? onlyChapterIndex,
    Map<String, String> canonicalMemory = const {},
    bool caseSensitive = false,
  }) {
    final generation = ++_generation;
    return _runSearch(
      generation: generation,
      bookId: bookId,
      chapters: List.unmodifiable(chapters),
      query: query,
      onlyChapterIndex: onlyChapterIndex,
      canonicalMemory: Map.unmodifiable(canonicalMemory),
      caseSensitive: caseSensitive,
    );
  }

  Stream<ReaderSearchUpdate> _runSearch({
    required int generation,
    required String bookId,
    required List<Chapter> chapters,
    required String query,
    required int? onlyChapterIndex,
    required Map<String, String> canonicalMemory,
    required bool caseSensitive,
  }) async* {
    if (generation != _generation) return;
    final needle = query.trim();
    if (needle.isEmpty) {
      yield ReaderSearchUpdate(
        searchedChapters: 0,
        totalChapters: chapters.length,
        done: true,
      );
      return;
    }
    if (needle.characters.length > 128) {
      throw const FormatException('关键词不能超过 128 个字符');
    }
    ReaderCacheService? local;
    var keys = <String>{};
    final needsDisk = [
      for (var i = 0; i < chapters.length; i++)
        if ((onlyChapterIndex == null || i == onlyChapterIndex) &&
            chapters[i].content == null &&
            !canonicalMemory.containsKey(chapters[i].itemId))
          i,
    ].isNotEmpty;
    if (needsDisk) {
      final root = await cache.documents();
      if (generation != _generation) return;
      local = ReaderCacheService(documents: () async => root);
      keys = await local.cachedChapterKeys(bookId);
      if (generation != _generation) return;
    }
    final candidates = [
      for (var i = 0; i < chapters.length; i++)
        if ((onlyChapterIndex == null || i == onlyChapterIndex) &&
            (chapters[i].content != null ||
                canonicalMemory.containsKey(chapters[i].itemId) ||
                keys.contains(ReaderCacheService.segment(chapters[i].itemId))))
          i,
    ];
    var searched = 0;
    var matches = 0;
    for (final index in candidates) {
      if (generation != _generation) return;
      final chapter = chapters[index];
      final memory = canonicalMemory[chapter.itemId];
      final content =
          memory ??
          chapter.content ??
          await local!.read(bookId, chapter.itemId);
      if (generation != _generation) return;
      if (!ReaderCacheService.isReadable(content)) continue;
      final request = _SearchRequest(
        text: content!,
        title: chapter.title,
        canonical: memory != null,
        query: needle,
        caseSensitive: caseSensitive,
        limit: maxResults - matches,
      );
      final found = content.length > 50000
          ? await compute(_scanChapter, request)
          : _scanChapter(request);
      if (generation != _generation) return;
      searched++;
      matches += found.length;
      final batch = [
        for (final hit in found)
          ReaderSearchHit(
            chapterIndex: index,
            chapterTitle: chapter.title,
            position: ReadingPosition(
              chapterId: chapter.itemId,
              paragraphIndex: hit.paragraph,
              characterOffset: hit.start,
            ),
            endOffset: hit.end,
            quote: hit.quote,
            snippet: hit.snippet,
            snippetStart: hit.snippetStart,
            snippetEnd: hit.snippetEnd,
          ),
      ];
      if (batch.isNotEmpty || searched % 8 == 0) {
        yield ReaderSearchUpdate(
          hits: batch,
          searchedChapters: searched,
          totalChapters: chapters.length,
        );
      }
      if (matches >= maxResults) {
        yield ReaderSearchUpdate(
          searchedChapters: searched,
          totalChapters: chapters.length,
          done: true,
          limited: true,
        );
        return;
      }
      // Give UI/cancellation a turn even for tiny cached chapters.
      await Future<void>.delayed(Duration.zero);
    }
    if (generation == _generation) {
      yield ReaderSearchUpdate(
        searchedChapters: searched,
        totalChapters: chapters.length,
        done: true,
      );
    }
  }
}

class _SearchRequest {
  final String text, title, query;
  final bool canonical, caseSensitive;
  final int limit;
  const _SearchRequest({
    required this.text,
    required this.title,
    required this.query,
    required this.canonical,
    required this.caseSensitive,
    required this.limit,
  });
}

class _ParagraphHit {
  final int paragraph, start, end, snippetStart, snippetEnd;
  final String quote, snippet;
  const _ParagraphHit(
    this.paragraph,
    this.start,
    this.end,
    this.quote,
    this.snippet,
    this.snippetStart,
    this.snippetEnd,
  );
}

int _boundary(List<int> boundaries, int target, {bool ceiling = false}) {
  var low = 0;
  var high = boundaries.length - 1;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (boundaries[middle] < target) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return !ceiling && boundaries[low] > target && low > 0
      ? boundaries[low - 1]
      : boundaries[low];
}

List<_ParagraphHit> _scanChapter(_SearchRequest request) {
  final paragraphs = request.canonical
      ? request.text.split('\n\n').map((p) => p.trim()).toList()
      : ReaderText.paragraphs(request.text, chapterTitle: request.title);
  final expression = RegExp(
    RegExp.escape(request.query),
    caseSensitive: request.caseSensitive,
    unicode: true,
  );
  final hits = <_ParagraphHit>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final paragraph = paragraphs[index];
    final matches = expression.allMatches(paragraph).iterator;
    if (!matches.moveNext()) continue;
    final boundaries = <int>[0];
    var cursor = 0;
    for (final character in paragraph.characters) {
      cursor += character.length;
      boundaries.add(cursor);
    }
    do {
      if (hits.length >= request.limit) return hits;
      final match = matches.current;
      final start = _boundary(boundaries, match.start);
      final end = _boundary(boundaries, match.end, ceiling: true);
      if (hits.isNotEmpty &&
          hits.last.paragraph == index &&
          hits.last.start == start &&
          hits.last.end == end) {
        continue;
      }
      final from = _boundary(boundaries, math.max(0, start - 24));
      final to = _boundary(
        boundaries,
        math.min(paragraph.length, end + 48),
        ceiling: true,
      );
      final prefix = from > 0 ? '…' : '';
      final snippet =
          '$prefix${paragraph.substring(from, to)}${to < paragraph.length ? '…' : ''}';
      hits.add(
        _ParagraphHit(
          index,
          start,
          end,
          paragraph.substring(start, end),
          snippet,
          prefix.length + start - from,
          prefix.length + end - from,
        ),
      );
    } while (matches.moveNext());
  }
  return hits;
}
