import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'app_theme.dart';
import 'screens/main_screen.dart';
import 'services/reader_route_observer.dart';
import 'services/reader_backup_service.dart';
import 'services/app_lifecycle_service.dart';
import 'services/reader_platform.dart';
import 'widgets/desktop_shortcuts.dart';
import 'services/download_service.dart';
import 'services/external_book_import_service.dart';
import 'services/reader_display_text.dart';
import 'services/external_reader_fonts.dart';
import 'services/reader_auto_backup_service.dart';
import 'services/reader_trash_service.dart';
import 'immersive/services/immersive_playback_coordinator.dart';
import 'webdav/services/webdav_sync_service.dart';
import 'services/app_theme_service.dart';
import 'services/text_replace_rule_service.dart';
import 'services/search_history_service.dart';

Future<void> initializeReaderApplication() async {
  AppLifecycleService.initialize();
  await ReaderPlatform.initialize();
  await ReaderBackupService().recover();
  await ReaderDisplayText.ensureLoaded();
  try {
    await AppThemeService().initialize();
  } catch (_) {}
  try {
    await TextReplaceRuleService().initialize();
  } catch (_) {}
  try {
    await SearchHistoryService().initialize();
  } catch (_) {}
  try {
    await ReaderTrashService().pruneExpired();
  } catch (_) {}
  await ReaderAutoBackupService().initialize();
  try {
    await ExternalReaderFonts().reload();
  } catch (_) {
    // A damaged optional font index must not prevent reading existing books.
  }
  if (ReaderPlatform.isDesktop) await DownloadService().initialize();
  await ExternalBookImportService().initialize();
  try {
    // 懒加载沉浸式听书配置与历史恢复，异常不阻塞普通阅读与单音色听书
    await ImmersivePlaybackCoordinator().loadAndValidateConfig();
  } catch (_) {}
  try {
    // 初始化 WebDAV 云同步配置（不在阻塞启动阶段发网络请求）
    await WebDavSyncService().initialize();
  } catch (_) {}
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
                      error is StateError && ReaderPlatform.requiresNativeBridge
                          ? (ReaderPlatform.isMacOS
                                ? 'macOS 客户端初始化失败，请重新构建或重试。原阅读数据未被清除。'
                                : 'Windows 客户端初始化失败，请重新构建或重试。原阅读数据未被清除。')
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
  // 移动端启用全面屏 Edge-to-Edge 透明系统栏适配
  if (!ReaderPlatform.isDesktop) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
  }
  // 配置全局图片缓存
  _configureImageCache();
  runApp(const FanqieApp());
}

/// 配置图片缓存策略（按桌面端与移动端差异化收敛内存占用，避免中低端机 OOM）
void _configureImageCache() {
  if (ReaderPlatform.isDesktop) {
    PaintingBinding.instance.imageCache.maximumSize = 500;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 200 * 1024 * 1024;
  } else {
    PaintingBinding.instance.imageCache.maximumSize = 200;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 80 * 1024 * 1024;
  }
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
    final themeService = AppThemeService();
    return AnimatedBuilder(
      animation: themeService,
      builder: (context, _) {
        final platformBrightness =
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
        return MaterialApp(
          title: '番茄Reader',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeService.resolveThemeMode(
            platformBrightness: platformBrightness,
          ),
          navigatorObservers: [readerRouteObserver],
          builder: (context, child) =>
              DesktopShortcuts(child: child ?? const SizedBox.shrink()),
          home: const MainScreen(),
        );
      },
    );
  }
}
