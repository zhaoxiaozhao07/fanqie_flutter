import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'app_theme.dart';
import 'screens/main_screen.dart';
import 'services/reader_route_observer.dart';
import 'services/reader_backup_service.dart';
import 'services/app_lifecycle_service.dart';
import 'services/reader_platform.dart';
import 'widgets/desktop_shortcuts.dart';

Future<void> initializeReaderApplication() async {
  AppLifecycleService.initialize();
  await ReaderPlatform.initialize();
  await ReaderBackupService().recover();
}

Future<void> main() async {
  // 确保 Flutter 绑定已初始化
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeReaderApplication();
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      error is StateError && ReaderPlatform.isMacOS
                          ? 'macOS 客户端初始化失败，请重新构建或重试。原阅读数据未被清除。'
                          : '上次恢复尚未完成，原数据与恢复日志已保留。请检查存储空间后重试。',
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: main, child: const Text('重试恢复')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
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
      title: '番茄Reader',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorObservers: [readerRouteObserver],
      builder: (context, child) =>
          DesktopShortcuts(child: child ?? const SizedBox.shrink()),
      home: const MainScreen(),
    );
  }
}
