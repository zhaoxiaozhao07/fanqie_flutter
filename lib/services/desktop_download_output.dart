import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'file_export_service.dart';
import 'reader_platform.dart';

/// Desktop downloads commit straight into an authorized output directory
/// (default: the user's Downloads/fanqie folder). No save dialog interrupts
/// the end of a task; name collisions append a numeric suffix instead of
/// overwriting neighbours. On Mac, paths are display-only: Swift owns the
/// Downloads permission and all persistent security-scoped bookmarks.
class DesktopDownloadOutput {
  static const prefKey = 'windows_download_dir';

  /// The default suggestion under the user's Downloads folder.
  static Future<String> defaultDirectory() async {
    if (ReaderPlatform.isMacOS) return resolve();
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

  /// Mac resolves native authority or fails explicitly. Windows retains its
  /// preference/default fallback and recreation of missing remembered folders.
  static Future<String> resolve() async {
    if (ReaderPlatform.isMacOS) {
      return (await _nativeDirectory('getDownloadDirectory'))!;
    }
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
  /// Returns null on cancellation (also on Windows failure, as before).
  /// Mac authorization/malformed-result failures throw a readable I/O error.
  static Future<String?> choose() async {
    if (ReaderPlatform.isMacOS) {
      return _nativeDirectory('pickDownloadDirectory', allowCancellation: true);
    }
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

  static bool _isNativePath(Object? path) =>
      path is String && path.startsWith('/') && !path.contains('\x00');

  static String _readableError(Object? error, String fallback) =>
      error is String && error.trim().isNotEmpty ? error : fallback;

  static Future<String?> _nativeDirectory(
    String method, {
    bool allowCancellation = false,
  }) async {
    const fallback = '保存目录不可用，请重新选择保存位置';
    try {
      final value = await ReaderPlatform.invoke<dynamic>(method);
      if (value is Map) {
        if (value['status'] == 'saved' && _isNativePath(value['path'])) {
          return value['path'] as String;
        }
        if (value['status'] == 'cancelled' && allowCancellation) return null;
        throw FileSystemException(_readableError(value['error'], fallback));
      }
      throw const FileSystemException(fallback);
    } on FileSystemException {
      rethrow;
    } on PlatformException catch (error) {
      throw FileSystemException(_readableError(error.message, fallback));
    } catch (_) {
      throw const FileSystemException(fallback);
    }
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
      final args = <String, Object?>{
        'id': requestId ?? '${DateTime.now().microsecondsSinceEpoch}',
        'sourcePath': source.path,
        'fileName': name,
      };
      if (!ReaderPlatform.isMacOS) {
        args['directory'] = await resolve();
      }
      // Windows resolution can await filesystem/preference I/O before the
      // native ID enters the queue. Mac dispatch has no Dart directory I/O.
      if (isCancelled?.call() == true) {
        return const FileExportResult.cancelled();
      }
      final reply = await ReaderPlatform.invoke<dynamic>(
        'commitDownloadFile',
        args,
      );
      final value = reply is Map ? reply : null;
      switch (value?['status']) {
        case 'saved':
          final path = value?['path'];
          if (path is String &&
              path.isNotEmpty &&
              (!ReaderPlatform.isMacOS || _isNativePath(path))) {
            return FileExportResult.saved(path);
          }
          return const FileExportResult.failed('系统未返回已保存文件的位置');
        case 'cancelled':
          return const FileExportResult.cancelled();
        default:
          const fallback = '文件保存失败，请检查目录权限与存储空间';
          return FileExportResult.failed(
            ReaderPlatform.isMacOS
                ? _readableError(value?['error'], fallback)
                : value?['error']?.toString() ?? fallback,
          );
      }
    } on PlatformException catch (error) {
      return FileExportResult.failed(
        ReaderPlatform.isMacOS
            ? _readableError(error.message, '文件保存失败，请检查目录权限与存储空间')
            : '文件保存失败，请检查目录权限与存储空间',
      );
    } catch (_) {
      return const FileExportResult.failed('文件保存失败，请检查目录权限与存储空间');
    }
  }
}
