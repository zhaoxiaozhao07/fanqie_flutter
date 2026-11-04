import 'fanqie_mobile_gateway.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/discovery.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import 'font_decryptor.dart';
import 'reader_cache_service.dart';
import 'online_chapter.dart';
import 'online_illustration_store.dart';

/// 番茄小说内置后端引擎
/// 直接请求已验证的官方接口，不依赖旧第三方代理节点：
/// - 搜索服务 (novel.snssdk.com 接口对接与字体解密)
/// - 官方动态分类元数据与书库多维筛选；不以关键词搜索伪造榜单
/// - 书籍详情与双向卷/章节目录智能解析 (提取 window.__INITIAL_STATE__)
/// - 章节正文阅读与本地持久化磁盘缓存
/// - 高性能并发下载接口（由后端引擎控制并发度与持久化，前端不设人为限速与批次延迟）
class FanqieBackendEngine {
  static const Duration timeout = Duration(seconds: 25);
  static const String defaultUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const String dalvikUserAgent = 'Dalvik/2.1.0 (Linux; U; Android 10)';

  FanqieBackendEngine({
    http.Client? client,
    ReaderCacheService? cache,
    Future<String?> Function(String)? chapterLoader,
    Future<OnlineChapter?> Function(String)? chapterDocumentLoader,
  }) : _client = client ?? http.Client(),
       readerCache = cache ?? ReaderCacheService(),
       _chapterLoader = chapterLoader,
       _chapterDocumentLoader = chapterDocumentLoader;

  final http.Client _client;
  final ReaderCacheService readerCache;
  final Future<String?> Function(String)? _chapterLoader;
  final Future<OnlineChapter?> Function(String)? _chapterDocumentLoader;
  late final onlineImages = OnlineIllustrationStore(readerCache, _client);
  final ValueNotifier<String?> cacheWarning = ValueNotifier(null);

  Future<void> _cacheForReading(
    String bookId,
    String itemId,
    String content,
  ) async {
    try {
      await readerCache.write(bookId, itemId, content);
      final policy = await ReaderCachePolicy.load();
      await readerCache.trim(policy.maxBytes);
      cacheWarning.value = null;
    } on FileSystemException {
      cacheWarning.value = '正文已加载，但离线缓存写入失败，请检查存储空间';
    }
  }

  // 内存详情缓存（包含 chapterListWithVolume 和 itemIds）
  final Map<String, Map<String, dynamic>> _detailCache = {};

  Map<String, String> get _browserHeaders => {
    'User-Agent': defaultUserAgent,
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': 'https://fanqienovel.com/',
  };

