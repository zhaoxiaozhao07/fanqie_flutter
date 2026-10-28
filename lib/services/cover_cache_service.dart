import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 书籍封面持久化缓存与离线提取服务
class CoverCacheService {
  static final CoverCacheService _instance = CoverCacheService._internal();
  factory CoverCacheService() => _instance;
  CoverCacheService._internal();

  /// 获取书籍持久化存储目录
  Future<Directory> _getBookDir(String bookId) async {
    final cleanId = bookId.trim();
    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final dir = Directory('${baseDir.path}/offline_books/$cleanId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 获取指定书籍本地封面文件
  Future<File> getCoverFile(String bookId) async {
    final dir = await _getBookDir(bookId);
    return File('${dir.path}/cover.jpg');
  }

  /// 判断指定书籍是否已有本地离线封面
  Future<bool> hasLocalCover(String bookId) async {
    try {
      final file = await getCoverFile(bookId);
      if (await file.exists()) {
        return (await file.length()) > 100;
      }
    } catch (_) {}
    return false;
  }

  /// 从已下载的 EPUB 文件中直接解压提取封面
  Future<File?> extractCoverFromEpub(String bookId, String epubPath) async {
    if (epubPath.isEmpty || !epubPath.toLowerCase().endsWith('.epub')) return null;
    try {
      final epubFile = File(epubPath);
      if (!await epubFile.exists()) return null;

      final bytes = await epubFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? coverFile;
      for (final file in archive) {
        final name = file.name.toLowerCase();
        if (name.contains('cover') && (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png'))) {
          coverFile = file;
          break;
        }
      }

      if (coverFile != null) {
        final content = coverFile.content as List<int>;
        if (content.isNotEmpty) {
          final localCover = await getCoverFile(bookId);
          await localCover.writeAsBytes(content);
          return localCover;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('extractCoverFromEpub error: $e');
    }
    return null;
  }

  /// 下载网络封面并持久化保存到本地离线目录
  Future<File?> cacheNetworkCover(String bookId, String imageUrl) async {
    if (imageUrl.isEmpty || !imageUrl.startsWith('http')) return null;
    try {
      final localCover = await getCoverFile(bookId);
      if (await localCover.exists() && (await localCover.length()) > 100) {
        return localCover;
      }

      final res = await http.get(Uri.parse(imageUrl)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200 && res.bodyBytes.length > 100) {
        await localCover.writeAsBytes(res.bodyBytes);
        return localCover;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('cacheNetworkCover error: $e');
    }
    return null;
  }
}
