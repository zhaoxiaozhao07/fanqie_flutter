import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 阅读器系统级辅助服务（屏幕常亮、电量获取）
class ReaderSystemService {
  static const MethodChannel _channel = MethodChannel('com.fanqie.fanqie_flutter/download');

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
