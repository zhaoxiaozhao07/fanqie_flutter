import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fanqie_flutter/immersive/models/immersive_entities.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/models/bookshelf_book.dart';
import 'package:fanqie_flutter/models/reading_history.dart';
import 'package:fanqie_flutter/webdav/models/webdav_config.dart';
import 'package:fanqie_flutter/webdav/services/webdav_client.dart';
import 'package:fanqie_flutter/webdav/services/webdav_crypto.dart';
import 'package:fanqie_flutter/webdav/services/webdav_sync_service.dart';
import 'package:fanqie_flutter/webdav/widgets/webdav_sync_sheet.dart';

/// 内存普通 AI 朗读配置桩
class _FakeNormalTtsBridge implements NormalTtsConfigBridge {
  NormalTtsConfigSnapshot value;

  _FakeNormalTtsBridge([NormalTtsConfigSnapshot? initial])
    : value =
          initial ??
          const NormalTtsConfigSnapshot(
            engine: 'native',
            baseUrl: 'https://api.openai.com',
            apiKey: '',
            model: 'tts-1',
            voice: 'alloy',
            rate: 1.0,
            nativeVoice: '',
          );

  @override
  Future<NormalTtsConfigSnapshot> read() async => value;

  @override
  Future<void> write(NormalTtsConfigSnapshot snapshot) async {
    value = snapshot;
  }
}

/// 标准 RFC 4918 内存 WebDAV 测试服务端（支持 ETag、HEAD、MOVE 原子替换与并发冲突注入）
class _InMemoryWebDavServer {
  final String username;
  final String password;
  final Set<String> dirs = {'/'};
  final Map<String, List<int>> files = {};
  final Map<String, String> etags = {};
  int _etagSeq = 0;
  int requestCount = 0;
  int moveCount = 0;
  void Function(String method, String path)? onBeforeRequest;
  HttpServer? _server;

  _InMemoryWebDavServer({required this.username, required this.password});

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  void putFileDirect(String path, List<int> bytes) {
    files[path] = bytes;
    etags[path] = '"etag-${++_etagSeq}"';
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    requestCount++;
    final expected = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    if (req.headers.value('authorization') != expected) {
      req.response.statusCode = 401;
      req.response.headers.set('www-authenticate', 'Basic realm="test"');
      req.response.write('401 Unauthorized');
      await req.response.close();
      return;
    }

    final rawPath = Uri.decodeComponent(req.uri.path);
    final dirPath = rawPath.endsWith('/') ? rawPath : '$rawPath/';
    final filePath = rawPath.endsWith('/') && rawPath.length > 1
        ? rawPath.substring(0, rawPath.length - 1)
        : rawPath;
    final method = req.method.toUpperCase();
    onBeforeRequest?.call(method, filePath);

    switch (method) {
      case 'OPTIONS':
        req.response.statusCode = 200;
        req.response.headers.set('DAV', '1, 2');
        await req.response.close();
        return;

      case 'HEAD':
        final data = files[filePath];
        if (data == null) {
          req.response.statusCode = 404;
        } else {
          req.response.statusCode = 200;
          req.response.headers.set('content-length', data.length.toString());
          if (etags[filePath] != null) {
            // 故意返回弱 ETag 测试客户端 normalizeEtag 兼容能力
            req.response.headers.set('etag', 'W/${etags[filePath]!}');
          }
        }
        await req.response.close();
        return;

      case 'MKCOL':
        if (dirs.contains(dirPath)) {
          req.response.statusCode = 405;
        } else {
          dirs.add(dirPath);
          req.response.statusCode = 201;
        }
        await req.response.close();
        return;

      case 'PROPFIND':
        final depth = req.headers.value('depth') ?? '0';
        if (!dirs.contains(dirPath) && !files.containsKey(filePath)) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final buf = StringBuffer(
          '<?xml version="1.0" encoding="UTF-8"?><D:multistatus xmlns:D="DAV:">',
        );
        if (dirs.contains(dirPath)) {
          buf.write(
            '<D:response><D:href>$dirPath</D:href><D:propstat><D:prop>'
            '<D:resourcetype><D:collection/></D:resourcetype>'
            '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
          );
          if (depth == '1') {
            for (final d in dirs) {
              if (d != dirPath && d.startsWith(dirPath)) {
                final rest = d.substring(dirPath.length);
                final segs = rest.split('/').where((s) => s.isNotEmpty).toList();
                if (segs.length == 1) {
                  buf.write(
                    '<D:response><D:href>$d</D:href><D:propstat><D:prop>'
                    '<D:displayname>${segs.first}</D:displayname>'
                    '<D:resourcetype><D:collection/></D:resourcetype>'
                    '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
                  );
                }
              }
            }
            for (final e in files.entries) {
              if (e.key.startsWith(dirPath)) {
                final rest = e.key.substring(dirPath.length);
                if (!rest.contains('/')) {
                  buf.write(
                    '<D:response><D:href>${e.key}</D:href><D:propstat><D:prop>'
                    '<D:displayname>$rest</D:displayname>'
                    '<D:resourcetype/>'
                    '<D:getcontentlength>${e.value.length}</D:getcontentlength>'
                    '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
                  );
                }
              }
            }
          }
        } else {
          buf.write(
            '<D:response><D:href>$filePath</D:href><D:propstat><D:prop>'
            '<D:resourcetype/>'
            '<D:getcontentlength>${files[filePath]!.length}</D:getcontentlength>'
            '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
          );
        }
        buf.write('</D:multistatus>');
        req.response.statusCode = 207;
        req.response.headers.set('content-type', 'text/xml; charset=utf-8');
        req.response.write(buf.toString());
        await req.response.close();
        return;

      case 'PUT':
        final ifMatch = req.headers.value('if-match');
        if (ifMatch != null &&
            etags[filePath] != null &&
            WebDavClient.normalizeEtag(ifMatch) !=
                WebDavClient.normalizeEtag(etags[filePath])) {
          req.response.statusCode = 412;
          await req.response.close();
          return;
        }
        final bytes = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        putFileDirect(filePath, bytes);
        req.response.statusCode = 201;
        req.response.headers.set('etag', etags[filePath]!);
        await req.response.close();
        return;

      case 'MOVE':
        final destHeader = req.headers.value('destination');
        final data = files[filePath];
        if (destHeader == null || data == null) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final destUri = Uri.parse(destHeader);
        final destPath = Uri.decodeComponent(destUri.path);
        final ifMatch = req.headers.value('if-match');
        if (ifMatch != null &&
            etags[destPath] != null &&
            WebDavClient.normalizeEtag(ifMatch) !=
                WebDavClient.normalizeEtag(etags[destPath])) {
          req.response.statusCode = 412;
          await req.response.close();
          return;
        }
        files.remove(filePath);
        etags.remove(filePath);
        putFileDirect(destPath, data);
        moveCount++;
        req.response.statusCode = 201;
        req.response.headers.set('etag', etags[destPath]!);
        await req.response.close();
        return;

      case 'GET':
        final data = files[filePath];
        if (data == null) {
          req.response.statusCode = 404;
        } else {
          req.response.statusCode = 200;
          if (etags[filePath] != null) {
            req.response.headers.set('etag', 'W/${etags[filePath]!}');
          }
          req.response.add(data);
        }
        await req.response.close();
        return;

      case 'DELETE':
        files.remove(filePath);
        etags.remove(filePath);
        dirs.remove(dirPath);
        req.response.statusCode = 204;
        await req.response.close();
        return;

      default:
        req.response.statusCode = 405;
        await req.response.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 允许连接本机回环 Mock WebDAV Server（绕过 flutter_test 默认屏蔽 socket 的 HttpOverrides）
    HttpOverrides.global = null;
  });

