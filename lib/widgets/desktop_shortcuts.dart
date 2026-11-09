import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/desktop_commands.dart';
import '../services/desktop_shortcut_preferences.dart';
import '../services/reader_platform.dart';
import 'desktop_reader_selection.dart';

/// Native menus and Flutter use the same effective bindings. Remapping removes
/// the old binding; editing/IME/selection always take priority over reading.
class DesktopShortcuts extends StatefulWidget {
  final Widget child;
  const DesktopShortcuts({super.key, required this.child});

  @override
  State<DesktopShortcuts> createState() => _DesktopShortcutsState();
}

class _DesktopShortcutsState extends State<DesktopShortcuts> {
  final _preferences = DesktopShortcutPreferences();
  static const _fixed = <SingleActivator, String>{
    SingleActivator(LogicalKeyboardKey.f3, includeRepeats: false): 'findNext',
    SingleActivator(LogicalKeyboardKey.f3, shift: true, includeRepeats: false):
        'findPrevious',
    SingleActivator(LogicalKeyboardKey.keyO, meta: true): 'import',
    SingleActivator(LogicalKeyboardKey.comma, meta: true): 'settings',
    SingleActivator(LogicalKeyboardKey.equal, meta: true): 'fontIncrease',
    SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true):
        'fontIncrease',
    SingleActivator(LogicalKeyboardKey.add, meta: true): 'fontIncrease',
    SingleActivator(LogicalKeyboardKey.minus, meta: true): 'fontDecrease',
    SingleActivator(LogicalKeyboardKey.digit0, meta: true): 'fontReset',
    SingleActivator(LogicalKeyboardKey.f1, includeRepeats: false): 'shortcuts',
  };

  @override
  void initState() {
    super.initState();
    if (ReaderPlatform.isMacOS) unawaited(_preferences.load());
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final focused = FocusManager.instance.primaryFocus?.context;
    final editable = focused?.widget is EditableText
        ? focused!.widget as EditableText
        : focused?.findAncestorWidgetOfExactType<EditableText>();
    if (editable != null &&
        editable.controller.value.composing.isValid &&
        !editable.controller.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    var command = _preferences.match(event);
    for (final entry in _fixed.entries) {
      if (command == null &&
          entry.key.accepts(event, HardwareKeyboard.instance)) {
        command = entry.value;
      }
    }
    if (command == null) return KeyEventResult.ignored;
    final selected =
        focused
            ?.findAncestorWidgetOfExactType<DesktopReaderSelection>()
            ?.controller
            .hasSelection ??
        false;
    if ((editable != null || selected) && command != 'find') {
      return KeyEventResult.ignored;
    }
    return DesktopCommands.dispatch(command)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => !ReaderPlatform.isMacOS
      ? widget.child
      : Focus(autofocus: true, onKeyEvent: _key, child: widget.child);
}
