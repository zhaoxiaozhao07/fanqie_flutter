import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import '../models/chapter.dart';
import 'fanqie_backend_engine.dart';

/// API 服务 - 接入内置番茄小说后端引擎
/// 覆盖原有全部接口并直接内置运行：
/// - checkHealth: 健康检查
/// - searchBooks: 搜索书籍
/// - discoverBooks: 发现/榜单/分类多维筛选
/// - getBookDetail: 书籍详情
/// - getBookDirectory: 简化章节目录
/// - getBookFull: 完整书籍与目录备用
/// - getBookChapters: 智能多级回退获取目录
/// - getIosChapterContent: 章节正文（优先通道）
/// - getNormalChapterContent: 章节正文（备用通道）
/// - getChapterContent: 获取章节正文
/// - getBookCover: 获取书籍封面图片数据
/// - downloadChapters: 高性能全章节并发下载
class ApiService {
  final FanqieBackendEngine _engine;
  final http.Client _client;

  ApiService({http.Client? client, FanqieBackendEngine? engine})
      : _client = client ?? http.Client(),
        _engine = engine ?? FanqieBackendEngine(client: client);

  FanqieBackendEngine get engine => _engine;

  /// 1. 健康检查接口（内置引擎恒定可用）
  Future<bool> checkHealth([String? targetUrl]) async {
    return true;
  }

  /// 2. 搜索书籍接口
  Future<List<Book>> searchBooks(
    String keyword, {
    int offset = 0,
    int tabType = 3,
  }) async {
    return _engine.searchBooks(keyword, offset: offset, tabType: tabType);
  }

  /// 3. 发现/榜单/分类多维筛选接口
  Future<List<Book>> discoverBooks({
    String? bdtype,
    int? type,
    int gender = 1,
    bool isRanking = false,
    int genreType = 0,
    int? creationStatus,
    int? wordCount,
    int sort = 0,
    int page = 1,
  }) async {
    return _engine.discoverBooks(
      bdtype: bdtype,
      type: type,
      gender: gender,
      isRanking: isRanking,
      genreType: genreType,
      creationStatus: creationStatus,
      wordCount: wordCount,
      sort: sort,
      page: page,
    );
  }

  /// 发现/分类快捷接口
  Future<List<Book>> discoverByType({
    required int type,
    int gender = 1,
    int page = 1,
    int? creationStatus,
    int? wordCount,
    int sort = 0,
  }) {
    return discoverBooks(
      type: type,
      gender: gender,
      page: page,
      creationStatus: creationStatus,
      wordCount: wordCount,
      sort: sort,
      isRanking: false,
    );
  }

  /// 4. 书籍详情接口
  Future<Book?> getBookDetail(String bookId) async {
    return _engine.getBookDetail(bookId);
  }

  /// 5. 简化章节目录接口
  Future<List<Chapter>> getBookDirectory(String bookId) async {
    return _engine.getBookDirectory(bookId);
  }

  /// 6. 完整书籍信息接口
  Future<Map<String, dynamic>?> getBookFull(String bookId) async {
    return _engine.getBookFull(bookId);
  }

  /// 获取书籍章节目录（优先简化目录，回退完整书籍）
  Future<List<Chapter>> getBookChapters(String bookId) async {
    final chapters = await _engine.getBookDirectory(bookId);
    if (chapters.isNotEmpty) {
      return chapters;
    }

    final full = await _engine.getBookFull(bookId);
    if (full != null) {
      final volumeList = full['chapterListWithVolume'] as List?;
      if (volumeList != null && volumeList.isNotEmpty) {
        final list = <Chapter>[];
        for (var volume in volumeList) {
          if (volume is List) {
            for (var chapter in volume) {
              if (chapter is Map) {
                list.add(
                  Chapter.fromBookJson(Map<String, dynamic>.from(chapter)),
                );
              }
            }
          }
        }
        if (list.isNotEmpty) return list;
      }

      final allIds = full['allItemIds'] as List?;
      if (allIds != null && allIds.isNotEmpty) {
        return allIds.asMap().entries.map((entry) {
          return Chapter(
            itemId: entry.value.toString(),
            title: '第${entry.key + 1}章',
            order: entry.key + 1,
          );
        }).toList();
      }
    }

    return [];
  }

  /// 7. 章节正文接口（iOS 通道）
  Future<String?> getIosChapterContent(String itemId, {String? bookId}) async {
    return _engine.getChapterContent(itemId, bookId: bookId);
  }

  /// 8. 章节正文接口（普通通道）
  Future<String?> getNormalChapterContent(
    String itemId, {
    String tab = '小说',
    String? bookId,
  }) async {
    return _engine.getChapterContent(itemId, bookId: bookId);
  }

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
    _client.close();
  }
}