  /// 缓存目录
  Future<Directory> _getChapterCacheDir() async {
    Directory baseDir;
    try {
      baseDir = await getTemporaryDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final dir = Directory('${baseDir.path}/fanqie_cache/chapters');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _getChapterCacheFile(String itemId) async {
    final dir = await _getChapterCacheDir();
    return File('${dir.path}/${ReaderCacheService.segment(itemId)}.txt');
  }

  /// 获取书籍离线持久化存储目录 (持久保存在文档目录，支持离线阅读与快速读取)
  Future<Directory> getOfflineBookDir(String bookId) async {
    final cleanId = ReaderCacheService.segment(bookId.trim());
    final baseDir = await readerCache.documents();
    final dir = Directory('${baseDir.path}/offline_books/$cleanId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 获取指定书籍的离线章节文件
  Future<File> getOfflineChapterFile(String bookId, String itemId) async {
    final dir = await getOfflineBookDir(bookId);
    return File('${dir.path}/${ReaderCacheService.segment(itemId)}.txt');
  }

  /// 检查某本书的某个章节是否已离线缓存
  Future<bool> isChapterOffline(String bookId, String itemId) async {
    return await readerCache.read(bookId, itemId) != null;
  }

  /// 直接读取离线章节内容（若无离线则返回 null）
  Future<String?> getOfflineChapterContent(String bookId, String itemId) async {
    return readerCache.read(bookId, itemId);
  }

  /// 获取指定书籍已离线的章节数
  Future<int> getOfflineChapterCount(String bookId) async {
    final names = <String>{};
    try {
      for (final dir in [
        await getOfflineBookDir(bookId),
        Directory(
          '${(await readerCache.temporaryRoot()).path}/${ReaderCacheService.segment(bookId)}',
        ),
      ]) {
        if (!await dir.exists()) continue;
        await for (final file in dir.list(followLinks: false)) {
          if (file is File &&
              file.path.endsWith('.txt') &&
              ReaderCacheService.isReadable(await file.readAsString())) {
            names.add(file.uri.pathSegments.last);
          }
        }
      }
    } catch (_) {}
    return names.length;
  }

  /// 1. 搜索书籍接口
  Future<List<Book>> searchBooks(
    String keyword, {
    int offset = 0,
    int count = 20,
  }) async {
    final cleanKeyword = keyword.trim();
    if (cleanKeyword.isEmpty) return [];

    final uri = Uri.parse(
      'https://novel.snssdk.com/api/novel/channel/homepage/search/search/v1/?'
      'q=${Uri.encodeComponent(cleanKeyword)}&aid=1967&offset=$offset&count=$count&tab_type=3',
    );

    try {
      final response = await _client
          .get(uri, headers: {'User-Agent': dalvikUserAgent})
          .timeout(timeout);

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        if (data['code'] != 0) {
          throw const FanqieApiException('搜索暂时不可用，请稍后重试');
        }
        final retData = data['data']?['ret_data'] as List?;
        if (retData == null) {
          throw const FanqieApiException('搜索响应不完整，请稍后重试');
        }

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
              thumbUrl:
                  item['thumb_url']?.toString() ??
                  item['audio_thumb_uri']?.toString(),
              wordNumber:
                  int.tryParse(
                    item['word_count']?.toString() ??
                        item['word_number']?.toString() ??
                        '0',
                  ) ??
                  0,
              serialCount:
                  int.tryParse(
                    item['serial_count']?.toString() ??
                        item['chapter_count']?.toString() ??
                        '0',
                  ) ??
                  0,
              creationStatus: creationStatus,
              tags: tags,
              score: item['score']?.toString(),
            ),
          );
        }
        return books;
      }
    } catch (_) {
      throw const FanqieApiException('搜索暂时不可用，请稍后重试');
    }
    throw const FanqieApiException('搜索暂时不可用，请稍后重试');
  }

