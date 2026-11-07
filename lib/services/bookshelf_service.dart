import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/bookshelf_book.dart';
import 'api_service.dart';
import 'reader_trash_service.dart';

/// 书架服务 - 本地收藏、进度缓存与批量管理
class BookshelfService {
  static const String _storageKey = 'bookshelf_books_v1';

  static final BookshelfService _instance = BookshelfService._internal();
  factory BookshelfService() => _instance;
  BookshelfService._internal();
  BookshelfService.forTesting({
    this.directoryLoader,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  Future<List<Chapter>> Function(String)? directoryLoader;
  DateTime Function() _clock = DateTime.now;
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  Future<Map<String, int>>? _updateRequest;
  DateTime? _lastUpdateAttempt;
  final Map<String, int> _membership = {};
  static const updateInterval = Duration(minutes: 30);

  final List<BookshelfBook> _books = [];
  SharedPreferences? _prefs;
  bool _initialized = false;
  bool _storageReadable = true;
  int _generation = 0;

  Future<void> reload() async {
    _generation++;
    _initialization = null;
    _updateRequest = null;
    _lastUpdateAttempt = null;
    _membership.clear();
    _initialized = false;
    _prefs = null;
    _books.clear();
    await initialize();
    changeNotifier.value++;
  }

  /// 用于触发全局书架状态更新
  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  List<BookshelfBook> get books {
    // 默认按最后阅读时间降序排序（最新阅读过的在最前），若无阅读记录则按添加时间降序
    final sorted = List<BookshelfBook>.from(_books);
    sorted.sort((a, b) {
      final aTime = a.lastReadTime ?? a.addedTime;
      final bTime = b.lastReadTime ?? b.addedTime;
      final order = bTime.compareTo(aTime);
      return order != 0 ? order : a.bookId.compareTo(b.bookId);
    });
    return sorted;
  }

  Future<void> initialize() {
    if (_initialized) return Future.value();
    if (_initialization != null) return _initialization!;
    late final Future<void> request;
    request = _initialize(_generation).whenComplete(() {
      if (identical(_initialization, request)) _initialization = null;
    });
    return _initialization = request;
  }

  Future<void> _initialize(int generation) async {
    final prefs = await SharedPreferences.getInstance();
    if (generation != _generation) return;
    _prefs = prefs;
    _storageReadable = true;
    final jsonStr = prefs.getString(_storageKey);
    var repaired = false;
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> list = json.decode(jsonStr);
        final byId = <String, BookshelfBook>{};
        for (final raw in list.whereType<Map>()) {
          final book = BookshelfBook.fromJson(Map<String, dynamic>.from(raw));
          if (book.bookId.isEmpty) {
            repaired = true;
            continue;
          }
          final old = byId[book.bookId];
          if (old == null) {
            byId[book.bookId] = book;
          } else {
            // Older index-based update races could already have persisted a
            // duplicate ID. Keep the newer reading state before assigning keys.
            repaired = true;
            final newer =
                (book.lastReadTime ?? book.addedTime).isAfter(
                  old.lastReadTime ?? old.addedTime,
                )
                ? book
                : old;
            final cover = [
              newer.thumbUrl,
              old.thumbUrl,
              book.thumbUrl,
            ].whereType<String>().where((url) => url.isNotEmpty).firstOrNull;
            byId[book.bookId] = cover == null
                ? newer
                : newer.copyWithCover(cover);
          }
        }
        _books.clear();
        _books.addAll(byId.values);
      } catch (e) {
        _storageReadable = false;
        if (kDebugMode) debugPrint('初始化书架失败: $e');
      }
    }
    _initialized = true;
    if (repaired) {
      try {
        await _save(notify: false);
      } catch (_) {
        /* Keep the valid in-memory shelf. */
      }
    }
  }

