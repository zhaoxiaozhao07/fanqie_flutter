import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/desktop_shortcut_preferences.dart';

class ReaderShortcutsDialog extends StatefulWidget {
  const ReaderShortcutsDialog({super.key});
  @override
  State<ReaderShortcutsDialog> createState() => _ReaderShortcutsDialogState();
}

class _ReaderShortcutsDialogState extends State<ReaderShortcutsDialog> {
  final _service = DesktopShortcutPreferences();
  String? _recording, _error;
  bool _busy = false;
  Future<void> _set(String command, ReaderShortcut? shortcut) async {
    setState(() => _busy = true);
    try {
      await _service.set(command, shortcut);
      if (mounted) {
        setState(() {
          _recording = null;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : '快捷键未保存',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (_recording == null || _busy || event is! KeyDownEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _recording = null);
      } else {
        final shortcut = ReaderShortcut.fromEvent(event);
        if (![
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.metaRight,
          LogicalKeyboardKey.shiftLeft,
          LogicalKeyboardKey.shiftRight,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlRight,
          LogicalKeyboardKey.altLeft,
          LogicalKeyboardKey.altRight,
        ].contains(event.logicalKey)) {
          _set(_recording!, shortcut);
        }
      }
      return KeyEventResult.handled;
    },
    child: AlertDialog(
      title: const Text('自定义阅读快捷键'),
      content: SizedBox(
        width: 480,
        height: 430,
        child: AnimatedBuilder(
          animation: _service,
          builder: (_, _) => ListView(
            children: [
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Text('点击修改后按组合键；Esc 取消录制。输入框和选区保持优先。'),
              for (final entry in DesktopShortcutPreferences.commands.entries)
                ListTile(
                  title: Text(entry.value),
                  subtitle: _recording == entry.key
                      ? const Text('请按快捷键…')
                      : null,
                  trailing: Wrap(
                    children: [
                      TextButton(
                        key: ValueKey('shortcut-${entry.key}'),
                        onPressed: _busy
                            ? null
                            : () => setState(() => _recording = entry.key),
                        child: Text(_service.bindings[entry.key]!.label),
                      ),
                      IconButton(
                        tooltip: '恢复默认',
                        onPressed: _busy ? null : () => _set(entry.key, null),
                        icon: const Icon(Icons.restart_alt, size: 18),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
