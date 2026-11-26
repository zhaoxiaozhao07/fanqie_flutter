import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地搜索历史管理服务（支持去重置顶、单项删除、清空与备份同步）
class SearchHistoryService extends ChangeNotifier {
  static const String preferencesKey = 'search_history_v1';
  static const int maxEntries = 20;

  static final SearchHistoryService _instance = SearchHistoryService._();
  factory SearchHistoryService() => _instance;
  SearchHistoryService._();

  final List<String> _items = [];
  bool _initialized = false;

  bool get initialized => _initialized;
  List<String> get items => List.unmodifiable(_items);

  Future<void> initialize() async {
    if (_initialized) return;
    await reload();
    _initialized = true;
  }

  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferencesKey);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        _items.addAll(decodeHistory(raw));
      } catch (_) {}
    }
    notifyListeners();
  }

  static List<String> decodeHistory(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('搜索历史格式损坏');
    }
    final seen = <String>{};
    final result = <String>[];
    for (final entry in decoded) {
      final keyword = entry?.toString().trim() ?? '';
      if (keyword.isEmpty || keyword.length > 100) continue;
      if (seen.add(keyword)) {
        result.add(keyword);
        if (result.length >= maxEntries) break;
      }
    }
    return result;
  }

  static String mergeEncoded(String currentRaw, String incomingRaw) {
    final merged = <String>[];
    final seen = <String>{};
    for (final item in [...decodeHistory(currentRaw), ...decodeHistory(incomingRaw)]) {
      if (seen.add(item)) {
        merged.add(item);
        if (merged.length >= maxEntries) break;
      }
    }
    return jsonEncode(merged);
  }

  Future<void> addKeyword(String keyword) async {
    await initialize();
    final clean = keyword.trim();
    if (clean.isEmpty) return;
    _items.remove(clean);
    _items.insert(0, clean);
    if (_items.length > maxEntries) {
      _items.removeRange(maxEntries, _items.length);
    }
    await _persist();
  }

  Future<void> removeKeyword(String keyword) async {
    await initialize();
    if (_items.remove(keyword)) {
      await _persist();
    }
  }

  Future<void> clearAll() async {
    await initialize();
    if (_items.isEmpty) return;
    _items.clear();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferencesKey, jsonEncode(_items));
    notifyListeners();
  }
}