  Future<void> _save({bool notify = true}) {
    final generation = _generation;
    // Encode at execution time, not before awaiting a prior disk write.
    _writes = _writes.catchError((_) {}).then((_) async {
      if (generation != _generation) return;
      if (!_storageReadable) throw StateError('书架数据损坏，原记录已保留；请先恢复备份');
      _prefs ??= await SharedPreferences.getInstance();
      if (generation != _generation) return;
      if (!await _prefs!.setString(
        _storageKey,
        json.encode(_books.map((b) => b.toJson()).toList()),
      )) {
        throw StateError('书架未保存，请检查存储空间');
      }
      if (notify) changeNotifier.value++;
    });
    return _writes;
  }

  /// 是否在书架中
  bool isInBookshelf(String bookId) {
    return _books.any((b) => b.bookId == bookId);
  }

  /// 切换书架状态：如果在书架中则移除，否则加入
  /// 返回 true 表示已加入，false 表示已移除
  Future<bool> toggleBookshelf(
    Book book, {
    int? chapterIndex,
    String? chapterTitle,
  }) async {
    await initialize();
    if (isInBookshelf(book.bookId)) {
      await removeFromBookshelf(book.bookId);
      return false;
    } else {
      await addToBookshelf(
        book,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
      );
      return true;
    }
  }

  /// 添加到书架
  Future<void> addToBookshelf(
    Book book, {
    int? chapterIndex,
    String? chapterTitle,
    int totalChapters = 0,
  }) async {
    await initialize();
    if (isInBookshelf(book.bookId)) {
      if (chapterIndex != null || chapterTitle != null) {
        await updateReadingProgress(
          book.bookId,
          chapterIndex ?? 0,
          chapterTitle ?? '',
        );
      }
      return;
    }

    _membership[book.bookId] = (_membership[book.bookId] ?? 0) + 1;
    _books.add(
      BookshelfBook.fromBook(
        book,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        readTime: chapterIndex != null ? DateTime.now() : null,
        totalChapters: totalChapters,
      ),
    );
    await _save();
  }

  /// 从书架移除单本书
  Future<void> removeFromBookshelf(String bookId) async {
    await removeMultipleWithUndo([bookId]);
  }

  /// 批量从书架中移除书籍
  Future<void> removeMultiple(List<String> bookIds) async {
    await removeMultipleWithUndo(bookIds);
  }

  Future<ReaderTrashEntry?> removeMultipleWithUndo(List<String> bookIds) async {
    await initialize();
    if (!_storageReadable) throw StateError('书架数据损坏，未执行删除');
    final idSet = bookIds.toSet();
    final removed = _books.where((b) => idSet.contains(b.bookId)).toList();
    if (removed.isEmpty) return null;
    for (final id in idSet) {
      _membership[id] = (_membership[id] ?? 0) + 1;
    }
    final entry = await ReaderTrashService().stash(
      targetKey: _storageKey,
      label: removed.length == 1
          ? removed.first.bookName
          : '${removed.length} 本书',
      items: removed.map((e) => e.toJson()).toList(),
    );
    _books.removeWhere((b) => idSet.contains(b.bookId));
    try {
      await _save();
    } catch (_) {
      _books.addAll(removed.where((e) => !isInBookshelf(e.bookId)));
      rethrow;
    }
    return entry;
  }

  Future<void> flush() => _writes;
  Future<void> restoreSnapshots(ReaderTrashEntry entry) async {
    await initialize();
    for (final json in entry.items) {
      final book = BookshelfBook.fromJson(json);
      final current = getBook(book.bookId);
      if (current != null) {
        // Never replace reading progress accumulated after a book was removed.
        continue;
      }
      _membership[book.bookId] = (_membership[book.bookId] ?? 0) + 1;
      _books.add(book);
    }
    await _save();
  }

  /// 更新书架书籍的阅读进度并置顶
  Future<void> updateReadingProgress(
    String bookId,
    int chapterIndex,
    String chapterTitle,
  ) async {
    await initialize();
    final index = _books.indexWhere((b) => b.bookId == bookId);
    if (index != -1) {
      final b = _books[index];
      final isLatest =
          b.latestRemoteChapters != null &&
          (chapterIndex + 1) >= b.latestRemoteChapters!;
      _books[index] = _books[index].copyWith(
        lastReadChapterIndex: chapterIndex,
        lastReadChapterTitle: chapterTitle,
        lastReadTime: DateTime.now(),
        hasUpdate: isLatest ? false : b.hasUpdate,
        totalChapters: isLatest
            ? (b.latestRemoteChapters ?? b.totalChapters)
            : b.totalChapters,
      );
      await _save();
    }
  }

