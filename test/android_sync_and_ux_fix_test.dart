import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/download_history.dart';
import 'package:fanqie_flutter/screens/bookshelf_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/download_queue_store.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/reader_trash_service.dart';
import 'package:fanqie_flutter/widgets/reader_undo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubApi extends ApiService {
  @override
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int, int, String)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 12,
  }) async {
    onProgress?.call(chapters.length, chapters.length, '章节下载完成');
  }

  @override
  Future<List<Book>> searchBooks(String keyword, {int offset = 0}) async => [];

  @override
  Future<Book?> getBookDetail(String id) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.fanqie.fanqie_flutter/download'),
          (_) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.fanqie.fanqie_flutter/download'),
          null,
        );
  });

  testWidgets('撤销提示栏不永久驻留：支持点击关闭按钮立即关闭且到期自动消失', (tester) async {
    final entry = ReaderTrashEntry(
      id: 'trash_undo_1',
      targetKey: 'bookshelf_books_v1',
      action: 'delete',
      label: '测试书',
      deletedAt: DateTime.utc(2026, 11, 26),
      items: [
        {'book_id': 'b1', 'book_name': '测试书', 'author': '作者'},
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  showReaderUndo(context, '已移出书架，原书、进度和笔记保留', [entry]),
              child: const Text('触发删除'),
            ),
          ),
        ),
      ),
    );

    // 1. 触发后验证 SnackBar 配置了 persist == false 且带有关闭图标
    await tester.tap(find.text('触发删除'));
    await tester.pumpAndSettle();

    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.persist, isFalse);
    expect(snackBar.showCloseIcon, isTrue);
    expect(find.text('撤销'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    // 2. 点击关闭图标立即关掉
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    // 3. 再次触发并验证 5 秒到期后自动关闭（不再永久卡在底部）
    await tester.tap(find.text('触发删除'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  test('DownloadHistory 格式自愈：.epub 路径与 local_epub_ 标识正确修正为 EPUB', () {
    final byPath = DownloadHistory.fromJson({
      'book_id': '6854833465657920516',
      'book_name': '三国测试',
      'author': '作者',
      'format': 'TXT',
      'file_path': '/storage/emulated/0/Download/fanqie/三国测试.epub',
      'file_size': 2048,
    });
    expect(byPath.format, 'EPUB');
    expect(byPath.displayFormat, 'EPUB');

    final byLocalId = DownloadHistory.fromJson({
      'book_id': 'local_epub_abcdef',
      'book_name': '本地EPUB',
      'author': '本地导入',
      'format': '',
      'file_path': '',
      'file_size': 1024,
    });
    expect(byLocalId.format, 'EPUB');
    expect(byLocalId.displayFormat, 'EPUB');
  });

  test('阅读器纯离线章节缓存任务(exportFile: false)不导出文件也不覆盖已有 EPUB 下载历史', () async {
    final root = await Directory.systemTemp.createTemp('offline-cache-task-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final history = HistoryService.forTesting();
    final book = Book(bookId: 'book_epub_1', bookName: '测试EPUB书', author: '作者');
    await history.addHistory(
      DownloadHistory(
        bookId: book.bookId,
        bookName: book.bookName,
        author: book.author,
        creationStatus: '完结',
        wordNumber: 50000,
        downloadTime: DateTime.utc(2026, 11, 26),
        format: 'EPUB',
        filePath: '/storage/emulated/0/Download/fanqie/测试EPUB书.epub',
        fileSize: 512000,
      ),
    );

    var exportCalled = false;
    final api = _StubApi();
    final downloadService = DownloadService.forTesting(
      apiService: api,
      historyService: history,
      store: DownloadQueueStore(documents: () async => root),
      requestPermission: () async => true,
      exportTask: (_) async {
        exportCalled = true;
        return '${root.path}/should_not_exist.txt';
      },
    );
    addTearDown(() {
      downloadService.dispose();
      api.dispose();
    });

    final task = downloadService.startBackgroundDownload(
      book: book,
      chapters: [Chapter(itemId: 'c1', title: '第1章')],
      format: 'TXT',
      exportFile: false,
    );
    expect(task.displayFormat, '离线');

    await downloadService.waitForIdle();
    expect(task.status, DownloadTaskStatus.completed);
    expect(task.message, '离线缓存完成');
    expect(exportCalled, isFalse);

    final record = await history.getHistoryByBookId(book.bookId);
    expect(record, isNotNull);
    expect(record!.format, 'EPUB');
  });

  testWidgets('书架已下载三列宫格封面右下角正确显示 EPUB 标签（自动纠正错标 TXT）', (tester) async {
    SharedPreferences.setMockInitialValues({'bookshelf_view_mode': 'grid3'});
    final shelf = BookshelfService.forTesting();
    final history = HistoryService.forTesting();
    final api = _StubApi();
    addTearDown(api.dispose);

    await history.addHistory(
      DownloadHistory(
        bookId: 'book_grid_epub',
        bookName: '神通者',
        author: '天蚕土豆',
        creationStatus: '连载中',
        wordNumber: 100000,
        downloadTime: DateTime.utc(2026, 11, 26),
        format: 'TXT', // 故意传入错误格式，测试 .epub 路径自愈
        filePath: '/storage/emulated/0/Download/fanqie/神通者.epub',
        fileSize: 1024 * 1024,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: BookshelfScreen(
          bookshelfService: shelf,
          historyService: history,
          apiService: api,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('已下载 (1)'));
    await tester.pumpAndSettle();

    expect(find.text('EPUB'), findsOneWidget);
    expect(find.text('TXT'), findsNothing);
  });
}
