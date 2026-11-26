import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单条正文净化与替换规则
class TextReplaceRule {
  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool enabled;
  /// 为空字符串表示全局生效，非空表示仅针对指定 bookId 生效
  final String scopeBookId;
  final bool applyToReader;
  final bool applyToTts;
  final DateTime updatedAt;

  TextReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = false,
    this.enabled = true,
    this.scopeBookId = '',
    this.applyToReader = true,
    this.applyToTts = true,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();

  bool matchesScope(String? bookId) {
    if (scopeBookId.isEmpty) return true;
    return bookId != null && scopeBookId == bookId;
  }

  TextReplaceRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
    String? scopeBookId,
    bool? applyToReader,
    bool? applyToTts,
    DateTime? updatedAt,
  }) {
    return TextReplaceRule(
      id: id,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      replacement: replacement ?? this.replacement,
      isRegex: isRegex ?? this.isRegex,
      enabled: enabled ?? this.enabled,
      scopeBookId: scopeBookId ?? this.scopeBookId,
      applyToReader: applyToReader ?? this.applyToReader,
      applyToTts: applyToTts ?? this.applyToTts,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'is_regex': isRegex,
    'enabled': enabled,
    'scope_book_id': scopeBookId,
    'apply_to_reader': applyToReader,
    'apply_to_tts': applyToTts,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory TextReplaceRule.fromJson(Map<String, dynamic> json) {
    final id = (json['id']?.toString() ?? '').trim();
    final name = (json['name']?.toString() ?? '').trim();
    final pattern = json['pattern']?.toString() ?? '';
    if (id.isEmpty || pattern.isEmpty) {
      throw const FormatException('净化规则缺少必要标识或匹配内容');
    }
    return TextReplaceRule(
      id: id,
      name: name.isEmpty ? '未命名规则' : name,
      pattern: pattern,
      replacement: json['replacement']?.toString() ?? '',
      isRegex: json['is_regex'] == true,
      enabled: json['enabled'] != false,
      scopeBookId: (json['scope_book_id']?.toString() ?? '').trim(),
      applyToReader: json['apply_to_reader'] != false,
      applyToTts: json['apply_to_tts'] != false,
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// 带偏移映射表的净化结果，保证原文划线批注高亮可准确投影到净化后的展示文本
class MappedTextResult {
  final String text;
  /// 长度为 original.length + 1，rawToDisplay[i] 表示原文索引 i 在净化后文本中的对应位置
  final List<int> rawToDisplay;
  final bool modified;

  const MappedTextResult({
    required this.text,
    required this.rawToDisplay,
    required this.modified,
  });

  /// 将原文范围 [start, end) 映射到净化后展示文本中的范围
  ({int start, int end}) mapRawRange(int start, int end) {
    if (!modified || rawToDisplay.isEmpty) {
      return (
        start: start.clamp(0, text.length),
        end: end.clamp(0, text.length),
      );
    }
    final maxIdx = rawToDisplay.length - 1;
    final mappedStart = rawToDisplay[start.clamp(0, maxIdx)].clamp(0, text.length);
    final mappedEnd = rawToDisplay[end.clamp(0, maxIdx)].clamp(mappedStart, text.length);
    return (start: mappedStart, end: mappedEnd);
  }
}

/// 正文净化与替换规则管理服务（支持正则与普通文本替换、全局/单书作用域、阅读器与听书联动）
class TextReplaceRuleService extends ChangeNotifier {
  static const String preferencesKey = 'reader_replace_rules_v1';
  static const int maxRuleCount = 200;

  static final TextReplaceRuleService _instance = TextReplaceRuleService._();
  factory TextReplaceRuleService() => _instance;
  TextReplaceRuleService._();

  final List<TextReplaceRule> _rules = [];
  bool _initialized = false;
  int _revision = 0;
  Future<void> _writes = Future.value();

  bool get initialized => _initialized;
  int get revision => _revision;
  List<TextReplaceRule> get rules => List.unmodifiable(_rules);

  /// 常见网文净化规则预设模板（由用户按需一键添加）
  static List<TextReplaceRule> get builtinTemplates => [
    TextReplaceRule(
      id: 'tpl_remove_ticket_ads',
      name: '去除章末求票与催更提示',
      pattern: r'(?:求(?:月票|推荐票|收藏|打赏|追读|五星好评)[^\n。！？!?]{0,40}[。！？!?~～]*)+',
      replacement: '',
      isRegex: true,
      enabled: true,
      applyToReader: true,
      applyToTts: true,
    ),
    TextReplaceRule(
      id: 'tpl_remove_qq_group',
      name: '去除书友群与加群广告',
      pattern: r'(?:书友群|读者群|粉丝群|交流群)[^\n。！？]{0,30}[0-9]{5,12}[^\n]*',
      replacement: '',
      isRegex: true,
      enabled: true,
      applyToReader: true,
      applyToTts: true,
    ),
    TextReplaceRule(
      id: 'tpl_clean_divider_symbols',
      name: '清理冗长装饰分割符号',
      pattern: r'[=\-*~—_★☆◆◇■□●○]{5,}',
      replacement: '',
      isRegex: true,
      enabled: true,
      applyToReader: true,
      applyToTts: true,
    ),
  ];

  Future<void> initialize() async {
    if (_initialized) return;
    await reload();
    _initialized = true;
  }

  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferencesKey);
    _rules.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        _rules.addAll(decodeRules(raw));
      } catch (_) {}
    }
    _revision++;
    notifyListeners();
  }

  Future<void> flush() => _writes;

  static List<TextReplaceRule> decodeRules(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['version'] != 1 || decoded['rules'] is! List) {
      throw const FormatException('净化规则格式或版本不支持');
    }
    final list = decoded['rules'] as List;
    if (list.length > maxRuleCount) {
      throw const FormatException('净化规则数量超过限制');
    }
    final seen = <String>{};
    final parsed = <TextReplaceRule>[];
    for (final item in list) {
      if (item is! Map) throw const FormatException('净化规则项损坏');
      final rule = TextReplaceRule.fromJson(Map<String, dynamic>.from(item));
      if (seen.add(rule.id)) {
        parsed.add(rule);
      }
    }
    return parsed;
  }

  static String encodeRules(List<TextReplaceRule> rules) => jsonEncode({
    'version': 1,
    'rules': rules.map((r) => r.toJson()).toList(),
  });

  /// 合并两端规则集（按 id 去重，保留 updatedAt 较新的规则）
  static String mergeEncoded(String currentRaw, String incomingRaw) {
    final map = <String, TextReplaceRule>{};
    for (final r in [...decodeRules(currentRaw), ...decodeRules(incomingRaw)]) {
      final old = map[r.id];
      if (old == null || r.updatedAt.isAfter(old.updatedAt)) {
        map[r.id] = r;
      }
    }
    final merged = map.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return encodeRules(merged.take(maxRuleCount).toList());
  }

  /// 校验正则表达式或规则有效性，返回 null 表示合法，否则返回中文错误原因
  static String? validateRule({
    required String name,
    required String pattern,
    required bool isRegex,
  }) {
    if (name.trim().isEmpty) return '规则名称不能为空';
    if (pattern.isEmpty) return '匹配内容不能为空';
    if (pattern.length > 500) return '匹配内容过长（最多 500 字符）';
    if (isRegex) {
      try {
        RegExp(pattern, multiLine: true);
      } on FormatException catch (e) {
        return '正则表达式无效：${e.message}';
      }
    }
    return null;
  }

  Future<void> upsertRule(TextReplaceRule rule) async {
    await initialize();
    final err = validateRule(
      name: rule.name,
      pattern: rule.pattern,
      isRegex: rule.isRegex,
    );
    if (err != null) throw FormatException(err);
    final idx = _rules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      _rules[idx] = rule.copyWith(updatedAt: DateTime.now().toUtc());
    } else {
      if (_rules.length >= maxRuleCount) {
        throw const FormatException('净化规则已达上限（最多 200 条）');
      }
      _rules.insert(0, rule.copyWith(updatedAt: DateTime.now().toUtc()));
    }
    await _save();
  }

  Future<void> toggleRule(String id, bool enabled) async {
    await initialize();
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx < 0) return;
    _rules[idx] = _rules[idx].copyWith(
      enabled: enabled,
      updatedAt: DateTime.now().toUtc(),
    );
    await _save();
  }

  Future<void> deleteRule(String id) async {
    await initialize();
    final before = _rules.length;
    _rules.removeWhere((r) => r.id == id);
    if (_rules.length != before) {
      await _save();
    }
  }

  /// 一键导入内置常用净化模板（按 ID 去重）
  Future<int> installBuiltinTemplates() async {
    await initialize();
    var added = 0;
    for (final tpl in builtinTemplates) {
      if (_rules.any((r) => r.id == tpl.id)) continue;
      if (_rules.length >= maxRuleCount) break;
      _rules.add(tpl.copyWith(updatedAt: DateTime.now().toUtc()));
      added++;
    }
    if (added > 0) {
      await _save();
    }
    return added;
  }

  String exportRulesJson() => encodeRules(_rules);

  Future<int> importRulesJson(String raw) async {
    await initialize();
    final incoming = decodeRules(raw);
    var count = 0;
    for (final rule in incoming) {
      if (validateRule(
            name: rule.name,
            pattern: rule.pattern,
            isRegex: rule.isRegex,
          ) !=
          null) {
        continue;
      }
      final idx = _rules.indexWhere((r) => r.id == rule.id);
      if (idx >= 0) {
        _rules[idx] = rule;
      } else if (_rules.length < maxRuleCount) {
        _rules.add(rule);
      }
      count++;
    }
    if (count > 0) {
      await _save();
    }
    return count;
  }

  List<TextReplaceRule> activeRulesFor({
    String? bookId,
    required bool forTts,
  }) {
    if (_rules.isEmpty) return const [];
    return _rules
        .where(
          (r) =>
              r.enabled &&
              (forTts ? r.applyToTts : r.applyToReader) &&
              r.matchesScope(bookId),
        )
        .toList(growable: false);
  }

  bool hasActiveReaderRules(String? bookId) =>
      _rules.any((r) => r.enabled && r.applyToReader && r.matchesScope(bookId));

  /// 对单段正文执行阅读展示净化，并生成原文索引到展示索引的精确映射表
  MappedTextResult applyForDisplay(String raw, {String? bookId}) {
    final active = activeRulesFor(bookId: bookId, forTts: false);
    if (raw.isEmpty || active.isEmpty) {
      return MappedTextResult(
        text: raw,
        rawToDisplay: const [],
        modified: false,
      );
    }
    return applyRulesWithMapping(raw, active);
  }

  /// 对送入 TTS / 沉浸式语音合成的文本执行净化清洗
  String applyForTts(String raw, {String? bookId}) {
    final active = activeRulesFor(bookId: bookId, forTts: true);
    if (raw.isEmpty || active.isEmpty) return raw;
    return applyRulesPlain(raw, active);
  }

  /// 纯文本顺序应用规则（常用于 TTS 与沙盒预览）
  static String applyRulesPlain(String raw, List<TextReplaceRule> rules) {
    var current = raw;
    for (final rule in rules) {
      if (!rule.enabled || rule.pattern.isEmpty) continue;
      if (rule.isRegex) {
        try {
          final reg = RegExp(rule.pattern, multiLine: true);
          current = current.replaceAllMapped(
            reg,
            (m) => _expandRegexReplacement(rule.replacement, m),
          );
        } catch (_) {
          // 单个损坏正则跳过，绝不影响正常阅读或听书
        }
      } else {
        current = current.replaceAll(rule.pattern, rule.replacement);
      }
    }
    return current;
  }

  /// 逐规则执行文本替换并维护复合映射表，使任意原文偏移可投影至最终展示偏移
  static MappedTextResult applyRulesWithMapping(
    String raw,
    List<TextReplaceRule> rules,
  ) {
    var current = raw;
    var map = List<int>.generate(raw.length + 1, (i) => i);
    var modified = false;

    for (final rule in rules) {
      if (!rule.enabled || rule.pattern.isEmpty || current.isEmpty) continue;
      final Iterable<Match> matches;
      if (rule.isRegex) {
        try {
          matches = RegExp(rule.pattern, multiLine: true).allMatches(current);
        } catch (_) {
          continue;
        }
      } else {
        matches = rule.pattern.allMatches(current);
      }
      final matchList = matches.toList();
      if (matchList.isEmpty) continue;

      final sb = StringBuffer();
      final stepMap = List<int>.filled(current.length + 1, 0);
      var cursor = 0;
      var outPos = 0;

      for (final m in matchList) {
        if (m.start < cursor) continue;
        // 拷贝未匹配前缀（1:1 精确映射）
        if (m.start > cursor) {
          final prefix = current.substring(cursor, m.start);
          sb.write(prefix);
          for (var i = cursor; i < m.start; i++) {
            stepMap[i] = outPos + (i - cursor);
          }
          outPos += m.start - cursor;
        }
        final rep = rule.isRegex
            ? _expandRegexReplacement(rule.replacement, m)
            : rule.replacement;
        sb.write(rep);
        final matchLen = m.end - m.start;
        for (var i = m.start; i < m.end; i++) {
          final ratio = matchLen > 0 ? (i - m.start) / matchLen : 0.0;
          stepMap[i] = outPos + (ratio * rep.length).floor();
        }
        outPos += rep.length;
        cursor = m.end;
      }

      if (cursor < current.length) {
        sb.write(current.substring(cursor));
        for (var i = cursor; i < current.length; i++) {
          stepMap[i] = outPos + (i - cursor);
        }
        outPos += current.length - cursor;
      }
      stepMap[current.length] = outPos;

      final nextText = sb.toString();
      if (nextText != current) {
        modified = true;
        // 复合映射：raw -> current -> nextText
        for (var i = 0; i < map.length; i++) {
          final prevIdx = map[i].clamp(0, stepMap.length - 1);
          map[i] = stepMap[prevIdx];
        }
        current = nextText;
      }
    }

    return MappedTextResult(
      text: current,
      rawToDisplay: map,
      modified: modified,
    );
  }

  static String _expandRegexReplacement(String template, Match m) {
    if (!template.contains(r'$')) return template;
    return template.replaceAllMapped(RegExp(r'\$(\d+)'), (ref) {
      final groupIdx = int.tryParse(ref.group(1) ?? '');
      if (groupIdx == null || groupIdx < 0 || groupIdx > m.groupCount) {
        return ref.group(0) ?? '';
      }
      return m.group(groupIdx) ?? '';
    });
  }

  Future<void> _save() {
    _revision++;
    final payload = encodeRules(_rules);
    _writes = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(preferencesKey, payload);
    });
    notifyListeners();
    return _writes;
  }
}
