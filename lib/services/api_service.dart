import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import '../models/chapter.dart';
import 'source_service.dart';

/// API 服务 - 负责与番茄小说 FastAPI 后端服务交互
/// 覆盖后端全部接口：
/// - GET /health
/// - GET /api/search
/// - GET /api/discover (支持多维筛选与分页)
/// - GET /api/detail
/// - GET /api/directory (优先章节目录)
/// - GET /api/book (完整书籍与目录备用)
/// - GET /api/ios/content (优先正文通道)
/// - GET /api/content (备用正文通道)
class ApiService {
  static const Duration timeout = Duration(seconds: 25);

  final http.Client _client;
  final SourceService _sourceService = SourceService();

  int get _currentUrlIndex => _sourceService.currentUrlIndex;
  set _currentUrlIndex(int val) => _sourceService.currentUrlIndex = val;

  List<String> get _baseUrls => _sourceService.activeSourceUrls;

  String get _baseUrl {
    return _sourceService.currentActiveUrl ?? SourceService.defaultBackendUrl;
  }

  ApiService({http.Client? client}) : _client = client ?? http.Client() {
    _sourceService.initialize();
  }

  /// 通用 GET 请求，支持自动多源故障转移和重试
  Future<http.Response?> _get(
    String path, {
    Map<String, dynamic>? queryParameters,
    int maxRetries = 2,
  }) async {
    final urls = _baseUrls;
    if (urls.isEmpty) return null;

    final nonNullParams = <String, String>{};
    if (queryParameters != null) {
      for (final entry in queryParameters.entries) {
        if (entry.value != null) {
          nonNullParams[entry.key] = entry.value.toString();
        }
      }
    }

    for (int urlIndex = _currentUrlIndex; urlIndex < urls.length; urlIndex++) {
      final baseStr = urls[urlIndex].replaceAll(RegExp(r'/+$'), '');
      final baseUri = Uri.parse(baseStr);
      final uri = Uri(
        scheme: baseUri.scheme,
        host: baseUri.host,
        port: baseUri.hasPort ? baseUri.port : null,
        path: '${baseUri.path}$path'.replaceAll('//', '/'),
        queryParameters: nonNullParams.isNotEmpty ? nonNullParams : null,
      );

      for (int retry = 0; retry < maxRetries; retry++) {
        try {
          final response = await _client
              .get(uri, headers: _getHeaders())
              .timeout(timeout);

          if (response.statusCode == 200) {
            if (urlIndex != _currentUrlIndex) {
              _currentUrlIndex = urlIndex;
            }
            return response;
          }

          if (response.statusCode >= 500 && retry < maxRetries - 1) {
            await Future.delayed(Duration(milliseconds: 500 * (retry + 1)));
            continue;
          }

          return response;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('请求异常 [$uri] (重试 ${retry + 1}/$maxRetries): $e');
          }
          if (retry < maxRetries - 1) {
            await Future.delayed(Duration(milliseconds: 500 * (retry + 1)));
          }
        }
      }
    }

