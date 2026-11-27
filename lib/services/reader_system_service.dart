import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme_service.dart';
import 'reader_platform.dart';
import 'reader_scroll_input.dart';

/// 蓝牙耳机 / 车载媒体控制「上一曲 / 下一曲」按键行为映射
enum MediaButtonBehavior {
  /// 切换上一段 / 下一段（默认）
  segment,

  /// 当前音频快退 / 快进 15 秒
  seek15s,

  /// 切换上一章 / 下一章
  chapter,
}

extension MediaButtonBehaviorX on MediaButtonBehavior {
  String get storageValue {
    switch (this) {
      case MediaButtonBehavior.segment:
        return 'segment';
      case MediaButtonBehavior.seek15s:
        return 'seek15s';
      case MediaButtonBehavior.chapter:
        return 'chapter';
    }
  }

  String get label {
    switch (this) {
      case MediaButtonBehavior.segment:
        return '切换上/下一句';
      case MediaButtonBehavior.seek15s:
        return '快进/快退 15 秒';
      case MediaButtonBehavior.chapter:
        return '切换上/下一章';
    }
  }

  static MediaButtonBehavior parse(String? raw) {
    switch (raw) {
      case 'seek15s':
        return MediaButtonBehavior.seek15s;
      case 'chapter':
        return MediaButtonBehavior.chapter;
      default:
        return MediaButtonBehavior.segment;
    }
  }
}

/// 阅读器系统级辅助服务（屏幕常亮、电量、媒体键定制、保活引导、图片分享与桌面小组件）
class ReaderSystemService {
  static const MethodChannel _channel = ReaderPlatform.channel;
  static const String _mediaButtonPrefKey = 'android_media_button_behavior_v1';

  static final ValueNotifier<MediaButtonBehavior> mediaButtonBehaviorNotifier =
      ValueNotifier<MediaButtonBehavior>(MediaButtonBehavior.segment);
  static bool _mediaButtonLoaded = false;

  static MediaButtonBehavior get mediaButtonBehavior =>
      mediaButtonBehaviorNotifier.value;

  static Future<MediaButtonBehavior> loadMediaButtonBehavior() async {
    if (_mediaButtonLoaded) return mediaButtonBehaviorNotifier.value;
    try {
      final prefs = await SharedPreferences.getInstance();
      final parsed = MediaButtonBehaviorX.parse(
        prefs.getString(_mediaButtonPrefKey),
      );
      mediaButtonBehaviorNotifier.value = parsed;
      _mediaButtonLoaded = true;
    } catch (_) {}
    return mediaButtonBehaviorNotifier.value;
  }

