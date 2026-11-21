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
  static Future<void>? _mutationTail;
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
      _ensureSettingsEditable(prefs.getString(key));
      await _persist(prefs, key, jsonEncode(values));
      if (bookId != null) return;
      // Compatibility mirrors for older consumers. Book overrides stay isolated.
      for (final entry in legacyKeys.entries) {
        final value = values[entry.key];
        if (value is bool || value is num || value is String) {
          await _persist(prefs, entry.value, value);
        }
      }
    });
  }

  Future<void> clearBookOverride(String bookId) =>
      _serialize(bookKey(bookId), () async {
        final prefs = await SharedPreferences.getInstance();
        _ensureSettingsEditable(prefs.getString(bookKey(bookId)));
        await _persist(prefs, bookKey(bookId), null);
      });

  void _ensureSettingsEditable(String? raw) {
    if (raw != null && _decode(raw) == null) {
      throw StateError('原设置损坏或版本不受支持，已保留原数据');
    }
  }

  Future<void> _persist(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    final cached = prefs.get(key);
    final previous = cached is List<String> ? cached.toList() : cached;
    try {
      if (!await _writeValue(prefs, key, value)) {
        throw StateError('阅读设置保存失败');
      }
    } catch (_) {
      // Both public and Windows store caches mutate before the disk result.
      // A key-scoped compensating write restores both, even when disk writes
      // still return false. reload() would just copy the optimistic store cache.
      try {
        await _writeValue(prefs, key, previous);
      } catch (_) {
        // Keep the original persistence error if compensation also throws.
      }
      rethrow;
    }
  }

  Future<bool> _writeValue(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) => switch (value) {
    null => prefs.remove(key),
    bool value => prefs.setBool(key, value),
    int value => prefs.setInt(key, value),
    double value => prefs.setDouble(key, value),
    String value => prefs.setString(key, value),
    List<String> value => prefs.setStringList(key, value),
    _ => throw ArgumentError('不支持的阅读设置类型'),
  };

  Future<Map<String, ReaderSettings>> loadPresets() async {
    await _writes[presetsKey]?.catchError((_) {});
    return _readPresets(await SharedPreferences.getInstance());
  }

  Map<String, ReaderSettings> _readPresets(SharedPreferences prefs) {
    final result = <String, ReaderSettings>{};
    try {
      final data = _presetData(prefs);
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

  Map<String, dynamic> _presetData(SharedPreferences prefs) {
    try {
      return jsonDecode(prefs.getString(presetsKey) ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {
      throw StateError('个人预设数据损坏，已保留原数据');
    }
  }

  void _ensurePresetEditable(Map<String, dynamic> presets, String name) {
    if (!presets.containsKey(name)) return;
    try {
      ReaderSettings.fromJson(presets[name] as Map<String, dynamic>);
    } catch (_) {
      throw StateError('原预设损坏或版本不受支持，已保留原数据');
    }
  }

  Future<void> savePreset(String name, ReaderSettings settings) {
    final clean = name.trim();
    if (clean.isEmpty || clean.characters.length > 24) {
      throw ArgumentError('预设名称须为 1–24 个字符');
    }
    return _serialize(presetsKey, () async {
      final prefs = await SharedPreferences.getInstance();
      final presets = _presetData(prefs);
      _ensurePresetEditable(presets, clean);
      presets.remove(clean);
      presets[clean] = settings.toJson();
      if (presets.length > 8) throw StateError('最多保存 8 个预设，请先删除一个');
      await _persist(prefs, presetsKey, jsonEncode(presets));
    });
  }

  Future<void> removePreset(String name) => _serialize(presetsKey, () async {
    final prefs = await SharedPreferences.getInstance();
    final presets = _presetData(prefs);
    _ensurePresetEditable(presets, name);
    presets.remove(name);
    await _persist(prefs, presetsKey, jsonEncode(presets));
  });

  static Future<void> _serialize(String key, Future<void> Function() task) {
    late final Future<void> next;
    // Windows persists the entire store map for every key. Do not let a
    // different-key write persist an optimistic failed mutation before its
    // compensation has restored the store cache.
    next = (_mutationTail ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => task())
        .whenComplete(() {
          if (identical(_writes[key], next)) _writes.remove(key);
          if (identical(_mutationTail, next)) _mutationTail = null;
        });
    _writes[key] = next;
    _mutationTail = next;
    return next;
  }
}