  /// 更新书籍封面（若原有封面为空）
  Future<void> updateCover(String bookId, String thumbUrl) async {
    await initialize();
    final index = _books.indexWhere((b) => b.bookId == bookId);
    if (index != -1 &&
        (_books[index].thumbUrl == null || _books[index].thumbUrl!.isEmpty)) {
      _books[index] = _books[index].copyWithCover(thumbUrl);
      await _save();
    }
  }

  /// 获取某本书的进度
  BookshelfBook? getBook(String bookId) {
    try {
      return _books.firstWhere((b) => b.bookId == bookId);
    } catch (_) {
      return null;
    }
  }

  /// Update checks never replace a whole old book or write by a stale index.
  /// Notifications describe real visible changes, not another refresh trigger.
  Future<Map<String, int>> checkBookshelfUpdates({bool force = false}) {
    final pending = _updateRequest;
    if (pending != null) return pending;
    final now = _clock();
    if (!force &&
        _lastUpdateAttempt != null &&
        now.difference(_lastUpdateAttempt!) < updateInterval) {
      return Future.value({});
    }
    _lastUpdateAttempt = now;
    late final Future<Map<String, int>> request;
    request = _checkUpdates(force).whenComplete(() {
      if (identical(_updateRequest, request)) _updateRequest = null;
    });
    _updateRequest = request;
    return request;
  }

  Future<Map<String, int>> _checkUpdates(bool force) async {
    final generation = _generation;
    await initialize();
    if (generation != _generation) return {};
    final targets = [
      for (final b in _books) (b.bookId, _membership[b.bookId] ?? 0),
    ];
    final api = directoryLoader == null ? ApiService() : null;
    final found = <String, int>{};
    var touched = false, visibleChanged = false;
    try {
      for (final target in targets) {
        final before = getBook(target.$1);
        if (before == null ||
            before.bookId.startsWith('local_') ||
            (!force && const {'完结', '已完结'}.contains(before.creationStatus))) {
          continue;
        }
        try {
          final chapters =
              await (directoryLoader?.call(target.$1) ??
                  api!.getBookDirectory(target.$1, refresh: true));
          if (generation != _generation) return {};
          if (chapters.isEmpty || (_membership[target.$1] ?? 0) != target.$2) {
            continue;
          }
          final index = _books.indexWhere((b) => b.bookId == target.$1);
          if (index < 0) continue;
          final current =
              _books[index]; // Preserve concurrent progress/cover changes.
          final count = chapters.length;
          final hasUpdate =
              current.totalChapters > 0 && count > current.totalChapters;
          final baseline = hasUpdate ? current.totalChapters : count;
          final changed =
              current.hasUpdate != hasUpdate ||
              current.latestRemoteChapters != count ||
              current.totalChapters != baseline;
          _books[index] = current.copyWith(
            totalChapters: baseline,
            latestRemoteChapters: count,
            hasUpdate: hasUpdate,
            lastCheckedTime: _clock(),
          );
          touched = true;
          visibleChanged |= changed;
          if (hasUpdate && changed) {
            found[target.$1] = count - current.totalChapters;
          }
        } catch (_) {
          /* A failed check does not mutate the book or its order. */
        }
      }
      if (touched && generation == _generation) {
        await _save(notify: visibleChanged);
      }
      return found;
    } finally {
      api?.dispose();
    }
  }

  /// 消除某本书的更新红点徽标
  Future<void> clearBookUpdateBadge(String bookId) async {
    await initialize();
    final index = _books.indexWhere((b) => b.bookId == bookId);
    if (index != -1 && _books[index].hasUpdate) {
      final b = _books[index];
      _books[index] = b.copyWith(
        hasUpdate: false,
        totalChapters: b.latestRemoteChapters ?? b.totalChapters,
      );
      await _save();
    }
  }
}
