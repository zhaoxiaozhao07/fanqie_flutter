import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_settings.dart';

class ReaderSettingsRecord {
  final ReaderSettings settings;
  final bool bookOverride;
  const ReaderSettingsRecord(this.settings, {this.bookOverride = false});
}

class ReaderSettingsRepository {
  static const globalKey = 'reader_settings_v2';
  static const presetsKey = 'reader_typography_presets_v1';
  static String bookKey(String bookId) => 'reader_settings_book_$bookId';
  static final Map<String, Future<void>> _writes = {};
  static Future<void> flush() => Future.wait(_writes.values).then((_) {});
  static const legacyKeys = {
    'fontSize': 'reader_font_size',
    'lineHeight': 'reader_line_height',
    'letterSpacing': 'reader_letter_spacing',
    'paragraphSpacing': 'reader_paragraph_spacing',
    'horizontalPadding': 'reader_horizontal_padding',
    'fontFamily': 'reader_font_family',
    'indent': 'reader_indent_two_chars',
    'pageMode': 'reader_is_page_mode',
    'pageAnimation': 'reader_page_turn_animation',
    'themeIndex': 'reader_theme_index',
    'commentBubbles': 'reader_show_comment_bubbles',
    'volumeKeys': 'reader_volume_key_scroll',
    'tapLayout': 'reader_tap_layout',
  };

  Future<ReaderSettingsRecord> load([String? bookId]) async {
    await _writes[globalKey]?.catchError((_) {});
    if (bookId != null) await _writes[bookKey(bookId)]?.catchError((_) {});
    final prefs = await SharedPreferences.getInstance();
    if (bookId != null) {
      final book = _decode(prefs.getString(bookKey(bookId)));
      if (book != null) return ReaderSettingsRecord(book, bookOverride: true);
    }
    final global = _decode(prefs.getString(globalKey));
    if (global != null) return ReaderSettingsRecord(global);
    final legacy = <String, dynamic>{
      for (final entry in legacyKeys.entries)
        if (prefs.containsKey(entry.value)) entry.key: prefs.get(entry.value),
    };
    return ReaderSettingsRecord(ReaderSettings.fromJson(legacy));
  }

  ReaderSettings? _decode(String? raw) {
    if (raw == null) return null;
    try {
      return ReaderSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // Preserve malformed/future data; a read never deletes it.
    }
  }

  Future<void> save(ReaderSettings settings, {String? bookId}) {
    final key = bookId == null ? globalKey : bookKey(bookId);
    final values = settings.toJson();
    return _serialize(key, () async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, jsonEncode(values))) {
        throw StateError('阅读设置保存失败');
      }
      if (bookId != null) return;
      // Compatibility mirrors for older consumers. Book overrides stay isolated.
      for (final entry in legacyKeys.entries) {
        final value = values[entry.key];
        if (value is bool) {
          await prefs.setBool(entry.value, value);
        } else if (value is int) {
          await prefs.setInt(entry.value, value);
        } else if (value is double) {
          await prefs.setDouble(entry.value, value);
        } else if (value is String) {
          await prefs.setString(entry.value, value);
        }
      }
    });
  }

  Future<void> clearBookOverride(String bookId) =>
      _serialize(bookKey(bookId), () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(bookKey(bookId));
      });

  Future<Map<String, ReaderSettings>> loadPresets() async {
    await _writes[presetsKey]?.catchError((_) {});
    return _readPresets(await SharedPreferences.getInstance());
  }

  Map<String, ReaderSettings> _readPresets(SharedPreferences prefs) {
    final result = <String, ReaderSettings>{};
    try {
      final data =
          jsonDecode(prefs.getString(presetsKey) ?? '{}')
              as Map<String, dynamic>;
      for (final entry in data.entries.take(8)) {
        try {
          result[entry.key] = ReaderSettings.fromJson(
            entry.value as Map<String, dynamic>,
          );
        } catch (_) {
          /* One malformed preset does not hide the other presets. */
        }
      }
    } catch (_) {
      /* Preserve unreadable source data. */
    }
    return result;
  }

  Future<void> savePreset(String name, ReaderSettings settings) {
    final clean = name.trim();
    if (clean.isEmpty || clean.characters.length > 24) {
      throw ArgumentError('预设名称须为 1–24 个字符');
    }
    return _serialize(presetsKey, () async {
      final prefs = await SharedPreferences.getInstance();
      final presets = _readPresets(prefs)..remove(clean);
      presets[clean] = settings;
      if (presets.length > 8) throw StateError('最多保存 8 个预设，请先删除一个');
      await prefs.setString(
        presetsKey,
        jsonEncode({
          for (final entry in presets.entries) entry.key: entry.value.toJson(),
        }),
      );
    });
  }

  Future<void> removePreset(String name) => _serialize(presetsKey, () async {
    final prefs = await SharedPreferences.getInstance();
    final presets = _readPresets(prefs)..remove(name);
    await prefs.setString(
      presetsKey,
      jsonEncode({
        for (final entry in presets.entries) entry.key: entry.value.toJson(),
      }),
    );
  });

  static Future<void> _serialize(String key, Future<void> Function() task) {
    late final Future<void> next;
    next = (_writes[key] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => task())
        .whenComplete(() {
          if (identical(_writes[key], next)) _writes.remove(key);
        });
    _writes[key] = next;
    return next;
  }
}
