import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_position.dart';

class ReaderPositionService {
  Future<void> _writes = Future.value();

  Future<ReadingPosition?> load(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('reader_position_$bookId');
    if (saved == null) return null;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) return null;
      return ReadingPosition.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String bookId, ReadingPosition position) {
    final encoded = jsonEncode(position.toJson());
    // 生命周期收尾与防抖保存也遵循同一写入顺序，旧位置不能覆盖新位置。
    _writes = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reader_position_$bookId', encoded);
    });
    return _writes;
  }
}
