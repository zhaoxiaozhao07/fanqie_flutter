import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import 'font_decryptor.dart';

/// 番茄小说内置后端引擎
/// 原 fanqie-backend 服务完整移植至 Dart，直接在前端内置运行：
/// - 搜索服务 (novel.snssdk.com 接口对接与字体解密)
/// - 发现/书库多维筛选与榜单浏览 (fanqienovel.com/api/author/library 与动态降级检索)
/// - 书籍详情与双向卷/章节目录智能解析 (提取 window.__INITIAL_STATE__)
/// - 章节正文阅读与本地持久化磁盘缓存
/// - 高性能并发下载接口（由后端引擎控制并发度与持久化，前端不设人为限速与批次延迟）
class FanqieBackendEngine {
  static const Duration timeout = Duration(seconds: 25);
  static const String defaultUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String dalvikUserAgent = 'Dalvik/2.1.0 (Linux; U; Android 10)';

  static const String defaultCookie =
      'novel_web_id=7681901428650247732; ttwid=1%7CkNjzN_Ynh0Ldvq6ZsJ1XOGEtGdkmNVkY3Yf0RiQ2QFQ%7C1788583129%7Caeac7d8d47e102419b7794dc3b2d6074a57a447772af6dbffc3bd1c303981dc6';

  static const Map<int, String> categoryMap = {
    1: "都市",
    2: "修仙",
    3: "现代言情",
    4: "校园",
    5: "古代言情",
    7: "玄幻",
    8: "科幻",
    10: "悬疑",
    11: "乡村",
    12: "历史",
    15: "体育",
    16: "武侠",
    17: "鉴宝",
    19: "系统",
    20: "神豪",
    23: "种田",
    24: "快穿",
    25: "赘婿",
    26: "神医",
    27: "战神",
    28: "萌宝",
    29: "总裁",
    30: "宠妻",
    32: "幻想言情",
    34: "婚恋",
    36: "重生",
    37: "穿越",
    39: "二次元",
    40: "海岛",
    42: "奶爸",
    43: "娱乐圈",
    44: "空间",
    61: "推理",
    66: "洪荒",
    67: "三国",
    68: "末世",
    69: "直播",
    70: "无限流",
    71: "诸天万界",
    72: "兽世",
    73: "大唐",
    74: "宠物",
    75: "外卖",
    76: "清穿",
    77: "星际",
    78: "美食",
    79: "年代",
    80: "剑道",
    81: "盗墓",
    82: "学霸",
    83: "公主",
    84: "皇后",
    85: "王妃",
    86: "女强",
    87: "皇叔",
    88: "嫡女",
    91: "多女主",
    93: "扮猪吃虎",
    94: "团宠",
    95: "虐文",
    96: "甜宠",
    100: "灵异",
    124: "都市修真",
    125: "家庭",
    126: "明朝",
    127: "职场",
    246: "宫斗宅斗",
    247: "医术",
    248: "玄幻言情",
    253: "古言脑洞",
    257: "玄幻脑洞",
    258: "传统玄幻",
    259: "奇幻仙侠",
    261: "都市日常",
    262: "都市脑洞",
    263: "都市种田",
    265: "先婚后爱",
    266: "马甲",
    267: "现言脑洞",
    272: "历史脑洞",
    273: "历史古代",
    275: "双男主",
    504: "抗战谍战",
    539: "悬疑脑洞",
    704: "双女主",
    718: "动漫衍生",
    745: "星光璀璨",
    746: "游戏体育",
    747: "女频悬疑",
    748: "豪门总裁",
    749: "青春甜宠",
    750: "职场婚恋",
    751: "悬疑灵异",
    1014: "都市高武",
    1015: "女频衍生",
    1016: "男频衍生",
    1017: "民国言情",
    1139: "古风世情",
    1140: "东方仙侠",
    1141: "西方奇幻",
  };

  static const List<String> categoryFallbackOrder = [
    "玄幻", "都市", "修仙", "科幻", "历史", "悬疑", "言情", "战神",
    "重生", "穿越", "种田", "游戏", "末世", "系统", "同人", "二次元"
  ];

  static const Map<String, String> rankKeywordMap = {
    "巅峰榜": "高分",
    "热搜榜": "热门",
    "黑马榜": "新书",
    "爆更榜": "连载",
    "推荐榜": "精选",
    "完结榜": "完结",
    "出版榜": "出版",
  };

