import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/discovery.dart';
import '../models/chapter.dart';
import '../models/comment.dart';
import 'fanqie_backend_engine.dart';
import 'fanqie_mobile_gateway.dart';
import 'atomic_file.dart';

/// API 服务 - 接入内置番茄小说后端引擎
/// 覆盖原有全部接口并直接内置运行：
/// - searchBooks: 搜索书籍
/// - getCategories / discoverBooks: 官方分类与书库多维筛选
/// - getBookDetail: 书籍详情
/// - getBookDirectory: 简化章节目录
/// - getBookFull: 完整书籍与目录备用
/// - getBookChapters: 智能多级回退获取目录
/// - getChapterContent: 获取章节正文
/// - getBookCover: 获取书籍封面图片数据
/// - downloadChapters: 高性能全章节并发下载
class ApiService {
  final FanqieBackendEngine _engine;
  final FanqieMobileGateway _mobileGateway = FanqieMobileGateway();
  final http.Client _client;
  final Future<ChapterCommentStats?> Function(String)? chapterStatsLoader;
  final Map<String, DateTime> _commentRefreshes = {};
  bool _disposed = false;

  ApiService({
    http.Client? client,
    FanqieBackendEngine? engine,
    this.chapterStatsLoader,
  }) : _client = client ?? http.Client(),
       _engine = engine ?? FanqieBackendEngine(client: client);

