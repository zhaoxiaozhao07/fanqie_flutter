import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sm3.dart';
import 'package:pointycastle/export.dart' as pc;
import '../models/comment.dart';

/// 番茄小说移动端接口与解密网关 (Fanqie Mobile Gateway)
/// 参考 Fanqie-novel-Downloader (POf-L) 及移动端协议实现：
/// - 彻底突破 Web 端 200 字锁章/试读预览截断限制
/// - 原生实现字节跳动移动端请求签名体系 (x-argus 551 + x-ladon + x-khronos + x-ss-req-ticket)
/// - 原生实现正文动态 AES 密钥协商 (registerkey) 与全量章节内容解密
class FanqieMobileGateway {
  static final FanqieMobileGateway _instance = FanqieMobileGateway._internal();
  factory FanqieMobileGateway() => _instance;
  FanqieMobileGateway._internal();

  static const String readingBaseUrl = 'https://reading.snssdk.com';
  static const String userAgent = 'com.dragon.read';

  // 默认种子设备（与移动端对齐）
  final String _deviceId = '2187355326004404';
  final String _installId = '2187355326270644';

  Map<String, String> _buildCommonParams({Map<String, String>? extra}) {
    return {
      'iid': _installId,
      'device_id': _deviceId,
      'ac': 'wifi',
      'channel': '43536163a',
      'aid': '1967',
      'app_name': 'novelapp',
      'version_code': '70132',
      'version_name': '7.0.1.32',
      'device_platform': 'android',
      'os': 'android',
      'ssmix': 'a',
      'os_version': '10',
      'device_type': 'P30',
      'device_brand': 'realme',
      'update_version_code': '70132',
      'manifest_version_code': '70132',
      'pv_player': '70132',
      'compliance_status': '0',
      if (extra != null) ...extra,
    };
  }

  // 16 字节 AES 密钥协商初始公共密钥
  static final Uint8List _sharedKey = Uint8List.fromList([
    172, 37, 198, 125, 221, 143, 56, 193, 179, 122, 35, 72, 130, 142, 34, 46
  ]);

  // 当前正文解密密钥
  Uint8List? _contentKey = _hexToBytes('3fdb97b8bcdfdd6ccdc11b315d52dfbc');
  int _keyVer = 1783624030;
  Completer<bool>? _refreshKeyCompleter;
  HttpClient? _sharedClient;

