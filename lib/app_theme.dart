import 'package:flutter/material.dart';

/// 应用主题配置 - Modern Material 3 Design
/// 主题色：番茄红 (Tomato Red)
class AppTheme {
  // 核心色板
  static const Color primaryColor = Color(0xFFFF5252); // 更鲜艳的番茄红
  static const Color primaryLight = Color(0xFFFFEBEE);
  static const Color primaryDark = Color(0xFFD32F2F);

  // 辅助色
  static const Color secondaryColor = Color(0xFFFF8A80);
  static const Color accentColor = secondaryColor; // Maintain compatibility
  static const Color surfaceColor = Colors.white;
  static const Color backgroundColor = Color(
    0xFFF5F5F7,
  ); // iOS style light grey background
  static const Color dividerColor = Color(0xFFEEEEEE);

  // 文字颜色 - 优化对比度
  static const Color textPrimary = Color(0xFF1F1F1F); // 近似黑
  static const Color textSecondary = Color(0xFF757575); // 次级灰
  static const Color textHint = Color(0xFFBDBDBD);

  // 状态颜色
  static const Color successColor = Color(0xFF4CAF50);
  static const Color warningColor = Color(0xFFFF9800);
  static const Color errorColor = Color(0xFFF44336);

  // 标签颜色 (保持鲜艳但不过饱和)
  static const Color tagSerializing = Color(0xFF2196F3);
  static const Color tagCompleted = Color(0xFF00C853);
  static const Color tagCategory = Color(0xFFFF5252);

  // 暗色模式色板
  static const Color darkSurfaceColor = Color(0xFF1C1E22);
  static const Color darkBackgroundColor = Color(0xFF121316);
  static const Color darkCardBorderColor = Color(0xFF2B2E36);
  static const Color darkInputFillColor = Color(0xFF252830);
  static const Color darkDividerColor = Color(0xFF2A2D35);
  static const Color darkTextPrimary = Color(0xFFEAECEF);
  static const Color darkTextSecondary = Color(0xFFA0A6B2);
  static const Color darkTextHint = Color(0xFF6E7582);

  /// 根据当前上下文亮度返回语义颜色，避免深色模式下出现白底刺眼或对比度不足
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color surfaceOf(BuildContext context) =>
      isDark(context) ? darkSurfaceColor : surfaceColor;

  static Color backgroundOf(BuildContext context) =>
      isDark(context) ? darkBackgroundColor : backgroundColor;

  static Color inputFillOf(BuildContext context) =>
      isDark(context) ? darkInputFillColor : const Color(0xFFF2F4F7);

  static Color dividerOf(BuildContext context) =>
      isDark(context) ? darkDividerColor : dividerColor;

  static Color textPrimaryOf(BuildContext context) =>
      isDark(context) ? darkTextPrimary : textPrimary;

  static Color textSecondaryOf(BuildContext context) =>
      isDark(context) ? darkTextSecondary : textSecondary;

  static Color textHintOf(BuildContext context) =>
      isDark(context) ? darkTextHint : textHint;

  static Color primarySoftOf(BuildContext context) => isDark(context)
      ? primaryColor.withValues(alpha: 0.2)
      : primaryLight;

  static Color primaryAccentTextOf(BuildContext context) =>
      isDark(context) ? const Color(0xFFFF8A80) : primaryDark;

  /// 获取暗色主题
  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      primary: const Color(0xFFFF6E6E),
      surface: darkSurfaceColor,
      brightness: Brightness.dark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: darkBackgroundColor,
      dividerColor: darkDividerColor,
      canvasColor: darkSurfaceColor,
      dialogTheme: const DialogThemeData(
        backgroundColor: darkSurfaceColor,
        surfaceTintColor: Colors.transparent,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: darkSurfaceColor,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: darkSurfaceColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: darkCardBorderColor),
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: darkSurfaceColor,
        surfaceTintColor: Colors.transparent,
        foregroundColor: darkTextPrimary,
        iconTheme: IconThemeData(color: darkTextPrimary),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: darkTextPrimary,
          letterSpacing: 0.5,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: darkSurfaceColor,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: darkCardBorderColor, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkInputFillColor,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: Color(0xFFFF6E6E), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        hintStyle: const TextStyle(color: darkTextHint, fontSize: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: darkSurfaceColor,
        height: 65,
        elevation: 0,
        indicatorColor: primaryColor.withValues(alpha: 0.22),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: Color(0xFFFF7A7A));
          }
          return const IconThemeData(color: darkTextSecondary);
        }),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkSurfaceColor,
        selectedItemColor: Color(0xFFFF7A7A),
        unselectedItemColor: darkTextHint,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: darkTextPrimary,
          letterSpacing: -0.5,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: darkTextPrimary,
          height: 1.4,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: darkTextSecondary,
          height: 1.5,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: darkTextHint,
          height: 1.4,
        ),
      ),
    );
  }

  /// 获取亮色主题
  static ThemeData get lightTheme {
    // 基础 ColorScheme
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      primary: primaryColor,
      surface: surfaceColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: backgroundColor,
      dividerColor: dividerColor,

      // AppBar 现代简约风格
      appBarTheme: const AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent, // 避免 M3 滚动变色太重
        foregroundColor: textPrimary,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          letterSpacing: 0.5,
        ),
      ),

      // Card 扁平化风格
      cardTheme: CardThemeData(
        elevation: 0,
        color: surfaceColor,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFF0F0F0), width: 1), // 细腻边框
        ),
      ),

      // 输入框圆润风格
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24), // 更圆润
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: primaryColor, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        hintStyle: const TextStyle(color: textHint, fontSize: 14),
      ),

      // 按钮样式
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0, // 扁平按钮
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),

      // 底部导航栏
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceColor,
        height: 65,
        elevation: 0,
        indicatorColor: primaryLight,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: primaryColor);
          }
          return const IconThemeData(color: textSecondary);
        }),
      ),

      // 传统的 BottomNavigationBar 样式 (如果仍在使用)
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surfaceColor,
        selectedItemColor: primaryColor,
        unselectedItemColor: textHint,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
      ),

      // 文字层级优化
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: -0.5,
        ),
        // 书名等标题
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: textPrimary,
          height: 1.4,
        ),
        // 正文
        bodyMedium: TextStyle(fontSize: 14, color: textSecondary, height: 1.5),
        // 辅助文字
        bodySmall: TextStyle(fontSize: 12, color: textHint, height: 1.4),
      ),
    );
  }
}