  void _refreshComments(String key, Future<Object?> Function() fetch) {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.difference(_commentRefreshes[key] ?? DateTime(2000)) <
        const Duration(minutes: 1)) {
      return;
    }
    _commentRefreshes[key] = now;
    unawaited(fetch().then<void>((_) {}, onError: (Object _) {}));
  }

  FanqieBackendEngine get engine => _engine;

  Future<List<Book>> searchBooks(String keyword, {int offset = 0}) =>
      _engine.searchBooks(keyword, offset: offset);

  Future<CategoryCatalog> getCategories({int gender = 1}) =>
      _engine.getCategories(gender: gender);

  Future<LibraryPage> discoverBooks({
    int categoryId = -1,
    int gender = 1,
    int creationStatus = -1,
    int wordCount = -1,
    int sort = 0,
    int page = 1,
  }) => _engine.discoverBooks(
    categoryId: categoryId,
    gender: gender,
    creationStatus: creationStatus,
    wordCount: wordCount,
    sort: sort,
    page: page,
  );

  /// 4. 书籍详情接口
  Future<Book?> getBookDetail(String bookId) async {
    return _engine.getBookDetail(bookId);
  }

  /// 5. 简化章节目录接口
  Future<List<Chapter>> getBookDirectory(
    String bookId, {
    bool refresh = false,
  }) async {
    return _engine.getBookDirectory(bookId, refresh: refresh);
  }

  /// 6. 完整书籍信息接口
  Future<Map<String, dynamic>?> getBookFull(String bookId) async {
    return _engine.getBookFull(bookId);
  }

  /// A single retryable catalog path; never repeat a failed detail-page fetch.
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) => _engine.getBookDirectory(bookId, refresh: refresh);

  /// 获取单个章节内容
  Future<String?> getChapterContent(String itemId, {String? bookId}) async {
    return _engine.getChapterContent(itemId, bookId: bookId);
  }

  /// 判断某书籍的指定章节是否已离线
  Future<bool> isChapterOffline(String bookId, String itemId) async {
    return _engine.isChapterOffline(bookId, itemId);
  }

  /// 获取某书籍已离线的章节数量
  Future<int> getOfflineChapterCount(String bookId) async {
    return _engine.getOfflineChapterCount(bookId);
  }

  // ==========================================
  // 评论与段评体系（支持在线获取与离线本地缓存）
  // ==========================================

  /// 获取评论本地持久化存储目录
  Future<Directory> _getCommentCacheDir({String? bookId}) async {
    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    String path;
    if (bookId != null && bookId.isNotEmpty) {
      path = '${baseDir.path}/offline_books/$bookId/comments';
    } else {
      path = '${baseDir.path}/comment_cache';
    }
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 获取章节段评数量统计（支持离线缓存回退）
  Future<ChapterCommentStats?> getChapterCommentStats(
    String itemId, {
    String? bookId,
    bool preferCache = true,
  }) async {
    final cleanId = itemId.trim();
    if (cleanId.isEmpty) return null;
    if (preferCache) {
      final cached = await _loadCommentStatsFromDisk(cleanId, bookId: bookId);
      if (cached != null) {
        _refreshComments(
          'stats:$cleanId',
          () => getChapterCommentStats(
            cleanId,
            bookId: bookId,
            preferCache: false,
          ),
        );
        return cached;
      }
    }

    // 1. 尝试在线获取
    try {
      final stats =
          await (chapterStatsLoader?.call(cleanId) ??
              _mobileGateway.fetchChapterCommentStats(cleanId));
      if (stats != null) {
        await _saveCommentStatsToDisk(cleanId, stats, bookId: bookId);
        return stats;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取段评统计失败，尝试离线缓存: $e');
      }
    }

    // 2. 在线获取失败或无网络时，尝试读取本地缓存
    return _loadCommentStatsFromDisk(cleanId, bookId: bookId);
  }

  Future<void> _saveCommentStatsToDisk(
    String itemId,
    ChapterCommentStats stats, {
    String? bookId,
  }) async {
    try {
      final jsonStr = jsonEncode(stats.toJson());
      final dir = await _getCommentCacheDir(bookId: bookId);
      final file = File('${dir.path}/stats_$itemId.json');
      await AtomicFile.writeString(file, jsonStr);

      // 如果提供了离线书籍ID，同步写入通用缓存
      if (bookId != null && bookId.isNotEmpty) {
        final commonDir = await _getCommentCacheDir();
        final commonFile = File('${commonDir.path}/stats_$itemId.json');
        await AtomicFile.writeString(commonFile, jsonStr);
      }
    } catch (_) {}
  }

  Future<ChapterCommentStats?> _loadCommentStatsFromDisk(
    String itemId, {
    String? bookId,
  }) async {
    try {
      if (bookId != null && bookId.isNotEmpty) {
        final offlineDir = await _getCommentCacheDir(bookId: bookId);
        final offlineFile = File('${offlineDir.path}/stats_$itemId.json');
        if (await offlineFile.exists()) {
          final content = await offlineFile.readAsString();
          return ChapterCommentStats.fromJson(jsonDecode(content));
        }
      }

      final commonDir = await _getCommentCacheDir();
      final commonFile = File('${commonDir.path}/stats_$itemId.json');
      if (await commonFile.exists()) {
        final content = await commonFile.readAsString();
        return ChapterCommentStats.fromJson(jsonDecode(content));
      }
    } catch (_) {}
    return null;
  }

  /// 获取本章评论（章节末尾的独立章评 / 章节讨论）
  Future<CommentPageData?> getChapterComments(
    String bookId,
    String itemId, {
    int offset = 0,
    int count = 20,
    bool preferCache = true,
  }) async {
    final cleanItemId = itemId.trim();
    final cleanBookId = bookId.trim();
    if (preferCache && offset == 0) {
      final cached = await _loadChapterCommentsFromDisk(
        cleanBookId,
        cleanItemId,
      );
      if (cached != null) {
        _refreshComments(
          'chapter:$cleanBookId:$cleanItemId',
          () => getChapterComments(
            cleanBookId,
            cleanItemId,
            count: count,
            preferCache: false,
          ),
        );
        return cached;
      }
    }

    // 1. 尝试在线获取
    try {
      final page = await _mobileGateway.fetchChapterComments(
        cleanBookId,
        cleanItemId,
        offset: offset,
        count: count,
      );
      if (page != null) {
        if (offset == 0) {
          _saveChapterCommentsToDisk(cleanBookId, cleanItemId, page);
        }
        return page;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取本章评论失败，尝试离线缓存: $e');
      }
    }

    // 2. 离线回退
    if (offset == 0) {
      return _loadChapterCommentsFromDisk(cleanBookId, cleanItemId);
    }
    return null;
  }

  void _saveChapterCommentsToDisk(
    String bookId,
    String itemId,
    CommentPageData page,
  ) async {
    try {
      final jsonStr = jsonEncode(page.toJson());
      final dir = await _getCommentCacheDir(bookId: bookId);
      final file = File('${dir.path}/chapter_${itemId}_comments.json');
      await AtomicFile.writeString(file, jsonStr);
    } catch (_) {}
  }

  Future<CommentPageData?> _loadChapterCommentsFromDisk(
    String bookId,
    String itemId,
  ) async {
    try {
      final dir = await _getCommentCacheDir(bookId: bookId);
      final file = File('${dir.path}/chapter_${itemId}_comments.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return CommentPageData.fromJson(jsonDecode(content));
      }
    } catch (_) {}
    return null;
  }

  /// 获取指定段落评论列表（支持离线缓存回退）
  /// 当 paraIndex 为 null 时获取全章综合段评
  Future<CommentPageData?> getParagraphComments(
    String bookId,
    String itemId,
    int? paraIndex, {
    int sort = 1,
    String cursor = '',
    int count = 20,
    bool preferCache = true,
  }) async {
    final cleanItemId = itemId.trim();
    final cleanBookId = bookId.trim();
    if (preferCache && cursor.isEmpty) {
      final cached = await _loadParagraphCommentsFromDisk(
        cleanBookId,
        cleanItemId,
        paraIndex,
        sort,
      );
      if (cached != null) {
        _refreshComments(
          'para:$cleanBookId:$cleanItemId:$paraIndex:$sort',
          () => getParagraphComments(
            cleanBookId,
            cleanItemId,
            paraIndex,
            sort: sort,
            count: count,
            preferCache: false,
          ),
        );
        return cached;
      }
    }

    // 1. 尝试在线获取
    try {
      final page = await _mobileGateway.fetchParagraphComments(
        cleanBookId,
        cleanItemId,
        paraIndex,
        sort: sort,
        cursor: cursor,
        count: count,
      );
      if (page != null) {
        // 仅对第一页做本地离线缓存
        if (cursor.isEmpty) {
          _saveParagraphCommentsToDisk(
            cleanBookId,
            cleanItemId,
            paraIndex,
            sort,
            page,
          );
        }
        return page;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取段落评论列表失败，尝试离线缓存: $e');
      }
    }

    // 2. 离线/网络失败回退（首屏）
    if (cursor.isEmpty) {
      return _loadParagraphCommentsFromDisk(
        cleanBookId,
        cleanItemId,
        paraIndex,
        sort,
      );
    }
    return null;
  }

  void _saveParagraphCommentsToDisk(
    String bookId,
    String itemId,
    int? paraIndex,
    int sort,
    CommentPageData page,
  ) async {
    try {
      final jsonStr = jsonEncode(page.toJson());
      final dir = await _getCommentCacheDir(bookId: bookId);
      final tag = paraIndex != null ? '$paraIndex' : 'all';
      final file = File('${dir.path}/para_${itemId}_${tag}_s$sort.json');
      await AtomicFile.writeString(file, jsonStr);
    } catch (_) {}
  }

  Future<CommentPageData?> _loadParagraphCommentsFromDisk(
    String bookId,
    String itemId,
    int? paraIndex,
    int sort,
  ) async {
    try {
      final dir = await _getCommentCacheDir(bookId: bookId);
      final tag = paraIndex != null ? '$paraIndex' : 'all';
      final file = File('${dir.path}/para_${itemId}_${tag}_s$sort.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        return CommentPageData.fromJson(jsonDecode(content));
      }
    } catch (_) {}
    return null;
  }

  /// 获取指定评论的楼中楼二级回复列表
  Future<CommentReplyPageData?> getCommentReplies(
    String commentId, {
    String cursor = '',
    int count = 20,
  }) async {
    return _mobileGateway.fetchCommentReplies(
      commentId,
      cursor: cursor,
      count: count,
    );
  }

  /// 获取全书读者书评列表 (书籍详情页)
  Future<CommentPageData?> getBookReviews(
    String bookId, {
    int sort = 1,
    String cursor = '',
    int count = 20,
  }) async {
    return _mobileGateway.fetchBookReviews(
      bookId,
      sort: sort,
      cursor: cursor,
      count: count,
    );
  }

  /// 获取书籍封面图片数据
  Future<List<int>?> getBookCover(String bookId) async {
    final book = await getBookDetail(bookId);
    if (book?.thumbUrl == null || book!.thumbUrl!.isEmpty) {
      return null;
    }

    try {
      final response = await _client
          .get(Uri.parse(book.thumbUrl!))
          .timeout(FanqieBackendEngine.timeout);

      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取封面失败: $e');
      }
      return null;
    }
  }

  /// 高性能并发下载章节
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int current, int total, String message)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 12,
  }) async {
    return _engine.downloadChapters(
      bookId: bookId,
      chapters: chapters,
      onProgress: onProgress,
      isCancelled: isCancelled,
      concurrency: concurrency,
    );
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
