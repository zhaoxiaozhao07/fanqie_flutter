import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_illustration.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/download_queue_store.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/widgets/download_manager_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _QueueApi extends ApiService {
  final started = <String>[];
  final gates = <String, Completer<void>>{};
  Future<void> Function(String, int)? onRun;
  int running = 0, maxRunning = 0;

  @override
  Future<void> downloadChapters({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int, int, String)? onProgress,
    bool Function()? isCancelled,
    int concurrency = 12,
  }) async {
    started.add(bookId);
    running++;
    maxRunning = math.max(maxRunning, running);
    try {
      onProgress?.call(1, chapters.length, '已下载第一章');
      await gates[bookId]?.future;
      await onRun?.call(bookId, started.length);
      if (isCancelled?.call() == true) return;
      onProgress?.call(chapters.length, chapters.length, '章节下载完成');
    } finally {
      running--;
    }
  }
}

class _FailingStore extends DownloadQueueStore {
  _FailingStore(Directory root) : super(documents: () async => root);
  @override
  Future<void> save(List<DownloadTask> tasks) async =>
      throw const FileSystemException('磁盘写入失败');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DownloadQueueStore store;
  final services = <DownloadService>[];
  final apis = <ApiService>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('download-queue-');
    store = DownloadQueueStore(documents: () async => root);
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    for (final api in apis) {
      api.dispose();
    }
    apis.clear();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.fanqie.fanqie_flutter/download'),
          null,
        );
    await root.delete(recursive: true);
  });

  List<Chapter> chapters({bool images = false}) => [
    Chapter(
      itemId: 'one',
      title: '第一章',
      content: '不应写入队列的正文',
      illustrations: images
          ? [
              ReaderIllustration(
                id: 'picture',
                asset: 'images/${'a' * 64}.png',
                paragraphIndex: 3,
                characterOffset: 12,
              ),
            ]
          : const [],
    ),
    Chapter(itemId: 'two', title: '第二章'),
  ];
  Book book(String id) => Book(bookId: id, bookName: '书籍$id', author: '作者');
  DownloadTask snapshot(
    String id, {
    DownloadTaskStatus status = DownloadTaskStatus.downloading,
    bool images = false,
  }) => DownloadTask(
    id: 'task-$id',
    book: book(id),
    chapters: chapters(images: images),
    format: 'TXT',
    status: status,
    current: 1,
    total: 2,
  );

  DownloadService service(
    ApiService api, {
    DownloadQueueStore? queueStore,
    Future<String?> Function(DownloadTask)? export,
    int concurrency = 1,
  }) {
    apis.add(api);
    final result = DownloadService.forTesting(
      apiService: api,
      historyService: HistoryService.forTesting(),
      store: queueStore ?? store,
      maxConcurrentTasks: concurrency,
      requestPermission: () async => true,
      exportTask: export ?? (task) async => '${root.path}/${task.id}.txt',
    );
    services.add(result);
    return result;
  }

  Future<void> until(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('下载状态没有在期限内完成');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'pending priority order and concurrency settings persist without losing other choices',
    () async {
      final api = _QueueApi();
      final gate = api.gates['a'] = Completer<void>();
      final queue = service(api);
      final a = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.length == 1);
      queue.startBackgroundDownload(
        book: book('b'),
        chapters: chapters(),
        format: 'TXT',
      );
      final c = queue.startBackgroundDownload(
        book: book('c'),
        chapters: chapters(),
        format: 'TXT',
      );
      await queue.prioritize(c.id);
      gate.complete();
      await queue.waitForIdle();
      expect(api.started, ['a', 'c', 'b']);
      expect(a.status, DownloadTaskStatus.completed);
      await Future.wait([
        queue.setConcurrency(books: 4),
        queue.setConcurrency(chapters: 3),
      ]);
      expect(queue.maxConcurrentTasks, 4);
      expect(queue.chapterConcurrency, 3);
      final saved =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  DownloadService.preferencesKey,
                )!,
              )
              as Map;
      expect(saved['books'], 4);
      expect(saved['chapters'], 3);
    },
  );
  test(
    'explicit transient network errors retry twice with bounded backoff',
    () async {
      final api = _QueueApi();
      api.onRun = (_, attempt) async {
        if (attempt <= 2) {
          throw const SocketException('isolated transient failure');
        }
      };
      apis.add(api);
      final queue = DownloadService.forTesting(
        apiService: api,
        store: store,
        requestPermission: () async => true,
        maxConcurrentTasks: 1,
        retryBase: const Duration(milliseconds: 5),
        exportTask: (task) async => '${root.path}/done.txt',
      );
      services.add(queue);
      final task = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await queue.waitForIdle();
      expect(api.started.length, 3);
      expect(task.retryCount, 2);
      expect(task.status, DownloadTaskStatus.completed);
      expect(task.error, isNull);
    },
  );
  test(
    'filesystem errors are classified and never automatically retried',
    () async {
      final api = _QueueApi();
      api.onRun = (_, _) async =>
          throw const FileSystemException('isolated disk failure');
      final queue = service(api);
      final task = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await queue.waitForIdle();
      expect(api.started.length, 1);
      expect(task.errorKind, 'disk');
      expect(task.status, DownloadTaskStatus.failed);
      expect(task.retryCount, 0);
    },
  );

  test(
    'queue round-trip omits text and interrupted runs never auto-start',
    () async {
      await store.save([
        snapshot('a', images: true),
        snapshot('b', status: DownloadTaskStatus.saving),
      ]);
      final raw = await (await store.file).readAsString();
      expect(raw.contains('不应写入队列的正文'), false);
      final api = _QueueApi();
      var exports = 0;
      final queue = service(
        api,
        export: (_) async {
          exports++;
          return 'unused';
        },
      );
      await queue.initialize();
      expect(queue.tasks.map((task) => task.status), [
        DownloadTaskStatus.paused,
        DownloadTaskStatus.paused,
      ]);
      expect(queue.tasks.first.current, 1);
      final image = queue.tasks.first.chapters.first.illustrations.single;
      expect(image.id, 'picture');
      expect(image.paragraphIndex, 3);
      expect(image.characterOffset, 12);
      expect(image.asset, 'images/${'a' * 64}.png');
      expect(queue.tasks.first.chapters.map((chapter) => chapter.itemId), [
        'one',
        'two',
      ]);
      expect(api.started, isEmpty);
      expect(exports, 0);
      await queue.flush();
      expect(
        (await store.load()).every(
          (task) => task.status == DownloadTaskStatus.paused,
        ),
        true,
      );
    },
  );

  test(
    'queue is FIFO and bounded, with independent pending cancellation',
    () async {
      final api = _QueueApi();
      for (final id in ['a', 'b', 'c']) {
        api.gates[id] = Completer<void>();
      }
      final queue = service(api);
      await queue.initialize();
      final tasks = [
        for (final id in ['a', 'b', 'c'])
          queue.startBackgroundDownload(
            book: book(id),
            chapters: chapters(),
            format: 'TXT',
          ),
      ];
      await until(() => api.started.isNotEmpty);
      expect(api.started, ['a']);
      expect(tasks[1].status, DownloadTaskStatus.pending);
      queue.cancelDownload('c');
      api.gates['a']!.complete();
      await until(() => api.started.length == 2);
      expect(api.started, ['a', 'b']);
      queue.cancelDownload('b');
      api.gates['b']!.complete();
      await queue.waitForIdle();
      expect(api.maxRunning, 1);
      expect(tasks[0].status, DownloadTaskStatus.completed);
      expect(tasks[1].status, DownloadTaskStatus.cancelled);
      expect(tasks[2].status, DownloadTaskStatus.cancelled);
      await queue.flush();
      expect((await store.load()).map((task) => task.status), [
        DownloadTaskStatus.cancelled,
        DownloadTaskStatus.cancelled,
        DownloadTaskStatus.completed,
      ]);
    },
  );

  test(
    'different exports of the same book never race its shared chapter cache',
    () async {
      final api = _QueueApi();
      final a = api.gates['a'] = Completer<void>();
      final b = api.gates['b'] = Completer<void>();
      final queue = service(api, concurrency: 2);
      await queue.initialize();
      final txt = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.isNotEmpty);
      queue.pauseDownload(txt.id);
      final epub = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'EPUB',
      );
      queue.startBackgroundDownload(
        book: book('b'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.length >= 2);
      expect(api.started, ['a', 'b']);
      expect(epub.status, DownloadTaskStatus.pending);
      b.complete();
      a.complete();
      await queue.waitForIdle();
      expect(epub.status, DownloadTaskStatus.completed);
      expect(txt.status, DownloadTaskStatus.paused);
      expect(api.started, ['a', 'b', 'a']);
      expect(api.maxRunning, 2);
      await queue.resumeDownload(txt.id);
      await queue.waitForIdle();
      expect(txt.status, DownloadTaskStatus.completed);
      expect(api.started, ['a', 'b', 'a', 'a']);
    },
  );
  test(
    'rapid pause/resume cannot revive a stale request or late failure',
    () async {
      final api = _QueueApi();
      final pending = Completer<void>();
      api.onRun = (_, run) async {
        if (run == 1) {
          await pending.future;
          throw StateError('暂停后迟到的异常');
        }
      };
      final queue = service(api);
      await queue.initialize();
      final task = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.length == 1);
      queue.pauseDownload(task.id);
      final resumed = queue.resumeDownload(task.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.started.length, 1);
      expect(task.status, DownloadTaskStatus.paused);
      pending.complete();
      await resumed;
      await queue.waitForIdle();
      expect(api.started, ['a', 'a']);
      expect(api.maxRunning, 1);
      expect(task.status, DownloadTaskStatus.completed);
      expect(task.error, isNull);
    },
  );
  test(
    'queued tasks persist behind stalled downloads and quit does not await HTTP',
    () async {
      final api = _QueueApi();
      final gate = api.gates['a'] = Completer<void>();
      final queue = service(api);
      await queue.initialize();
      queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.isNotEmpty);
      queue.startBackgroundDownload(
        book: book('b'),
        chapters: chapters(),
        format: 'TXT',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((await store.load()).length != 2) {
        if (DateTime.now().isAfter(deadline)) fail('排队任务没有持久保存');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await queue.prepareToQuit().timeout(const Duration(seconds: 1));
      expect(
        queue.tasks.every((task) => task.status == DownloadTaskStatus.paused),
        true,
      );
      expect(api.running, 1);
      expect(
        (await store.load()).every(
          (task) => task.status == DownloadTaskStatus.paused,
        ),
        true,
      );
      gate.complete();
      await queue.waitForIdle();
      expect(api.started, ['a']);
    },
  );

  test(
    'quit saves paused checkpoints before waiting and restart can resume',
    () async {
      final api = _QueueApi();
      final gate = api.gates['a'] = Completer<void>();
      final queue = service(api);
      await queue.initialize();
      final first = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      queue.startBackgroundDownload(
        book: book('b'),
        chapters: chapters(),
        format: 'TXT',
      );
      await until(() => api.started.isNotEmpty);
      final quitting = queue.pauseAllAndWait();
      await until(
        () => queue.tasks.every(
          (task) => task.status == DownloadTaskStatus.paused,
        ),
      );
      await queue.flush();
      expect(
        (await store.load()).every(
          (task) => task.status == DownloadTaskStatus.paused,
        ),
        true,
      );
      gate.complete();
      await quitting;
      expect(api.started, ['a']);
      final freshApi = _QueueApi();
      final fresh = service(freshApi);
      await fresh.initialize();
      await fresh.resumeDownload(first.id);
      await fresh.waitForIdle();
      expect(freshApi.started, ['a']);
      expect(
        fresh.tasks.firstWhere((task) => task.id == first.id).status,
        DownloadTaskStatus.completed,
      );
    },
  );

  test(
    'write failure stops before network and corrupt queue is preserved',
    () async {
      final api = _QueueApi();
      final queue = service(api, queueStore: _FailingStore(root));
      await queue.initialize();
      final task = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await queue.waitForIdle();
      expect(api.started, isEmpty);
      expect(task.status, DownloadTaskStatus.failed);
      expect(queue.queueError, isNotNull);
      final file = await store.file;
      await file.writeAsString('unreadable original');
      final corrupt = service(_QueueApi());
      await corrupt.initialize();
      expect(corrupt.queueError, contains('原文件已保留'));
      expect(await file.readAsString(), 'unreadable original');
      expect(corrupt.tasks, isEmpty);
      await expectLater(corrupt.flush(), throwsStateError);
      await corrupt.prepareToQuit();
      expect(await file.readAsString(), 'unreadable original');
    },
  );

  test(
    'cancelled export can retry and a committed native file wins over pause',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.fanqie.fanqie_flutter/download'),
            (_) async => true,
          );
      final committed = Completer<String?>();
      var exports = 0;
      final queue = service(
        _QueueApi(),
        export: (_) async {
          exports++;
          if (exports == 1) throw const FileExportCancelled();
          return committed.future;
        },
      );
      await queue.initialize();
      final task = queue.startBackgroundDownload(
        book: book('a'),
        chapters: chapters(),
        format: 'TXT',
      );
      await queue.waitForIdle();
      expect(task.status, DownloadTaskStatus.cancelled);
      await queue.resumeDownload(task.id);
      await until(() => exports == 2);
      queue.pauseDownload(task.id);
      committed.complete('${root.path}/committed.txt');
      await queue.waitForIdle();
      expect(task.status, DownloadTaskStatus.completed);
      expect(task.filePath, endsWith('committed.txt'));
    },
  );

  test(
    'real backend resume fetches only missing chapters, then exports offline',
    () async {
      final cache = ReaderCacheService(documents: () async => root);
      final ids = <String>[];
      final seed = FanqieBackendEngine(
        cache: cache,
        chapterDocumentLoader: (id) async =>
            OnlineChapter.parse('<p>已下载第一章的完整正文。</p>'),
      );
      await seed.downloadChapters(bookId: 'a', chapters: [chapters().first]);
      seed.dispose();
      await store.save([snapshot('a')]);
      final backend = FanqieBackendEngine(
        cache: cache,
        chapterDocumentLoader: (id) async {
          ids.add(id);
          return OnlineChapter.parse('<p>补齐第二章的完整正文。</p>');
        },
      );
      final queue = service(ApiService(engine: backend));
      await queue.initialize();
      await queue.resumeDownload('task-a');
      await queue.waitForIdle();
      expect(ids, ['two']);
      expect(queue.tasks.single.status, DownloadTaskStatus.completed);
      final cached = await backend.getOfflineChapterFile('a', 'one');
      expect(await cached.readAsString(), contains('已下载第一章'));
      await store.save([snapshot('a', status: DownloadTaskStatus.saving)]);
      final offline = service(
        ApiService(
          engine: FanqieBackendEngine(
            cache: cache,
            chapterDocumentLoader: (_) async => throw StateError('不能联网'),
          ),
        ),
      );
      await offline.initialize();
      await offline.resumeDownload('task-a');
      await offline.waitForIdle();
      expect(offline.tasks.single.status, DownloadTaskStatus.completed);
      expect(ids, ['two']);
    },
  );

  test(
    'unknown queue versions and duplicate chapter IDs are rejected without writes',
    () async {
      final file = await store.file;
      await file.writeAsString(jsonEncode({'version': 99, 'tasks': []}));
      await expectLater(store.load(), throwsFormatException);
      final raw = snapshot('a').toJson();
      raw['chapters'] = [
        {'item_id': 'one', 'title': '第一章'},
        {'item_id': 'one', 'title': '重复章节'},
      ];
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'tasks': [raw],
        }),
      );
      await expectLater(store.load(), throwsFormatException);
    },
  );

  testWidgets('paused queue UI exposes resume and non-destructive removal', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(720, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = service(_QueueApi());
    await tester.runAsync(() async {
      await store.save([snapshot('a')]);
      await queue.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadManagerSheet(downloadService: queue)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('download-resume-task-a')),
      findsOneWidget,
    );
    expect(find.byTooltip('移除任务（保留正文和导出文件）'), findsOneWidget);
    expect(find.textContaining('上次下载中断'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