  static final FanqieBackendEngine _instance = FanqieBackendEngine._internal();
  factory FanqieBackendEngine({http.Client? client}) {
    if (client != null) {
      _instance._client = client;
    }
    return _instance;
  }
  FanqieBackendEngine._internal() : _client = http.Client();

  http.Client _client;

  // 内存详情缓存（包含 chapterListWithVolume 和 itemIds）
  final Map<String, Map<String, dynamic>> _detailCache = {};

  Map<String, String> get _browserHeaders => {
    'User-Agent': defaultUserAgent,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': 'https://fanqienovel.com/',
    'Cookie': defaultCookie,
  };

  /// 缓存目录
  Future<Directory> _getChapterCacheDir() async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory('${tempDir.path}/fanqie_cache/chapters');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _getChapterCacheFile(String itemId) async {
    final dir = await _getChapterCacheDir();
    return File('${dir.path}/$itemId.txt');
  }

  /// 1. 搜索书籍接口
  Future<List<Book>> searchBooks(
    String keyword, {
    int offset = 0,
    int tabType = 3,
    int count = 20,
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return [];

    if (cleanKeyword == 'test_conn') {
      return [
        Book(
          bookId: 'test',
          bookName: '内置引擎已就绪',
          author: 'System',
          abstract: '番茄小说内置后端运行正常',
          category: '系统',
          wordNumber: 0,
          serialCount: 0,
          creationStatus: '连载中',
          tags: ['测试', '内置引擎'],
          score: '10.0',
        ),
      ];
    }

    final uri = Uri.parse(
      'https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?'
      'q=${Uri.encodeComponent(cleanKeyword)}&aid=1967&offset=$offset&count=$count&tab_type=$tabType',
    );

    try {
      final response = await _client.get(
        uri,
        headers: {'User-Agent': dalvikUserAgent},
      ).timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final retData = data['data']?['ret_data'] as List?;
        if (retData == null) return [];

        final books = <Book>[];
        for (final item in retData) {
          if (item is! Map) continue;
          final rawName = item['title'] ?? item['book_name'] ?? '';
          final rawAuthor = item['author'] ?? '';
          final rawAbstract = item['abstract'] ?? '';
          final rawCat = item['category'] ?? '';
          final rawStatus = item['creation_status'];

          String creationStatus = '连载中';
          if (rawStatus != null) {
            final sStr = rawStatus.toString();
            creationStatus = sStr == '1' ? '连载中' : '完结';
          }

          final decryptedCat = FontDecryptor.decryptText(rawCat.toString());
          final tags = decryptedCat.isNotEmpty ? [decryptedCat] : <String>[];

          books.add(
            Book(
              bookId: item['book_id']?.toString() ?? '',
              bookName: FontDecryptor.decryptText(rawName.toString()),
              author: FontDecryptor.decryptText(rawAuthor.toString()),
              abstract: FontDecryptor.decryptText(rawAbstract.toString()),
              category: decryptedCat,
              thumbUrl: item['thumb_url']?.toString() ?? item['audio_thumb_uri']?.toString(),
              wordNumber: int.tryParse(item['word_count']?.toString() ?? item['word_number']?.toString() ?? '0') ?? 0,
              serialCount: int.tryParse(item['serial_count']?.toString() ?? item['chapter_count']?.toString() ?? '0') ?? 0,
              creationStatus: creationStatus,
              tags: tags,
              score: item['score']?.toString() ?? '9.0',
            ),
          );
        }
        return books;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieBackendEngine search error: $e');
      }
    }
    return [];
  }

  /// 2. 发现/分类/榜单接口
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
    final pageCount = 20;
    final pageIndex = (page - 1).clamp(0, 9999);

    // 性别映射：1=男频(1)，2=女频(0)，-1/0=全部(-1)
    int libGender = -1;
    if (gender == 2) {
      libGender = 0;
    } else if (gender == 1) {
      libGender = 1;
    }

    final libCatId = (type != null && type > 0) ? type : -1;
    final cStatus = creationStatus ?? -1;
    final wCount = wordCount ?? -1;

