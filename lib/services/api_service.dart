import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import '../models/chapter.dart';
import 'source_service.dart';

/// API 服务 - 负责与番茄小说 API 交互
class ApiService {
  static const Duration timeout = Duration(seconds: 30);

  final http.Client _client;
  final SourceService _sourceService = SourceService();

  /// 当前使用的域名在 activeSourceUrls 中的索引
  int get _currentUrlIndex => _sourceService.currentUrlIndex;
  set _currentUrlIndex(int val) => _sourceService.currentUrlIndex = val;

  /// 获取当前可用的域名列表
  List<String> get _baseUrls => _sourceService.activeSourceUrls;

  /// 获取当前使用的域名
  String get _baseUrl {
    return _sourceService.currentActiveUrl ?? 'https://bk.yydjtc.cn';
  }

  ApiService() : _client = http.Client() {
    // 确保 SourceService 已初始化（最好在 main.dart 中做，这里尝试补救）
    _sourceService.initialize();
  }

  /// 搜索书籍
  /// [keyword] 搜索关键词
  /// [offset] 分页偏移量，默认为 0
  /// 返回书籍列表
  Future<List<Book>> searchBooks(String keyword, {int offset = 0}) async {
    final encodedKeyword = Uri.encodeComponent(keyword);
    final url =
        '$_baseUrl/api/search?key=$encodedKeyword&tab_type=3&offset=$offset';

    try {
      final response = await _client
          .get(Uri.parse(url), headers: _getHeaders())
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          return _parseSearchResults(data);
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取发现/推荐书籍（榜单）
  /// [bdtype] 榜单类型：巅峰榜、出版榜、热搜榜、黑马榜、爆更榜、推荐榜、完结榜
  /// [gender] 性别：1=男频，2=女频
  /// [page] 页码，从1开始
  Future<List<Book>> discoverBooks({
    String bdtype = '巅峰榜',
    int gender = 1,
    int page = 1,
  }) async {
    final encodedTab = Uri.encodeComponent('小说');
    final encodedBdtype = Uri.encodeComponent(bdtype);
    final url =
        '$_baseUrl/api/discover?tab=$encodedTab&bdtype=$encodedBdtype&gender=$gender&is_ranking=1&page=$page';

    try {
      final response = await _client
          .get(Uri.parse(url), headers: _getHeaders())
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          final bookList = data['data'] as List?;
          if (bookList != null) {
            return bookList.map((item) => Book.fromDiscoverJson(item)).toList();
          }
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取发现/推荐书籍（按分类标签）
  /// [type] 分类类型 ID
  /// [gender] 性别：1=男频，2=女频
  /// [page] 页码，从1开始
  Future<List<Book>> discoverByType({
    required int type,
    int gender = 1,
    int page = 1,
  }) async {
    final encodedTab = Uri.encodeComponent('小说');
    final url =
        '$_baseUrl/api/discover?tab=$encodedTab&type=$type&gender=$gender&genre_type=0&page=$page';

    try {
      final response = await _client
          .get(Uri.parse(url), headers: _getHeaders())
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          final bookList = data['data'] as List?;
          if (bookList != null) {
            return bookList.map((item) => Book.fromDiscoverJson(item)).toList();
          }
        }
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 获取书籍详情
  /// [bookId] 书籍 ID
  Future<Book?> getBookDetail(String bookId) async {
    final url = '$_baseUrl/api/detail?book_id=$bookId';

    try {
      final response = await _requestWithRetry(url);

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          final bookData = data['data']?['data'];
          if (bookData != null) {
            return Book.fromDetailJson(bookData);
          }
        }
      }
      return null;
    } catch (e) {
      print('获取书籍详情失败: $e');
      return null;
    }
  }

  /// 获取书籍章节目录
  /// [bookId] 书籍 ID
  Future<List<Chapter>> getBookChapters(String bookId) async {
    // 优先使用简化目录接口
    final chapters = await _getDirectoryChapters(bookId);
    if (chapters.isNotEmpty) {
      return chapters;
    }

    // 回退到完整目录接口
    return _getBookChapters(bookId);
  }

  /// 带重试和域名故障转移机制的 HTTP 请求
  /// [path] API 路径（不含域名部分）
  /// [maxRetries] 每个域名的最大尝试次数
  Future<http.Response?> _requestWithRetry(
    String url, {
    int maxRetries = 2,
  }) async {
    // 从 URL 中提取路径部分（用于域名切换时重建 URL）
    final originalUri = Uri.parse(url);
    final pathWithQuery = originalUri.hasQuery
        ? '${originalUri.path}?${originalUri.query}'
        : originalUri.path;

    // 尝试所有可用域名
    final urls = _baseUrls;
    if (urls.isEmpty) return null;

    for (int urlIndex = _currentUrlIndex; urlIndex < urls.length; urlIndex++) {
      final currentUrl = '${urls[urlIndex]}$pathWithQuery';

      for (int retry = 0; retry < maxRetries; retry++) {
        try {
          final response = await _client
              .get(Uri.parse(currentUrl), headers: _getHeaders())
              .timeout(timeout);

          if (response.statusCode == 200) {
            // 请求成功，更新当前有效域名索引
            if (urlIndex != _currentUrlIndex) {
              print('域名切换成功: ${urls[_currentUrlIndex]} -> ${urls[urlIndex]}');
              _currentUrlIndex = urlIndex;
            }
            return response;
          }

          // 如果是 5xx 错误，等待后重试
          if (response.statusCode >= 500) {
            print('服务器错误 ${response.statusCode}, 重试 ${retry + 1}/$maxRetries');
            await Future.delayed(Duration(seconds: retry + 1));
            continue;
          }

          return response; // 其他状态码直接返回
        } catch (e) {
          print('请求失败 [${urls[urlIndex]}] (重试 ${retry + 1}/$maxRetries): $e');
          if (retry < maxRetries - 1) {
            await Future.delayed(Duration(seconds: retry + 1));
          }
        }
      }

      // 当前域名所有重试都失败，尝试下一个域名
      if (urlIndex < urls.length - 1) {
        print('域名 ${urls[urlIndex]} 不可用，切换到 ${urls[urlIndex + 1]}');
      }
    }

    // 所有域名都失败，重置为第一个域名（下次请求重新开始尝试）
    _currentUrlIndex = 0;
    return null;
  }

  /// 使用简化目录接口获取章节
  Future<List<Chapter>> _getDirectoryChapters(String bookId) async {
    final url = '$_baseUrl/api/directory?book_id=$bookId';

    try {
      final response = await _requestWithRetry(url);

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
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
      print('获取简化目录失败: $e');
      return [];
    }
  }

  /// 使用完整目录接口获取章节
  Future<List<Chapter>> _getBookChapters(String bookId) async {
    final url = '$_baseUrl/api/book?book_id=$bookId';

    try {
      final response = await _requestWithRetry(url);

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          final innerData = data['data']?['data'];
          if (innerData != null) {
            // 从 chapterListWithVolume 获取
            final volumeList = innerData['chapterListWithVolume'] as List?;
            if (volumeList != null && volumeList.isNotEmpty) {
              final chapters = <Chapter>[];
              for (var volume in volumeList) {
                if (volume is List) {
                  for (var chapter in volume) {
                    if (chapter is Map) {
                      chapters.add(
                        Chapter.fromBookJson(
                          Map<String, dynamic>.from(chapter),
                        ),
                      );
                    }
                  }
                }
              }
              if (chapters.isNotEmpty) return chapters;
            }

            // 从 allItemIds 获取
            final allIds = innerData['allItemIds'] as List?;
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
        }
      }
      return [];
    } catch (e) {
      print('获取完整目录失败: $e');
      return [];
    }
  }

  /// 获取单个章节内容
  /// [itemId] 章节 ID
  Future<String?> getChapterContent(String itemId) async {
    // 优先使用 iOS 接口
    var content = await _getIosChapterContent(itemId);
    if (content != null && content.isNotEmpty) {
      return content;
    }

    // 回退到普通接口
    return _getNormalChapterContent(itemId);
  }

  /// 使用 iOS 接口获取章节内容
  Future<String?> _getIosChapterContent(String itemId) async {
    final url = '$_baseUrl/api/ios/content?item_id=$itemId';

    try {
      final response = await _client
          .get(Uri.parse(url), headers: _getHeaders())
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          return data['data']?['content']?.toString();
        }
      }
      return null;
    } catch (e) {
      print('iOS 接口获取章节失败: $e');
      return null;
    }
  }

  /// 使用普通接口获取章节内容
  Future<String?> _getNormalChapterContent(String itemId) async {
    final encodedTab = Uri.encodeComponent('小说');
    final url = '$_baseUrl/api/content?tab=$encodedTab&item_id=$itemId';

    try {
      final response = await _client
          .get(Uri.parse(url), headers: _getHeaders())
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 200) {
          return data['data']?['content']?.toString();
        }
      }
      return null;
    } catch (e) {
      print('普通接口获取章节失败: $e');
      return null;
    }
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
      print('获取封面失败: $e');
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
                    books.add(Book.fromSearchJson(bookData));
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      print('解析搜索结果失败: $e');
    }

    return books;
  }

  /// 获取请求头
  Map<String, String> _getHeaders() {
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Accept-Encoding': 'gzip, deflate', // 禁用 br 压缩，提高稳定性
      'Connection': 'keep-alive',
    };
  }

  /// 关闭客户端
  void dispose() {
    _client.close();
  }
}
