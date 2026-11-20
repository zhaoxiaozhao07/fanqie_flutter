import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/models/download_history.dart';
import 'package:fanqie_flutter/screens/book_detail_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sharedKeyBytes = [
  172,
  37,
  198,
  125,
  221,
  143,
  56,
  193,
  179,
  122,
  35,
  72,
  130,
  142,
  34,
  46,
];

String _encryptPayload(List<int> plain, List<int> key) {
  final iv = Uint8List(16);
  final pad = 16 - plain.length % 16;
  final bytes = Uint8List.fromList([...plain, ...List.filled(pad, pad)]);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), iv));
  final encrypted = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i += 16) {
    cipher.processBlock(bytes, i, encrypted, i);
  }
  return base64Encode([...iv, ...encrypted]);
}

class _MockHeaders extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;
}

class _MockResponse extends Fake implements HttpClientResponse {
  @override
  final int statusCode;
  final List<int> body;
  _MockResponse(this.body, {this.statusCode = 200});
  factory _MockResponse.json(Object data, {int statusCode = 200}) =>
      _MockResponse(utf8.encode(jsonEncode(data)), statusCode: statusCode);
  @override
  Future<T> fold<T>(T initialValue, T Function(T, List<int>) combine) async =>
      combine(initialValue, body);
}

class _MockRequest extends Fake implements HttpClientRequest {
  @override
  final _MockHeaders headers = _MockHeaders();
  final Future<HttpClientResponse> Function() responder;
  _MockRequest(this.responder);
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() => responder();
}

class _MockHttpClient extends Fake implements HttpClient {
  final Future<HttpClientResponse> Function(Uri uri, bool isPost) handler;
  final requests = <Uri>[];
  _MockHttpClient(this.handler);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _MockRequest(() => handler(url, false));
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    requests.add(url);
    return _MockRequest(() => handler(url, true));
  }
}

class _StubDetailApi extends ApiService {
  @override
  Future<Book?> getBookDetail(String bookId) async => null;

