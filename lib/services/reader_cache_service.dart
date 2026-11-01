import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderCacheMode { saver, standard, commute }

class ReaderCachePolicy {
  final ReaderCacheMode mode;
  final bool wifiOnly;
  final int maxBytes;

  const ReaderCachePolicy({
    this.mode = ReaderCacheMode.standard,
    this.wifiOnly = false,
    this.maxBytes = 300 * 1024 * 1024,
  });

  int get ahead => switch (mode) {
    ReaderCacheMode.saver => 1,
    ReaderCacheMode.standard => 4,
    ReaderCacheMode.commute => 12,
  };

  bool allowsPrefetch(String network) =>
      network != 'offline' && (!wifiOnly || network == 'wifi');

  static Future<ReaderCachePolicy> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ReaderCachePolicy(
      mode: ReaderCacheMode
          .values[(prefs.getInt('reader_cache_mode') ?? 1).clamp(0, 2)],
      wifiOnly: prefs.getBool('reader_cache_wifi_only') ?? false,
      maxBytes:
          (prefs.getInt('reader_cache_max_mb') ?? 300).clamp(50, 1000) *
          1024 *
          1024,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('reader_cache_mode', mode.index);
    await prefs.setBool('reader_cache_wifi_only', wifiOnly);
    await prefs.setInt('reader_cache_max_mb', maxBytes ~/ (1024 * 1024));
  }
}

/// Temporary reader data lives in its own tree. Explicit downloads, legacy
/// offline data and imported books are read-only here, never eviction targets.
class ReaderCacheService {
  final Future<Directory> Function() documents;
  static final Map<String, Future<void>> _operations = {};
  static final Set<String> pinnedBooks = {};
  static final Map<String, int> _pinCounts = {};

  static void pinBook(String bookId) {
    _pinCounts[bookId] = (_pinCounts[bookId] ?? 0) + 1;
    pinnedBooks.add(bookId);
  }

  static void unpinBook(String bookId) {
    final count = (_pinCounts[bookId] ?? 1) - 1;
    if (count <= 0) {
      _pinCounts.remove(bookId);
      pinnedBooks.remove(bookId);
    } else {
      _pinCounts[bookId] = count;
    }
  }

  ReaderCacheService({Future<Directory> Function()? documents})
    : documents = documents ?? _documents;

  static Future<Directory> _documents() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  static String segment(String value) =>
      RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value)
      ? value
      : 'encoded_${base64Url.encode(utf8.encode(value)).replaceAll('=', '')}';

  static bool isReadable(String? content) =>
      content != null &&
      content.trim().isNotEmpty &&
      !content.contains('APP端专享/锁章章节') &&
      !content.contains('[本章内容下载失败');

  Future<Directory> temporaryRoot() async =>
      Directory('${(await documents()).path}/reader_cache_v2');

  Future<File> temporaryFile(String bookId, String chapterId) async => File(
    '${(await temporaryRoot()).path}/${segment(bookId)}/${segment(chapterId)}.txt',
  );

  Future<String?> read(String bookId, String chapterId) async {
    final base = await documents();
    final protected = File(
      '${base.path}/offline_books/${segment(bookId)}/${segment(chapterId)}.txt',
    );
    final saved = await _readFile(protected);
    if (saved != null) return saved;
    final cached = await temporaryFile(bookId, chapterId);
    final result = await _readFile(cached);
    if (result != null) {
      try {
        await cached.setLastModified(DateTime.now());
      } on FileSystemException {
        // A successful read is useful even on a read-only/full filesystem.
      }
    }
    return result;
  }

  Future<String?> _readFile(File file) async {
    try {
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return isReadable(content) ? content : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(String bookId, String chapterId, String content) async {
    if (!isReadable(content)) throw const FormatException('章节内容不完整');
    final file = await temporaryFile(bookId, chapterId);
    await _serialize(file.parent.parent.path, () async {
      await file.parent.create(recursive: true);
      final staging = File('${file.path}.pending');
      try {
        await staging.writeAsString(content, flush: true);
        await staging.rename(file.path);
      } finally {
        if (await staging.exists()) await staging.delete();
      }
    });
  }

  /// Only counts complete, readable chapter files; no network side effects.
  Future<int> contiguousEnd(
    String bookId,
    List<String> chapterIds,
    int start,
  ) async {
    var end = start - 1;
    for (var index = start; index < chapterIds.length; index++) {
      if (await read(bookId, chapterIds[index]) == null) break;
      end = index;
    }
    return end;
  }

  Future<int> temporaryBytes() async {
    final root = await temporaryRoot();
    var total = 0;
    if (!await root.exists()) return total;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // Concurrent removal.
        }
      }
    }
    return total;
  }

  /// Returns bytes remaining. Pinned reading books can temporarily exceed the
  /// limit, but imported/downloaded books are never even enumerated.
  Future<int> trim(int maxBytes, {bool includePinned = false}) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final root = await temporaryRoot();
    var remaining = 0;
    await _serialize(root.path, () async {
      if (!await root.exists()) return;
      final candidates = <(File, FileStat)>[];
      await for (final entry in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File || !entry.path.endsWith('.txt')) continue;
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        remaining += stat.size;
        final pinned = pinnedBooks.any(
          (book) => entry.parent.path == '${root.path}/${segment(book)}',
        );
        if (includePinned || !pinned) candidates.add((entry, stat));
      }
      candidates.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final entry in candidates) {
        if (remaining <= maxBytes) break;
        await entry.$1.delete();
        remaining -= entry.$2.size;
      }
    });
    return remaining;
  }

  static Future<void> _serialize(
    String key,
    Future<void> Function() operation,
  ) {
    late final Future<void> next;
    next = (_operations[key] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => operation())
        .whenComplete(() {
          if (identical(_operations[key], next)) _operations.remove(key);
        });
    _operations[key] = next;
    return next;
  }
}
