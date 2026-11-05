import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'atomic_file.dart';
import 'app_storage.dart';
import 'book_image_fetcher.dart';
import 'reader_cache_service.dart';
import 'reader_platform.dart';

/// 书籍封面持久化缓存与离线提取服务
class CoverCacheService {
  static final CoverCacheService _instance = CoverCacheService._internal();
  factory CoverCacheService() => _instance;
  CoverCacheService._internal();
  CoverCacheService.forTesting({required this.documents, required this.client});
  Future<Directory> Function()? documents;
  http.Client? client;

  final Map<String, _CoverRecord> _validated = {};
  final Map<String, Future<File?>> _requests = {};
  int _revision = 0;

  File? peekCover(String bookId) => _validated[bookId]?.file;
  int coverRevision(String bookId) => _validated[bookId]?.revision ?? 0;

  /// 获取书籍持久化存储目录
  Future<Directory> _getBookDir(String bookId) async {
    final cleanId = ReaderCacheService.segment(bookId.trim());
    Directory baseDir;
    try {
      baseDir = await (documents ?? AppStorage.documents)();
    } catch (_) {
      if (ReaderPlatform.isMacOS) rethrow;
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
      final stat = await file.stat();
      if (!await FileSystemEntity.isLink(file.path) &&
          stat.type == FileSystemEntityType.file &&
          stat.size <= BookImageFetcher.maxBytes) {
        final fingerprint = (file.path, stat.size, stat.modified, stat.changed);
        if (_validated[bookId]?.fingerprint == fingerprint) return true;
        await BookImageFetcher.validate(await file.readAsBytes());
        _validated[bookId] = _CoverRecord(file, fingerprint, ++_revision);
        if (_validated.length > 500) _validated.remove(_validated.keys.first);
        return true;
      }
      _validated.remove(bookId);
    } catch (_) {
      _validated.remove(bookId);
    }
    return false;
  }

  /// 从已下载的 EPUB 文件中直接解压提取封面
  Future<File?> extractCoverFromEpub(String bookId, String epubPath) async {
    if (epubPath.isEmpty || !epubPath.toLowerCase().endsWith('.epub')) {
      return null;
    }
    try {
      final epubFile = File(epubPath);
      if (!await epubFile.exists()) return null;

      final bytes = await epubFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      ArchiveFile? coverFile;
      for (final file in archive) {
        final name = file.name.toLowerCase();
        if (name.contains('cover') &&
            (name.endsWith('.jpg') ||
                name.endsWith('.jpeg') ||
                name.endsWith('.png') ||
                name.endsWith('.webp'))) {
          coverFile = file;
          break;
        }
      }

      if (coverFile != null) {
        final content = coverFile.content as List<int>;
        if (content.isNotEmpty) {
          await BookImageFetcher.validate(Uint8List.fromList(content));
          final localCover = await getCoverFile(bookId);
          await AtomicFile.writeBytes(localCover, content);
          if (await hasLocalCover(bookId)) return localCover;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('extractCoverFromEpub error: $e');
    }
    return null;
  }

  /// 下载网络封面并持久化保存到本地离线目录
  Future<File?> cacheNetworkCover(String bookId, String imageUrl) {
    final key = '$bookId:$imageUrl';
    final pending = _requests[key];
    if (pending != null) return pending;
    late final Future<File?> request;
    request = _cacheNetworkCover(bookId, imageUrl).whenComplete(() {
      if (identical(_requests[key], request)) _requests.remove(key);
    });
    _requests[key] = request;
    return request;
  }

  Future<File?> _cacheNetworkCover(String bookId, String imageUrl) async {
    if (imageUrl.isEmpty) return null;
    final connection = client ?? http.Client();
    try {
      final localCover = await getCoverFile(bookId);
      if (await hasLocalCover(bookId)) {
        return localCover;
      }

      final image = await BookImageFetcher(connection).fetch(imageUrl);
      await AtomicFile.writeBytes(localCover, image.bytes);
      if (await hasLocalCover(bookId)) return localCover;
    } catch (e) {
      if (kDebugMode) debugPrint('cacheNetworkCover error: $e');
    } finally {
      if (client == null) connection.close();
    }
    return null;
  }
}

class _CoverRecord {
  final File file;
  final Object fingerprint;
  final int revision;
  const _CoverRecord(this.file, this.fingerprint, this.revision);
}