  @override
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) async => [Chapter(itemId: 'ch_1', title: '第一章 测试正文', order: 1)];

  @override
  Future<CommentPageData?> getBookReviews(
    String bookId, {
    int sort = 1,
    String cursor = '',
    int count = 20,
  }) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel('com.fanqie.fanqie_flutter/download');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookshelfService().reload();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (_) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
  });

  test('动态设备会话池在遇空响应限流和达配额时自动轮换新设备并成功拉取正文', () async {
    var nextDeviceNum = 1000000000000001;
    final keysByDevice = <String, Uint8List>{};
    final requestsPerDevice = <String, int>{};
    var throttledOnce = false;

    final client = _MockHttpClient((uri, isPost) async {
      if (uri.path.contains('/service/2/device_register')) {
        final did = (nextDeviceNum++).toString();
        final iid = (nextDeviceNum++).toString();
        return _MockResponse.json({
          'device_id_str': did,
          'install_id_str': iid,
        });
      }
      if (uri.path.contains('/reading/crypt/registerkey')) {
        final did = uri.queryParameters['device_id']!;
        final key = Uint8List.fromList(
          List.generate(16, (i) => (did.hashCode + i) & 0xff),
        );
        keysByDevice[did] = key;
        return _MockResponse.json({
          'code': 0,
          'data': {'key': _encryptPayload(key, _sharedKeyBytes), 'keyver': 1},
        });
      }
      if (uri.path.contains('/reading/reader/full/v')) {
        final did = uri.queryParameters['device_id']!;
        final itemId = uri.queryParameters['item_id']!;
        final count = (requestsPerDevice[did] ?? 0) + 1;
        requestsPerDevice[did] = count;

        // 模拟第一台设备在第 2 次请求时遭遇服务端 200 空响应体限流
        if (!throttledOnce && count == 2) {
          throttledOnce = true;
          return _MockResponse(const <int>[], statusCode: 200);
        }

        final key = keysByDevice[did]!;
        final html = '<h1>第$itemId章</h1><p>这是通过会话 $did 正常解密的完整正文内容。</p>';
        final gz = GZipEncoder().encode(utf8.encode(html));
        return _MockResponse.json({
          'code': 0,
          'data': {
            'key_version': 1,
            'compress_status': 1,
            'content': _encryptPayload(gz, key),
          },
        });
      }
      return _MockResponse(const <int>[], statusCode: 404);
    });

    final gateway = FanqieMobileGateway(
      client: client,
      allowDynamicRegistration: true,
      maxRequestsPerSession: 2,
    );

    for (var i = 1; i <= 5; i++) {
      final doc = await gateway.fetchChapterDocument(
        'chapter_$i',
        useSessionPool: true,
      );
      expect(doc, isNotNull);
      expect(doc!.text, contains('正常解密的完整正文内容'));
    }

    // 确认至少注册并切换了多台匿名设备（单设备限流 + 配额轮换均已生效）
    expect(throttledOnce, isTrue);
    expect(keysByDevice.length, greaterThanOrEqualTo(3));
  });

  test('downloadChapters 直接写入离线目录不污染临时缓存，且末尾补漏重试可挽救偶发失败章节', () async {
    final root = await Directory.systemTemp.createTemp('download-sweep-');
    addTearDown(() => root.delete(recursive: true));

    final cache = ReaderCacheService(documents: () async => root);
    final attempts = <String, int>{};

    final engine = FanqieBackendEngine(
      cache: cache,
      chapterDocumentLoader: (itemId) async {
        final count = (attempts[itemId] ?? 0) + 1;
        attempts[itemId] = count;
        // 模拟最后两章在前两次尝试全部失败，仅在第 3 次（补漏轮次）成功
        if ((itemId == 'ch_4' || itemId == 'ch_5') && count <= 2) {
          return null;
        }
        return OnlineChapter('<p>第 $itemId 章完整正文内容。</p>');
      },
    );
    addTearDown(engine.dispose);

    final chapters = [
      for (var i = 1; i <= 5; i++)
        Chapter(itemId: 'ch_$i', title: '第$i章', order: i),
    ];

    await engine.downloadChapters(
      bookId: 'book_sweep_test',
      chapters: chapters,
      concurrency: 4,
    );

    // 所有 5 章均应落盘在离线目录
    for (final ch in chapters) {
      final file = await engine.getOfflineChapterFile(
        'book_sweep_test',
        ch.itemId,
      );
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), contains('完整正文内容'));
    }
    // 下载路径不再冗余写入 reader_cache_v2 临时缓存目录
    expect(await cache.temporaryBytes(), 0);
    // 确认末尾章节确实经过了补漏轮次才成功
    expect(attempts['ch_4'], 3);
    expect(attempts['ch_5'], 3);
  });

  testWidgets('书籍详情页仅在确认已下载且本地文件真实存在时显示“已下载”，文件删除后恢复“下载”', (
    tester,
  ) async {
    late Directory root;
    late File epubFile;
    late HistoryService historyService;
    final book = Book(
      bookId: 'book_verified_ui_1',
      bookName: '神通者',
      author: '天蚕土豆',
    );

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('verified-download-ui-');
      epubFile = File('${root.path}/神通者.epub');
      await epubFile.writeAsBytes(List<int>.filled(2048, 65));
      historyService = HistoryService.forTesting();
      await historyService.addHistory(
        DownloadHistory(
          bookId: book.bookId,
          bookName: book.bookName,
          author: book.author,
          creationStatus: '连载中',
          wordNumber: 500000,
          downloadTime: DateTime.now(),
          format: 'EPUB',
          filePath: epubFile.path,
          fileSize: 2048,
        ),
      );
    });
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    final api = _StubDetailApi();
    DownloadService(api, historyService);
    addTearDown(() => DownloadService(ApiService(), HistoryService()));

    tester.view.physicalSize = const Size(430, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> settleIo() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
    }

    // 1. 文件真实存在 -> 底部按钮和标签区显示“已下载”
    await tester.pumpWidget(
      MaterialApp(home: BookDetailScreen(book: book, apiService: api)),
    );
    await settleIo();

    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('已下载 (EPUB)'), findsOneWidget);
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);

    // 点击“已下载”按钮应弹出已下载详情对话框
    await tester.tap(find.text('已下载'));
    await settleIo();
    expect(find.textContaining('格式：EPUB'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    // 2. 删除本地文件 -> 重新进入详情页应恢复显示“下载”
    await tester.runAsync(() => epubFile.delete());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(home: BookDetailScreen(book: book, apiService: api)),
    );
    await settleIo();

    expect(find.text('下载'), findsOneWidget);
    expect(find.text('已下载'), findsNothing);
    expect(find.text('已下载 (EPUB)'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
