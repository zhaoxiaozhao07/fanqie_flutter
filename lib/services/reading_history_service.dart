import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/reading_history.dart';

/// 阅读历史服务 - 记录所有打开浏览/阅读过的书籍
class ReadingHistoryService {
  static const String _storageKey = 'reading_history_v1';
  static const int _maxHistoryCount = 300;

  static final ReadingHistoryService _instance = ReadingHistoryService._internal();
  factory ReadingHistoryService() => _instance;
  ReadingHistoryService._internal();

  final List<ReadingHistory> _historyList = [];
  SharedPreferences? _prefs;
  bool _initialized = false;

  final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    final jsonStr = _prefs?.getString(_storageKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> list = json.decode(jsonStr);
        _historyList.clear();
        _historyList.addAll(
          list.whereType<Map>().map((j) => ReadingHistory.fromJson(Map<String, dynamic>.from(j))),
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('初始化阅读历史失败: $e');
        }
      }
    }
    _initialized = true;
  }

  Future<void> _save() async {
    _prefs ??= await SharedPreferences.getInstance();
    final jsonList = _historyList.map((h) => h.toJson()).toList();
    await _prefs!.setString(_storageKey, json.encode(jsonList));
    changeNotifier.value++;
  }

  /// 记录一次阅读（不论是否在书架，均插入到历史首位）
  Future<void> recordReading({
    required Book book,
    required int chapterIndex,
    required String chapterTitle,
  }) async {
    await initialize();

    _historyList.removeWhere((h) => h.bookId == book.bookId);

    _historyList.insert(
      0,
      ReadingHistory(
        bookId: book.bookId,
        bookName: book.bookName,
        author: book.author,
        thumbUrl: book.thumbUrl,
        category: book.category,
        creationStatus: book.creationStatus,
        score: book.score,
        lastReadChapterTitle: chapterTitle,
        lastReadChapterIndex: chapterIndex,
        lastReadTime: DateTime.now(),
      ),
    );

    if (_historyList.length > _maxHistoryCount) {
      _historyList.removeRange(_maxHistoryCount, _historyList.length);
    }

    await _save();
  }

  /// 获取阅读历史列表
  Future<List<ReadingHistory>> getHistoryList() async {
    await initialize();
    return List.unmodifiable(_historyList);
  }

  /// 批量删除阅读历史
  Future<void> deleteHistories(List<String> bookIds) async {
    await initialize();
    final idSet = bookIds.toSet();
    _historyList.removeWhere((h) => idSet.contains(h.bookId));
    await _save();
  }

  /// 清空阅读历史
  Future<void> clearAll() async {
    await initialize();
    _historyList.clear();
    await _save();
  }
}
