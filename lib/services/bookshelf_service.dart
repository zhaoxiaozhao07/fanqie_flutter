import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/bookshelf_book.dart';

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
      _books[index] = _books[index].copyWith(
        lastReadChapterIndex: chapterIndex,
        lastReadChapterTitle: chapterTitle,
        lastReadTime: DateTime.now(),
      );
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
}