    _currentUrlIndex = 0;
    return null;
  }

  /// 1. 健康检查接口 GET /health
  Future<bool> checkHealth([String? targetUrl]) async {
    try {
      final base = targetUrl ?? _baseUrl;
      final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}/health');
      final response = await _client.get(uri).timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 2. 搜索书籍接口 GET /api/search
  /// [keyword] 搜索关键词
  /// [offset] 分页偏移量，默认为 0
  /// [tabType] Tab类型，默认为 3（书籍）
  Future<List<Book>> searchBooks(
    String keyword, {
    int offset = 0,
    int tabType = 3,
  }) async {
    try {
      final response = await _get('/api/search', queryParameters: {
        'key': keyword,
        'tab_type': tabType,
        'offset': offset,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          return _parseSearchResults(data as Map<String, dynamic>);
        }
      }
      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('searchBooks error: $e');
      }
      return [];
    }
  }

  /// 3. 发现/榜单/分类多维筛选接口 GET /api/discover
  /// [tab] 固定 "小说"
  /// [bdtype] 榜单类型：巅峰榜、出版榜、热搜榜、黑马榜、爆更榜、推荐榜、完结榜
  /// [type] 分类ID（玄幻=7、都市=1等）
  /// [gender] 读者性别：1=男频，2=女频，0=全部
  /// [isRanking] 是否榜单模式
  /// [genreType] 分类模式，默认 0
  /// [creationStatus] 状态：-1=全部，0=已完结，1=连载中
  /// [wordCount] 字数：-1=全部，1:30万以下，2:30-50万，3:50-100万，4:100-200万，5:200万以上
  /// [sort] 排序：0最热，1最新，2字数
  /// [page] 页码，从1开始
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
    final query = <String, dynamic>{
      'tab': '小说',
      'gender': gender,
      'sort': sort,
      'page': page,
    };

    if (isRanking && bdtype != null && bdtype.isNotEmpty) {
      query['bdtype'] = bdtype;
      query['is_ranking'] = 1;
    } else if (type != null) {
      query['type'] = type;
      query['genre_type'] = genreType;
    }

    if (creationStatus != null && creationStatus != -1) {
      query['creation_status'] = creationStatus;
    }

    if (wordCount != null && wordCount != -1) {
      query['word_count'] = wordCount;
    }

    try {
      final response = await _get('/api/discover', queryParameters: query);
      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final bookList = data['data'] as List?;
          if (bookList != null) {
            return bookList
                .whereType<Map>()
                .map((item) => Book.fromDiscoverJson(Map<String, dynamic>.from(item)))
                .toList();
          }
        }
      }
      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('discoverBooks error: $e');
      }
      return [];
    }
  }

  /// 发现/分类快捷接口（向后兼容）
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

  /// 4. 书籍详情接口 GET /api/detail
  /// [bookId] 书籍 ID
  Future<Book?> getBookDetail(String bookId) async {
    try {
      final response = await _get('/api/detail', queryParameters: {
        'book_id': bookId,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final bookData = data['data']?['data'];
          if (bookData is Map) {
            return Book.fromDetailJson(Map<String, dynamic>.from(bookData));
          }
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取书籍详情失败: $e');
      }
      return null;
    }
  }

  /// 5. 简化章节目录接口 GET /api/directory
  /// [bookId] 书籍 ID
  Future<List<Chapter>> getBookDirectory(String bookId) async {
    try {
      final response = await _get('/api/directory', queryParameters: {
        'book_id': bookId,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final lists = data['data']?['lists'];
          if (lists is List && lists.isNotEmpty) {
            final chapters = <Chapter>[];
            for (var i = 0; i < lists.length; i++) {
              final item = lists[i];
              if (item is Map) {
                chapters.add(
                  Chapter.fromDirectoryJson(Map<String, dynamic>.from(item), i),
                );
              }
            }
            return chapters;
          }
        }
      }
      return [];
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取简化目录失败: $e');
      }
      return [];
    }
  }

  /// 6. 完整书籍信息接口 GET /api/book
  /// [bookId] 书籍 ID
  Future<Map<String, dynamic>?> getBookFull(String bookId) async {
    try {
      final response = await _get('/api/book', queryParameters: {
        'book_id': bookId,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final inner = data['data']?['data'];
          if (inner is Map) {
            return Map<String, dynamic>.from(inner);
          }
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('获取完整书籍信息失败: $e');
      }
      return null;
    }
  }

  /// 获取书籍章节目录（优先 /api/directory，失败回退到 /api/book）
  Future<List<Chapter>> getBookChapters(String bookId) async {
    final chapters = await getBookDirectory(bookId);
    if (chapters.isNotEmpty) {
      return chapters;
    }

    return _getBookChaptersFromFull(bookId);
  }

  /// 从 /api/book 提取章节目录
  Future<List<Chapter>> _getBookChaptersFromFull(String bookId) async {
    final full = await getBookFull(bookId);
    if (full == null) return [];

    try {
      final volumeList = full['chapterListWithVolume'] as List?;
      if (volumeList != null && volumeList.isNotEmpty) {
        final chapters = <Chapter>[];
        for (var volume in volumeList) {
          if (volume is List) {
            for (var chapter in volume) {
              if (chapter is Map) {
                chapters.add(
                  Chapter.fromBookJson(Map<String, dynamic>.from(chapter)),
                );
              }
            }
          }
        }
        if (chapters.isNotEmpty) return chapters;
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
    } catch (e) {
      if (kDebugMode) {
        debugPrint('从完整书籍解析目录失败: $e');
      }
    }

    return [];
  }

  /// 7. 章节正文接口（iOS 通道）GET /api/ios/content
  /// [itemId] 章节 ID
  Future<String?> getIosChapterContent(String itemId) async {
    try {
      final response = await _get('/api/ios/content', queryParameters: {
        'item_id': itemId,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final content = data['data']?['content']?.toString();
          if (content != null && content.isNotEmpty) {
            return content;
          }
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('iOS 接口获取章节失败: $e');
      }
      return null;
    }
  }

  /// 8. 章节正文接口（普通通道）GET /api/content
  /// [itemId] 章节 ID
  /// [tab] 固定 "小说"
  Future<String?> getNormalChapterContent(
    String itemId, {
    String tab = '小说',
  }) async {
    try {
      final response = await _get('/api/content', queryParameters: {
        'tab': tab,
        'item_id': itemId,
      });

      if (response != null && response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data is Map && (data['code'] == 200 || data['code'] == 0)) {
          final content = data['data']?['content']?.toString();
          if (content != null && content.isNotEmpty) {
            return content;
          }
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('普通接口获取章节失败: $e');
      }
      return null;
    }
  }

  /// 获取单个章节内容（优先 iOS 通道，回退普通通道）
  /// [itemId] 章节 ID
  Future<String?> getChapterContent(String itemId) async {
    final content = await getIosChapterContent(itemId);
    if (content != null && content.isNotEmpty) {
      return content;
    }
    return getNormalChapterContent(itemId);
  }

  /// 获取书籍封面图片数据
  /// [bookId] 书籍 ID
  Future<List<int>?> getBookCover(String bookId) async {
    final book = await getBookDetail(bookId);
    if (book?.thumbUrl == null || book!.thumbUrl!.isEmpty) {
      return null;
    }

    try {
      final response = await _client
          .get(Uri.parse(book.thumbUrl!))
          .timeout(timeout);

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

  /// 解析搜索结果
  List<Book> _parseSearchResults(Map<String, dynamic> data) {
    final books = <Book>[];
    try {
      final searchTabs = data['data']?['search_tabs'] as List?;
      if (searchTabs != null) {
        for (var tab in searchTabs) {
          if (tab['tab_type'] == 3) {
            final tabData = tab['data'] as List?;
            if (tabData != null) {
              for (var item in tabData) {
                final bookDataList = item['book_data'] as List?;
                if (bookDataList != null) {
                  for (var bookData in bookDataList) {
                    if (bookData is Map) {
                      books.add(Book.fromSearchJson(Map<String, dynamic>.from(bookData)));
                    }
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('解析搜索结果失败: $e');
      }
    }
    return books;
  }

  /// 请求头
  Map<String, String> _getHeaders() {
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
    };
  }

  void dispose() {
    _client.close();
  }
}
