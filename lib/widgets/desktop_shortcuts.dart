import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/desktop_commands.dart';
import '../services/reader_platform.dart';

/// Native menus handle these on macOS; the Flutter bindings also support
/// accessibility dispatch and focused desktop/widget tests.
class DesktopShortcuts extends StatelessWidget {
  final Widget child;
  const DesktopShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!ReaderPlatform.isMacOS) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            () => DesktopCommands.dispatch('import'),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            () => DesktopCommands.dispatch('find'),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            () => DesktopCommands.dispatch('settings'),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            () => DesktopCommands.dispatch('bookmark'),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
