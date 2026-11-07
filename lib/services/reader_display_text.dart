import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';

/// Display-only transformations have an exact 1:1 UTF-16 mapping. Source,
/// copying, annotations, search and speech are never rewritten.
class ReaderDisplayText {
  static Future<void>? _loading;
  static final _tables = <String, Map<int, int>>{};
  static final _cache = <(String, String), String>{};
  static Future<void> ensureLoaded() =>
      _tables.length == 2 ? Future.value() : _loading ??= _load();

  static Future<void> _load() async {
    try {
      final raw =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/data/reader_script_map.json',
                ),
              )
              as Map;
      for (final name in ['simplified', 'traditional']) {
        final pairs = (raw[name] as String).codeUnits;
        if (pairs.length.isOdd) throw const FormatException('无效简繁映射');
        _tables[name] = {
          for (var i = 0; i < pairs.length; i += 2) pairs[i]: pairs[i + 1],
        };
      }
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  static String convert(String source, String script) {
    if (script == 'original' || source.isEmpty) return source;
    final table = _tables[script];
    if (table == null) return source;
    final key = (source, script);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final result = String.fromCharCodes(
      source.codeUnits.map((code) => table[code] ?? code),
    );
    if (source.length <= 10000) {
      _cache[key] = result;
      while (_cache.length > 256) {
        _cache.remove(_cache.keys.first);
      }
    }
    return result;
  }

  static InlineSpan span(InlineSpan original, String script) {
    if (script == 'original' || original is! TextSpan) return original;
    return TextSpan(
      text: original.text == null ? null : convert(original.text!, script),
      style: original.style,
      recognizer: original.recognizer,
      mouseCursor: original.mouseCursor,
      onEnter: original.onEnter,
      onExit: original.onExit,
      semanticsLabel: original.semanticsLabel,
      locale: original.locale,
      spellOut: original.spellOut,
      children: original.children?.map((e) => span(e, script)).toList(),
    );
  }
}
