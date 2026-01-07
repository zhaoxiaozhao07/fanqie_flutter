import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'app_theme.dart';
import 'screens/main_screen.dart';

void main() {
  // 确保 Flutter 绑定已初始化
  WidgetsFlutterBinding.ensureInitialized();
  // 配置全局图片缓存
  _configureImageCache();
  runApp(const FanqieApp());
}

/// 配置图片缓存策略
void _configureImageCache() {
  // 增大内存缓存容量（默认约 100MB）
  PaintingBinding.instance.imageCache.maximumSize = 500; // 最多缓存 500 张图片
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      200 * 1024 * 1024; // 200MB 内存
}

/// 自定义缓存管理器 - 30 天磁盘缓存
class BookCoverCacheManager {
  static const key = 'bookCoverCache';
  static CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 30), // 缓存 30 天
      maxNrOfCacheObjects: 500, // 最多缓存 500 个文件
    ),
  );
}

/// 番茄小说 Flutter 应用
class FanqieApp extends StatelessWidget {
  const FanqieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '番茄下载',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const MainScreen(),
    );
  }
}
