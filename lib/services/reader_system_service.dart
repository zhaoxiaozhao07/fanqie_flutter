import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'reader_platform.dart';

/// 阅读器系统级辅助服务（屏幕常亮、电量获取）
class ReaderSystemService {
  static const MethodChannel _channel = ReaderPlatform.channel;

  static void Function(String direction)? _volumeKeyCallback;
  static Object? _volumeOwner;
  static void Function(String method, dynamic args)? _ttsCallback;
  static void Function(String method)? _mediaCallback;
  static bool _handlerInitialized = false;
  static Object? _brightnessOwner;
  static Object? _screenOwner;
  static Future<bool> Function()? _quitHandler;
  static bool Function(String)? _desktopCommandHandler;
  static final Map<Object, Future<void> Function()> _saveParticipants = {};

  static void registerQuitHandler(Future<bool> Function() handler) {
    _quitHandler = handler;
    _ensureGlobalHandler();
  }

  static void registerDesktopCommandHandler(bool Function(String) handler) {
    _desktopCommandHandler = handler;
    _ensureGlobalHandler();
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
    // Non-reader routes currently use the application's light theme.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
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
      } else if (call.method == 'onDesktopCommand') {
        return _desktopCommandHandler?.call(call.arguments?.toString() ?? '') ??
            false;
      } else if (call.method == 'onWindowHidden') {
        try {
          await flushParticipants();
        } catch (_) {
          // Durable write errors are reported by the reader/quit coordinator.
        }
      } else if (call.method == 'onVolumeScroll') {
        final dir = call.arguments?.toString() ?? 'down';
        _volumeKeyCallback?.call(dir);
      } else if (call.method.startsWith('onTts') ||
          call.method.startsWith('onAudio')) {
        _ttsCallback?.call(call.method, call.arguments);
      } else if (call.method.startsWith('onMedia')) {
        _mediaCallback?.call(call.method);
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

  /// 更新系统锁屏媒体中心播控信息与状态通知
  static Future<void> updateMediaPlaybackState({
    required String title,
    required String subtitle,
    required bool isPlaying,
  }) async {
    if (!ReaderPlatform.capabilities.tts) return;
    try {
      await _channel.invokeMethod('updateMediaPlaybackState', {
        'title': title,
        'subtitle': subtitle,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }
}
