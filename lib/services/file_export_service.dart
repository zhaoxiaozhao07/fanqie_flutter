import 'dart:io';

import 'reader_platform.dart';

enum FileExportStatus { saved, cancelled, failed }

class FileExportResult {
  final FileExportStatus status;
  final String? path;
  final String? error;

  const FileExportResult.saved(String this.path)
    : status = FileExportStatus.saved,
      error = null;
  const FileExportResult.cancelled()
    : status = FileExportStatus.cancelled,
      path = null,
      error = null;
  const FileExportResult.failed(String this.error)
    : status = FileExportStatus.failed,
      path = null;
}

class FileExportCancelled implements Exception {
  const FileExportCancelled();
  @override
  String toString() => '已取消导出，已下载正文仍保留';
}

/// Pass source paths rather than loading large books/backups into byte arrays.
class FileExportService {
  Future<FileExportResult> save(
    File source, {
    required String name,
    required String mimeType,
    String? requestId,
    bool Function()? isCancelled,
  }) async {
    final safeName = name.replaceAll(RegExp(r'[/\\\x00]'), '_');
    if (safeName.isEmpty || !await source.exists()) {
      return const FileExportResult.failed('导出文件不存在或文件名为空');
    }
    // Cancellation can arrive during the asynchronous source-file preflight,
    // before the native request ID has entered its serialized panel queue.
    if (isCancelled?.call() == true) {
      return const FileExportResult.cancelled();
    }
    try {
      if (ReaderPlatform.isMacOS) {
        final value = await ReaderPlatform.invoke<Map<dynamic, dynamic>>(
          'saveExportFile',
          {
            'filePath': source.path,
            'fileName': safeName,
            'mimeType': mimeType,
            'id': requestId ?? '${DateTime.now().microsecondsSinceEpoch}',
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
              value?['error']?.toString() ?? '文件保存失败，请检查文件权限与存储空间',
            );
        }
      }
      if (Platform.isAndroid) {
        final saved = await ReaderPlatform.invoke<bool>('saveToDownloads', {
          'filePath': source.path,
          'fileName': safeName,
          'mimeType': mimeType,
        });
        return saved == true
            ? FileExportResult.saved('下载/fanqie/$safeName')
            : const FileExportResult.failed('导出保存失败');
      }
      return FileExportResult.saved(source.path);
    } catch (_) {
      return const FileExportResult.failed('文件保存失败，请检查文件权限与存储空间');
    }
  }
}
