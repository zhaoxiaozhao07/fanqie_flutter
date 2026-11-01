enum ReaderThemeMode { manual, system, scheduled }

/// Layout preferences are independent of viewport size and reading position.
class ReaderSettings {
  static const schemaVersion = 2;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final double horizontalPadding;
  final String fontFamily;
  final bool indent;
  final bool pageMode;
  final String pageAnimation;
  final int themeIndex;
  final int dayThemeIndex;
  final int nightThemeIndex;
  final ReaderThemeMode themeMode;
  final int dayStartMinutes;
  final int nightStartMinutes;
  final bool systemBrightness;
  final double brightness;
  final bool commentBubbles;
  final bool volumeKeys;
  final String tapLayout;
  final bool pureMode;
  final bool showHeader;
  final bool showStatus;
  final bool keepScreenOn;
  final bool haptics;
  final bool restReminder;
  final int restMinutes;

  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.letterSpacing = .5,
    this.paragraphSpacing = 14,
    this.horizontalPadding = 20,
    this.fontFamily = 'system',
    this.indent = true,
    this.pageMode = false,
    this.pageAnimation = 'cover',
    this.themeIndex = 1,
    this.dayThemeIndex = 1,
    this.nightThemeIndex = 3,
    this.themeMode = ReaderThemeMode.manual,
    this.dayStartMinutes = 420,
    this.nightStartMinutes = 1320,
    this.systemBrightness = true,
    this.brightness = .5,
    this.commentBubbles = true,
    this.volumeKeys = false,
    this.tapLayout = 'balanced',
    this.pureMode = false,
    this.showHeader = true,
    this.showStatus = true,
    this.keepScreenOn = true,
    this.haptics = false,
    this.restReminder = false,
    this.restMinutes = 30,
  });

  int effectiveTheme({required bool systemDark, required DateTime now}) {
    if (themeMode == ReaderThemeMode.manual) return themeIndex;
    if (themeMode == ReaderThemeMode.system) {
      return systemDark ? nightThemeIndex : dayThemeIndex;
    }
    final minute = now.hour * 60 + now.minute;
    final duration = (dayStartMinutes - nightStartMinutes + 1440) % 1440;
    final elapsed = (minute - nightStartMinutes + 1440) % 1440;
    return elapsed < duration ? nightThemeIndex : dayThemeIndex;
  }

  Map<String, dynamic> toJson() => {
    'version': schemaVersion,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'letterSpacing': letterSpacing,
    'paragraphSpacing': paragraphSpacing,
    'horizontalPadding': horizontalPadding,
    'fontFamily': fontFamily,
    'indent': indent,
    'pageMode': pageMode,
    'pageAnimation': pageAnimation,
    'themeIndex': themeIndex,
    'dayThemeIndex': dayThemeIndex,
    'nightThemeIndex': nightThemeIndex,
    'themeMode': themeMode.name,
    'dayStartMinutes': dayStartMinutes,
    'nightStartMinutes': nightStartMinutes,
    'systemBrightness': systemBrightness,
    'brightness': brightness,
    'commentBubbles': commentBubbles,
    'volumeKeys': volumeKeys,
    'tapLayout': tapLayout,
    'pureMode': pureMode,
    'showHeader': showHeader,
    'showStatus': showStatus,
    'keepScreenOn': keepScreenOn,
    'haptics': haptics,
    'restReminder': restReminder,
    'restMinutes': restMinutes,
  };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    final version = json['version'] ?? schemaVersion;
    if (version != schemaVersion) {
      throw const FormatException('不支持的阅读设置版本');
    }
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    String choice(String key, Set<String> choices, String fallback) =>
        choices.contains(json[key]) ? json[key] as String : fallback;
    final day = number('dayStartMinutes', 420, 0, 1439).toInt();
    final night = number('nightStartMinutes', 1320, 0, 1439).toInt();
    return ReaderSettings(
      fontSize: number('fontSize', 18, 13, 36),
      lineHeight: number('lineHeight', 1.8, 1.2, 2.6),
      letterSpacing: number('letterSpacing', .5, 0, 3),
      paragraphSpacing: number('paragraphSpacing', 14, 0, 32),
      horizontalPadding: number('horizontalPadding', 20, 8, 48),
      fontFamily: choice('fontFamily', {
        'system',
        'serif',
        'kaiti',
        'sans-serif',
      }, 'system'),
      indent: flag('indent', true),
      pageMode: flag('pageMode', false),
      pageAnimation: choice('pageAnimation', {
        'cover',
        'slide',
        'fade',
        'simulation',
        'none',
      }, 'cover'),
      themeIndex: number('themeIndex', 1, 0, 4).toInt(),
      dayThemeIndex: number('dayThemeIndex', 1, 0, 2).toInt(),
      nightThemeIndex: number('nightThemeIndex', 3, 3, 4).toInt(),
      themeMode: ReaderThemeMode.values.firstWhere(
        (mode) => mode.name == json['themeMode'],
        orElse: () => ReaderThemeMode.manual,
      ),
      dayStartMinutes: day == night ? 420 : day,
      nightStartMinutes: day == night ? 1320 : night,
      systemBrightness: flag('systemBrightness', true),
      brightness: number('brightness', .5, .05, 1),
      commentBubbles: flag('commentBubbles', true),
      volumeKeys: flag('volumeKeys', false),
      pureMode: flag('pureMode', false),
      showHeader: flag('showHeader', true),
      showStatus: flag('showStatus', true),
      keepScreenOn: flag('keepScreenOn', true),
      haptics: flag('haptics', false),
      restReminder: flag('restReminder', false),
      restMinutes: number('restMinutes', 30, 10, 120).toInt(),
      tapLayout: choice('tapLayout', {
        'balanced',
        'right_hand',
        'left_hand',
      }, 'balanced'),
    );
  }

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? paragraphSpacing,
    double? horizontalPadding,
    String? fontFamily,
    bool? indent,
    bool? pageMode,
    String? pageAnimation,
    int? themeIndex,
    int? dayThemeIndex,
    int? nightThemeIndex,
    ReaderThemeMode? themeMode,
    int? dayStartMinutes,
    int? nightStartMinutes,
    bool? systemBrightness,
    double? brightness,
    bool? commentBubbles,
    bool? volumeKeys,
    String? tapLayout,
    bool? pureMode,
    bool? showHeader,
    bool? showStatus,
    bool? keepScreenOn,
    bool? haptics,
    bool? restReminder,
    int? restMinutes,
  }) => ReaderSettings.fromJson({
    ...toJson(),
    if (fontSize != null) 'fontSize': fontSize,
    if (lineHeight != null) 'lineHeight': lineHeight,
    if (letterSpacing != null) 'letterSpacing': letterSpacing,
    if (paragraphSpacing != null) 'paragraphSpacing': paragraphSpacing,
    if (horizontalPadding != null) 'horizontalPadding': horizontalPadding,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (indent != null) 'indent': indent,
    if (pageMode != null) 'pageMode': pageMode,
    if (pageAnimation != null) 'pageAnimation': pageAnimation,
    if (themeIndex != null) 'themeIndex': themeIndex,
    if (dayThemeIndex != null) 'dayThemeIndex': dayThemeIndex,
    if (nightThemeIndex != null) 'nightThemeIndex': nightThemeIndex,
    if (themeMode != null) 'themeMode': themeMode.name,
    if (dayStartMinutes != null) 'dayStartMinutes': dayStartMinutes,
    if (nightStartMinutes != null) 'nightStartMinutes': nightStartMinutes,
    if (systemBrightness != null) 'systemBrightness': systemBrightness,
    if (brightness != null) 'brightness': brightness,
    if (commentBubbles != null) 'commentBubbles': commentBubbles,
    if (volumeKeys != null) 'volumeKeys': volumeKeys,
    if (tapLayout != null) 'tapLayout': tapLayout,
    if (pureMode != null) 'pureMode': pureMode,
    if (showHeader != null) 'showHeader': showHeader,
    if (showStatus != null) 'showStatus': showStatus,
    if (keepScreenOn != null) 'keepScreenOn': keepScreenOn,
    if (haptics != null) 'haptics': haptics,
    if (restReminder != null) 'restReminder': restReminder,
    if (restMinutes != null) 'restMinutes': restMinutes,
  });

  ReaderSettings typographyFrom(ReaderSettings preset) => copyWith(
    fontSize: preset.fontSize,
    lineHeight: preset.lineHeight,
    letterSpacing: preset.letterSpacing,
    paragraphSpacing: preset.paragraphSpacing,
    horizontalPadding: preset.horizontalPadding,
    fontFamily: preset.fontFamily,
    indent: preset.indent,
  );

  static const presets = {
    '紧凑': ReaderSettings(
      fontSize: 16,
      lineHeight: 1.5,
      letterSpacing: 0,
      paragraphSpacing: 8,
      horizontalPadding: 16,
    ),
    '纸书': ReaderSettings(
      fontSize: 20,
      lineHeight: 1.8,
      fontFamily: 'serif',
      paragraphSpacing: 16,
      horizontalPadding: 24,
    ),
    '大字': ReaderSettings(
      fontSize: 28,
      lineHeight: 1.8,
      paragraphSpacing: 18,
      horizontalPadding: 18,
    ),
  };
}