  static Future<void> setMediaButtonBehavior(
    MediaButtonBehavior behavior,
  ) async {
    mediaButtonBehaviorNotifier.value = behavior;
    _mediaButtonLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_mediaButtonPrefKey, behavior.storageValue);
    } catch (_) {}
  }

  static void Function(String direction)? _volumeKeyCallback;
  static Object? _volumeOwner;
  static void Function(String method, dynamic args)? _ttsCallback;
  static void Function(String method)? _mediaCallback;
  static final Set<void Function(String method, dynamic args)>
  _extraTtsListeners = {};
  static final Set<void Function(String method)> _extraMediaListeners = {};
  static bool _handlerInitialized = false;
  static Object? _brightnessOwner;
  static Object? _screenOwner;
  static Future<bool> Function()? _quitHandler;
  static Future<void> Function()? _windowHiddenHandler;
  static bool Function(String)? _desktopCommandHandler;
  static Object? _externalImportOwner;
  static Future<void> Function()? _externalImportsAvailable;
  static Object? _shortcutOwner;
  static void Function(String action, String? bookId)? _shortcutHandler;
  static final Map<Object, Future<void> Function()> _saveParticipants = {};

  static void registerQuitHandler(Future<bool> Function() handler) {
    _quitHandler = handler;
    _ensureGlobalHandler();
  }

  static void registerWindowHiddenHandler(Future<void> Function() handler) {
    _windowHiddenHandler = handler;
    _ensureGlobalHandler();
  }

  static void registerDesktopCommandHandler(bool Function(String) handler) {
    _desktopCommandHandler = handler;
    _ensureGlobalHandler();
  }

  static void registerExternalImportsListener(
    Object owner,
    Future<void> Function()? handler,
  ) {
    if (handler == null && !identical(owner, _externalImportOwner)) return;
    _externalImportOwner = handler == null ? null : owner;
    _externalImportsAvailable = handler;
    _ensureGlobalHandler();
  }

  /// 注册 Android 桌面小组件与图标长按快捷方式回调
  static void registerShortcutListener(
    Object owner,
    void Function(String action, String? bookId)? handler,
  ) {
    if (handler == null && !identical(owner, _shortcutOwner)) return;
    _shortcutOwner = handler == null ? null : owner;
    _shortcutHandler = handler;
    _ensureGlobalHandler();
  }

  /// 提取冷启动阶段挂起的快捷方式或小组件指令
  static Future<List<({String action, String? bookId})>>
  takePendingShortcuts() async {
    if (!ReaderPlatform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'takePendingShortcuts',
      );
      if (raw == null || raw.isEmpty) return const [];
      final list = <({String action, String? bookId})>[];
      for (final item in raw) {
        if (item is Map) {
          final act = item['action']?.toString() ?? '';
          if (act.isNotEmpty) {
            final bid = item['bookId']?.toString();
            list.add((action: act, bookId: bid?.isEmpty == true ? null : bid));
          }
        }
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  static void registerSaveParticipant(
    Object owner,
    Future<void> Function()? callback,
  ) {
    if (callback == null) {
      _saveParticipants.remove(owner);
    } else {
      _saveParticipants[owner] = callback;
    }
  }

  static Future<void> flushParticipants() async {
    for (final callback in _saveParticipants.values.toList()) {
      await callback();
    }
  }

  static Future<void> setWindowBrightness(Object owner, double? value) async {
    _brightnessOwner = owner;
    if (!ReaderPlatform.capabilities.windowBrightness) return;
    try {
      await _channel.invokeMethod('setReaderBrightness', {
        'value': value == null ? -1.0 : value.clamp(.05, 1.0),
      });
    } catch (_) {
      // Unsupported platforms never change global brightness as a fallback.
    }
  }

  static Future<void> restoreWindowBrightness(Object owner) async {
    if (!identical(_brightnessOwner, owner)) return;
    _brightnessOwner = null;
    // 退出阅读页后根据当前外围亮暗主题恢复系统状态栏文字与图标色
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final resolvedMode = AppThemeService().resolveThemeMode(
      platformBrightness: platformBrightness,
    );
    final isDark = resolvedMode == ThemeMode.dark ||
        (resolvedMode == ThemeMode.system &&
            platformBrightness == Brightness.dark);
    SystemChrome.setSystemUIOverlayStyle(
      isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    );
    if (!ReaderPlatform.capabilities.windowBrightness) return;
    try {
      await _channel.invokeMethod('restoreReaderBrightness');
    } catch (_) {}
  }

  /// A hint for prefetch policy, never proof that a request will succeed.
  static Future<String> getNetworkType() async {
    if (!ReaderPlatform.capabilities.networkType) return 'unknown';
    try {
      return await _channel.invokeMethod<String>('getNetworkType') ?? 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  /// 统一初始化单一消息处理总线，避免多个服务 setMethodCallHandler 互相覆盖
  static void _ensureGlobalHandler() {
    if (_handlerInitialized) return;
    _handlerInitialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAppQuitRequested') {
        return await _quitHandler?.call() ?? false;
      } else if (call.method == 'onReaderScrollInput') {
        ReaderScrollInput.record(call.arguments);
      } else if (call.method == 'onDesktopCommand') {
        return _desktopCommandHandler?.call(call.arguments?.toString() ?? '') ??
            false;
      } else if (call.method == 'onExternalImportsAvailable') {
        await _externalImportsAvailable?.call();
        return true;
      } else if (call.method == 'onShortcutAction') {
        if (call.arguments is Map) {
          final map = Map<String, dynamic>.from(call.arguments as Map);
          final action = map['action']?.toString() ?? '';
          final bookId = map['bookId']?.toString();
          if (action.isNotEmpty) {
            _shortcutHandler?.call(
              action,
              bookId?.isEmpty == true ? null : bookId,
            );
          }
        }
        return true;
      } else if (call.method == 'onWindowHidden') {
        try {
          await flushParticipants();
          await _windowHiddenHandler?.call();
        } catch (_) {
          // Durable write errors are reported by the reader/quit coordinator.
        }
      } else if (call.method == 'onVolumeScroll') {
        final dir = call.arguments?.toString() ?? 'down';
        _volumeKeyCallback?.call(dir);
      } else if (call.method.startsWith('onTts') ||
          call.method.startsWith('onAudio')) {
        _ttsCallback?.call(call.method, call.arguments);
        for (final listener in _extraTtsListeners.toList()) {
          listener(call.method, call.arguments);
        }
      } else if (call.method.startsWith('onMedia')) {
        _mediaCallback?.call(call.method);
        for (final listener in _extraMediaListeners.toList()) {
          listener(call.method);
        }
      }
    });
  }

  /// 注册音量键物理滚动回调
  static void registerVolumeKeyListener(
    void Function(String direction)? callback, {
    Object? owner,
  }) {
    _ensureGlobalHandler();
    if (callback == null && owner != null && !identical(owner, _volumeOwner)) {
      return;
    }
    _volumeKeyCallback = callback;
    _volumeOwner = callback == null ? null : owner;
  }

  /// 注册全局 TTS/音频完成事件回调
  static void registerTtsListener(
    void Function(String method, dynamic args)? callback,
  ) {
    _ensureGlobalHandler();
    _ttsCallback = callback;
  }

  static void registerMediaListener(void Function(String method)? callback) {
    _ensureGlobalHandler();
    _mediaCallback = callback;
  }

  /// 添加额外的音频状态监听者（供沉浸式听书等独立播放所有者复用原生媒体通道）
  static void addTtsListener(
    void Function(String method, dynamic args) callback,
  ) {
    _ensureGlobalHandler();
    _extraTtsListeners.add(callback);
  }

  /// 移除额外的音频状态监听者
  static void removeTtsListener(
    void Function(String method, dynamic args) callback,
  ) {
    _extraTtsListeners.remove(callback);
  }

  /// 添加额外的锁屏媒体按钮监听者
  static void addMediaListener(void Function(String method) callback) {
    _ensureGlobalHandler();
    _extraMediaListeners.add(callback);
  }

  /// 移除额外的锁屏媒体按钮监听者
  static void removeMediaListener(void Function(String method) callback) {
    _extraMediaListeners.remove(callback);
  }

  /// 开启或关闭音量键按键拦截
  static Future<void> setVolumeKeyScrollEnabled(
    bool enabled, {
    Object? owner,
  }) async {
    if (owner != null && !identical(owner, _volumeOwner)) return;
    if (!ReaderPlatform.capabilities.volumeKeys) return;
    try {
      await _channel.invokeMethod('setVolumeKeyScrollEnabled', {
        'enabled': enabled,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('setVolumeKeyScrollEnabled error: $e');
    }
  }

  /// 设置阅读时屏幕常亮
  static Future<void> setKeepScreenOn(bool enabled, {Object? owner}) async {
    if (enabled) {
      _screenOwner = owner;
    } else {
      if (owner != null && !identical(owner, _screenOwner)) return;
      _screenOwner = null;
    }
    if (!ReaderPlatform.capabilities.keepAwake) return;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'enabled': enabled});
    } catch (e) {
      if (kDebugMode) debugPrint('setKeepScreenOn error: $e');
    }
  }

  /// 获取系统电量百分比 (0~100，异常返回 -1)
  static Future<int> getBatteryLevel() async {
    if (!ReaderPlatform.capabilities.battery) return -1;
    try {
      final level = await _channel.invokeMethod<int>('getBatteryLevel');
      return level ?? -1;
    } catch (e) {
      return -1;
    }
  }

  /// 更新系统锁屏媒体中心播控信息、封面大图与进度
  static Future<void> updateMediaPlaybackState({
    required String title,
    required String subtitle,
    required bool isPlaying,
    bool isActive = true,
    String? coverPath,
    int? durationMs,
    int? positionMs,
  }) async {
    if (!ReaderPlatform.capabilities.mediaPlayback) return;
    try {
      await _channel.invokeMethod('updateMediaPlaybackState', {
        'title': title,
        'subtitle': subtitle,
        'isPlaying': isPlaying,
        'isActive': isActive,
        if (coverPath != null) 'coverPath': coverPath,
        if (durationMs != null) 'durationMs': durationMs,
        if (positionMs != null) 'positionMs': positionMs,
      });
    } catch (_) {}
  }

  /// 控制当前播放中的原生音频按毫秒绝对跳转或相对快进/快退
  static Future<bool> seekAudio({int? positionMs, int? deltaMs}) async {
    if (!ReaderPlatform.capabilities.mediaPlayback) return false;
    try {
      final res = await _channel.invokeMethod('seekAudio', {
        if (positionMs != null) 'positionMs': positionMs,
        if (deltaMs != null) 'deltaMs': deltaMs,
      });
      if (res is Map) return res['ok'] == true;
      return res == true;
    } catch (_) {
      return false;
    }
  }

  /// 查询当前应用是否已加入 Android 电池优化白名单（后台防杀）
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!ReaderPlatform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 跳转系统电池优化设置页，引导用户放行后台听书保活
  static Future<bool> openBatteryOptimizationSettings() async {
    if (!ReaderPlatform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>(
        'openBatteryOptimizationSettings',
      );
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 调用 Android 原生系统分享面板分享本地图片文件（如金句海报卡片）
  static Future<bool> shareImageFile({
    required String filePath,
    String? text,
    String title = '分享金句卡片',
  }) async {
    if (!ReaderPlatform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('shareImageFile', {
        'filePath': filePath,
        if (text != null) 'text': text,
        'title': title,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 将最近在读信息同步刷新至 Android 桌面小组件
  static Future<void> updateHomeWidget({
    required String bookId,
    required String bookName,
    required String chapterTitle,
    String progressText = '',
  }) async {
    if (!ReaderPlatform.isAndroid) return;
    try {
      await _channel.invokeMethod('updateHomeWidget', {
        'bookId': bookId,
        'bookName': bookName,
        'chapterTitle': chapterTitle,
        'progressText': progressText,
      });
    } catch (_) {}
  }
}
