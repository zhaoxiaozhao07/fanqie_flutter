import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Runtime capabilities, separate from portable reading preferences.
class ReaderCapabilities {
  final bool tts;
  final bool nativeSpeech, mediaPlayback;
  final bool secureStorage;
  final bool windowBrightness;
  final bool volumeKeys;
  final bool haptics;
  final bool battery;
  final bool keepAwake;
  final bool networkType;
  final bool textDecoder;
  final bool fileExport;
  final bool fileImport;

  const ReaderCapabilities({
    this.tts = false,
    this.nativeSpeech = false,
    this.mediaPlayback = false,
    this.secureStorage = false,
    this.windowBrightness = false,
    this.volumeKeys = false,
    this.haptics = false,
    this.battery = false,
    this.keepAwake = false,
    this.networkType = false,
    this.textDecoder = false,
    this.fileExport = false,
    this.fileImport = false,
  });

  factory ReaderCapabilities.forPlatform(TargetPlatform platform) {
    final android = platform == TargetPlatform.android;
    final desktop =
        platform == TargetPlatform.macOS || platform == TargetPlatform.windows;
    return ReaderCapabilities(
      tts: android,
      nativeSpeech: android,
      mediaPlayback: android,
      secureStorage: android,
      windowBrightness: android,
      volumeKeys: android,
      haptics: android,
      battery: android || desktop,
      keepAwake: android || desktop,
      networkType: android || desktop,
      textDecoder: android || desktop,
      fileExport: android || desktop,
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
      nativeSpeech: flag('nativeSpeech', fallback.nativeSpeech),
      mediaPlayback: flag('mediaPlayback', fallback.mediaPlayback),
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
      fileImport: flag('fileImport', false),
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

  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Desktop platforms share the native bridge contract (quit handshake,
  /// transcoding, save panels, window integration) and desktop UX.
  static bool get isDesktop => isMacOS || isWindows;

  static bool get requiresNativeBridge => isMacOS || isWindows;

  static ReaderCapabilities get capabilities =>
      _initializedPlatform == defaultTargetPlatform && _capabilities != null
      ? _capabilities!
      : ReaderCapabilities.forPlatform(defaultTargetPlatform);

  static Future<void> initialize() async {
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && !requiresNativeBridge) return;
    try {
      final values = await channel.invokeMapMethod<String, dynamic>(
        'getReaderCapabilities',
      );
      if (values == null) throw StateError('平台能力信息缺失');
      _capabilities = ReaderCapabilities.fromMap(values, platform);
      _initializedPlatform = platform;
    } catch (_) {
      // Android keeps its existing support even on older native bridges.
      if (requiresNativeBridge) {
        throw StateError(
          isMacOS
              ? 'macOS 原生模块未能初始化，请重新启动或重新构建客户端'
              : 'Windows 原生模块未能初始化，请重新启动或重新构建客户端',
        );
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
