import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/bookmark.dart';
import '../models/reader_settings.dart';
import '../models/reading_snapshot.dart';
import 'atomic_file.dart';
import 'app_storage.dart';
import 'bookmark_service.dart';
import 'bookshelf_service.dart';
import 'reader_position_service.dart';
import 'reader_settings_repository.dart';
import 'reading_history_service.dart';
import 'safe_zip_reader.dart';
import 'tts_service.dart';
import 'reading_activity_service.dart';
import 'external_reader_fonts.dart';
import 'reader_trash_service.dart';
import 'reader_library_service.dart';

enum ReaderRestoreMode { merge, replace }

class ReaderBackupInfo {
  final int books, notes, bookmarks, files;
  final DateTime createdAt;
  final int fonts;
  const ReaderBackupInfo(
    this.books,
    this.notes,
    this.bookmarks,
    this.files,
    this.createdAt, {
    this.fonts = 0,
  });
}

class ReaderBackupService {
  final Future<Directory> Function() documents;
  final bool notifyServices;
  ReaderBackupService({
    Future<Directory> Function()? documents,
    this.notifyServices = true,
  }) : documents = documents ?? AppStorage.documents;
  static int _activeTransactions = 0;
  static bool get hasActiveTransaction => _activeTransactions > 0;
  static Future<void>? _creates;
  static Future<void> flushCreates() async {
    await _creates;
  }

  static const _journal = 'reader_restore_journal.json';
  static final _id = RegExp(r'^[a-zA-Z0-9_-]{1,180}$');
  static const _exact = {
    'bookshelf_books_v1',
    'reading_history_v1',
    'reader_settings_v2',
    'reader_typography_presets_v1',
    'reader_cache_mode',
    'reader_cache_wifi_only',
    'reader_cache_max_mb',
    'reader_activity_v1',
    'reader_activity_enabled',
    BookmarkService.noteBooksKey,
    ExternalReaderFonts.preferencesKey,
    ReaderTrashService.preferencesKey,
    ReaderLibraryService.preferencesKey,
  };
  static const _prefixes = [
    'reader_position_',
    'reader_settings_book_',
    'bookmarks_',
    'notes_',
    'read_progress_index_',
    'read_progress_title_',
    'read_progress_time_',
  ];

  static bool allowedKey(String key) =>
      _exact.contains(key) ||
      ReaderSettingsRepository.legacyKeys.values.contains(key) ||
      _prefixes.any(
        (prefix) =>
            key.startsWith(prefix) &&
            _id.hasMatch(key.substring(prefix.length)),
      );