    // 1. 优先调用番茄官方书库 API（支持完整多维筛选与分页）
    try {
      final queryParams = {
        'page_count': '$pageCount',
        'page_index': '$pageIndex',
        'gender': '$libGender',
        'category_id': '$libCatId',
        'creation_status': '$cStatus',
        'word_count': '$wCount',
        'book_type': '-1',
        'sort': '$sort',
      };
      final uri = Uri.https('fanqienovel.com', '/api/author/library/book_list/v0/', queryParams);
      final response = await _client.get(uri, headers: _browserHeaders).timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final bookList = data['data']?['book_list'] as List?;
        if (bookList != null && bookList.isNotEmpty) {
          final books = <Book>[];
          for (final b in bookList) {
            if (b is! Map) continue;
            final rawName = b['book_name']?.toString() ?? '';
            final rawAuthor = b['author']?.toString() ?? '';
            final rawAbstract = b['abstract']?.toString() ?? '';
            final rawCat = b['category']?.toString() ?? '';
            final catName = FontDecryptor.decryptLibText(rawCat);

            final statusVal = FontDecryptor.parseIntSafe(b['creation_status'], 1);

            books.add(
              Book(
                bookId: b['book_id']?.toString() ?? '',
                bookName: FontDecryptor.decryptLibText(rawName),
                author: FontDecryptor.decryptLibText(rawAuthor),
                abstract: FontDecryptor.decryptLibText(rawAbstract),
                category: catName,
                thumbUrl: b['thumb_url']?.toString() ?? b['thumb_uri']?.toString(),
                wordNumber: FontDecryptor.parseIntSafe(b['word_count']),
                serialCount: FontDecryptor.parseIntSafe(b['serial_count'] ?? b['chapter_count']),
                creationStatus: statusVal == 1 ? '连载中' : '完结',
                tags: catName.isNotEmpty ? [catName] : [],
                score: b['score']?.toString() ?? '9.5',
              ),
            );
          }
          if (books.isNotEmpty) return books;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieBackendEngine discover library API error: $e');
      }
    }

