import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_export_service.dart';
import 'reader_platform.dart';

/// Windows downloads commit straight into a configured output directory
/// (default: the user's Downloads/fanqie folder). No save dialog interrupts
/// the end of a task; name collisions append a numeric suffix instead of
/// overwriting neighbours.
class DesktopDownloadOutput {
  static const prefKey = 'windows_download_dir';

  /// The default suggestion under the user's Downloads folder.
  static Future<String> defaultDirectory() async {
    var base = '';
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        base = downloads.path;
      } else {
        base = (await getApplicationSupportDirectory()).path;
      }
    } catch (_) {
      base = (await getApplicationSupportDirectory()).path;
    }
    return '$base\\fanqie';
  }

  /// Resolves the effective directory, recreating a remembered folder that
  /// disappeared (renamed/removed drive). Throws when nothing is writable.
  static Future<String> resolve() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(prefKey);
    if (stored != null && stored.isNotEmpty) {
      final directory = Directory(stored);
      if (await directory.exists()) return stored;
      try {
        await directory.create(recursive: true);
        return stored;
      } on FileSystemException {
        // Fall through to the default location.
      }
    }
    final fallback = Directory(await defaultDirectory());
    await fallback.create(recursive: true);
    return fallback.path;
  }

  /// Opens the native folder picker and remembers the choice on success.
  /// Returns the chosen path, or null when cancelled/failed.
  static Future<String?> choose() async {
    if (!ReaderPlatform.isWindows) return null;
    try {
      final value = await ReaderPlatform.invoke<Map<dynamic, dynamic>>(
        'pickDownloadDirectory',
      );
      if (value?['status'] == 'saved' && value?['path'] is String) {
        final path = value!['path'] as String;
        if (path.isEmpty) return null;
        if (!await Directory(path).exists()) return null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefKey, path);
        return path;
      }
    } catch (_) {}
    return null;
  }

  /// Commits a finished temporary file into the output directory. The native
  /// side streams the copy and atomically renames; a numeric suffix resolves
  /// name collisions without ever overwriting an existing file.
  static Future<FileExportResult> commit(
    File source,
    String name, {
    String? requestId,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) return const FileExportResult.cancelled();
    try {
      final directory = await resolve();
      final value = await ReaderPlatform.invoke<Map<dynamic, dynamic>>(
        'commitDownloadFile',
        {
          'id': requestId ?? '${DateTime.now().microsecondsSinceEpoch}',
          'sourcePath': source.path,
          'directory': directory,
          'fileName': name,
        },
      );
      switch (value?['status']) {
        case 'saved':
          final path = value?['path'];
          if (path is String && path.isNotEmpty) {
            return FileExportResult.saved(path);
          }
          return const FileExportResult.failed('系统未返回已保存文件的位置');
        case 'cancelled':
          return const FileExportResult.cancelled();
        default:
          return FileExportResult.failed(
            value?['error']?.toString() ?? '文件保存失败，请检查目录权限与存储空间',
          );
      }
    } catch (_) {
      return const FileExportResult.failed('文件保存失败，请检查目录权限与存储空间');
    }
  }
}
