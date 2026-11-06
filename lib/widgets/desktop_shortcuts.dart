import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/desktop_commands.dart';
import '../services/reader_platform.dart';
import '../services/reader_system_service.dart';

/// Native menus handle these on macOS; the Flutter bindings also support
/// accessibility dispatch and focused desktop/widget tests. Windows registers
/// the matching Ctrl shortcuts (the plan's Ctrl+O / Ctrl+F / Ctrl+, / Ctrl+B).
class DesktopShortcuts extends StatelessWidget {
  final Widget child;
  const DesktopShortcuts({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!ReaderPlatform.isDesktop) return child;
    final useControl = ReaderPlatform.isWindows;
    return CallbackShortcuts(
      bindings: {
        // F11 toggles native full-screen from any page without modifiers; text
        // fields never consume it.
        const SingleActivator(LogicalKeyboardKey.f11):
            () => ReaderSystemService.toggleFullScreen(),
        SingleActivator(
          LogicalKeyboardKey.keyO,
          control: useControl,
          meta: !useControl,
        ): () => DesktopCommands.dispatch('import'),
        SingleActivator(
          LogicalKeyboardKey.keyF,
          control: useControl,
          meta: !useControl,
        ): () => DesktopCommands.dispatch('find'),
        SingleActivator(
          LogicalKeyboardKey.comma,
          control: useControl,
          meta: !useControl,
        ): () => DesktopCommands.dispatch('settings'),
        SingleActivator(
          // macOS keeps the native menu's Cmd+D; the Windows plan uses Ctrl+B.
          ReaderPlatform.isWindows
              ? LogicalKeyboardKey.keyB
              : LogicalKeyboardKey.keyD,
          control: useControl,
          meta: !useControl,
        ): () => DesktopCommands.dispatch('bookmark'),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
