import 'dart:convert';
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderBookStatus { toRead, reading, read }

const readerBookStatusLabels = {
  ReaderBookStatus.toRead: '未读',
  ReaderBookStatus.reading: '在读',
  ReaderBookStatus.read: '已读完',
};

class ReaderLibrarySnapshot {
  final Map<String, Map<String, dynamic>> groups, books;
  const ReaderLibrarySnapshot({this.groups = const {}, this.books = const {}});
  Map<String, dynamic> toJson() => {
    'version': 1,
    'groups': groups,
    'books': books,
  };
  factory ReaderLibrarySnapshot.fromJson(Map json) {
    if (json['version'] != 1 ||
        json['groups'] is! Map ||
        json['books'] is! Map ||
        (json['groups'] as Map).length > 50 ||
        (json['books'] as Map).length > 10000) {
      throw const FormatException('书架分组索引损坏，原记录保留');
    }
    final groups = <String, Map<String, dynamic>>{};
    for (final entry in (json['groups'] as Map).entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      if (!RegExp(
            r'^group_[a-zA-Z0-9_-]{1,100}$',
          ).hasMatch(entry.key.toString()) ||
          value['name'] is! String ||
          (value['name'] as String).trim().isEmpty ||
          (value['name'] as String).characters.length > 24 ||
          DateTime.tryParse(value['updated_at']?.toString() ?? '') == null) {
        throw const FormatException('分组信息无效');
      }
      groups[entry.key] = value;
    }
    final books = <String, Map<String, dynamic>>{};
    for (final entry in (json['books'] as Map).entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,180}$').hasMatch(entry.key.toString()) ||
          !ReaderBookStatus.values.any((e) => e.name == value['status']) ||
          value['group_id'] is! String ||
          ((value['group_id'] as String).isNotEmpty &&
              !groups.containsKey(value['group_id'])) ||
          DateTime.tryParse(value['updated_at']?.toString() ?? '') == null) {
        throw const FormatException('书架状态或分组引用无效');
      }
      books[entry.key] = value;
    }
    return ReaderLibrarySnapshot(groups: groups, books: books);
  }
}

/// Optional metadata, independent of membership and authoritative text anchors.
class ReaderLibraryService extends ChangeNotifier {
  static const preferencesKey = 'reader_library_v1';
  static final _instance = ReaderLibraryService._();
  factory ReaderLibraryService() => _instance;
  ReaderLibraryService._();
  ReaderLibrarySnapshot _snapshot = const ReaderLibrarySnapshot();
  ReaderLibrarySnapshot get snapshot => _snapshot;
  Future<void>? _writes;
  int _sequence = 0;
  Future<ReaderLibrarySnapshot> _read() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      preferencesKey,
    );
    if (raw == null) return const ReaderLibrarySnapshot();
    if (utf8.encode(raw).length > 2 * 1024 * 1024) {
      throw const FormatException('书架索引超限');
    }
    return ReaderLibrarySnapshot.fromJson(jsonDecode(raw) as Map);
  }

  Future<void> load() async {
    await flush();
    _snapshot = await _read();
    notifyListeners();
  }

  Future<void> flush() async {
    await _writes;
  }

  String groupFor(String bookId) => _snapshot.books[bookId]?['group_id'] ?? '';
  ReaderBookStatus statusFor(String bookId, {bool hasRead = false}) =>
      ReaderBookStatus.values.firstWhere(
        (e) => e.name == _snapshot.books[bookId]?['status'],
        orElse: () =>
            hasRead ? ReaderBookStatus.reading : ReaderBookStatus.toRead,
      );
  String labelFor(String bookId, {bool hasRead = false}) {
    final group = _snapshot.groups[groupFor(bookId)]?['name'] as String?;
    return '${readerBookStatusLabels[statusFor(bookId, hasRead: hasRead)]}'
        '${group == null ? '' : ' · $group'}';
  }

  Future<String> createGroup(String name) => _serialize(() async {
    final before = await _read();
    final clean = _name(name);
    if (before.groups.length >= 50) throw StateError('最多 50 个分组');
    if (before.groups.values.any((e) => e['name'] == clean)) {
      throw StateError('已有同名分组');
    }
    final id = 'group_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    await _save(
      ReaderLibrarySnapshot(
        groups: {
          ...before.groups,
          id: {
            'name': clean,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        },
        books: before.books,
      ),
    );
    return id;
  });
  Future<void> renameGroup(String id, String name) => _serialize(() async {
    final before = await _read(), clean = _name(name);
    if (!before.groups.containsKey(id)) throw StateError('分组已不存在');
    if (before.groups.entries.any(
      (e) => e.key != id && e.value['name'] == clean,
    )) {
      throw StateError('已有同名分组');
    }
    await _save(
      ReaderLibrarySnapshot(
        groups: {
          ...before.groups,
          id: {
            'name': clean,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        },
        books: before.books,
      ),
    );
  });
  Future<void> deleteGroup(String id) => _serialize(() async {
    final before = await _read();
    final groups = {...before.groups}..remove(id);
    await _save(
      ReaderLibrarySnapshot(
        groups: groups,
        books: {
          for (final entry in before.books.entries)
            entry.key: entry.value['group_id'] == id
                ? {
                    ...entry.value,
                    'group_id': '',
                    'updated_at': DateTime.now().toUtc().toIso8601String(),
                  }
                : entry.value,
        },
      ),
    );
  });
  Future<void> setBooks(
    Set<String> ids, {
    String? groupId,
    ReaderBookStatus? status,
  }) => _serialize(() async {
    final before = await _read();
    if (groupId != null &&
        groupId.isNotEmpty &&
        !before.groups.containsKey(groupId)) {
      throw StateError('分组已不存在');
    }
    final books = {...before.books};
    for (final id in ids) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,180}$').hasMatch(id)) {
        throw ArgumentError('书籍标识无效');
      }
      books[id] = {
        'status':
            status?.name ??
            books[id]?['status'] ??
            ReaderBookStatus.toRead.name,
        'group_id': groupId ?? books[id]?['group_id'] ?? '',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
    }
    await _save(ReaderLibrarySnapshot(groups: before.groups, books: books));
  });
  Future<void> markReading(String id) => _serialize(() async {
    final before = await _read();
    if (before.books[id]?['status'] == 'reading' ||
        before.books[id]?['status'] == 'read') {
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,180}$').hasMatch(id)) return;
    await _save(
      ReaderLibrarySnapshot(
        groups: before.groups,
        books: {
          ...before.books,
          id: {
            'status': 'reading',
            'group_id': before.books[id]?['group_id'] ?? '',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        },
      ),
    );
  });
  static String _name(String value) {
    final clean = value.trim();
    if (clean.isEmpty || clean.characters.length > 24) {
      throw ArgumentError('分组名称须为 1–24 个字符');
    }
    return clean;
  }

  Future<void> _save(ReaderLibrarySnapshot next) async {
    ReaderLibrarySnapshot.fromJson(next.toJson());
    final raw = jsonEncode(next.toJson());
    if (utf8.encode(raw).length > 2 * 1024 * 1024) throw StateError('分组索引已满');
    if (!await (await SharedPreferences.getInstance()).setString(
      preferencesKey,
      raw,
    )) {
      throw StateError('分组索引未保存');
    }
    _snapshot = next;
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
