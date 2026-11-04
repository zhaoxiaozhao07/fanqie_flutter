import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/models/discovery.dart';
import 'package:fanqie_flutter/screens/book_detail_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/widgets/download_manager_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DetailApi extends ApiService {
  bool healthy = false;
  int directoryCalls = 0, downloadCalls = 0;
  List<String> downloadedIds = [];
  final detail = Completer<Book?>();
  Completer<List<Chapter>>? pendingDirectory;
  final List<bool> refreshes = [];
  @override
  Future<Book?> getBookDetail(String bookId) => detail.future;
  @override
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) async {
    directoryCalls++;
    refreshes.add(refresh);
    if (pendingDirectory != null) return pendingDirectory!.future;
    if (!healthy) throw const FanqieApiException('无法获取章节目录：目录接口 HTTP 503，请重试');
    return [Chapter(itemId: 'c1', title: '第一章', content: '目录恢复后可阅读的真实正文内容。')];
  }

  @override
  Future<CommentPageData?> getBookReviews(
    String bookId, {
    String cursor = '',
    int count = 20,
    int sort = 0,
  }) async => null;
  @override
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int, int, String)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 12,
  }) async {
    downloadCalls++;
    downloadedIds = chapters.map((c) => c.itemId).toList();
    throw StateError('测试：已到达下载执行层');
  }
}

void main() {
  const native = MethodChannel('com.fanqie.fanqie_flutter/download');
  TestWidgetsFlutterBinding.ensureInitialized();
  late _DetailApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookshelfService().reload();
    api = _DetailApi();
    DownloadService(api);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (_) async => null);
  });
  tearDown(() {
    if (!api.detail.isCompleted) api.detail.complete(null);
    DownloadService().cancelDownload('local_detail_retry');
    DownloadService(ApiService());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailScreen(
          book: Book(
            bookId: 'local_detail_retry',
            bookName: '目录故障回归',
            author: '测试',
          ),
          apiService: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'a hanging detail page cannot block a successful catalog or reading',
    (tester) async {
      api.healthy = true;
      await open(tester);
      expect(api.detail.isCompleted, false);
      expect(find.text('开始阅读'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      await tester.tap(find.text('开始阅读'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.textContaining('目录恢复后可阅读', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'failed start-reading actually reacquires directory on next tap',
    (tester) async {
      await open(tester);
      expect(api.directoryCalls, 1);
      expect(find.text('重试章节目录'), findsOneWidget);
      api.healthy = true;
      await tester.tap(find.text('开始阅读'));
      await tester.pumpAndSettle();
      expect(api.directoryCalls, 2);
      expect(api.refreshes, [false, true]);
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.text('正在加载章节目录，请稍候...'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'visible retry restores catalog without leaving/re-entering details',
    (tester) async {
      await open(tester);
      api.healthy = true;
      await tester.ensureVisible(find.text('重试章节目录'));
      await tester.tap(find.text('重试章节目录'));
      await tester.pumpAndSettle();
      expect(api.directoryCalls, 2);
      expect(find.byKey(const ValueKey('directory-error')), findsNothing);
      expect(find.text('第一章'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'download selection retries a failed directory then reaches download execution',
    (tester) async {
      await open(tester);
      api.healthy = true;
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TXT 格式'));
      await tester.pumpAndSettle();
      expect(api.directoryCalls, 2);
      expect(api.downloadCalls, 1);
      expect(api.downloadedIds, ['c1']);
      expect(find.text('无法获取章节目录'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'download manager waits for catalog before closing and opens reader',
    (tester) async {
      final book = Book(
        bookId: 'local_manager_retry',
        bookName: '下载后阅读',
        author: '测试',
      );
      final chapter = Chapter(
        itemId: 'c1',
        title: '第一章',
        content: '已经下载的章节正文。',
      );
      final task = DownloadService().startBackgroundDownload(
        book: book,
        chapters: [chapter],
        format: 'TXT',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => DownloadManagerSheet(apiService: api),
                ),
                child: const Text('打开下载管理'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Task transport is covered separately; exercise the real completed-task UI.
      task.status = DownloadTaskStatus.completed;
      api.pendingDirectory = Completer<List<Chapter>>();
      await tester.tap(find.text('打开下载管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即阅读'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(DownloadManagerSheet), findsOneWidget);
      expect(find.byType(ReaderScreen), findsNothing);
      api.pendingDirectory!.complete([chapter]);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(DownloadManagerSheet), findsNothing);
      expect(
        find.textContaining('已经下载的章节正文', findRichText: true),
        findsWidgets,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
