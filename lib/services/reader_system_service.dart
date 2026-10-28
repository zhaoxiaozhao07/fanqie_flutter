import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 阅读器系统级辅助服务（屏幕常亮、电量获取）
class ReaderSystemService {
  static const MethodChannel _channel = MethodChannel('com.fanqie.fanqie_flutter/download');

  static void Function(String direction)? _volumeKeyCallback;
  static void Function(String method, dynamic args)? _ttsCallback;
  static bool _handlerInitialized = false;

  /// 统一初始化单一消息处理总线，避免多个服务 setMethodCallHandler 互相覆盖
  static void _ensureGlobalHandler() {
    if (_handlerInitialized) return;
    _handlerInitialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVolumeScroll') {
        final dir = call.arguments?.toString() ?? 'down';
        _volumeKeyCallback?.call(dir);
      } else if (call.method.startsWith('onTts') || call.method.startsWith('onAudio')) {
        _ttsCallback?.call(call.method, call.arguments);
      }
    });
  }

  /// 注册音量键物理滚动回调
  static void registerVolumeKeyListener(void Function(String direction)? callback) {
    _ensureGlobalHandler();
    _volumeKeyCallback = callback;
  }

  /// 注册全局 TTS/音频完成事件回调
  static void registerTtsListener(void Function(String method, dynamic args)? callback) {
    _ensureGlobalHandler();
    _ttsCallback = callback;
  }

  /// 开启或关闭音量键按键拦截
  static Future<void> setVolumeKeyScrollEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setVolumeKeyScrollEnabled', {'enabled': enabled});
    } catch (e) {
      if (kDebugMode) debugPrint('setVolumeKeyScrollEnabled error: $e');
    }
  }

  /// 设置阅读时屏幕常亮
  static Future<void> setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'enabled': enabled});
    } catch (e) {
      if (kDebugMode) debugPrint('setKeepScreenOn error: $e');
    }
  }

  /// 获取系统电量百分比 (0~100，异常返回 -1)
  static Future<int> getBatteryLevel() async {
    if (!Platform.isAndroid) return -1;
    try {
      final level = await _channel.invokeMethod<int>('getBatteryLevel');
      return level ?? -1;
    } catch (e) {
      return -1;
    }
  }
}
