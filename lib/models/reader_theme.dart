import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ReaderTheme {
  final String name;
  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final Color highlightColor;
  final Brightness systemBrightness;

  const ReaderTheme({
    required this.name,
    required this.backgroundColor,
    required this.textColor,
    required this.secondaryColor,
    required this.highlightColor,
    required this.systemBrightness,
  });

  ReaderTheme withColors({int? background, int? text}) {
    if (background == null && text == null) return this;
    final bg = background == null ? backgroundColor : Color(background);
    final fg = text == null ? textColor : Color(text);
    return ReaderTheme(
      name: '自定义',
      backgroundColor: bg,
      textColor: fg,
      secondaryColor: Color.lerp(fg, bg, .28)!,
      highlightColor: Color.lerp(bg, fg, .10)!,
      systemBrightness: bg.computeLuminance() < .2
          ? Brightness.dark
          : Brightness.light,
    );
  }

  double get contrastRatio {
    final a = backgroundColor.computeLuminance();
    final b = textColor.computeLuminance();
    return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
  }

  ThemeData get materialTheme => ThemeData(
    brightness: systemBrightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: textColor,
      brightness: systemBrightness,
      surface: backgroundColor,
      onSurface: textColor,
    ),
    scaffoldBackgroundColor: backgroundColor,
  );

  SystemUiOverlayStyle get systemUiStyle => SystemUiOverlayStyle(
    statusBarColor: backgroundColor,
    statusBarBrightness: systemBrightness,
    statusBarIconBrightness: systemBrightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarColor: backgroundColor,
    systemNavigationBarDividerColor: backgroundColor,
    systemNavigationBarIconBrightness: systemBrightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  Widget wrap(Widget child) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: systemUiStyle,
    child: Theme(data: materialTheme, child: child),
  );

  static const presets = [
    ReaderTheme(
      name: '白昼',
      backgroundColor: Color(0xFFFAF9F6),
      textColor: Color(0xFF222222),
      secondaryColor: Color(0xFF626262),
      highlightColor: Color(0xFFE8E2D2),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '羊皮纸',
      backgroundColor: Color(0xFFF5EEDC),
      textColor: Color(0xFF3B2F2F),
      secondaryColor: Color(0xFF665B4F),
      highlightColor: Color(0xFFE5DAC4),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '柔绿',
      backgroundColor: Color(0xFFE2EED9),
      textColor: Color(0xFF233621),
      secondaryColor: Color(0xFF506247),
      highlightColor: Color(0xFFCEE0C3),
      systemBrightness: Brightness.light,
    ),
    ReaderTheme(
      name: '暗夜',
      backgroundColor: Color(0xFF18181A),
      textColor: Color(0xFFB8B8B8),
      secondaryColor: Color(0xFF96969B),
      highlightColor: Color(0xFF28282C),
      systemBrightness: Brightness.dark,
    ),
    ReaderTheme(
      name: '纯黑',
      backgroundColor: Color(0xFF000000),
      textColor: Color(0xFFC7C7CC),
      secondaryColor: Color(0xFF96969B),
      highlightColor: Color(0xFF222224),
      systemBrightness: Brightness.dark,
    ),
  ];
}