  Future<Map<String, Object>> _snapshot() async {
    if (notifyServices) await ReadingActivityService().flush();
    await BookmarkService().flush();
    await ReaderTrashService().flush();
    await ReaderLibraryService().flush();
    if (notifyServices) await BookshelfService().flush();
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in prefs.getKeys())
        if (allowedKey(key)) key: prefs.get(key)!,
    };
  }

  Future<File> create({bool includeBooks = false, bool includeFonts = true}) {
    final operation = (_creates ?? Future<void>.value())
        .catchError((_) {})
        .then(
          (_) =>
              _create(includeBooks: includeBooks, includeFonts: includeFonts),
        );
    late final Future<void> pending;
    pending = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_creates, pending)) _creates = null;
        });
    _creates = pending;
    return operation;
  }

  Future<String> fingerprint() async {
    final snapshot = await _snapshot();
    final keys = snapshot.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(jsonEncode({for (final key in keys) key: snapshot[key]})),
        )
        .toString();
  }

  Future<File> _create({
    required bool includeBooks,
    required bool includeFonts,
  }) async {
    final data = await _snapshot();
    _validate(data);
    final base = await documents();
    final output = Directory('${base.path}/reader_backups');
    await output.create(recursive: true);
    final file = File(
      '${output.path}/fanqie-backup-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final manifest = jsonEncode({
      'format': 'fanqie-reading-backup',
      'version': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'preferences': data,
    });
    if (utf8.encode(manifest).length > 32 * 1024 * 1024) {
      throw const FormatException('元数据超过 32 MB，请分书导出笔记');
    }
    await compute(
      _writeBackup,
      _BackupWrite(base.path, file.path, manifest, includeBooks, includeFonts),
    );
    return file;
  }

  Future<(SafeZipReader, Map<String, Object>, ReaderBackupInfo)> _read(
    File file,
  ) async {
    final zip = await SafeZipReader.open(
      file,
      fileLimit: 1024 * 1024 * 1024,
      entryLimit: 50000,
      inflatedLimit: 1024 * 1024 * 1024,
      individualLimit: 128 * 1024 * 1024,
    );
    final decoded =
        jsonDecode(
              utf8.decode(
                await zip.read('manifest.json', maxBytes: 32 * 1024 * 1024),
              ),
            )
            as Map<String, dynamic>;
    if (decoded['format'] != 'fanqie-reading-backup' ||
        decoded['version'] != 1) {
      throw const FormatException('备份格式或版本不受支持');
    }
    final preferences = Map<String, Object>.from(decoded['preferences'] as Map);
    _validate(preferences);
    var files = 0;
    for (final entry in zip.entries.values) {
      if (entry.name == 'manifest.json' || entry.name.endsWith('/')) continue;
      final (kind, id, _) = _bookPath(entry.name);
      if (kind == 'font') {
        final inspected = await compute(
          inspectReaderFont,
          await zip.read(
            entry.name,
            maxBytes: ExternalReaderFonts.maxFileBytes,
          ),
        );
        if (inspected.hash != id) throw const FormatException('备份字体校验失败');
      }
      files++;
    }
    int count(String key) => preferences[key] is String
        ? (jsonDecode(preferences[key] as String) as List).length
        : 0;
    int prefixed(String prefix) => preferences.entries
        .where((e) => e.key.startsWith(prefix))
        .fold(
          0,
          (total, e) => total + (jsonDecode(e.value as String) as List).length,
        );
    return (
      zip,
      preferences,
      ReaderBackupInfo(
        count('bookshelf_books_v1'),
        prefixed('notes_'),
        prefixed('bookmarks_'),
        files,
        DateTime.parse(decoded['created_at'] as String),
        fonts: preferences[ExternalReaderFonts.preferencesKey] is String
            ? (jsonDecode(
                        preferences[ExternalReaderFonts.preferencesKey]
                            as String,
                      )
                      as List)
                  .length
            : 0,
      ),
    );
  }

  Future<ReaderBackupInfo> inspect(File file) async => (await _read(file)).$3;

  static (String, String, String) _bookPath(String name) {
    final parts = SafeZipReader.safeName(name).split('/');
    if (parts.length == 3 &&
        parts.first == 'fonts' &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(parts[1]) &&
        ['font.ttf', 'font.otf'].contains(parts[2])) {
      return ('font', parts[1], parts[2]);
    }
    if (parts.length < 3 ||
        parts.first != 'books' ||
        !_id.hasMatch(parts[1]) ||
        parts.skip(2).any((part) => part.isEmpty || part == '.')) {
      throw const FormatException('备份包含不支持的书籍路径');
    }
    return ('book', parts[1], parts.skip(2).join('/'));
  }

  static void _validate(Map<String, Object> data) {
    if (data.length > 50000) throw const FormatException('备份键数量超限');
    final defaults = const ReaderSettings().toJson();
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      if (!allowedKey(key)) throw FormatException('备份含不允许恢复的设置：$key');
      if (key.startsWith('read_progress_index_') ||
          key.startsWith('read_progress_time_') ||
          key == 'reader_cache_mode' ||
          key == 'reader_cache_max_mb') {
        if (value is! int || value < 0) throw const FormatException('数值设置损坏');
      } else if (key == 'reader_cache_wifi_only' ||
          key == 'reader_activity_enabled') {
        if (value is! bool) throw const FormatException('开关设置损坏');
      } else if (ReaderSettingsRepository.legacyKeys.values.contains(key)) {
        final modelKey = ReaderSettingsRepository.legacyKeys.entries
            .firstWhere((e) => e.value == key)
            .key;
        final expected = defaults[modelKey];
        if ((expected is bool && value is! bool) ||
            (expected is num && value is! num) ||
            (expected is String && value is! String)) {
          throw const FormatException('旧版设置类型不正确');
        }
      } else if (key.startsWith('read_progress_title_')) {
        if (value is! String || value.length > 1000) {
          throw const FormatException('章节名不正确');
        }
      } else {
        if (value is! String || value.length > 16 * 1024 * 1024) {
          throw const FormatException('备份数据过大或类型不正确');
        }
        final json = jsonDecode(value);
        if (key.startsWith('reader_position_')) {
          ReadingSnapshot.fromJson(Map<String, dynamic>.from(json as Map));
        } else if (key == ReaderSettingsRepository.globalKey ||
            key.startsWith('reader_settings_book_')) {
          ReaderSettings.fromJson(Map<String, dynamic>.from(json as Map));
        } else if (key == ReaderSettingsRepository.presetsKey) {
          for (final preset in (json as Map).values) {
            ReaderSettings.fromJson(Map<String, dynamic>.from(preset as Map));
          }
        } else if (key == ReaderLibraryService.preferencesKey) {
          ReaderLibrarySnapshot.fromJson(json as Map);
        } else if (key == ReaderTrashService.preferencesKey) {
          ReaderTrashService.decode(value);
        } else if (key == ExternalReaderFonts.preferencesKey) {
          if (json is! List || json.length > 20) {
            throw const FormatException('字体索引超限');
          }
          final fonts = json
              .map((e) => ExternalReaderFont.fromJson(e as Map))
              .toList();
          if (fonts.map((e) => e.id).toSet().length != fonts.length) {
            throw const FormatException('字体索引重复');
          }
        } else if (key == BookmarkService.noteBooksKey) {
          if (json is! Map || json.length > 10000) {
            throw const FormatException('笔记书籍名称索引损坏');
          }
          for (final entry in json.entries) {
            if (!_id.hasMatch(entry.key.toString()) ||
                entry.value is! Map ||
                (entry.value as Map)['book_id'] != entry.key) {
              throw const FormatException('笔记书籍身份不匹配');
            }
          }
        } else if (key.startsWith('notes_') || key.startsWith('bookmarks_')) {
          final prefix = key.startsWith('notes_') ? 'notes_' : 'bookmarks_';
          final bookId = key.substring(prefix.length);
          if (json is! List || json.length > 5000) {
            throw const FormatException('批注数量超限');
          }
          for (final raw in json) {
            final item = Map<String, dynamic>.from(raw as Map);
            if (item['book_id'] != bookId ||
                (item['id']?.toString().isEmpty ?? true)) {
              throw const FormatException('批注身份不匹配');
            }
            if (prefix == 'notes_') {
              if ((item['version'] as num? ?? 1) > 3) {
                throw const FormatException('笔记版本过新');
              }
              final note = ReadingNote.fromJson(item);
              if (note.text.isEmpty || !note.validAnchor) {
                throw const FormatException('笔记原文范围损坏');
              }
            } else {
              Bookmark.fromJson(item);
            }
          }
        } else if (key == 'bookshelf_books_v1' || key == 'reading_history_v1') {
          if (json is! List || json.length > 10000) {
            throw const FormatException('书籍数量超限');
          }
          for (final item in json) {
            if (item is! Map ||
                !_id.hasMatch(item['book_id']?.toString() ?? '')) {
              throw const FormatException('书籍标识不合法');
            }
          }
        } else if (key == 'reader_activity_v1' &&
            (json is! Map ||
                json['version'] != 1 ||
                json['books'] is! Map ||
                json['days'] is! Map)) {
          throw const FormatException('阅读统计损坏或版本不支持');
        }
      }
    }
  }

  static DateTime _timestamp(Map item) {
    for (final key in [
      'updated_at',
      'last_read_time',
      'created_at',
      'added_time',
    ]) {
      final date = DateTime.tryParse(item[key]?.toString() ?? '');
      if (date != null) return date;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static Map<String, Object> merge(
    Map<String, Object> current,
    Map<String, Object> incoming,
  ) {
    final output = {...current};
    for (final entry in incoming.entries) {
      final key = entry.key;
      final previous = current[key];
      if (previous == null) {
        output[key] = entry.value;
        continue;
      }
      if (key.startsWith('notes_') ||
          key.startsWith('bookmarks_') ||
          key == 'bookshelf_books_v1' ||
          key == 'reading_history_v1') {
        final id = key.startsWith('notes_') || key.startsWith('bookmarks_')
            ? 'id'
            : 'book_id';
        final items = <String, Map<String, dynamic>>{};
        for (final raw in [
          ...jsonDecode(previous as String) as List,
          ...jsonDecode(entry.value as String) as List,
        ]) {
          final item = Map<String, dynamic>.from(raw as Map);
          final identity = item[id].toString();
          final old = items[identity];
          if (old == null || _timestamp(item).isAfter(_timestamp(old))) {
            items[identity] = item;
          }
        }
        final list = items.values.toList()
          ..sort((a, b) => _timestamp(b).compareTo(_timestamp(a)));
        output[key] = jsonEncode(list);
      } else if (key == ReaderLibraryService.preferencesKey) {
        final old = ReaderLibrarySnapshot.fromJson(
          jsonDecode(previous as String) as Map,
        );
        final incoming = ReaderLibrarySnapshot.fromJson(
          jsonDecode(entry.value as String) as Map,
        );
        Map<String, Map<String, dynamic>> combine(
          Map<String, Map<String, dynamic>> a,
          Map<String, Map<String, dynamic>> b,
        ) {
          final result = {...a};
          for (final item in b.entries) {
            if (result[item.key] == null ||
                _timestamp(item.value).isAfter(_timestamp(result[item.key]!))) {
              result[item.key] = item.value;
            }
          }
          return result;
        }

        final combined = ReaderLibrarySnapshot(
          groups: combine(old.groups, incoming.groups),
          books: combine(old.books, incoming.books),
        );
        ReaderLibrarySnapshot.fromJson(combined.toJson());
        output[key] = jsonEncode(combined.toJson());
      } else if (key == ReaderTrashService.preferencesKey) {
        final entries = <String, ReaderTrashEntry>{
          for (final record in [
            ...ReaderTrashService.decode(previous as String),
            ...ReaderTrashService.decode(entry.value as String),
          ])
            record.id: record,
        };
        final raw = jsonEncode({
          'version': 1,
          'entries': entries.values.map((e) => e.toJson()).toList(),
        });
        ReaderTrashService.decode(raw);
        output[key] = raw;
      } else if (key == ExternalReaderFonts.preferencesKey) {
        final fonts = <String, dynamic>{
          for (final font in jsonDecode(previous as String) as List)
            font['id']: font,
        };
        for (final font in jsonDecode(entry.value as String) as List) {
          fonts.putIfAbsent(font['id'] as String, () => font);
        }
        if (fonts.length > 20) {
          throw const FormatException('合并后字体超过 20 种，请先清理字体库');
        }
        output[key] = jsonEncode(fonts.values.toList());
      } else if (key == BookmarkService.noteBooksKey) {
        final items = Map<String, dynamic>.from(
          jsonDecode(previous as String) as Map,
        );
        final next = jsonDecode(entry.value as String) as Map;
        for (final item in next.entries) {
          final old = items[item.key];
          if (old == null ||
              _timestamp(item.value as Map).isAfter(_timestamp(old as Map))) {
            items[item.key.toString()] = item.value;
          }
        }
        output[key] = jsonEncode(items);
      } else if (key.startsWith('reader_position_')) {
        final old = jsonDecode(previous as String) as Map;
        final next = jsonDecode(entry.value as String) as Map;
        if (_timestamp(next).isAfter(_timestamp(old))) {
          output[key] = entry.value;
        }
      }
    }
    // Keep compatibility summaries consistent with the chosen authoritative anchor.
    for (final entry in output.entries.toList()) {
      if (!entry.key.startsWith('reader_position_')) continue;
      final bookId = entry.key.substring('reader_position_'.length);
      final position = ReadingSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(entry.value as String) as Map),
      );
      output['read_progress_index_$bookId'] = position.chapterIndex;
      output['read_progress_title_$bookId'] = position.chapterTitle;
      output['read_progress_time_$bookId'] =
          position.updatedAt.millisecondsSinceEpoch;
    }
    return output;
  }

  Future<void> _writePreferences(Map<String, Object> data) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where(allowedKey).toList()) {
      if (!data.containsKey(key) && !await prefs.remove(key)) {
        throw StateError('恢复设置失败');
      }
    }
    for (final entry in data.entries) {
      final value = entry.value;
      bool saved;
      if (value is bool) {
        saved = await prefs.setBool(entry.key, value);
      } else if (value is int) {
        final modelKeys = ReaderSettingsRepository.legacyKeys.entries.where(
          (e) => e.value == entry.key,
        );
        final isDouble =
            modelKeys.isNotEmpty &&
            const ReaderSettings().toJson()[modelKeys.first.key] is double;
        saved = isDouble
            ? await prefs.setDouble(entry.key, value.toDouble())
            : await prefs.setInt(entry.key, value);
      } else if (value is double) {
        saved = await prefs.setDouble(entry.key, value);
      } else if (value is String) {
        saved = await prefs.setString(entry.key, value);
      } else {
        throw const FormatException('不支持的设置类型');
      }
      if (!saved) throw StateError('恢复设置失败');
    }
  }

  Future<void> restore(
    File file, {
    ReaderRestoreMode mode = ReaderRestoreMode.merge,
  }) async {
    _activeTransactions++;
    try {
      await _restore(file, mode: mode);
    } finally {
      _activeTransactions--;
    }
  }

  Future<void> _restore(File file, {required ReaderRestoreMode mode}) async {
    final (zip, incoming, _) = await _read(file);
    final base = await documents();
    await recover();
    final work = Directory(
      '${base.path}/restore_work/restore-${DateTime.now().microsecondsSinceEpoch}',
    );
    final fresh = Directory('${work.path}/new');
    await fresh.create(recursive: true);
    final groups = <(String, String)>{};
    try {
      // Validate all bytes before changing preferences or any existing book.
      for (final entry in zip.entries.values) {
        if (entry.name == 'manifest.json' || entry.name.endsWith('/')) continue;
        final (kind, id, relative) = _bookPath(entry.name);
        groups.add((kind, id));
        final target = File('${fresh.path}/$kind/$id/$relative');
        await target.parent.create(recursive: true);
        await zip.stream(entry.name).pipe(target.openWrite());
      }
      if (notifyServices && TtsService().isActive) await TtsService().stop();
      final previous = await _snapshot();
      _validate(previous);
      final chosen = mode == ReaderRestoreMode.merge
          ? merge(previous, incoming)
          : incoming;
      _validate(chosen);
      final operations = <Map<String, Object>>[];
      for (final (kind, id) in groups) {
        final destination = _destination(base, kind, id);
        if (await FileSystemEntity.type(
              destination.parent.path,
              followLinks: false,
            ) ==
            FileSystemEntityType.link) {
          throw const FormatException('恢复目标目录不能是符号链接');
        }
        final exists = await destination.exists();
        if (mode == ReaderRestoreMode.merge && exists) continue;
        operations.add({'id': id, 'kind': kind, 'had_old': exists});
      }
      await AtomicFile.writeString(
        File('${base.path}/$_journal'),
        jsonEncode({
          'version': 2,
          'work': path.basename(work.path),
          'preferences': previous,
          'books': operations,
        }),
      );
      for (final op in operations) {
        final id = op['id'] as String;
        final kind = op['kind'] as String;
        final destination = _destination(base, kind, id);
        if (op['had_old'] == true) {
          final old = Directory('${work.path}/old/$kind/$id');
          await old.parent.create(recursive: true);
          await destination.rename(old.path);
        }
        await destination.parent.create(recursive: true);
        await Directory('${fresh.path}/$kind/$id').rename(destination.path);
      }
      await _writePreferences(chosen);
      await File('${base.path}/$_journal').delete();
      await _notify();
    } catch (_) {
      await recover();
      rethrow;
    } finally {
      if (!await File('${base.path}/$_journal').exists() &&
          await work.exists()) {
        await work.delete(recursive: true);
      }
    }
  }

  /// Roll back an interrupted transaction before exposing the main application UI.
  Future<void> recover() async {
    _activeTransactions++;
    try {
      await _recover();
    } finally {
      _activeTransactions--;
    }
  }

  Future<void> _recover() async {
    final base = await documents();
    final file = File('${base.path}/$_journal');
    if (!await file.exists()) return;
    final journal = jsonDecode(await file.readAsString()) as Map;
    if (![1, 2].contains(journal['version']) ||
        !RegExp(r'^restore-\d+$').hasMatch(journal['work'] as String)) {
      throw const FormatException('恢复日志损坏，已保留现场');
    }
    final previous = Map<String, Object>.from(journal['preferences'] as Map);
    _validate(previous);
    final work = Directory('${base.path}/restore_work/${journal['work']}');
    for (final op in (journal['books'] as List).reversed) {
      final id = (op as Map)['id'] as String;
      final kind = journal['version'] == 1 ? 'book' : op['kind'] as String;
      if ((kind != 'book' && kind != 'font') ||
          (kind == 'book'
              ? !_id.hasMatch(id)
              : !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))) {
        throw const FormatException('恢复日志路径不合法');
      }
      final current = _destination(base, kind, id);
      final old = Directory(
        journal['version'] == 1
            ? '${work.path}/old/$id'
            : '${work.path}/old/$kind/$id',
      );
      if (await old.exists()) {
        if (await current.exists()) await current.delete(recursive: true);
        await old.rename(current.path);
      } else if (op['had_old'] == false && await current.exists()) {
        await current.delete(recursive: true);
      }
    }
    await _writePreferences(previous);
    await file.delete();
    if (await work.exists()) await work.delete(recursive: true);
    await _notify();
  }

  Future<void> _notify() async {
    if (!notifyServices) return;
    BookmarkService().invalidate();
    await BookshelfService().reload();
    await ReadingHistoryService().reload();
    await ReadingActivityService().reload();
    await ExternalReaderFonts().reload();
    await ReaderLibraryService().load();
  }

  static Directory _destination(Directory base, String kind, String id) =>
      Directory(
        '${base.path}/${kind == 'font' ? 'reader_fonts' : 'offline_books'}/$id',
      );
}

