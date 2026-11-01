import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/reading_position.dart';
import '../models/reading_snapshot.dart';

class ReaderPositionService {
  // Shared across reader instances: a disposing route must not race a new one.
  static final Map<String, Future<void>> _writes = {};
  static Future<void> flush() => Future.wait(_writes.values).then((_) {});

  Future<ReadingPosition?> load(String bookId) async {
    return (await loadSnapshot(bookId))?.position;
  }

  Future<ReadingSnapshot?> loadSnapshot(String bookId) async {
    await _writes[bookId]?.catchError((_) {});
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('reader_position_$bookId');
    if (saved == null) return null;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) return null;
      return ReadingSnapshot.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    String bookId,
    ReadingPosition position, {
    int chapterIndex = 0,
    String chapterTitle = '',
    String? previousChapterId,
    String? nextChapterId,
    Future<void> Function()? onCommitted,
  }) {
    final snapshot = ReadingSnapshot(
      position: position,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      previousChapterId: previousChapterId,
      nextChapterId: nextChapterId,
      updatedAt: DateTime.now().toUtc(),
    );
    final encoded = jsonEncode(snapshot.toJson());
    // 生命周期收尾与防抖保存也遵循同一写入顺序，旧位置不能覆盖新位置。
    final previous = _writes[bookId] ?? Future<void>.value();
    late final Future<void> write;
    write = previous
        .catchError((_) {})
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          final saved = await prefs.setString(
            'reader_position_$bookId',
            encoded,
          );
          if (!saved) throw StateError('阅读进度保存失败');
          // Legacy consumers are summaries only; all resume routes load the record.
          await prefs.setInt('read_progress_index_$bookId', chapterIndex);
          await prefs.setString('read_progress_title_$bookId', chapterTitle);
          await prefs.setInt(
            'read_progress_time_$bookId',
            snapshot.updatedAt.millisecondsSinceEpoch,
          );
          await onCommitted?.call();
        })
        .whenComplete(() {
          if (identical(_writes[bookId], write)) _writes.remove(bookId);
        });
    _writes[bookId] = write;
    return write;
  }
}
