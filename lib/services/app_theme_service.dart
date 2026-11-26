import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/reader_settings.dart';
import '../models/reader_theme.dart';
import 'reader_settings_repository.dart';

/// 全局外围界面外观模式偏好
enum AppThemePreference {
  system,
  light,
  dark,
  followReader,
}

/// 全局外围深色模式管理服务（支持跟随系统、手动浅/深色及跟随阅读器日夜配色）
class AppThemeService extends ChangeNotifier {
  static const String preferencesKey = 'app_theme_mode_v1';

  static final AppThemeService _instance = AppThemeService._();
  factory AppThemeService() => _instance;
  AppThemeService._();

  AppThemePreference _preference = AppThemePreference.system;
  ReaderSettings? _latestReaderSettings;
  bool _initialized = false;
  Timer? _scheduleTicker;

  AppThemePreference get preference => _preference;
  bool get initialized => _initialized;

  static String labelOf(AppThemePreference pref) {
    switch (pref) {
      case AppThemePreference.system:
        return '跟随系统';
      case AppThemePreference.light:
        return '始终浅色';
      case AppThemePreference.dark:
        return '始终深色';
      case AppThemePreference.followReader:
        return '跟随阅读日夜模式';
    }
  }

  /// 初始化并加载已保存的外围外观配置
  Future<void> initialize() async {
    if (_initialized) return;
    await reload();
    _initialized = true;
  }

  /// 从本地存储重新加载外观配置与全局阅读设置快照
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferencesKey);
    _preference = AppThemePreference.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => AppThemePreference.system,
    );
    try {
      _latestReaderSettings = (await ReaderSettingsRepository().load()).settings;
    } catch (_) {
      _latestReaderSettings ??= const ReaderSettings();
    }
    _syncScheduleTicker();
    notifyListeners();
  }

  /// 更新外围外观偏好并持久化
  Future<void> setPreference(AppThemePreference next) async {
    if (_preference == next && _initialized) return;
    _preference = next;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferencesKey, next.name);
    if (next == AppThemePreference.followReader && _latestReaderSettings == null) {
      try {
        _latestReaderSettings = (await ReaderSettingsRepository().load()).settings;
      } catch (_) {
        _latestReaderSettings = const ReaderSettings();
      }
    }
    _syncScheduleTicker();
    notifyListeners();
  }

  /// 同步阅读器最新设置（当外围外观选择“跟随阅读日夜模式”时实时联动）
  void syncReaderSettings(ReaderSettings settings) {
    _latestReaderSettings = settings;
    _syncScheduleTicker();
    if (_preference == AppThemePreference.followReader) {
      notifyListeners();
    }
  }

  /// 解析当前 MaterialApp 应使用的 ThemeMode
  ThemeMode resolveThemeMode({
    required Brightness platformBrightness,
    DateTime? now,
    ReaderSettings? readerSettingsOverride,
  }) {
    switch (_preference) {
      case AppThemePreference.system:
        return ThemeMode.system;
      case AppThemePreference.light:
        return ThemeMode.light;
      case AppThemePreference.dark:
        return ThemeMode.dark;
      case AppThemePreference.followReader:
        final settings =
            readerSettingsOverride ?? _latestReaderSettings ?? const ReaderSettings();
        final themeIdx = settings.effectiveTheme(
          systemDark: platformBrightness == Brightness.dark,
          now: now ?? DateTime.now(),
        );
        final preset = ReaderTheme.presets[themeIdx.clamp(0, ReaderTheme.presets.length - 1)];
        final customBg = settings.customBackground;
        final isDark = customBg != null
            ? ThemeData.estimateBrightnessForColor(Color(customBg)) == Brightness.dark
            : preset.systemBrightness == Brightness.dark;
        return isDark ? ThemeMode.dark : ThemeMode.light;
    }
  }

  void _syncScheduleTicker() {
    _scheduleTicker?.cancel();
    _scheduleTicker = null;
    if (_preference == AppThemePreference.followReader &&
        _latestReaderSettings?.themeMode == ReaderThemeMode.scheduled) {
      _scheduleTicker = Timer.periodic(const Duration(minutes: 1), (_) {
        notifyListeners();
      });
    }
  }
}