class _BackupWrite {
  final String root, target, manifest;
  final bool includeBooks, includeFonts;
  const _BackupWrite(
    this.root,
    this.target,
    this.manifest,
    this.includeBooks,
    this.includeFonts,
  );
}

Future<void> _writeBackup(_BackupWrite request) async {
  final output = File(request.target);
  final staging = File('${request.target}.pending');
  final manifest = File('${request.target}.manifest');
  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    await manifest.writeAsString(request.manifest);
    encoder.create(staging.path);
    opened = true;
    await encoder.addFile(manifest, 'manifest.json');
    var total = 0;
    var count = 1;
    if (request.includeFonts) {
      final metadata =
          (jsonDecode(request.manifest) as Map)['preferences'] as Map;
      final fonts =
          jsonDecode(
                metadata[ExternalReaderFonts.preferencesKey] as String? ?? '[]',
              )
              as List;
      for (final raw in fonts) {
        final font = ExternalReaderFont.fromJson(raw as Map);
        final file = File(
          '${request.root}/reader_fonts/${font.hash}/font.${font.format}',
        );
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.length() > ExternalReaderFonts.maxFileBytes) {
          throw const FormatException('字体文件丢失或过大，可取消包含字体后备份元数据');
        }
        final inspected = inspectReaderFont(await file.readAsBytes());
        if (inspected.hash != font.hash) {
          throw const FormatException('字体文件校验失败');
        }
        total += await file.length();
        count++;
        await encoder.addFile(file, 'fonts/${font.hash}/font.${font.format}');
      }
    }
    final books = Directory('${request.root}/offline_books');
    if (request.includeBooks && await books.exists()) {
      await for (final entity in books.list(followLinks: false)) {
        if (entity is! Directory ||
            !ReaderBackupService._id.hasMatch(path.basename(entity.path))) {
          continue;
        }
        await for (final file in entity.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is! File) continue;
          final size = await file.length();
          total += size;
          count++;
          if (size > 128 * 1024 * 1024 ||
              total > 900 * 1024 * 1024 ||
              count > 50000) {
            throw const FormatException('书籍备份过大，请减少书籍文件或仅备份阅读数据');
          }
          final relative = path
              .relative(file.path, from: books.path)
              .replaceAll('\\', '/');
          await encoder.addFile(file, 'books/$relative');
        }
      }
    }
    await encoder.close();
    opened = false;
    if (await staging.length() > 1024 * 1024 * 1024) {
      throw const FormatException('备份超过 1 GB');
    }
    await staging.rename(output.path);
  } finally {
    if (opened) await encoder.close();
    if (await staging.exists()) await staging.delete();
    if (await manifest.exists()) await manifest.delete();
  }
}
