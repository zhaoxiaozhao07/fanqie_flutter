import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_platform.dart';

class ReaderShortcut {
  final int key;
  final bool meta, control, alt, shift;
  const ReaderShortcut(
    this.key, {
    this.meta = false,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });
  SingleActivator get activator => SingleActivator(
    LogicalKeyboardKey(key),
    meta: meta,
    control: control,
    alt: alt,
    shift: shift,
    includeRepeats: false,
  );
  String get label =>
      '${control ? '⌃' : ''}${alt ? '⌥' : ''}'
      '${shift ? '⇧' : ''}${meta ? '⌘' : ''}${LogicalKeyboardKey(key).keyLabel}';
  String get identity => '$key/$meta/$control/$alt/$shift';
  Map<String, Object> toJson() => {
    'key': key,
    'meta': meta,
    'control': control,
    'alt': alt,
    'shift': shift,
  };
  static ReaderShortcut fromEvent(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    return ReaderShortcut(
      event.logicalKey.keyId,
      meta: keys.isMetaPressed,
      control: keys.isControlPressed,
      alt: keys.isAltPressed,
      shift: keys.isShiftPressed,
    );
  }

  factory ReaderShortcut.fromJson(Map json) => ReaderShortcut(
    json['key'] as int,
    meta: json['meta'] == true,
    control: json['control'] == true,
    alt: json['alt'] == true,
    shift: json['shift'] == true,
  );
}

class DesktopShortcutPreferences extends ChangeNotifier {
  static const key = 'reader_shortcuts_v1';
  static final _instance = DesktopShortcutPreferences._();
  factory DesktopShortcutPreferences() => _instance;
  DesktopShortcutPreferences._();
  static const commands = {
    'find': '搜索',
    'directory': '目录',
    'jump': '跳转章节',
    'bookmark': '书签',
    'back': '阅读后退',
    'forward': '阅读前进',
    'findNext': '下一处匹配',
    'findPrevious': '上一处匹配',
    'immersion': '沉浸阅读',
    'notes': '笔记工作台',
  };
  static final defaults = <String, ReaderShortcut>{
    'find': ReaderShortcut(LogicalKeyboardKey.keyF.keyId, meta: true),
    'directory': ReaderShortcut(
      LogicalKeyboardKey.keyD.keyId,
      meta: true,
      shift: true,
    ),
    'jump': ReaderShortcut(LogicalKeyboardKey.keyJ.keyId, meta: true),
    'bookmark': ReaderShortcut(LogicalKeyboardKey.keyD.keyId, meta: true),
    'back': ReaderShortcut(LogicalKeyboardKey.bracketLeft.keyId, meta: true),
    'forward': ReaderShortcut(
      LogicalKeyboardKey.bracketRight.keyId,
      meta: true,
    ),
    'findNext': ReaderShortcut(LogicalKeyboardKey.keyG.keyId, meta: true),
    'findPrevious': ReaderShortcut(
      LogicalKeyboardKey.keyG.keyId,
      meta: true,
      shift: true,
    ),
    'immersion': ReaderShortcut(LogicalKeyboardKey.f11.keyId),
    'notes': ReaderShortcut(
      LogicalKeyboardKey.keyN.keyId,
      meta: true,
      shift: true,
    ),
  };
  Map<String, ReaderShortcut> _overrides = {};
  Future<void>? _writes;
  Map<String, ReaderShortcut> get bindings => {...defaults, ..._overrides};
  bool overridden(String command) => _overrides.containsKey(command);

  Future<void> load() async {
    await _writes?.catchError((_) {});
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(prefs.getString(key) ?? '{}');
      if (raw is! Map) return;
      final result = <String, ReaderShortcut>{};
      for (final entry in raw.entries) {
        if (!commands.containsKey(entry.key) || entry.value is! Map) continue;
        final shortcut = ReaderShortcut.fromJson(entry.value);
        validate(shortcut);
        result[entry.key as String] = shortcut;
      }
      final effective = {...defaults, ...result};
      if (effective.values.map((value) => value.identity).toSet().length !=
          effective.length) {
        return;
      }
      _overrides = result;
      notifyListeners();
      await _updateNativeMenu();
    } catch (_) {
      _overrides = {};
      notifyListeners(); // Reads never delete damaged preferences.
    }
  }

  static void validate(ReaderShortcut shortcut) {
    final logical = LogicalKeyboardKey(shortcut.key);
    if (logical.keyLabel.isEmpty ||
        [
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.metaRight,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.f1,
          LogicalKeyboardKey.f3,
        ].contains(logical)) {
      throw const FormatException('请选择带修饰键的字符键或功能键');
    }
    final function =
        logical.keyLabel.startsWith('F') &&
        int.tryParse(logical.keyLabel.substring(1)) != null;
    if (!function && !shortcut.meta && !shortcut.control && !shortcut.alt) {
      throw const FormatException('字符快捷键必须带 ⌘、⌃ 或 ⌥，避免影响正文输入');
    }
    if ((shortcut.meta || shortcut.control) &&
        !shortcut.alt &&
        [
          'A',
          'C',
          'V',
          'X',
          'Z',
          'Q',
          'W',
          'O',
          ',',
          '=',
          '+',
          '-',
          '0',
        ].contains(logical.keyLabel.toUpperCase())) {
      throw const FormatException('该组合由复制、撤销、退出或系统操作使用');
    }
  }

  Future<void> set(String command, ReaderShortcut? shortcut) async {
    if (!commands.containsKey(command)) throw ArgumentError('未知快捷键');
    if (shortcut != null) validate(shortcut);
    late final Future<void> write;
    write = (_writes ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          final next = Map<String, ReaderShortcut>.from(_overrides);
          if (shortcut == null ||
              shortcut.identity == defaults[command]!.identity) {
            next.remove(command);
          } else {
            next[command] = shortcut;
          }
          final effective = {...defaults, ...next};
          if (effective.values.map((value) => value.identity).toSet().length !=
              effective.length) {
            throw const FormatException('快捷键已被另一项操作使用');
          }
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(
            key,
            jsonEncode({
              for (final entry in next.entries) entry.key: entry.value.toJson(),
            }),
          )) {
            throw StateError('快捷键保存失败');
          }
          _overrides = next;
          notifyListeners();
          await _updateNativeMenu();
        })
        .whenComplete(() {
          if (identical(_writes, write)) _writes = null;
        });
    _writes = write;
    return write;
  }

  String? match(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    for (final entry in bindings.entries) {
      if (entry.value.activator.accepts(event, HardwareKeyboard.instance)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _updateNativeMenu() async {
    if (!ReaderPlatform.isMacOS) return;
    try {
      await ReaderPlatform.invoke('setReaderShortcuts', {
        'bindings': {
          for (final entry in bindings.entries)
            entry.key: {
              ...entry.value.toJson(),
              'label': LogicalKeyboardKey(
                entry.value.key,
              ).keyLabel.toLowerCase(),
            },
        },
      });
    } catch (_) {
      // Flutter bindings remain available if a native menu is not installed.
    }
  }
}