  /// Metadata is fetched per audience. Last successful metadata is an explicit
  /// offline fallback, never a hard-coded or guessed ID-to-name table.
  Future<CategoryCatalog> getCategories({int gender = 1}) async {
    final serverGender = LibraryFilters.serverGender(gender);
    final cacheKey = 'library_categories_v1_$serverGender';
    try {
      final uri = Uri.https(
        'fanqienovel.com',
        '/api/author/book/category_list/v0/',
        {'gender': '$serverGender'},
      );
      final response = await _client
          .get(uri, headers: _browserHeaders)
          .timeout(timeout);
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode != 200 ||
          body is! Map ||
          body['code'] != 0 ||
          body['data'] is! List) {
        throw const FormatException('Invalid category response');
      }
      final categories = LibraryCategory.parseList(body['data'] as List);
      if (categories.isEmpty) {
        throw const FormatException('Empty category metadata');
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          cacheKey,
          jsonEncode(categories.map((c) => c.toJson()).toList()),
        );
      } catch (_) {
        /* Metadata remains usable if local storage is unavailable. */
      }
      return CategoryCatalog(categories);
    } catch (_) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(cacheKey);
        if (raw != null) {
          final data = jsonDecode(raw);
          if (data is List) {
            final categories = LibraryCategory.parseList(data);
            if (categories.isNotEmpty) {
              return CategoryCatalog(categories, isCached: true);
            }
          }
        }
      } catch (_) {
        /* Corrupt cache must not invent category choices. */
      }
      throw const FanqieApiException('分类加载失败，请联网重试');
    }
  }

  /// A successful empty page terminates pagination. Failures do not silently
  /// fall back to unrelated search results or drop the selected filters.
  Future<LibraryPage> discoverBooks({
    int categoryId = -1,
    int gender = 1,
    int creationStatus = -1,
    int wordCount = -1,
    int sort = 0,
    int page = 1,
  }) async {
    final serverGender = LibraryFilters.serverGender(gender);
    if ((categoryId != -1 && categoryId <= 0) ||
        page < 1 ||
        !LibraryFilters.statuses.containsKey(creationStatus) ||
        !LibraryFilters.wordCounts.containsKey(wordCount) ||
        !LibraryFilters.sorts.containsKey(sort)) {
      throw ArgumentError('无效的书库筛选条件');
    }
    final uri =
        Uri.https('fanqienovel.com', '/api/author/library/book_list/v0/', {
          'page_count': '20',
          'page_index': '${page - 1}',
          'gender': '$serverGender',
          'category_id': '$categoryId',
          'creation_status': '$creationStatus',
          'word_count': '$wordCount',
          'book_type': '-1',
          'sort': '$sort',
        });
    try {
      final response = await _client
          .get(uri, headers: _browserHeaders)
          .timeout(timeout);
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode != 200 ||
          body is! Map ||
          body['code'] != 0 ||
          body['data'] is! Map) {
        throw const FormatException('Invalid library response');
      }
      final data = body['data'] as Map;
      final items = data['book_list'];
      if (items is! List) throw const FormatException('Missing book list');
      final books = <Book>[];
      final seen = <String>{};
      for (final item in items) {
        if (item is! Map) continue;
        final id = item['book_id']?.toString() ?? '';
        final name = FontDecryptor.decryptLibText(
          item['book_name']?.toString() ?? '',
        );
        if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
        final category = FontDecryptor.decryptLibText(
          item['category']?.toString() ?? '',
        );
        books.add(
          Book(
            bookId: id,
            bookName: name,
            author: FontDecryptor.decryptLibText(
              item['author']?.toString() ?? '',
            ),
            abstract: FontDecryptor.decryptLibText(
              item['abstract']?.toString() ?? '',
            ),
            category: category.isEmpty ? null : category,
            thumbUrl:
                item['thumb_url']?.toString() ?? item['thumb_uri']?.toString(),
            wordNumber: FontDecryptor.parseIntSafe(item['word_count']),
            serialCount: FontDecryptor.parseIntSafe(
              item['serial_count'] ?? item['chapter_count'],
            ),
            creationStatus:
                FontDecryptor.parseIntSafe(item['creation_status'], 1) == 1
                ? '连载中'
                : '完结',
            tags: category.isEmpty ? const [] : [category],
            score: item['score']?.toString(),
          ),
        );
      }
      if (items.isNotEmpty && books.isEmpty) {
        throw const FormatException('Invalid books');
      }
      return LibraryPage(
        List.unmodifiable(books),
        hasMore:
            books.isNotEmpty &&
            (data['has_more'] == true || data['has_more'] == 1),
        total: int.tryParse(data['total_count']?.toString() ?? ''),
      );
    } catch (_) {
      throw const FanqieApiException('书库加载失败，请稍后重试');
    }
  }

  /// 3. 书籍详情接口
  Future<Book?> getBookDetail(String bookId) async {
    final cleanId = bookId.trim();
    if (cleanId.isEmpty) return null;

    final uri = Uri.parse('https://fanqienovel.com/page/$cleanId');
    try {
      final response = await _client
          .get(uri, headers: _browserHeaders)
          .timeout(timeout);
      if (response.statusCode == 200) {
        final html = utf8.decode(response.bodyBytes);
        final state = _extractInitialState(html);
        if (state != null && state['page'] is Map) {
          final p = state['page'] as Map<String, dynamic>;
          if (p['bookId']?.toString() != cleanId ||
              (p['bookName']?.toString() ?? '').isEmpty) {
            return null;
          }

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

          final decryptedName = FontDecryptor.decryptText(
            p['bookName']?.toString() ?? '',
          );
          final decryptedAuthor = FontDecryptor.decryptText(
            p['author']?.toString() ?? '',
          );
          final decryptedAbstract = FontDecryptor.decryptText(
            p['abstract']?.toString() ?? '',
          );
          final decryptedCat = FontDecryptor.decryptText(cat);

          final itemIds =
              (p['itemIds'] as List?)?.map((e) => e.toString()).toList() ?? [];
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
            serialCount:
                int.tryParse(
                  p['chapterTotal']?.toString() ?? '${itemIds.length}',
                ) ??
                itemIds.length,
            creationStatus: creationStatus,
            tags: decryptedCat.isNotEmpty ? [decryptedCat] : [],
            score: p['score']?.toString(),
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

    // 0. 优先检查本地离线/本地导入书籍的 directory.json
    try {
      final bookDir = await getOfflineBookDir(cleanId);
      final dirFile = File('${bookDir.path}/directory.json');
      if (await dirFile.exists()) {
        final raw = await dirFile.readAsString();
        final List<dynamic> list = json.decode(raw);
        return list
            .map((e) => Chapter.fromDirectoryJson(e as Map<String, dynamic>, 0))
            .toList();
      }
    } catch (_) {}

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
                final itemId =
                    ch['itemId']?.toString() ?? ch['item_id']?.toString() ?? '';
                final title = FontDecryptor.decryptText(
                  ch['title']?.toString() ?? '',
                );
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
              'itemId':
                  ch['itemId']?.toString() ?? ch['item_id']?.toString() ?? '',
              'title': FontDecryptor.decryptText(ch['title']?.toString() ?? ''),
              'realChapterOrder':
                  int.tryParse(ch['realChapterOrder']?.toString() ?? '1') ?? 1,
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

  final FanqieMobileGateway _mobileGateway = FanqieMobileGateway();

  Future<OnlineChapter?> _fetchDocument(String id) async {
    if (_chapterDocumentLoader != null) return _chapterDocumentLoader(id);
    if (_chapterLoader != null) {
      final text = await _chapterLoader(id);
      return text == null ? null : OnlineChapter(text);
    }
    return _mobileGateway.fetchChapterDocument(id);
  }

  /// Bypass *all* text caches only to recover missing image metadata. Never
  /// replace an existing chapter's text/IDs/positions with a newer edition.
  Future<void> repairChapterImages(
    String bookId,
    String chapterId,
    String text, {
    bool permanent = false,
  }) async {
    if (bookId.startsWith('local_')) return;
    if (!await onlineImages.hasSources(bookId, chapterId, text)) {
      final document = await _fetchDocument(chapterId);
      if (document == null) throw const FormatException('插图信息获取失败，请联网重试');
      if (document.text.trim() != text.trim()) {
        throw const FormatException('线上正文已变化，未改动原书，请勿删除阅读数据');
      }
      await onlineImages.saveSources(bookId, chapterId, document);
    }
    final protect =
        permanent ||
        await (await getOfflineChapterFile(bookId, chapterId)).exists();
    try {
      await onlineImages.hydrate(bookId, chapterId, text, permanent: protect);
    } on FormatException {
      // Signed CDN URLs can expire while a failed image stays in the sidecar.
      // Refresh only from the same full chapter and keep the old text intact.
      final fresh = await _fetchDocument(chapterId);
      if (fresh == null || fresh.text.trim() != text.trim()) rethrow;
      await onlineImages.saveSources(bookId, chapterId, fresh, replace: true);
      await onlineImages.hydrate(bookId, chapterId, text, permanent: protect);
    }
  }

  /// 6. 获取章节正文内容（支持书籍离线优先、阅读自动持久化与移动端突破锁章）
  Future<String?> getChapterContent(String itemId, {String? bookId}) async {
    final cleanId = itemId.trim();
    if (cleanId.isEmpty) return null;

    final cacheBook = bookId?.isNotEmpty == true ? bookId! : '_shared';
    final offline = await readerCache.read(cacheBook, cleanId);
    if (offline != null) return offline;
    // Imported book IDs never fall through to a remote content endpoint.
    if (cacheBook.startsWith('local_')) return null;

    // 2. 检查通用本地缓存
    try {
      final cacheFile = await _getChapterCacheFile(cleanId);
      if (await cacheFile.exists()) {
        final cached = await cacheFile.readAsString();
        if (cached.length > 50 && ReaderCacheService.isReadable(cached)) {
          await _cacheForReading(cacheBook, cleanId, cached);
          return cached;
        }
      }
    } catch (_) {}

    // 3. 优先通过移动端通道获取完整无锁正文 (对接 reading.snssdk.com 移动端专属接口)
    try {
      final document = await _fetchDocument(cleanId);
      final mobileContent = document?.text;
      if (mobileContent != null &&
          ReaderCacheService.isReadable(mobileContent)) {
        // 成功获取完整正文，持久化缓存（实现无下载时的阅读自动缓存）
        await _cacheForReading(cacheBook, cleanId, mobileContent);
        try {
          await onlineImages.saveSources(cacheBook, cleanId, document!);
        } on FileSystemException {
          cacheWarning.value = '正文已加载，但插图信息保存失败，请检查存储空间';
        }
        return mobileContent;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieBackendEngine mobile fetchChapter failed: $e');
      }
    }

    // The web reader only guarantees a preview. Never return it as chapter
    // content or persist it as a successfully downloaded/offline chapter.
    return null;
  }

  /// 7. 高性能全章节并发下载接口（由内置后端引擎直接控制，无前端人为限速与批次延迟）
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int current, int total, String message)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 12,
  }) async {
    final total = chapters.length;
    if (total == 0) return;

    final offlineDir = await getOfflineBookDir(bookId);
    int completed = 0;
    int nextIndex = 0;
    int failures = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() == true) return;

        int currentIndex;
        if (nextIndex >= total) return;
        currentIndex = nextIndex++;

        final chapter = chapters[currentIndex];
        final offlineFile = File(
          '${offlineDir.path}/${ReaderCacheService.segment(chapter.itemId)}.txt',
        );

        // 检查是否已有离线文件
        bool hasCached = false;
        try {
          if (await offlineFile.exists()) {
            hasCached = ReaderCacheService.isReadable(
              await offlineFile.readAsString(),
            );
          }
        } catch (_) {}

        if (!hasCached) {
          String? content;
          for (int retry = 0; retry < 2; retry++) {
            if (isCancelled?.call() == true) return;
            try {
              content = await getChapterContent(chapter.itemId, bookId: bookId);
              if (ReaderCacheService.isReadable(content)) {
                break;
              }
            } catch (_) {}
            if (retry < 1) {
              await Future.delayed(Duration(milliseconds: 100 * (retry + 1)));
            }
          }

          if (isCancelled?.call() == true) return;
          if (ReaderCacheService.isReadable(content)) {
            try {
              final staged = File('${offlineFile.path}.pending');
              await staged.writeAsString(content!, flush: true);
              await staged.rename(offlineFile.path);
            } catch (_) {
              failures++;
            }
          } else {
            failures++;
          }
        }

        // Even already downloaded text may be from pre-image versions.
        // A missing image is a retryable failure, not a completed download.
        if (isCancelled?.call() == true) return;
        try {
          if (await offlineFile.exists()) {
            final text = await offlineFile.readAsString();
            if (ReaderCacheService.isReadable(text)) {
              await repairChapterImages(
                bookId,
                chapter.itemId,
                text,
                permanent: true,
              );
            }
          }
        } catch (_) {
          failures++;
        }
        completed++;
        onProgress?.call(completed, total, '正在下载: ${chapter.title}');
      }
    }

    final workerCount = concurrency.clamp(1, total);
    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
    if (failures > 0 && isCancelled?.call() != true) {
      throw StateError('$failures 处正文或插图未能完整下载，已保留成功内容，请重试');
    }
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

    final reg = RegExp(
      r'window\.__INITIAL_STATE__\s*=\s*(\{.+?\});',
      dotAll: true,
    );
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
