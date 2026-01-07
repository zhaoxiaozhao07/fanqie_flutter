import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_history.dart';

/// 下载历史服务 - 管理本地下载历史记录（单例模式）
class HistoryService {
  static const String _storageKey = 'download_history';

  // 单例实例
  static final HistoryService _instance = HistoryService._internal();

  // 工厂构造函数返回单例
  factory HistoryService() => _instance;

  // 私有构造函数
  HistoryService._internal();

  SharedPreferences? _prefs;
  List<DownloadHistory> _historyList = [];
  bool _initialized = false;

  /// 初始化服务
  Future<void> initialize() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();
    await _loadHistory();
    _initialized = true;
  }

  /// 从本地存储加载历史记录
  Future<void> _loadHistory() async {
    final jsonString = _prefs?.getString(_storageKey);
    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final List<dynamic> jsonList = json.decode(jsonString);
        _historyList = jsonList
            .map((item) => DownloadHistory.fromJson(item))
            .toList();
        // 按下载时间倒序排列
        _historyList.sort((a, b) => b.downloadTime.compareTo(a.downloadTime));
      } catch (e) {
        _historyList = [];
      }
    }
  }

  /// 保存历史记录到本地存储
  Future<void> _saveHistory() async {
    try {
      final jsonList = _historyList.map((item) => item.toJson()).toList();
      final jsonString = json.encode(jsonList);
      await _prefs?.setString(_storageKey, jsonString);
    } catch (e) {
      // 保存失败
    }
  }

  /// 添加下载记录
  Future<void> addHistory(DownloadHistory record) async {
    await initialize();

    // 移除同一本书的旧记录（如果存在）
    _historyList.removeWhere((item) => item.bookId == record.bookId);

    // 添加新记录到列表开头
    _historyList.insert(0, record);

    await _saveHistory();
  }

  /// 获取所有下载历史
  Future<List<DownloadHistory>> getHistoryList() async {
    await initialize();
    return List.from(_historyList);
  }

  /// 删除单条历史记录
  Future<void> deleteHistory(String bookId) async {
    await initialize();

    _historyList.removeWhere((item) => item.bookId == bookId);
    await _saveHistory();
  }

  /// 批量删除历史记录
  Future<void> deleteHistories(List<String> bookIds) async {
    await initialize();

    _historyList.removeWhere((item) => bookIds.contains(item.bookId));
    await _saveHistory();
  }

  /// 清空所有历史记录
  Future<void> clearAllHistory() async {
    await initialize();

    _historyList.clear();
    await _saveHistory();
  }

  /// 获取历史记录数量
  Future<int> getHistoryCount() async {
    await initialize();
    return _historyList.length;
  }

  /// 检查书籍是否在历史记录中
  Future<bool> hasHistory(String bookId) async {
    await initialize();
    return _historyList.any((item) => item.bookId == bookId);
  }

  /// 获取指定书籍的历史记录
  Future<DownloadHistory?> getHistoryByBookId(String bookId) async {
    await initialize();
    try {
      return _historyList.firstWhere((item) => item.bookId == bookId);
    } catch (e) {
      return null;
    }
  }
}