  HttpClient get _client {
    _sharedClient ??= HttpClient()
      ..maxConnectionsPerHost = 32
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 8);
    return _sharedClient!;
  }

  /// 获取单章完整正文（突破 200 字锁章限制）
  Future<String?> fetchChapter(String itemId, {int retryCount = 0}) async {
    final cleanId = itemId.trim();
    if (cleanId.isEmpty) return null;

    if (_contentKey == null) {
      await refreshKey();
    }

    final queryParams = _buildCommonParams(extra: {
      'item_id': cleanId,
      'req_type': '1',
    });

    final uri = Uri.https('reading.snssdk.com', '/reading/reader/full/v', queryParams);
    final sigHeaders = signRequest(uri.toString());

    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 8));
      req.headers.set('User-Agent', userAgent);
      for (final e in sigHeaders.entries) {
        req.headers.set(e.key, e.value);
      }

      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isEmpty) {
          if (retryCount < 1) {
            await Future.delayed(const Duration(milliseconds: 150));
            return await fetchChapter(itemId, retryCount: retryCount + 1);
          }
          return null;
        }

        final j = jsonDecode(jsonStr);
        if (j is Map && j['code'] == 0 && j['data'] is Map) {
          final data = j['data'] as Map<String, dynamic>;
          final encContent = data['content']?.toString() ?? '';
          final respKeyVer = int.tryParse(data['key_version']?.toString() ?? '0') ?? 0;

          // 密钥过期或无效处理
          if (encContent == 'Invalid' || (respKeyVer != 0 && respKeyVer != _keyVer)) {
            if (retryCount < 2) {
              await refreshKey();
              return await fetchChapter(itemId, retryCount: retryCount + 1);
            }
            return null;
          }

          if (encContent.isNotEmpty && _contentKey != null) {
            final plainHtml = _decryptAesCbc(encContent, _contentKey!, isCompressed: data['compress_status'] == 1);
            if (plainHtml != null && plainHtml.isNotEmpty) {
              return cleanMobileHtml(plainHtml);
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchChapter error: $e');
      }
      if (retryCount < 2) {
        await Future.delayed(Duration(milliseconds: 150 * (retryCount + 1)));
        return await fetchChapter(itemId, retryCount: retryCount + 1);
      }
    }
    return null;
  }

  /// 批量获取章节正文（高性能接口）
  Future<Map<String, String>> fetchBatchChapters(List<String> itemIds, {String bookId = '0'}) async {
    final results = <String, String>{};
    if (itemIds.isEmpty) return results;

    if (_contentKey == null) {
      await refreshKey();
    }

    final queryParams = _buildCommonParams(extra: {
      'book_id': bookId,
      'item_ids': itemIds.join(','),
      'novel_text_type': '1',
      'req_type': '1',
    });

    final uri = Uri.https('reading.snssdk.com', '/reading/reader/batch_full/v', queryParams);
    final sigHeaders = signRequest(uri.toString());

    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 12));
      req.headers.set('User-Agent', userAgent);
      for (final e in sigHeaders.entries) {
        req.headers.set(e.key, e.value);
      }

      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isNotEmpty) {
          final j = jsonDecode(jsonStr);
          if (j is Map && j['data'] is Map) {
            final dataMap = j['data'] as Map<String, dynamic>;
            for (final entry in dataMap.entries) {
              final itemObj = entry.value;
              if (itemObj is Map) {
                final enc = itemObj['content']?.toString() ?? '';
                if (enc.isNotEmpty && enc != 'Invalid' && _contentKey != null) {
                  final plain = _decryptAesCbc(
                    enc,
                    _contentKey!,
                    isCompressed: itemObj['compress_status'] == 1,
                  );
                  if (plain != null && plain.isNotEmpty) {
                    results[entry.key] = cleanMobileHtml(plain);
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchBatchChapters error: $e');
      }
    }
    return results;
  }

  /// 协商并刷新正文 AES 密钥
  Future<bool> refreshKey() async {
    if (_refreshKeyCompleter != null) {
      return _refreshKeyCompleter!.future;
    }
    final completer = Completer<bool>();
    _refreshKeyCompleter = completer;

    try {
      var id = BigInt.parse(_deviceId);
      final idBytes = Uint8List(16);
      for (int i = 15; i >= 0; i--) {
        idBytes[i] = (id & BigInt.from(0xFF)).toInt();
        id >>= 8;
      }
      final reversedId = Uint8List.fromList(idBytes.reversed.toList());

      final iv = Uint8List(16);
      final rnd = Random();
      for (int i = 0; i < 16; i++) {
        iv[i] = rnd.nextInt(256);
      }

      final padded = _pkcs7Pad(reversedId, 16);
      final encrypted = _aesCbcEncrypt(padded, _sharedKey, iv);

      final content = Uint8List(iv.length + encrypted.length);
      content.setRange(0, iv.length, iv);
      content.setRange(iv.length, content.length, encrypted);

      final plainBody = jsonEncode({'content': base64.encode(content)});
      final gzipped = GZipEncoder().encode(utf8.encode(plainBody));

      final queryParams = _buildCommonParams();

      final uri = Uri.https('reading.snssdk.com', '/reading/crypt/registerkey', queryParams);
      final sigHeaders = signRequest(uri.toString(), body: gzipped);

      final client = HttpClient();
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.headers.set('Content-Encoding', 'gzip');
      for (final e in sigHeaders.entries) {
        req.headers.set(e.key, e.value);
      }
      req.add(gzipped);

      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        final j = jsonDecode(jsonStr);

        final encryptedKey = j['data']?['key']?.toString();
        if (encryptedKey != null && encryptedKey.isNotEmpty) {
          final keyBuf = base64.decode(encryptedKey);
          final kIv = Uint8List.sublistView(keyBuf, 0, 16);
          final kCt = Uint8List.sublistView(keyBuf, 16);

          var decKey = _aesCbcDecrypt(kCt, _sharedKey, kIv);
          final padVal = decKey.last;
          if (padVal > 0 && padVal <= 16) {
            decKey = Uint8List.sublistView(decKey, 0, decKey.length - padVal);
          }
          if (decKey.length == 16) {
            _contentKey = decKey;
            _keyVer = int.tryParse(j['data']?['keyver']?.toString() ?? '0') ?? _keyVer;
            completer.complete(true);
            return true;
          }
        }
      }
      client.close();
      completer.complete(false);
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway refreshKey error: $e');
      }
      completer.complete(false);
      return false;
    } finally {
      _refreshKeyCompleter = null;
    }
  }

  /// 清洗移动端正文 HTML，还原标准排版与标题
  static String cleanMobileHtml(String html) {
    var cleaned = html.replaceAll(RegExp(r'<header[\s\S]*?</header>', caseSensitive: false), '');
    String? title;
    final h1Match = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false).firstMatch(cleaned);
    if (h1Match != null) {
      title = _stripHtml(h1Match.group(1) ?? '').trim();
    }
    final pRegex = RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false);
    final matches = pRegex.allMatches(cleaned);
    final paragraphs = <String>[];
    for (final m in matches) {
      final pText = _stripHtml(m.group(1) ?? '').trim();
      if (pText.isNotEmpty) {
        paragraphs.add(pText);
      }
    }

    // 智能去重：若正文第一段为重复的章节标题，自动剔除
    if (paragraphs.isNotEmpty) {
      final first = paragraphs.first;
      if (title != null && title.isNotEmpty) {
        final cleanFirst = first.replaceAll(RegExp(r'\s+'), '');
        final cleanTitle = title.replaceAll(RegExp(r'\s+'), '');
        if (cleanFirst == cleanTitle || (cleanFirst.length < 35 && cleanFirst.contains(cleanTitle))) {
          paragraphs.removeAt(0);
        }
      } else if (first.length < 30 && RegExp(r'^第[0-9一二三四五六七八九十百千万]+[章卷回节集]').hasMatch(first)) {
        paragraphs.removeAt(0);
      }
    }

    if (paragraphs.isNotEmpty) {
      return paragraphs.join('\n\n');
    }
    return _stripHtml(cleaned).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n\n');
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  // ==========================================
  // 官方评论/段评/书评/回复体系
  // ==========================================

  /// 重写图片 URL 为公共 WebP 格式（解决 HEIC 格式及特定私有模板在部分设备上无法解码的问题）
  static String cleanCommentImageUrl(String? rawUrl, {int targetWidth = 800}) {
    if (rawUrl == null || rawUrl.isEmpty) return '';
    final url = rawUrl.trim();
    final noQuery = url.split('?').first;
    final uri = Uri.tryParse(noQuery);
    if (uri == null) return url;
    final host = uri.host;
    final path = uri.path;

    if (!host.contains('fqnovelpic.com') && !host.contains('byteimg.com')) {
      return url;
    }

    final tplvIdx = path.indexOf('~tplv');
    if (tplvIdx <= 0) return url;

    final head = path.substring(0, tplvIdx);
    if (!head.startsWith('/tos-cn-i-') && !head.startsWith('/img/novel-static/')) {
      return url;
    }

    final w = targetWidth.clamp(16, 2048);
    return 'https://p3-novel.byteimg.com$head~tplv-1yzifmftcy-expand:$w:0:0.webp';
  }

  /// 从评论数据中提取有效的配图直链
  static List<String> extractCommentImages(dynamic rawImageDataList) {
    final urls = <String>[];
    if (rawImageDataList == null) return urls;

    void processEntry(dynamic item) {
      if (item is Map) {
        final webUrl = item['web_url']?.toString() ??
            item['dynamic_url']?.toString() ??
            item['url']?.toString();
        if (webUrl != null && webUrl.isNotEmpty) {
          urls.add(cleanCommentImageUrl(webUrl));
        }
      }
    }

    if (rawImageDataList is Map) {
      final imgData = rawImageDataList['image_data'];
      if (imgData is List) {
        for (final item in imgData) {
          processEntry(item);
        }
      } else if (imgData is Map) {
        processEntry(imgData);
      }
    } else if (rawImageDataList is List) {
      for (final item in rawImageDataList) {
        processEntry(item);
      }
    }
    return urls;
  }

  /// 提取用户身份标签/称号
  static List<String> extractUserTitles(dynamic userTag) {
    final titles = <String>[];
    if (userTag is! Map) return titles;

    if (userTag['is_author'] == true) {
      titles.add('作者');
    } else if (userTag['is_official_cert'] == true) {
      titles.add('官方');
    } else if (userTag['is_cp'] == true) {
      titles.add('小编');
    }

    final titleInfoList = userTag['user_title_info'];
    if (titleInfoList is List) {
      for (final t in titleInfoList) {
        if (t is Map) {
          if (t['is_vip_title'] == true) continue;
          if (userTag['is_author'] == true && t['is_author_title'] == true) continue;
          final zh = t['zh_title']?.toString().trim() ?? '';
          if (zh.isNotEmpty && !titles.contains(zh)) {
            titles.add(zh);
            if (titles.length >= 3) break;
          }
        }
      }
    }

    final sticker = userTag['sticker'];
    if (sticker is Map && sticker['is_worn'] == true) {
      final name = sticker['sticker']?['name']?.toString().trim() ?? '';
      if (name.isNotEmpty && !titles.contains(name) && titles.length < 3) {
        titles.add(name);
      }
    }
    return titles;
  }

  /// 解析单条评论
  static CommentItem? parseCommentItem(
    dynamic raw, {
    String bookId = '',
    String chapterId = '',
    int defaultParaIndex = 0,
  }) {
    if (raw is! Map) return null;
    final comment = raw['comment'] is Map ? raw['comment'] as Map : raw;
    final cid = comment['comment_id']?.toString() ?? '';
    if (cid.isEmpty) return null;

    final common = comment['common'] is Map
        ? comment['common'] as Map
        : (comment['Common'] is Map ? comment['Common'] as Map : const {});
    final content = common['content'] is Map ? common['content'] as Map : const {};
    final userInfo = common['user_info'] is Map ? common['user_info'] as Map : const {};
    final baseInfo = userInfo['base_info'] is Map ? userInfo['base_info'] as Map : userInfo;
    final userTag = userInfo['user_tag'] is Map ? userInfo['user_tag'] as Map : const {};
    final stat = comment['stat'] is Map ? comment['stat'] as Map : const {};
    final expand = comment['expand'] is Map ? comment['expand'] as Map : const {};
    final pos = expand['comment_pos'] is Map ? expand['comment_pos'] as Map : const {};

    final text = content['text']?.toString() ?? common['text']?.toString() ?? '';
    final rawImages = content['image_data_list'] ?? content['image_data'];
    final images = extractCommentImages(rawImages);
    final titles = extractUserTitles(userTag);
    final rawAvatar = baseInfo['user_avatar']?.toString() ?? '';
    final avatar = cleanCommentImageUrl(rawAvatar, targetWidth: 144);

    final paraIdx = pos['start_para_index'] is int
        ? pos['start_para_index'] as int
        : int.tryParse(pos['start_para_index']?.toString() ?? '') ?? defaultParaIndex;

    return CommentItem(
      id: cid,
      bookId: bookId,
      chapterId: chapterId,
      paraIndex: paraIdx,
      userName: baseInfo['user_name']?.toString() ?? '书友',
      userId: baseInfo['user_id']?.toString() ?? '',
      avatar: avatar,
      isAuthor: userTag['is_author'] == true,
      isVip: userTag['is_vip'] == true || userTag['is_blue_vip'] == true,
      titles: titles,
      text: text,
      images: images,
      createTime: int.tryParse(common['create_timestamp']?.toString() ?? '') ?? 0,
      diggCount: int.tryParse(stat['digg_count']?.toString() ?? '') ?? 0,
      replyCount: int.tryParse(stat['reply_count']?.toString() ?? '') ?? 0,
      score: int.tryParse(expand['score']?.toString() ?? ''),
      paraSrcContent: expand['para_src_content']?.toString(),
    );
  }

  /// 解析单条回复
  static CommentReplyItem? parseReplyItem(dynamic raw, String parentCommentId) {
    if (raw is! Map) return null;
    final rid = raw['reply_id']?.toString() ?? '';
    if (rid.isEmpty) return null;

    final common = raw['Common'] is Map
        ? raw['Common'] as Map
        : (raw['common'] is Map ? raw['common'] as Map : const {});
    final content = common['content'] is Map ? common['content'] as Map : const {};
    final userInfo = common['user_info'] is Map ? common['user_info'] as Map : const {};
    final baseInfo = userInfo['base_info'] is Map ? userInfo['base_info'] as Map : userInfo;
    final userTag = userInfo['user_tag'] is Map ? userInfo['user_tag'] as Map : const {};
    final stat = raw['stat'] is Map ? raw['stat'] as Map : const {};

    final text = content['text']?.toString() ?? '';
    final rawImages = content['image_data_list'] ?? content['image_data'];
    final images = extractCommentImages(rawImages);
    final titles = extractUserTitles(userTag);
    final rawAvatar = baseInfo['user_avatar']?.toString() ?? '';
    final avatar = cleanCommentImageUrl(rawAvatar, targetWidth: 144);

    return CommentReplyItem(
      replyId: rid,
      parentCommentId: parentCommentId,
      parentReplyId: raw['reply_to_reply_id']?.toString(),
      userName: baseInfo['user_name']?.toString() ?? '书友',
      userId: baseInfo['user_id']?.toString() ?? '',
      avatar: avatar,
      isAuthor: userTag['is_author'] == true,
      titles: titles,
      text: text,
      images: images,
      createTime: int.tryParse(common['create_timestamp']?.toString() ?? '') ?? 0,
      diggCount: int.tryParse(stat['digg_count']?.toString() ?? '') ?? 0,
    );
  }

  /// 1. 获取章节内各段评论数量统计 (idea/list)
  Future<ChapterCommentStats?> fetchChapterCommentStats(String itemId) async {
    final cleanId = itemId.trim();
    if (cleanId.isEmpty) return null;

    final queryParams = _buildCommonParams(extra: {
      'comment_source': '3',
      'item_id': cleanId,
      'server_channel': '7',
    });

    final uri = Uri.https('reading.snssdk.com', '/novel/commentapi/idea/list/$cleanId/v1/', queryParams);
    final sigHeaders = signRequest(uri.toString());

    try {
      final req = await _client.getUrl(uri).timeout(const Duration(seconds: 8));
      req.headers.set('User-Agent', userAgent);
      for (final e in sigHeaders.entries) {
        req.headers.set(e.key, e.value);
      }

      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isNotEmpty) {
          final j = jsonDecode(jsonStr);
          if (j is Map && j['code'] == 0 && j['data'] is Map) {
            final data = j['data']['data'];
            if (data is Map) {
              final counts = <int, int>{};
              var total = 0;
              for (final entry in data.entries) {
                final pIdx = int.tryParse(entry.key.toString());
                final c = int.tryParse(entry.value?['count']?.toString() ?? '0') ?? 0;
                if (pIdx != null && c > 0) {
                  counts[pIdx] = c;
                  total += c;
                }
              }
              return ChapterCommentStats(
                chapterId: cleanId,
                counts: counts,
                totalCount: total,
              );
            }
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchChapterCommentStats error: $e');
      }
    }
    return null;
  }

  /// 2. 获取指定段落的评论列表 (comment/list)
  Future<CommentPageData?> fetchParagraphComments(
    String bookId,
    String itemId,
    int paraIndex, {
    int sort = 1, // 1=最热, 3=最新
    String cursor = '',
    int count = 20,
  }) async {
    final cleanItemId = itemId.trim();
    final cleanBookId = bookId.trim();
    if (cleanItemId.isEmpty) return null;

    final queryParams = _buildCommonParams();
    final uri = Uri.https('reading.snssdk.com', '/novel/commentapi/comment/list/$cleanItemId/v1/', queryParams);

    final bodyMap = {
      'chapter_id': cleanItemId,
      'comment_source': 2,
      'comment_type': 1,
      'group_type': 15,
      'count': count.clamp(1, 50),
      'sort': sort,
      'cursor': cursor,
      'business_param': {
        'book_id': cleanBookId,
        'item_version': '0',
        'para_index': paraIndex,
      },
    };

    final bodyBytes = utf8.encode(jsonEncode(bodyMap));
    final sigHeaders = signRequest(uri.toString(), body: bodyBytes);

    try {
      final req = await _client.postUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      for (final e in sigHeaders.entries) {
        // 段评列表禁止携带 x-ss-stub，否则上游直接报 110001
        if (e.key == 'x-ss-stub') continue;
        req.headers.set(e.key, e.value);
      }
      req.add(bodyBytes);

      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isNotEmpty) {
          final j = jsonDecode(jsonStr);
          if (j is Map && j['code'] == 0 && j['data'] is Map) {
            final d = j['data'] as Map;
            final dataList = d['data_list'] as List<dynamic>? ?? const [];
            final info = d['common_list_info'] as Map<String, dynamic>? ?? const {};

            final comments = <CommentItem>[];
            for (final item in dataList) {
              final parsed = parseCommentItem(
                item,
                bookId: cleanBookId,
                chapterId: cleanItemId,
                defaultParaIndex: paraIndex,
              );
              if (parsed != null) {
                comments.add(parsed);
              }
            }

            return CommentPageData(
              comments: comments,
              cursor: info['cursor']?.toString() ?? '',
              hasMore: info['has_more'] == true,
              total: int.tryParse(info['total']?.toString() ?? '') ?? comments.length,
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchParagraphComments error: $e');
      }
    }
    return null;
  }

  /// 3. 获取楼中楼二级回复列表 (reply/list)
  Future<CommentReplyPageData?> fetchCommentReplies(
    String commentId, {
    String cursor = '',
    int count = 20,
  }) async {
    final cleanId = commentId.trim();
    if (cleanId.isEmpty) return null;

    final queryParams = _buildCommonParams();
    final uri = Uri.https('reading.snssdk.com', '/novel/commentapi/reply/list/$cleanId/v1/', queryParams);

    final bodyMap = {
      'comment_id': cleanId,
      'comment_source': 5,
      'comment_type': 1,
      'group_type': 15,
      'count': count.clamp(1, 50),
      'cursor': cursor,
    };

    final bodyBytes = utf8.encode(jsonEncode(bodyMap));
    final sigHeaders = signRequest(uri.toString(), body: bodyBytes);

    try {
      final req = await _client.postUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      for (final e in sigHeaders.entries) {
        if (e.key == 'x-ss-stub') continue;
        req.headers.set(e.key, e.value);
      }
      req.add(bodyBytes);

      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isNotEmpty) {
          final j = jsonDecode(jsonStr);
          if (j is Map && j['code'] == 0 && j['data'] is Map) {
            final d = j['data'] as Map;
            final replyList = d['reply_list'] as List<dynamic>? ?? const [];
            final info = (d['comment_list_info'] ?? d['common_list_info']) as Map<String, dynamic>? ?? const {};

            final replies = <CommentReplyItem>[];
            for (final item in replyList) {
              final parsed = parseReplyItem(item, cleanId);
              if (parsed != null) {
                replies.add(parsed);
              }
            }

            return CommentReplyPageData(
              replies: replies,
              cursor: info['cursor']?.toString() ?? '',
              hasMore: info['has_more'] == true,
              total: int.tryParse(info['total']?.toString() ?? '') ?? replies.length,
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchCommentReplies error: $e');
      }
    }
    return null;
  }

  /// 4. 获取全书书评列表 (书籍详情页)
  Future<CommentPageData?> fetchBookReviews(
    String bookId, {
    int sort = 1, // 1=最热, 3=最新
    String cursor = '',
    int count = 20,
  }) async {
    final cleanBookId = bookId.trim();
    if (cleanBookId.isEmpty) return null;

    final queryParams = _buildCommonParams();
    final uri = Uri.https('reading.snssdk.com', '/novel/commentapi/comment/list/$cleanBookId/v1/', queryParams);

    final bodyMap = {
      'business_param': {
        'book_id': cleanBookId,
        'need_count': true,
        'fold_type': 1,
      },
      'comment_source': 1,
      'comment_type': 2,
      'count': count.clamp(1, 50),
      'group_id': cleanBookId,
      'group_type': 1,
      'server_channel': 5,
      'sort': sort,
      if (cursor.isNotEmpty) 'cursor': cursor,
    };

    final bodyBytes = utf8.encode(jsonEncode(bodyMap));
    final sigHeaders = signRequest(uri.toString(), body: bodyBytes);

    try {
      final req = await _client.postUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      for (final e in sigHeaders.entries) {
        req.headers.set(e.key, e.value);
      }
      req.add(bodyBytes);

      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final respBytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
        final jsonStr = utf8.decode(respBytes, allowMalformed: true);
        if (jsonStr.isNotEmpty) {
          final j = jsonDecode(jsonStr);
          if (j is Map && j['code'] == 0 && j['data'] is Map) {
            final d = j['data'] as Map;
            final dataList = d['data_list'] as List<dynamic>? ?? const [];
            final info = d['common_list_info'] as Map<String, dynamic>? ?? const {};

            final comments = <CommentItem>[];
            for (final item in dataList) {
              final parsed = parseCommentItem(
                item,
                bookId: cleanBookId,
                chapterId: '',
                defaultParaIndex: 0,
              );
              if (parsed != null) {
                comments.add(parsed);
              }
            }

            return CommentPageData(
              comments: comments,
              cursor: info['cursor']?.toString() ?? '',
              hasMore: info['has_more'] == true,
              total: int.tryParse(info['total']?.toString() ?? '') ?? comments.length,
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FanqieMobileGateway fetchBookReviews error: $e');
      }
    }
    return null;
  }

  /// AES-128-CBC 解密正文并处理 Gzip
  String? _decryptAesCbc(String encContent, Uint8List key, {bool isCompressed = false}) {
    try {
      final rawBytes = base64.decode(encContent);
      if (rawBytes.length < 16) return null;

      final iv = Uint8List.sublistView(rawBytes, 0, 16);
      final ct = Uint8List.sublistView(rawBytes, 16);

      var pt = _aesCbcDecrypt(ct, key, iv);
      final padVal = pt.last;
      if (padVal > 0 && padVal <= 16) {
        pt = Uint8List.sublistView(pt, 0, pt.length - padVal);
      }

      if (isCompressed || (pt.length >= 2 && pt[0] == 0x1f && pt[1] == 0x8b)) {
        final decompressed = GZipDecoder().decodeBytes(pt);
        return utf8.decode(decompressed, allowMalformed: true);
      }
      return utf8.decode(pt, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ==========================================
  // 移动端请求签名体系 (Argus + Ladon + Simon + SM3)
  // ==========================================

  static final Uint8List _argusSignKey = _hexToBytes('fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304');
  static final Uint8List _argusAesKey = _hexToBytes('d31e3718288a1027baab59f146a09a9c');
  static final Uint8List _argusAesIv = _hexToBytes('ea180a0336ed352fcd24e4d50018ae54');
  static const List<int> _argus551Prefix = [0xf2, 0x81];
  static const List<int> _argus551Magic8 = [0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff];
  static const List<int> _argus551Tail9 = [0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54];
  static final BigInt _simonZ = BigInt.parse('3dc94c3a046d678b', radix: 16);
  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;

  // 预编译 Simon-64/128 72 轮密钥，避免重复大整数幂运算
  static final List<BigInt> _simonPrecomputedRoundKeys = () {
    final out = <BigInt>[];
    for (int i = 0; i < 4; i++) {
      var v = BigInt.zero;
      for (int j = 0; j < 8; j++) {
        v |= BigInt.from(_argusSignKey[i * 8 + j]) << (j * 8);
      }
      out.add(v);
    }
    final key = List<BigInt>.filled(72, BigInt.zero);
    key[0] = out[0];
    key[1] = out[1];
    key[2] = out[2];
    key[3] = out[3];

    for (int i = 4; i < 72; i++) {
      var tmp = _rotr64(key[i - 1], 3);
      tmp ^= key[i - 3];
      tmp ^= _rotr64(tmp, 1);
      final notVal = (~key[i - 4]) & _mask64;
      final bitVal = (_simonZ >> ((i - 4) % 62)) & BigInt.one;
      key[i] = (notVal ^ tmp ^ bitVal ^ BigInt.from(3)) & _mask64;
    }
    return key;
  }();

  static Map<String, String> signRequest(String url, {List<int>? body}) {
    final uri = Uri.parse(url);
    final query = uri.query;
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch ~/ 1000;
    final ticket = now.millisecondsSinceEpoch.toString();

    String stubHex = '';
    if (body != null && body.isNotEmpty) {
      stubHex = crypto.md5.convert(body).toString();
    }

    final randomBytes = Uint8List(4);
    final rnd = Random();
    for (int i = 0; i < 4; i++) {
      randomBytes[i] = rnd.nextInt(256);
    }

    final ladon = _ladonEncrypt(ts, 1611921764, 1967, randomBytes);
    final argus = _argusGetSign(
      queryString: query,
      stubHex: stubHex,
      timestamp: ts,
      aid: 1967,
      licenseId: 1611921764,
      deviceId: uri.queryParameters['device_id'] ?? '2187355326004404',
      installId: uri.queryParameters['iid'] ?? '2187355326270644',
    );

    final headers = <String, String>{
      'x-ss-req-ticket': ticket,
      'x-khronos': ts.toString(),
      'x-ladon': ladon,
      'x-argus': argus,
    };
    if (stubHex.isNotEmpty) {
      headers['x-ss-stub'] = stubHex;
    }
    return headers;
  }

  static String _argusGetSign({
    required String queryString,
    required String stubHex,
    required int timestamp,
    required int aid,
    required int licenseId,
    required String deviceId,
    required String installId,
  }) {
    final randField = Random().nextInt(0x7FFFFFFF);
    final bodyHash = stubHex.isEmpty ? _sm3Prefix6(Uint8List(16)) : _sm3Prefix6(_hexToBytes(stubHex));
    final queryHash = queryString.isEmpty ? _sm3Prefix6(Uint8List(16)) : _sm3Prefix6(Uint8List.fromList(utf8.encode(queryString)));

    final bean = _ProtoBuf();
    bean.putVarint(1, 1077940818);
    bean.putVarint(2, 2);
    bean.putVarint(3, randField);
    bean.putUtf8(4, aid.toString());
    bean.putUtf8(5, deviceId);
    bean.putUtf8(6, licenseId.toString());
    bean.putUtf8(7, '7.0.1.32');
    bean.putUtf8(8, 'v04.04.05-ov-android');
    bean.putVarint(9, 134744640);
    bean.putBytes(10, Uint8List(8));
    bean.putVarint(11, 0);
    bean.putVarint(12, timestamp << 1);
    bean.putBytes(13, bodyHash);
    bean.putBytes(14, queryHash);

    final sub15 = _ProtoBuf();
    sub15.putVarint(1, 1);
    sub15.putVarint(2, 1);
    sub15.putVarint(3, 1);
    sub15.putVarint(7, 0xC792ECCC);
    bean.putProtoBuf(15, sub15);

    bean.putUtf8(16, installId);
    bean.putUtf8(20, 'none');
    bean.putVarint(21, 738);

    final sub23 = _ProtoBuf();
    sub23.putUtf8(1, 'NX551J');
    sub23.putVarint(2, 8196);
    sub23.putVarint(4, 0x80E0D800);
    bean.putProtoBuf(23, sub23);

    bean.putVarint(25, 2);

    final pb = bean.toBuf();
    final padded = _pkcs7Pad(pb, 16);
    final encPb = _simonEncryptPadded(padded);

    final un = <int>[
      ..._argus551Magic8,
      ...encPb,
      ..._argus551Tail9,
    ];

    final buf = Uint8List(un.length);
    for (int i = 0; i < 8; i++) {
      buf[i] = _argus551Magic8[i];
    }
    for (int i = 8; i < un.length; i++) {
      buf[i] = un[i] ^ _argus551Magic8[i % 8];
    }

    final reversedList = buf.reversed.toList();
    reversedList.add(utf8.encode('a')[0]);
    reversedList.add(utf8.encode('o')[0]);

    final paddedBuf = _pkcs7Pad(Uint8List.fromList(reversedList), 16);
    final ct = _aesCbcEncrypt(paddedBuf, _argusAesKey, _argusAesIv);

    final raw = <int>[
      ..._argus551Prefix,
      ...ct,
    ];
    return base64.encode(raw);
  }

  static Uint8List _simonEncryptPadded(Uint8List protobuf) {
    final encPb = Uint8List(protobuf.length);
    for (int i = 0; i < protobuf.length ~/ 16; i++) {
      var a = BigInt.zero;
      var b = BigInt.zero;
      for (int j = 0; j < 8; j++) {
        a |= BigInt.from(protobuf[i * 16 + j]) << (j * 8);
        b |= BigInt.from(protobuf[i * 16 + 8 + j]) << (j * 8);
      }
      final ct = _simonEnc([a, b]);
      for (int j = 0; j < 8; j++) {
        encPb[i * 16 + j] = ((ct[0] >> (j * 8)) & BigInt.from(255)).toInt();
        encPb[i * 16 + 8 + j] = ((ct[1] >> (j * 8)) & BigInt.from(255)).toInt();
      }
    }
    return encPb;
  }

  static List<BigInt> _simonEnc(List<BigInt> pt) {
    var xi = pt[0];
    var xi1 = pt[1];

    for (final roundKey in _simonPrecomputedRoundKeys) {
      final tmp = xi1;
      final f = (_rotl64(xi1, 1) & _rotl64(xi1, 8)) & _mask64;
      xi1 = (xi ^ f ^ _rotl64(xi1, 2) ^ roundKey) & _mask64;
      xi = tmp;
    }
    return [xi, xi1];
  }

  static String _ladonEncrypt(int khronos, int lcId, int aid, Uint8List randomBytes) {
    final data = '$khronos-$lcId-$aid';
    final keygen = <int>[...randomBytes, ...utf8.encode(aid.toString())];
    final md5Hex = crypto.md5.convert(keygen).toString();
    final enc = _ladonEncryptRaw(md5Hex, Uint8List.fromList(utf8.encode(data)));
    final combined = Uint8List(randomBytes.length + enc.length);
    combined.setRange(0, randomBytes.length, randomBytes);
    combined.setRange(randomBytes.length, combined.length, enc);
    return base64.encode(combined);
  }

  static Uint8List _ladonEncryptRaw(String md5Hex, Uint8List data) {
    final ht = _ladonExpandHashTable(md5Hex);
    final size = data.length;
    final padLen = 16 - (size % 16);
    final newSize = size + padLen;
    final input = Uint8List(newSize);
    input.setRange(0, size, data);
    for (int i = size; i < newSize; i++) {
      input[i] = padLen;
    }

    final out = Uint8List(newSize);
    for (int i = 0; i < newSize ~/ 16; i++) {
      final blk = _ladonEncryptBlock(ht, Uint8List.sublistView(input, i * 16, i * 16 + 16));
      out.setRange(i * 16, i * 16 + 16, blk);
    }
    return out;
  }

  static Uint8List _ladonExpandHashTable(String md5Hex) {
    final ht = Uint8List(288);
    final bytes = utf8.encode(md5Hex);
    for (int i = 0; i < 32 && i < bytes.length; i++) {
      ht[i] = bytes[i];
    }

    BigInt load(int off) {
      var v = BigInt.zero;
      for (int j = 0; j < 8; j++) {
        v |= BigInt.from(ht[off + j]) << (j * 8);
      }
      return v;
    }

    final temp = <BigInt>[load(0), load(8), load(16), load(24)];
    var bufB0 = temp[0];
    var bufB8 = temp[1];
    temp.removeRange(0, 2);

    final mask64 = (BigInt.one << 64) - BigInt.one;

    for (int i = 0; i < 34; i++) {
      final x9 = bufB0;
      var x8 = bufB8;

      x8 = _rotr64(x8, 8);
      x8 = (x8 + x9) & mask64;
      x8 ^= BigInt.from(i);
      temp.add(x8);

      final rorX9 = _rotl64(x9, 3);
      x8 ^= rorX9;

      for (int j = 0; j < 8; j++) {
        ht[(i + 1) * 8 + j] = ((x8 >> (j * 8)) & BigInt.from(255)).toInt();
      }

      bufB0 = x8;
      bufB8 = temp[0];
      temp.removeAt(0);
    }
    return ht;
  }

  static Uint8List _ladonEncryptBlock(Uint8List ht, Uint8List block) {
    var data0 = BigInt.zero;
    var data1 = BigInt.zero;
    for (int i = 0; i < 8; i++) {
      data0 |= BigInt.from(block[i]) << (i * 8);
      data1 |= BigInt.from(block[8 + i]) << (i * 8);
    }

    final mask64 = (BigInt.one << 64) - BigInt.one;

    for (int i = 0; i < 34; i++) {
      var hash = BigInt.zero;
      for (int j = 0; j < 8; j++) {
        hash |= BigInt.from(ht[i * 8 + j]) << (j * 8);
      }
      final rotated = _rotr64(data1, 8);
      final sum = (data0 + rotated) & mask64;
      data1 = hash ^ sum;

      final rot0 = _rotl64(data0, 3);
      data0 = data1 ^ rot0;
    }

    final out = Uint8List(16);
    for (int i = 0; i < 8; i++) {
      out[i] = ((data0 >> (i * 8)) & BigInt.from(255)).toInt();
      out[8 + i] = ((data1 >> (i * 8)) & BigInt.from(255)).toInt();
    }
    return out;
  }

  static BigInt _rotr64(BigInt v, int n) {
    final mask = (BigInt.one << 64) - BigInt.one;
    final val = v & mask;
    return ((val >> n) | (val << (64 - n))) & mask;
  }

  static BigInt _rotl64(BigInt v, int n) {
    final mask = (BigInt.one << 64) - BigInt.one;
    final val = v & mask;
    return ((val << n) | (val >> (64 - n))) & mask;
  }

  static Uint8List _sm3Hash(Uint8List data) {
    final sm3 = SM3Digest();
    final out = Uint8List(32);
    sm3.update(data, 0, data.length);
    sm3.doFinal(out, 0);
    return out;
  }

  static Uint8List _sm3Prefix6(Uint8List data) {
    return _sm3Hash(data).sublist(0, 6);
  }

  static Uint8List _pkcs7Pad(Uint8List data, int block) {
    final pad = block - (data.length % block);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    for (int i = data.length; i < out.length; i++) {
      out[i] = pad;
    }
    return out;
  }

  static Uint8List _aesCbcEncrypt(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine());
    final params = pc.ParametersWithIV(pc.KeyParameter(key), iv);
    cipher.init(true, params);
    final out = Uint8List(data.length);
    for (int i = 0; i < data.length; i += 16) {
      cipher.processBlock(data, i, out, i);
    }
    return out;
  }

  static Uint8List _aesCbcDecrypt(Uint8List data, Uint8List key, Uint8List iv) {
    final cipher = pc.CBCBlockCipher(pc.AESEngine());
    final params = pc.ParametersWithIV(pc.KeyParameter(key), iv);
    cipher.init(false, params);
    final out = Uint8List(data.length);
    for (int i = 0; i < data.length; i += 16) {
      cipher.processBlock(data, i, out, i);
    }
    return out;
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

class _ProtoBuf {
  final List<_ProtoField> _fields = [];
  final List<List<int>> _blobs = [];

  void putVarint(int idx, int v) {
    _fields.add(_ProtoField(idx: idx, typ: 0, vUint: v, vBytes: 0));
  }

  void _putBlob(int idx, List<int> data) {
    _blobs.add(data);
    _fields.add(_ProtoField(idx: idx, typ: 2, vUint: 0, vBytes: _blobs.length - 1));
  }

  void putUtf8(int idx, String s) {
    _putBlob(idx, utf8.encode(s));
  }

  void putBytes(int idx, List<int> data) {
    _putBlob(idx, data);
  }

  void putProtoBuf(int idx, _ProtoBuf nested) {
    _putBlob(idx, nested.toBuf());
  }

  Uint8List toBuf() {
    final out = <int>[];
    for (final f in _fields) {
      final key = (f.idx << 3) | (f.typ & 7);
      _writeVarint(out, key);
      if (f.typ == 0) {
        _writeVarint(out, f.vUint);
      } else if (f.typ == 2) {
        final blob = _blobs[f.vBytes];
        _writeVarint(out, blob.length);
        out.addAll(blob);
      }
    }
    return Uint8List.fromList(out);
  }

  void _writeVarint(List<int> dst, int v) {
    var val = v & 0xFFFFFFFF;
    while (val >= 128) {
      dst.add((val & 127) | 128);
      val >>= 7;
    }
    dst.add(val & 127);
  }
}

class _ProtoField {
  final int idx;
  final int typ;
  final int vUint;
  final int vBytes;

  _ProtoField({required this.idx, required this.typ, required this.vUint, required this.vBytes});
}
