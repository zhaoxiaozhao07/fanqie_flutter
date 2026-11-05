import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Runtime capabilities, separate from portable reading preferences.
class ReaderCapabilities {
  final bool tts;
  final bool secureStorage;
  final bool windowBrightness;
  final bool volumeKeys;
  final bool haptics;
  final bool battery;
  final bool keepAwake;
  final bool networkType;
  final bool textDecoder;
  final bool fileExport;

  const ReaderCapabilities({
    this.tts = false,
    this.secureStorage = false,
    this.windowBrightness = false,
    this.volumeKeys = false,
    this.haptics = false,
    this.battery = false,
    this.keepAwake = false,
    this.networkType = false,
    this.textDecoder = false,
    this.fileExport = false,
  });

  factory ReaderCapabilities.forPlatform(TargetPlatform platform) {
    final android = platform == TargetPlatform.android;
    final macos = platform == TargetPlatform.macOS;
    return ReaderCapabilities(
      tts: android,
      secureStorage: android,
      windowBrightness: android,
      volumeKeys: android,
      haptics: android,
      battery: android,
      keepAwake: android || macos,
      networkType: android || macos,
      textDecoder: android || macos,
      fileExport: android || macos,
    );
  }

  factory ReaderCapabilities.fromMap(
    Map<String, dynamic> values,
    TargetPlatform platform,
  ) {
    final fallback = ReaderCapabilities.forPlatform(platform);
    bool flag(String key, bool defaultValue) =>
        values[key] is bool ? values[key] as bool : defaultValue;
    return ReaderCapabilities(
      tts: flag('tts', fallback.tts),
      secureStorage: flag('secureStorage', fallback.secureStorage),
      windowBrightness: flag(
        'windowBrightnessControl',
        fallback.windowBrightness,
      ),
      volumeKeys: flag('volumeKeys', fallback.volumeKeys),
      haptics: flag('haptics', fallback.haptics),
      battery: flag('battery', fallback.battery),
      keepAwake: flag('keepAwake', fallback.keepAwake),
      networkType: flag('networkType', fallback.networkType),
      textDecoder: flag('textDecoder', fallback.textDecoder),
      fileExport: flag('fileExport', fallback.fileExport),
    );
  }
}

/// Keep the Android wire contract, including its shared event bus, unchanged.
class ReaderPlatform {
  static const channel = MethodChannel('com.fanqie.fanqie_flutter/download');
  static ReaderCapabilities? _capabilities;
  static TargetPlatform? _initializedPlatform;

  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static ReaderCapabilities get capabilities =>
      _initializedPlatform == defaultTargetPlatform && _capabilities != null
      ? _capabilities!
      : ReaderCapabilities.forPlatform(defaultTargetPlatform);

  static Future<void> initialize() async {
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && !isMacOS) return;
    try {
      final values = await channel.invokeMapMethod<String, dynamic>(
        'getReaderCapabilities',
      );
      if (values == null) throw StateError('平台能力信息缺失');
      _capabilities = ReaderCapabilities.fromMap(values, platform);
      _initializedPlatform = platform;
    } catch (_) {
      // Android keeps its existing support even on older native bridges.
      if (isMacOS) {
        throw StateError('macOS 原生模块未能初始化，请重新启动或重新构建客户端');
      }
    }
  }

  static Future<T?> invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) => channel.invokeMethod<T>(method, arguments);

  @visibleForTesting
  static void resetForTesting() {
    _capabilities = null;
    _initializedPlatform = null;
  }
}
