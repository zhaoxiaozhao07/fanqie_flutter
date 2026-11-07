import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bookmark.dart';

bool readerJsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && readerJsonEquals(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => i,
        ).every((i) => readerJsonEquals(a[i], b[i]));
  }
  return a == b;
}

class ReaderTrashEntry {
  final String id, targetKey, action, label;
  final DateTime deletedAt;
  final List<Map<String, dynamic>> items, expected;
  const ReaderTrashEntry({
    required this.id,
    required this.targetKey,
    required this.action,
    required this.label,
    required this.deletedAt,
    required this.items,
    this.expected = const [],
  });
  String get kind => targetKey.startsWith('notes_')
      ? '笔记'
      : targetKey.startsWith('bookmarks_')
      ? '书签'
      : '书架';
  Map<String, dynamic> toJson() => {
    'id': id,
    'target_key': targetKey,
    'action': action,
    'label': label,
    'deleted_at': deletedAt.toUtc().toIso8601String(),
    'items': items,
    'expected': expected,
  };
  factory ReaderTrashEntry.fromJson(Map json) {
    final key = json['target_key']?.toString() ?? '';
    if ((!RegExp(r'^(notes_|bookmarks_)[a-zA-Z0-9_-]{1,180}$').hasMatch(key) &&
            key != 'bookshelf_books_v1') ||
        !['delete', 'edit'].contains(json['action']) ||
        json['id'] is! String ||
        (json['id'] as String).isEmpty ||
        (json['id'] as String).length > 180 ||
        json['label'] is! String ||
        (json['label'] as String).length > 512) {
      throw const FormatException('回收站记录损坏，原数据已保留');
    }
    List<Map<String, dynamic>> records(dynamic input) {
      if (input is! List || input.length > 5000) {
        throw const FormatException('回收站项目超限');
      }
      final result = input
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final identity = key == 'bookshelf_books_v1' ? 'book_id' : 'id';
      final bookId = key.startsWith('notes_')
          ? key.substring(6)
          : key.substring(10);
      for (final item in result) {
        if ((item[identity]?.toString().isEmpty ?? true) ||
            !RegExp(
              r'^[a-zA-Z0-9_-]{1,180}$',
            ).hasMatch(item['book_id']?.toString() ?? '') ||
            (key != 'bookshelf_books_v1' && item['book_id'] != bookId) ||
            (key.startsWith('notes_') && (item['version'] as num? ?? 1) > 3)) {
          throw const FormatException('回收站项目身份或版本不正确');
        }
        if (key.startsWith('notes_')) {
          final note = ReadingNote.fromJson(item);
          if (note.text.isEmpty || !note.validAnchor) {
            throw const FormatException('回收站笔记范围损坏');
          }
        }
      }
      if (result.map((e) => e[identity]).toSet().length != result.length) {
        throw const FormatException('回收站身份重复');
      }
      return result;
    }

    final items = records(json['items']);
    final expected = records(json['expected'] ?? []);
    final ids = items.map((e) => e['id']).toSet();
    if (expected.isNotEmpty &&
        (expected.length != items.length ||
            !expected.every((e) => ids.contains(e['id'])))) {
      throw const FormatException('回收站修改版本身份不一致');
    }
    if (items.isEmpty || (json['action'] == 'edit' && expected.isEmpty)) {
      throw const FormatException('回收站范围为空');
    }
    return ReaderTrashEntry(
      id: json['id'],
      targetKey: key,
      action: json['action'],
      label: json['label'],
      deletedAt: DateTime.parse(json['deleted_at']),
      items: items,
      expected: expected,
    );
  }
}

/// A copy is committed BEFORE deleting/updating live data. Failure to write
/// history refuses the destructive operation; duplicate restores are harmless.
class ReaderTrashService extends ChangeNotifier {
  static const preferencesKey = 'reader_trash_v1';
  static const maxBytes = 16 * 1024 * 1024;
  static final _instance = ReaderTrashService._();
  factory ReaderTrashService() => _instance;
  ReaderTrashService._();
  Future<void>? _writes;
  int _sequence = 0;
  static List<ReaderTrashEntry> decode(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('回收站数据超限');
    }
    final json = jsonDecode(raw);
    if (json is! Map ||
        json['version'] != 1 ||
        json['entries'] is! List ||
        (json['entries'] as List).length > 1000) {
      throw const FormatException('回收站格式损坏，未覆盖原数据');
    }
    final entries = (json['entries'] as List)
        .map((e) => ReaderTrashEntry.fromJson(e as Map))
        .toList();
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('回收站记录身份重复');
    }
    return entries;
  }

  Future<List<ReaderTrashEntry>> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      preferencesKey,
    );
    return raw == null ? [] : decode(raw);
  }

  Future<List<ReaderTrashEntry>> entries() async {
    await flush();
    return (await _read())..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
  }

  Future<void> flush() async {
    await _writes;
  }

  Future<ReaderTrashEntry> stash({
    required String targetKey,
    required String label,
    required List<Map<String, dynamic>> items,
    List<Map<String, dynamic>> expected = const [],
  }) => _serialize(() async {
    final now = DateTime.now();
    final entry = ReaderTrashEntry.fromJson(
      ReaderTrashEntry(
        id: 'trash_${now.microsecondsSinceEpoch}_${_sequence++}',
        targetKey: targetKey,
        action: expected.isEmpty ? 'delete' : 'edit',
        label: label,
        deletedAt: now,
        items: items,
        expected: expected,
      ).toJson(),
    );
    final next =
        (await _read())
            .where(
              (e) => now.difference(e.deletedAt) < const Duration(days: 30),
            )
            .toList()
          ..add(entry);
    await _save(next);
    return entry;
  });
  Future<void> discard(String id) => _serialize(() async {
    await _save((await _read()).where((e) => e.id != id).toList());
  });
  Future<void> pruneExpired() => _serialize(() async {
    final current = await _read();
    final next = current
        .where(
          (e) =>
              DateTime.now().difference(e.deletedAt) < const Duration(days: 30),
        )
        .toList();
    if (next.length != current.length) await _save(next);
  });
  Future<void> _save(List<ReaderTrashEntry> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
    if (entries.length > 1000 || utf8.encode(raw).length > maxBytes) {
      throw StateError('回收站已满，请先备份并清理；此次删除/修改尚未执行');
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      preferencesKey,
      raw,
    )) {
      throw StateError('回收站保存失败，此次删除/修改尚未执行');
    }
    notifyListeners();
  }

  Future<T> _serialize<T>(Future<T> Function() work) {
    final operation = (_writes ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => work());
    late final Future<void> pending;
    pending = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_writes, pending)) _writes = null;
        });
    _writes = pending;
    return operation;
  }
}
