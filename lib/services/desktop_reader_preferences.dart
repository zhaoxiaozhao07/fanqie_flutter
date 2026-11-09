import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Workspace state is separate from book typography presets and overrides.
class DesktopReaderPreferences {
  static const key = 'desktop_reader_workspace_v1';
  static const defaultWidth = 304.0;
  static Future<void>? _writes;
  final bool directoryOpen;
  final double sidebarWidth;

  const DesktopReaderPreferences({
    this.directoryOpen = false,
    this.sidebarWidth = defaultWidth,
  });

  static double boundedWidth(double width) =>
      width.isFinite ? width.clamp(240.0, 480.0) : defaultWidth;

  static Future<DesktopReaderPreferences> load() async {
    await _writes?.catchError((_) {});
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(prefs.getString(key) ?? '{}');
      if (raw is! Map) return const DesktopReaderPreferences();
      return DesktopReaderPreferences(
        directoryOpen: raw['directoryOpen'] == true,
        sidebarWidth: boundedWidth(
          (raw['sidebarWidth'] as num?)?.toDouble() ?? defaultWidth,
        ),
      );
    } catch (_) {
      return const DesktopReaderPreferences();
    }
  }

  Future<void> save() {
    final raw = jsonEncode({
      'directoryOpen': directoryOpen,
      'sidebarWidth': boundedWidth(sidebarWidth),
    });
    late final Future<void> operation;
    operation = (_writes ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString(key, raw)) throw StateError('侧栏偏好保存失败');
        })
        .whenComplete(() {
          if (identical(_writes, operation)) _writes = null;
        });
    _writes = operation;
    return operation;
  }

  static Future<void> flush() async => await _writes;
}