    // 2. 动态关键词搜索降级方案
    final offset = pageIndex * pageCount;
    if (isRanking || (bdtype != null && (type == null || type <= 0))) {
      final rankName = bdtype ?? '巅峰榜';
      String kw = rankKeywordMap[rankName] ?? '热门';
      if (gender == 2) {
        kw = '$kw女频';
      }
      return searchBooks(kw, offset: offset, count: pageCount);
    } else {
      String catName = '都市';
      if (type != null && categoryMap.containsKey(type)) {
        catName = categoryMap[type]!;
      } else if (type != null && type > 0 && type < categoryFallbackOrder.length) {
        catName = categoryFallbackOrder[type];
      } else if (gender == 2) {
        catName = '言情';
      }

      String queryWord = catName;
      if (gender == 2 && !catName.contains('女') && !catName.contains('言情') && !catName.contains('宠')) {
        queryWord = '$catName言情';
      }
      return searchBooks(queryWord, offset: offset, count: pageCount);
    }
  }

  /// 3. 书籍详情接口
  Future<Book?> getBookDetail(String bookId) async {
    final cleanId = bookId.trim();
    if (cleanId.isEmpty) return null;

    final uri = Uri.parse('https://fanqienovel.com/page/$cleanId');
    try {
      final response = await _client.get(uri, headers: _browserHeaders).timeout(timeout);
      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes);
        final state = _extractInitialState(html);
        if (state != null && state['page'] is Map) {
          final p = state['page'] as Map<String, dynamic>;

          String cat = p['category']?.toString() ?? '';
          if (cat.isEmpty && p['categoryV2'] != null) {
            try {
              final catObj = json.decode(p['categoryV2'].toString());
              if (catObj is List && catObj.isNotEmpty && catObj.first is Map) {
                cat = catObj.first['Name']?.toString() ?? '';
              }
            } catch (_) {}
          }

          final statusVal = p['creationStatus'] ?? p['status'] ?? 1;
          final creationStatus = statusVal.toString() == '1' ? '连载中' : '完结';

          final decryptedName = FontDecryptor.decryptText(p['bookName']?.toString() ?? '');
          final decryptedAuthor = FontDecryptor.decryptText(p['author']?.toString() ?? '');
          final decryptedAbstract = FontDecryptor.decryptText(p['abstract']?.toString() ?? '');
          final decryptedCat = FontDecryptor.decryptText(cat);

          final itemIds = (p['itemIds'] as List?)?.map((e) => e.toString()).toList() ?? [];
          final chapterVols = p['chapterListWithVolume'] as List? ?? [];

          // 保存详情元数据以便获取完整目录
          _detailCache[cleanId] = {
            'chapterListWithVolume': chapterVols,
            'allItemIds': itemIds,
          };

          return Book(
            bookId: p['bookId']?.toString() ?? cleanId,
            bookName: decryptedName.isNotEmpty ? decryptedName : '未知书名',
            author: decryptedAuthor.isNotEmpty ? decryptedAuthor : '未知作者',
            abstract: decryptedAbstract,
            category: decryptedCat,
            thumbUrl: p['thumbUrl']?.toString() ?? p['thumbUri']?.toString(),
            wordNumber: int.tryParse(p['wordNumber']?.toString() ?? '0') ?? 0,
            serialCount: int.tryParse(p['chapterTotal']?.toString() ?? '${itemIds.length}') ?? itemIds.length,
            creationStatus: creationStatus,
            tags: decryptedCat.isNotEmpty ? [decryptedCat] : [],
            score: p['score']?.toString() ?? '9.5',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieBackendEngine getBookDetail error: $e');
      }
    }
    return null;
  }

  /// 4. 章节目录接口
  Future<List<Chapter>> getBookDirectory(String bookId) async {
    final cleanId = bookId.trim();
    if (cleanId.isEmpty) return [];

    Map<String, dynamic>? meta = _detailCache[cleanId];
    if (meta == null) {
      await getBookDetail(cleanId);
      meta = _detailCache[cleanId];
    }

    final lists = <Chapter>[];
    if (meta != null) {
      final vols = meta['chapterListWithVolume'] as List?;
      if (vols != null && vols.isNotEmpty) {
        int order = 1;
        for (final vol in vols) {
          if (vol is List) {
            for (final ch in vol) {
              if (ch is Map) {
                final itemId = ch['itemId']?.toString() ?? ch['item_id']?.toString() ?? '';
                final title = FontDecryptor.decryptText(ch['title']?.toString() ?? '');
                if (itemId.isNotEmpty) {
                  lists.add(
                    Chapter(
                      itemId: itemId,
                      title: title.isNotEmpty ? title : '第$order章',
                      order: order++,
                    ),
                  );
                }
              }
            }
          }
        }
      }

      if (lists.isEmpty) {
        final itemIds = meta['allItemIds'] as List?;
        if (itemIds != null) {
          for (int i = 0; i < itemIds.length; i++) {
            lists.add(
              Chapter(
                itemId: itemIds[i].toString(),
                title: '第${i + 1}章',
                order: i + 1,
              ),
            );
          }
        }
      }
    }

    return lists;
  }

  /// 5. 完整书籍信息（含分卷目录备用）
  Future<Map<String, dynamic>?> getBookFull(String bookId) async {
    final cleanId = bookId.trim();
    if (cleanId.isEmpty) return null;

    Map<String, dynamic>? meta = _detailCache[cleanId];
    if (meta == null) {
      await getBookDetail(cleanId);
      meta = _detailCache[cleanId];
    }

    if (meta == null) return null;

    final vols = meta['chapterListWithVolume'] as List? ?? [];
    final cleanedVols = [];
    for (final vol in vols) {
      if (vol is List) {
        final volChapters = [];
        for (final ch in vol) {
          if (ch is Map) {
            volChapters.add({
              'itemId': ch['itemId']?.toString() ?? ch['item_id']?.toString() ?? '',
              'title': FontDecryptor.decryptText(ch['title']?.toString() ?? ''),
              'realChapterOrder': int.tryParse(ch['realChapterOrder']?.toString() ?? '1') ?? 1,
            });
          }
        }
        cleanedVols.add(volChapters);
      }
    }

    return {
      'chapterListWithVolume': cleanedVols,
      'allItemIds': meta['allItemIds'] ?? [],
    };
  }

  /// 6. 获取章节正文内容
  Future<String?> getChapterContent(String itemId) async {
    final cleanId = itemId.trim();
    if (cleanId.isEmpty) return null;

    // 1. 检查持久化本地缓存
    try {
      final cacheFile = await _getChapterCacheFile(cleanId);
      if (await cacheFile.exists()) {
        final cached = await cacheFile.readAsString();
        if (cached.length > 50) {
          return cached;
        }
      }
    } catch (_) {}

    // 2. 网络获取与反爬解密
    final uri = Uri.parse('https://fanqienovel.com/reader/$cleanId');
    for (int retry = 0; retry < 2; retry++) {
      try {
        final response = await _client.get(uri, headers: _browserHeaders).timeout(timeout);
        if (response.statusCode == 200) {
          final html = utf8.decode(response.bodyBytes);
          if (!html.contains('验证码')) {
            final state = _extractInitialState(html);
            if (state != null && state['reader'] is Map) {
              final reader = state['reader'] as Map<String, dynamic>;
              final ch = reader['chapterData'];
              if (ch is Map) {
                final rawContent = ch['content']?.toString() ?? '';
                final isLocked = ch['isChapterLock'] == true;

                if (rawContent.isNotEmpty) {
                  final decrypted = FontDecryptor.decryptHtmlToText(rawContent);
                  if (decrypted.isNotEmpty) {
                    if (isLocked || decrypted.length <= 200) {
                      return '$decrypted\n\n[提示：本章为番茄APP端专享/锁章章节，当前官方Web端仅提供试读预览]';
                    } else {
                      // 完整章节：写入本地持久化缓存
                      try {
                        final cacheFile = await _getChapterCacheFile(cleanId);
                        await cacheFile.writeAsString(decrypted);
                      } catch (_) {}
                      return decrypted;
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('FanqieBackendEngine getChapterContent ($cleanId) retry $retry: $e');
        }
        if (retry < 1) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    }

    return null;
  }

  /// 7. 高性能全章节并发下载接口（由内置后端引擎直接控制，无前端人为限速与批次延迟）
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int current, int total, String message)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 6,
  }) async {
    final total = chapters.length;
    if (total == 0) return;

    int completed = 0;
    int nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) return;

        int currentIndex;
        if (nextIndex >= total) return;
        currentIndex = nextIndex++;

        final chapter = chapters[currentIndex];

        // 检查是否已有缓存
        bool hasCached = false;
        try {
          final cacheFile = await _getChapterCacheFile(chapter.itemId);
          if (await cacheFile.exists() && await cacheFile.length() > 50) {
            hasCached = true;
          }
        } catch (_) {}

        if (!hasCached) {
          for (int retry = 0; retry < 3; retry++) {
            if (isCancelled?.call() == true) return;
            try {
              final content = await getChapterContent(chapter.itemId);
              if (content != null && content.isNotEmpty) {
                break;
              }
            } catch (_) {}
            if (retry < 2) {
              await Future.delayed(Duration(milliseconds: 80 * (retry + 1)));
            }
          }
        }

        completed++;
        onProgress?.call(completed, total, '正在下载: ${chapter.title}');
      }
    }

    final workerCount = concurrency.clamp(1, total);
    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
  }

  /// 提取页面中 window.__INITIAL_STATE__ JSON 对象
  Map<String, dynamic>? _extractInitialState(String html) {
    final idx = html.indexOf('window.__INITIAL_STATE__=');
    if (idx != -1) {
      int start = idx + 'window.__INITIAL_STATE__='.length;
      while (start < html.length &&
          (html[start] == ' ' ||
              html[start] == '\n' ||
              html[start] == '\r' ||
              html[start] == '\t')) {
        start++;
      }
      if (start < html.length && html[start] == '{') {
        int braceCount = 0;
        bool inString = false;
        bool escape = false;
        int end = -1;
        for (int i = start; i < html.length; i++) {
          final c = html[i];
          if (escape) {
            escape = false;
            continue;
          }
          if (c == '\\') {
            escape = true;
            continue;
          }
          if (c == '"') {
            inString = !inString;
            continue;
          }
          if (!inString) {
            if (c == '{') {
              braceCount++;
            } else if (c == '}') {
              braceCount--;
              if (braceCount == 0) {
                end = i + 1;
                break;
              }
            }
          }
        }
        if (end != -1) {
          String jsonStr = html.substring(start, end);
          jsonStr = jsonStr.replaceAll(RegExp(r':\s*undefined\b'), ': null');
          try {
            return json.decode(jsonStr) as Map<String, dynamic>;
          } catch (_) {}
        }
      }
    }

    final reg = RegExp(r'window\.__INITIAL_STATE__\s*=\s*(\{.+?\});', dotAll: true);
    final m = reg.firstMatch(html);
    if (m != null) {
      String jsonStr = m.group(1)!;
      jsonStr = jsonStr.replaceAll(RegExp(r':\s*undefined\b'), ': null');
      try {
        return json.decode(jsonStr) as Map<String, dynamic>;
      } catch (_) {}
    }
    return null;
  }

  void dispose() {
    _client.close();
  }
}