  group('WebDAV 配置规范化、隐藏内置目录与 UI 检查', () {
    test('W01: URL 全角符号规范化与自动剥离误填的内置目录名', () {
      expect(
        WebDavConfig.normalizeServerUrl('https：//webdav.971218.xyz/'),
        'https://webdav.971218.xyz',
      );
      expect(
        WebDavConfig.normalizeServerUrl('webdav.971218.xyz/FanQieReader/'),
        'https://webdav.971218.xyz',
      );
      final client = WebDavClient(
        serverUrl: 'https：//webdav.971218.xyz',
        username: 'u',
        password: 'p',
      );
      expect(
        client.buildAppUri('sync_index.json').toString(),
        'https://webdav.971218.xyz/FanQieReader/sync_index.json',
      );
      expect(
        client.buildAppUri('books/book_1.zip').toString(),
        'https://webdav.971218.xyz/FanQieReader/books/book_1.zip',
      );
      client.close();
    });

    testWidgets('W02: WebDAV 设置面板不向用户暴露内置目录 FanQieReader', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final tempDir = Directory.systemTemp.createTempSync('webdav_ui_test_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final secret = MemoryImmersiveSecretStore();
      final testService = WebDavSyncService.forTesting(
        documents: () async => tempDir,
        secretStore: secret,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => tempDir,
          secretStore: secret,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebDavSyncSheet(service: testService)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('WebDAV 云同步与备份'), findsOneWidget);
      expect(find.text('打开应用时自动同步'), findsOneWidget);
      expect(find.textContaining('FanQieReader'), findsNothing);

      // 滚动设置列表到底部，验证按钮文案已改为“云端拉取恢复”且无“从云端拉取恢复”
      final settingsScrollable = find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('webdav-pull-btn')),
        200,
        scrollable: settingsScrollable,
      );
      await tester.pumpAndSettle();
      expect(find.text('云端拉取恢复'), findsOneWidget);
      expect(find.text('从云端拉取恢复'), findsNothing);
      final pushBox = tester.getSize(find.byKey(const ValueKey('webdav-push-btn')));
      final pullBox = tester.getSize(find.byKey(const ValueKey('webdav-pull-btn')));
      expect((pushBox.height - pullBox.height).abs(), lessThan(2.0));
    });
  });

  group('WebDAV 完整双向同步（AI配置 + 阅读历史/书籍信息 + 离线书 vs 未离线书）', () {
    late _InMemoryWebDavServer server;
    late Directory tempRoot;

    setUp(() async {
      server = _InMemoryWebDavServer(
        username: 'tester@example.com',
        password: 'SecretPassword@123',
      );
      await server.start();
      tempRoot = await Directory.systemTemp.createTemp('webdav_sync_test_');
    });

    tearDown(() async {
      await server.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('W03: 凭据安全存 Keystore，完整同步沉浸式 AI + 正常朗读 + 阅读历史 + 仅离线书上传下载', () async {
      // ==================== 设备 A 初始化 ====================
      SharedPreferences.setMockInitialValues({});
      final dirA = Directory(p.join(tempRoot.path, 'deviceA'))..createSync();
      final secretA = MemoryImmersiveSecretStore();
      final immersiveServiceA = ImmersiveConfigService(
        documents: () async => dirA,
        secretStore: secretA,
      );
      final basePreset = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'sk-test-text-secret-001',
        ttsApiKey: 'sk-test-tts-secret-002',
        featureEnabled: true,
      );
      // 设备 A 停用一个 TTS 模型并自定义回溯章数为 6，验证同步保真
      final customImmersive = basePreset.copyWith(
        analysisPipeline: basePreset.analysisPipeline.copyWith(
          maxPrefixBacktrackChapters: 6,
        ),
      );
      await immersiveServiceA.saveConfig(customImmersive);

      final ttsA = _FakeNormalTtsBridge(
        const NormalTtsConfigSnapshot(
          engine: 'openAi',
          baseUrl: 'https://tts.custom.example/v1',
          apiKey: 'sk-normal-tts-real-secret',
          model: 'DeepSeek_female',
          voice: 'DeepSeek',
          rate: 1.35,
          nativeVoice: 'zh-CN-demo',
        ),
      );

      // 设备 A 拥有：1 本已离线本地书（offline_books/local_txt_demo）+ 1 本未离线在线书（仅书架/历史+临时缓存）
      final offlineBookDir = Directory(
        p.join(dirA.path, 'offline_books', 'local_txt_demo'),
      )..createSync(recursive: true);
      File(p.join(offlineBookDir.path, 'metadata.json')).writeAsStringSync(
        jsonEncode({
          'book_id': 'local_txt_demo',
          'book_name': '雪夜来客',
          'author': '本地测试作者',
          'chapter_count': 2,
        }),
      );
      File(p.join(offlineBookDir.path, 'ch_01.txt'))
          .writeAsStringSync('第一章 正文内容：大雪封山。');

      // 未离线在线书只存在于 reader_cache_v2（临时缓存）与书架/阅读历史，不在 offline_books
      final onlineCacheDir = Directory(
        p.join(dirA.path, 'reader_cache_v2', 'online_book_999'),
      )..createSync(recursive: true);
      File(p.join(onlineCacheDir.path, 'ch_88.txt'))
          .writeAsStringSync('临时在线缓存不应打包上传');

      // 仅有封面缓存(cover.jpg)但无离线正文的历史遗留目录，同样不应误判为离线书籍
      final coverOnlyDir = Directory(
        p.join(dirA.path, 'offline_books', 'cover_only_book_777'),
      )..createSync(recursive: true);
      File(p.join(coverOnlyDir.path, 'cover.jpg'))
          .writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);

      final prefsA = await SharedPreferences.getInstance();
      await prefsA.setString(
        'bookshelf_books_v1',
        jsonEncode([
          BookshelfBook(
            bookId: 'local_txt_demo',
            bookName: '雪夜来客',
            author: '本地测试作者',
            lastReadChapterIndex: 1,
            lastReadChapterTitle: '第二章 渡口重逢',
            lastReadTime: DateTime.utc(2026, 11, 25, 10, 0),
            totalChapters: 2,
          ).toJson(),
          BookshelfBook(
            bookId: 'online_book_999',
            bookName: '神通者',
            author: '天蚕土豆',
            lastReadChapterIndex: 88,
            lastReadChapterTitle: '第89章 决战',
            lastReadTime: DateTime.utc(2026, 11, 25, 11, 0),
            totalChapters: 320,
          ).toJson(),
        ]),
      );
      await prefsA.setString(
        'reading_history_v1',
        jsonEncode([
          ReadingHistory(
            bookId: 'online_book_999',
            bookName: '神通者',
            author: '天蚕土豆',
            lastReadChapterTitle: '第89章 决战',
            lastReadChapterIndex: 88,
            lastReadTime: DateTime.utc(2026, 11, 25, 11, 0),
          ).toJson(),
        ]),
      );

      final syncA = WebDavSyncService.forTesting(
        documents: () async => dirA,
        secretStore: secretA,
        immersiveConfigService: immersiveServiceA,
        normalTtsBridge: ttsA,
      );
      await syncA.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          autoSyncOnStart: true,
          syncAiConfig: true,
          syncReadingData: true,
          syncOfflineBooks: true,
        ),
      );

      // 断言密码未明文存入 SharedPreferences
      final savedCfgRaw = prefsA.getString(WebDavSyncService.preferencesKey)!;
      expect(savedCfgRaw.contains('SecretPassword@123'), isFalse);
      expect(await secretA.read('webdav_password_v1'), 'SecretPassword@123');

      final conn = await syncA.testConnection();
      expect(conn.success, isTrue);

      final reportA = await syncA.syncNow();
      expect(reportA.success, isTrue, reason: reportA.message);
      expect(reportA.uploadedBookIds, ['local_txt_demo']);

      // 断言全部文件均写入隐藏默认目录 FanQieReader 下
      expect(server.files.containsKey('/FanQieReader/sync_index.json'), isTrue);
      expect(server.files.containsKey('/FanQieReader/ai_config.json'), isTrue);
      expect(server.files.containsKey('/FanQieReader/reading_data.json'), isTrue);
      expect(
        server.files.containsKey('/FanQieReader/books/local_txt_demo.zip'),
        isTrue,
      );
      // 未离线的在线书与仅含封面缓存的目录绝不上传正文归档
      expect(
        server.files.containsKey('/FanQieReader/books/online_book_999.zip'),
        isFalse,
      );
      expect(
        server.files.containsKey('/FanQieReader/books/cover_only_book_777.zip'),
        isFalse,
      );

      // ==================== 设备 B（新设备）启动自动同步恢复与双向合并 ====================
      SharedPreferences.setMockInitialValues({
        // 设备 B 本地还有一本自己的未离线书，验证双向合并不会丢失
        'bookshelf_books_v1': jsonEncode([
          BookshelfBook(
            bookId: 'online_book_888',
            bookName: '剑来',
            author: '烽火戏诸侯',
            lastReadChapterIndex: 12,
            lastReadChapterTitle: '第十三章',
            lastReadTime: DateTime.utc(2026, 11, 25, 12, 0),
          ).toJson(),
        ]),
      });
      final dirB = Directory(p.join(tempRoot.path, 'deviceB'))..createSync();
      final secretB = MemoryImmersiveSecretStore();
      final immersiveServiceB = ImmersiveConfigService(
        documents: () async => dirB,
        secretStore: secretB,
      );
      final ttsB = _FakeNormalTtsBridge();

      final syncB = WebDavSyncService.forTesting(
        documents: () async => dirB,
        secretStore: secretB,
        immersiveConfigService: immersiveServiceB,
        normalTtsBridge: ttsB,
      );

      // 1) 先验证关闭 autoSyncOnStart 时不发网络请求
      await syncB.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          autoSyncOnStart: false,
          syncAiConfig: true,
          syncReadingData: true,
          syncOfflineBooks: true,
        ),
      );
      final reqBefore = server.requestCount;
      expect(await syncB.triggerAutoSyncOnStart(), isNull);
      expect(server.requestCount, reqBefore);

      // 2) 开启 autoSyncOnStart 模拟下次重新打开应用自动同步
      final syncB2 = WebDavSyncService.forTesting(
        documents: () async => dirB,
        secretStore: secretB,
        immersiveConfigService: immersiveServiceB,
        normalTtsBridge: ttsB,
      );
      await syncB2.saveConfig(
        syncB.config.copyWith(autoSyncOnStart: true),
      );
      final reportB = await syncB2.triggerAutoSyncOnStart();
      expect(reportB, isNotNull);
      expect(reportB!.success, isTrue, reason: reportB.message);
      expect(reportB.downloadedBookIds, ['local_txt_demo']);

      // 校验设备 B 沉浸式配置已完整还原（含 6 章回溯与 3 模型，且本地 config.json 零明文 sk-）
      final restoredImm = await immersiveServiceB.loadAndValidateConfig(
        autoInitPreset: false,
      );
      expect(restoredImm.available, isTrue);
      expect(restoredImm.config!.textAnalysisModels.length, 3);
      expect(restoredImm.config!.analysisPipeline.maxPrefixBacktrackChapters, 6);
      final rawConfigDisk = await (await immersiveServiceB.defaultConfigFile())
          .readAsString();
      expect(rawConfigDisk.contains('sk-'), isFalse);

      // 校验设备 B 正常 AI 朗读配置已完整还原（含真实 API Key 与 1.35x 语速）
      expect(ttsB.value.engine, 'openAi');
      expect(ttsB.value.baseUrl, 'https://tts.custom.example/v1');
      expect(ttsB.value.apiKey, 'sk-normal-tts-real-secret');
      expect(ttsB.value.model, 'DeepSeek_female');
      expect(ttsB.value.voice, 'DeepSeek');
      expect(ttsB.value.rate, closeTo(1.35, 0.001));

      // 校验设备 B 书架双向合并结果：3 本书全部保留（本地剑来 + 云端神通者 + 云端雪夜来客）
      final prefsB = await SharedPreferences.getInstance();
      final shelfB =
          (jsonDecode(prefsB.getString('bookshelf_books_v1')!) as List)
              .map((e) => BookshelfBook.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
      final shelfIdsB = shelfB.map((b) => b.bookId).toSet();
      expect(
        shelfIdsB,
        containsAll(['local_txt_demo', 'online_book_999', 'online_book_888']),
      );
      final restoredOnline = shelfB.firstWhere(
        (b) => b.bookId == 'online_book_999',
      );
      expect(restoredOnline.lastReadChapterIndex, 88);

      // 校验设备 B 离线书文件真实解压还原，而未离线在线书不落盘正文
      final restoredChapter = File(
        p.join(dirB.path, 'offline_books', 'local_txt_demo', 'ch_01.txt'),
      );
      expect(await restoredChapter.exists(), isTrue);
      expect(await restoredChapter.readAsString(), '第一章 正文内容：大雪封山。');
      expect(
        await Directory(
          p.join(dirB.path, 'offline_books', 'online_book_999'),
        ).exists(),
        isFalse,
      );
    });

    test('W04: 关闭自动离线书同步后，支持单本查看状态与手动上传/下载', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory(p.join(tempRoot.path, 'manual_device'))..createSync();
      final bookDir = Directory(
        p.join(dir.path, 'offline_books', 'local_txt_manual'),
      )..createSync(recursive: true);
      File(p.join(bookDir.path, 'ch_01.txt')).writeAsStringSync('手动同步章节');

      final secret = MemoryImmersiveSecretStore();
      final svc = WebDavSyncService.forTesting(
        documents: () async => dir,
        secretStore: secret,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dir,
          secretStore: secret,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
      );
      await svc.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          syncOfflineBooks: false,
        ),
      );

      // 一键同步不自动上传离线书
      final r = await svc.syncNow();
      expect(r.success, isTrue);
      expect(r.uploadedBookIds, isEmpty);

      // 列表显示仅本地
      var items = await svc.listOfflineBooksStatus();
      expect(items.length, 1);
      expect(items.first.status, WebDavOfflineBookStatus.localOnly);

      // 手动上传单本
      await svc.uploadOfflineBook('local_txt_manual');
      items = await svc.listOfflineBooksStatus();
      expect(items.first.status, WebDavOfflineBookStatus.synced);

      // 删除本地文件后列表显示仅云端，再手动下载恢复
      await bookDir.delete(recursive: true);
      items = await svc.listOfflineBooksStatus();
      expect(items.first.status, WebDavOfflineBookStatus.remoteOnly);

      await svc.downloadOfflineBook('local_txt_manual');
      expect(
        await File(p.join(bookDir.path, 'ch_01.txt')).readAsString(),
        '手动同步章节',
      );
      items = await svc.listOfflineBooksStatus();
      expect(items.first.status, WebDavOfflineBookStatus.synced);
    });

    test('W05: 云端 ai_config.json AES-256-GCM 端到端加密、错误密码拒解与旧版明文平滑升级', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory(p.join(tempRoot.path, 'enc_dev'))..createSync();
      final secret = MemoryImmersiveSecretStore();
      final imm = ImmersiveConfigService(
        documents: () async => dir,
        secretStore: secret,
      );
      await imm.saveConfig(
        ImmersivePresetConfig.createConfiguredDefault(
          textApiKey: 'sk-top-secret-text-key-999',
          ttsApiKey: 'sk-top-secret-tts-key-888',
          featureEnabled: true,
        ),
      );
      final tts = _FakeNormalTtsBridge(
        const NormalTtsConfigSnapshot(
          engine: 'openAi',
          baseUrl: 'https://tts.example/v1',
          apiKey: 'sk-normal-tts-secret-777',
          model: 'DeepSeek_female',
          voice: 'DeepSeek',
          rate: 1.1,
          nativeVoice: '',
        ),
      );
      final svc = WebDavSyncService.forTesting(
        documents: () async => dir,
        secretStore: secret,
        immersiveConfigService: imm,
        normalTtsBridge: tts,
      );
      await svc.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          encryptCloudAiConfig: true,
        ),
      );

      final r1 = await svc.syncNow();
      expect(r1.success, isTrue, reason: r1.message);

      // 1) 云端原始文本绝不包含任何明文密钥
      final rawRemoteStr = utf8.decode(server.files['/FanQieReader/ai_config.json']!);
      expect(rawRemoteStr.contains('sk-top-secret'), isFalse);
      expect(rawRemoteStr.contains('sk-normal-tts'), isFalse);
      final envelope = jsonDecode(rawRemoteStr) as Map<String, dynamic>;
      expect(WebDavCrypto.isEncryptedEnvelope(envelope), isTrue);
      expect(envelope['cipher'].toString(), contains('AES-256-GCM'));

      // 2) 错误口令解密必须报错（GCM Tag 校验失败）
      expect(
        () => WebDavCrypto.decryptJson(envelope, passphrase: 'WrongPassword!'),
        throwsA(isA<WebDavCryptoException>()),
      );

      // 3) 兼容旧版明文 v1 并在双向同步时原地自动升级为加密 v2
      final plainDecrypted = WebDavCrypto.decryptJson(
        envelope,
        passphrase: 'SecretPassword@123',
      );
      server.putFileDirect(
        '/FanQieReader/ai_config.json',
        utf8.encode(
          jsonEncode({
            ...plainDecrypted,
            'encrypted': false,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
      );
      expect(
        utf8.decode(server.files['/FanQieReader/ai_config.json']!).contains('sk-top-secret'),
        isTrue,
      );

      final r2 = await svc.syncNow();
      expect(r2.success, isTrue, reason: r2.message);
      final upgradedRaw = utf8.decode(server.files['/FanQieReader/ai_config.json']!);
      expect(upgradedRaw.contains('sk-top-secret'), isFalse);
      expect(
        WebDavCrypto.isEncryptedEnvelope(
          jsonDecode(upgradedRaw) as Map<String, dynamic>,
        ),
        isTrue,
      );
    });

    test('W06: 沉浸式书籍角色档案与人工音色锁定（manualLocked）跨设备双向同步', () async {
      SharedPreferences.setMockInitialValues({});
      final dirA = Directory(p.join(tempRoot.path, 'profA'))..createSync();
      final dirB = Directory(p.join(tempRoot.path, 'profB'))..createSync();
      final storeA = InMemoryImmersiveStateStore();
      final storeB = InMemoryImmersiveStateStore();

      // 设备 A：手动锁定角色林岚音色为 Kimi，并创建角色陆沉
      await storeA.saveBookAudioConfig(
        const BookAudioConfig(
          bookId: 'book_sync_01',
          selectedVoiceProfileIds: [
            'vp_oneapi_Kimi_female',
            'vp_oneapi_wenxin_male',
          ],
          narratorVoiceProfileId: 'vp_oneapi_Anthropic_male',
          castRevision: 2,
          updatedAtMs: 2000,
        ),
      );
      await storeA.saveCharacter(
        const ImmersiveCharacter(
          characterId: 'char_linlan',
          bookId: 'book_sync_01',
          canonicalName: '林岚',
          gender: 'female',
          firstSeenUnitId: 'u_1',
          updatedAtMs: 2000,
        ),
      );
      await storeA.upsertVoiceBinding(
        const VoiceBinding(
          bookId: 'book_sync_01',
          characterId: 'char_linlan',
          voiceProfileId: 'vp_oneapi_Kimi_female',
          manualLocked: true,
          bindingRevision: 3,
          updatedAtMs: 2000,
        ),
      );

      // 设备 B：林岚仍是较新时间戳的自动分配（manualLocked=false），另有一个新角色老管家
      await storeB.saveCharacter(
        const ImmersiveCharacter(
          characterId: 'char_linlan',
          bookId: 'book_sync_01',
          canonicalName: '林岚',
          gender: 'female',
          firstSeenUnitId: 'u_1',
          updatedAtMs: 1500,
        ),
      );
      await storeB.upsertVoiceBinding(
        const VoiceBinding(
          bookId: 'book_sync_01',
          characterId: 'char_linlan',
          voiceProfileId: 'vp_oneapi_DeepSeek_female',
          manualLocked: false,
          bindingRevision: 4,
          updatedAtMs: 3000,
        ),
      );
      await storeB.saveCharacter(
        const ImmersiveCharacter(
          characterId: 'char_butler',
          bookId: 'book_sync_01',
          canonicalName: '老管家',
          gender: 'male',
          firstSeenUnitId: 'u_9',
          updatedAtMs: 2500,
        ),
      );

      final secA = MemoryImmersiveSecretStore();
      final syncA = WebDavSyncService.forTesting(
        documents: () async => dirA,
        secretStore: secA,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dirA,
          secretStore: secA,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
        profilesBridge: StoreImmersiveProfilesBridge(storeA),
      );
      await syncA.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          syncImmersiveProfiles: true,
          syncOfflineBooks: false,
        ),
      );
      expect((await syncA.syncNow()).success, isTrue);
      expect(
        server.files.containsKey('/FanQieReader/immersive_profiles.json'),
        isTrue,
      );

      // 设备 B 同步：拉取云端并与本地合并
      SharedPreferences.setMockInitialValues({});
      final secB = MemoryImmersiveSecretStore();
      final syncB = WebDavSyncService.forTesting(
        documents: () async => dirB,
        secretStore: secB,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dirB,
          secretStore: secB,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
        profilesBridge: StoreImmersiveProfilesBridge(storeB),
      );
      await syncB.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          syncImmersiveProfiles: true,
          syncOfflineBooks: false,
        ),
      );
      final reportB = await syncB.syncNow();
      expect(reportB.success, isTrue, reason: reportB.message);

      // 校验：设备 B 既保留了老管家，又用设备 A 的人工锁定音色覆盖了本地自动分配
      final charsB = await storeB.getCharacters('book_sync_01');
      expect(charsB.map((c) => c.characterId), containsAll(['char_linlan', 'char_butler']));
      final bindingsB = await storeB.getVoiceBindings('book_sync_01');
      final linlanBind = bindingsB.firstWhere((b) => b.characterId == 'char_linlan');
      expect(linlanBind.manualLocked, isTrue);
      expect(linlanBind.voiceProfileId, 'vp_oneapi_Kimi_female');
    });

    test('W07: 退后台与退出阅读轻量同步（60 秒节流、零变更跳过与不上传离线大书）', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory(p.join(tempRoot.path, 'bg_dev'))..createSync();
      final secret = MemoryImmersiveSecretStore();
      var now = DateTime.utc(2026, 11, 25, 20, 0, 0);

      final svc = WebDavSyncService.forTesting(
        documents: () async => dir,
        secretStore: secret,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dir,
          secretStore: secret,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
        clock: () => now,
      );
      await svc.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          autoSyncOnBackground: true,
          syncOfflineBooks: true,
        ),
      );
      expect((await svc.syncNow()).success, isTrue);

      // 1) 刚同步完 10 秒内：被 60 秒节流直接跳过，零网络请求
      now = now.add(const Duration(seconds: 10));
      final req1 = server.requestCount;
      expect(await svc.triggerLightweightProgressSync(), isNull);
      expect(server.requestCount, req1);

      // 2) 超过 60 秒但阅读数据与角色档案均未变化：零网络跳过
      now = now.add(const Duration(seconds: 65));
      final req2 = server.requestCount;
      expect(await svc.triggerLightweightProgressSync(), isNull);
      expect(server.requestCount, req2);

      // 3) 写入新的阅读进度 + 新增一本大离线书：轻量同步仅推进度，绝不传大离线书 ZIP
      final bigBook = Directory(p.join(dir.path, 'offline_books', 'local_big_999'))
        ..createSync(recursive: true);
      File(p.join(bigBook.path, 'ch_01.txt')).writeAsStringSync('离线大书内容');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reading_history_v1',
        jsonEncode([
          ReadingHistory(
            bookId: 'online_fast_01',
            bookName: '快速翻页测试书',
            author: '作者',
            lastReadChapterTitle: '第12章',
            lastReadChapterIndex: 11,
            lastReadTime: now,
          ).toJson(),
        ]),
      );

      final bgReport = await svc.triggerLightweightProgressSync();
      expect(bgReport, isNotNull);
      expect(bgReport!.success, isTrue, reason: bgReport.message);
      expect(bgReport.uploadedBookIds, isEmpty);
      expect(
        server.files.containsKey('/FanQieReader/books/local_big_999.zip'),
        isFalse,
      );
    });

    test('W08: 原子写（PUT .tmp + MOVE）无残留，且 ETag 并发冲突时自动重拉重合并', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory(p.join(tempRoot.path, 'atomic_dev'))..createSync();
      final secret = MemoryImmersiveSecretStore();
      final svc = WebDavSyncService.forTesting(
        documents: () async => dir,
        secretStore: secret,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dir,
          secretStore: secret,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
      );
      await svc.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          syncOfflineBooks: false,
        ),
      );

      // 首次同步建立远端基线并断言走 MOVE 原子替换且无 .tmp 残留
      expect((await svc.syncNow()).success, isTrue);
      expect(server.moveCount, greaterThan(0));
      expect(
        server.files.keys.any((k) => k.contains('.tmp.')),
        isFalse,
        reason: '原子替换后远端不应残留 .tmp 文件',
      );

      // 本地新增一本书，同时在首次 HEAD 预检 reading_data.json 时注入并发写入模拟另一台设备抢先修改
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'bookshelf_books_v1',
        jsonEncode([
          BookshelfBook(
            bookId: 'local_book_A',
            bookName: '本地新增书A',
            author: 'A',
            lastReadChapterIndex: 3,
            lastReadChapterTitle: '第4章',
            lastReadTime: DateTime.utc(2026, 11, 25, 21, 0),
          ).toJson(),
        ]),
      );

      var injectedConflict = false;
      server.onBeforeRequest = (method, path) {
        if (!injectedConflict &&
            method == 'HEAD' &&
            path == '/FanQieReader/reading_data.json') {
          injectedConflict = true;
          // 另一设备抢先在云端 reading_data.json 中写入 concurrent_book_B，使远端 ETag 变化触发 412 冲突重合并
          final existingMap = Map<String, dynamic>.from(
            jsonDecode(
              utf8.decode(server.files['/FanQieReader/reading_data.json']!),
            ) as Map,
          );
          final prefsMap = Map<String, dynamic>.from(
            existingMap['preferences'] as Map? ?? const {},
          );
          prefsMap['bookshelf_books_v1'] = jsonEncode([
            BookshelfBook(
              bookId: 'concurrent_book_B',
              bookName: '并发设备新增书B',
              author: 'B',
              lastReadChapterIndex: 9,
              lastReadChapterTitle: '第10章',
              lastReadTime: DateTime.utc(2026, 11, 25, 21, 5),
            ).toJson(),
          ]);
          existingMap['preferences'] = prefsMap;
          server.putFileDirect(
            '/FanQieReader/reading_data.json',
            utf8.encode(jsonEncode(existingMap)),
          );
        }
      };

      final report = await svc.syncNow();
      expect(injectedConflict, isTrue);
      expect(report.success, isTrue, reason: report.message);

      // 校验冲突重合并后云端同时保留了 local_book_A 与 concurrent_book_B
      final finalReading = jsonDecode(
        utf8.decode(server.files['/FanQieReader/reading_data.json']!),
      ) as Map<String, dynamic>;
      final finalPrefs = Map<String, dynamic>.from(
        finalReading['preferences'] as Map,
      );
      final shelfIds =
          (jsonDecode(finalPrefs['bookshelf_books_v1'] as String) as List)
              .map((e) => (e as Map)['book_id'])
              .toSet();
      expect(shelfIds, containsAll(['local_book_A', 'concurrent_book_B']));
    });

    test('W09: 本地书架删除书籍后，上传覆盖云端同步清理云端离线书与孤儿归档，并支持单本删除云端', () async {
      SharedPreferences.setMockInitialValues({});
      final dir = Directory(p.join(tempRoot.path, 'push_delete_dev'))
        ..createSync();
      final secret = MemoryImmersiveSecretStore();

      // 本地原本有 2 本离线书（均在书架中）
      for (final entry in [
        ('book_keep', '保留书籍'),
        ('book_remove', '待删书籍'),
      ]) {
        final bDir = Directory(p.join(dir.path, 'offline_books', entry.$1))
          ..createSync(recursive: true);
        File(p.join(bDir.path, 'ch_01.txt')).writeAsStringSync('${entry.$2}正文');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'bookshelf_books_v1',
        jsonEncode([
          BookshelfBook(
            bookId: 'book_keep',
            bookName: '保留书籍',
            author: '作者甲',
          ).toJson(),
          BookshelfBook(
            bookId: 'book_remove',
            bookName: '待删书籍',
            author: '作者乙',
          ).toJson(),
        ]),
      );

      final svc = WebDavSyncService.forTesting(
        documents: () async => dir,
        secretStore: secret,
        immersiveConfigService: ImmersiveConfigService(
          documents: () async => dir,
          secretStore: secret,
        ),
        normalTtsBridge: _FakeNormalTtsBridge(),
      );
      await svc.saveConfig(
        WebDavConfig(
          enabled: true,
          serverUrl: server.baseUrl,
          username: 'tester@example.com',
          password: 'SecretPassword@123',
          syncOfflineBooks: true,
        ),
      );

      // 首次同步：2 本均上传至云端
      final r1 = await svc.syncNow();
      expect(r1.success, isTrue, reason: r1.message);
      expect(r1.uploadedBookIds, containsAll(['book_keep', 'book_remove']));
      expect(server.files.containsKey('/FanQieReader/books/book_keep.zip'), isTrue);
      expect(server.files.containsKey('/FanQieReader/books/book_remove.zip'), isTrue);

      // 额外在远端注入一个孤儿 zip（不在 sync_index.json 中）
      server.putFileDirect('/FanQieReader/books/orphan_book_01.zip', [1, 2, 3]);

      // 模拟用户在本地书架移出了 book_remove（磁盘 offline_books/book_remove 目录尚未删除，保留以支持回收站）
      await prefs.setString(
        'bookshelf_books_v1',
        jsonEncode([
          BookshelfBook(
            bookId: 'book_keep',
            bookName: '保留书籍',
            author: '作者甲',
          ).toJson(),
        ]),
      );

      // scanLocalOfflineBooks 自动过滤已从本地书架与下载列表删除的残留目录
      final localAfterDelete = await svc.scanLocalOfflineBooks();
      expect(localAfterDelete.keys, ['book_keep']);

      // 执行“上传覆盖云端”
      final rPush = await svc.syncNow(mode: WebDavSyncMode.pushToRemote);
      expect(rPush.success, isTrue, reason: rPush.message);
      expect(
        rPush.deletedRemoteBookIds,
        containsAll(['book_remove', 'orphan_book_01']),
      );
      expect(rPush.conciseSummary, contains('清理云端离线书'));

      // 校验云端 zip 与 sync_index.json 均已彻底删除 book_remove 和孤儿 zip
      expect(server.files.containsKey('/FanQieReader/books/book_remove.zip'), isFalse);
      expect(server.files.containsKey('/FanQieReader/books/orphan_book_01.zip'), isFalse);
      expect(server.files.containsKey('/FanQieReader/books/book_keep.zip'), isTrue);

      final indexAfter = WebDavSyncIndex.fromJson(
        jsonDecode(utf8.decode(server.files['/FanQieReader/sync_index.json']!))
            as Map<String, dynamic>,
      );
      expect(indexAfter.offlineBooks.keys, ['book_keep']);

      // 离线书籍管理列表中不再出现已删除的 book_remove
      final itemsAfterPush = await svc.listOfflineBooksStatus();
      expect(itemsAfterPush.map((e) => e.bookId).toList(), ['book_keep']);

      // 单本删除云端 + 删除本地离线缓存
      await svc.deleteRemoteOfflineBook('book_keep');
      expect(server.files.containsKey('/FanQieReader/books/book_keep.zip'), isFalse);
      final itemsLocalOnly = await svc.listOfflineBooksStatus();
      expect(itemsLocalOnly.single.status, WebDavOfflineBookStatus.localOnly);

      expect(await svc.deleteLocalOfflineBook('book_keep'), isTrue);
      final itemsEmpty = await svc.listOfflineBooksStatus();
      expect(itemsEmpty, isEmpty);
    });
  });
}
