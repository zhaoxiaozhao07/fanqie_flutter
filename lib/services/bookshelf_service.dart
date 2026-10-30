import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';
import 'api_service.dart';

/// 书架服务 - 本地收藏、进度缓存与批量管理
class BookshelfService {
  static const String _storageKey = 'bookshelf_books_v1';

  static final BookshelfService _instance = BookshelfService._internal();
  factory BookshelfService() => _instance;
  BookshelfService._internal();

  final List<BookshelfBook> _books = [];
  SharedPreferences? _prefs;
  bool _initialized = false;

  /// 用于触发全局书架状态更新
  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  List<BookshelfBook> get books {
    // 默认按最后阅读时间降序排序（最新阅读过的在最前），若无阅读记录则按添加时间降序
    final sorted = List<BookshelfBook>.from(_books);
    sorted.sort((a, b) {
      final aTime = a.lastReadTime ?? a.addedTime;
      final bTime = b.lastReadTime ?? b.addedTime;
      return bTime.compareTo(aTime);
    });
    return sorted;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    final jsonStr = _prefs?.getString(_storageKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> list = json.decode(jsonStr);
        _books.clear();
        _books.addAll(
          list.whereType<Map>().map((j) => BookshelfBook.fromJson(Map<String, dynamic>.from(j))),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('初始化书架失败: $e');
        }
      }
    }
    _initialized = true;
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    final jsonList = _books.map((b) => b.toJson()).toList();
    await _prefs!.setString(_storageKey, json.encode(jsonList));
    changeNotifier.value++;
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
    await initialize();
    _books.removeWhere((b) => b.bookId == bookId);
    await _save();
  }

  /// 批量从书架中移除书籍
  Future<void> removeMultiple(List<String> bookIds) async {
    await initialize();
    final idSet = bookIds.toSet();
    _books.removeWhere((b) => idSet.contains(b.bookId));
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
      final isLatest = b.latestRemoteChapters != null && (chapterIndex + 1) >= b.latestRemoteChapters!;
      _books[index] = _books[index].copyWith(
        lastReadChapterIndex: chapterIndex,
        lastReadChapterTitle: chapterTitle,
        lastReadTime: DateTime.now(),
        hasUpdate: isLatest ? false : b.hasUpdate,
        totalChapters: isLatest ? (b.latestRemoteChapters ?? b.totalChapters) : b.totalChapters,
      );
      await _save();
    }
  }

  /// 更新书籍封面（若原有封面为空）
  Future<void> updateCover(String bookId, String thumbUrl) async {
    await initialize();
    final index = _books.indexWhere((b) => b.bookId == bookId);
    if (index != -1 && (_books[index].thumbUrl == null || _books[index].thumbUrl!.isEmpty)) {
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

  /// 检查连载书籍更新 (Update Watcher)
  Future<Map<String, int>> checkBookshelfUpdates({bool force = false}) async {
    await initialize();
    final apiService = ApiService();
    final updatesFound = <String, int>{};

    for (int i = 0; i < _books.length; i++) {
      final book = _books[i];
      // 已完结的书籍如果不是 force 则跳过
      if (!force && book.creationStatus == '已完结') continue;

      try {
        final chapters = await apiService.getBookDirectory(book.bookId);
        if (chapters.isNotEmpty) {
          final remoteCount = chapters.length;
          final localBaseCount = book.totalChapters > 0
              ? book.totalChapters
              : (book.lastReadChapterIndex != null ? (book.lastReadChapterIndex! + 1) : 0);

          if (remoteCount > localBaseCount && localBaseCount > 0) {
            final diff = remoteCount - localBaseCount;
            updatesFound[book.bookId] = diff;
            _books[i] = book.copyWith(
              latestRemoteChapters: remoteCount,
              hasUpdate: true,
              lastCheckedTime: DateTime.now(),
            );
          } else {
            _books[i] = book.copyWith(
              totalChapters: remoteCount,
              latestRemoteChapters: remoteCount,
              hasUpdate: false,
              lastCheckedTime: DateTime.now(),
            );
          }
        }
      } catch (_) {}
    }

    if (updatesFound.isNotEmpty) {
      await _save();
    }
    return updatesFound;
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
