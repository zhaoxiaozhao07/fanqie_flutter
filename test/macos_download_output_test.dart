import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/download_history.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_download_output.dart';
import 'package:fanqie_flutter/services/download_queue_store.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/widgets/download_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _nativeDirectory = '/native-authorized/Downloads/fanqie';

final class _ReleasedMacScope extends IOOverrides {
  final String outputPath;
  int metadataReads = 0;

  _ReleasedMacScope(this.outputPath);

  @override
  File createFile(String path) =>
      path == outputPath ? _DeniedOutputFile(this) : super.createFile(path);
}

class _DeniedOutputFile extends Fake implements File {
  final _ReleasedMacScope scope;
  _DeniedOutputFile(this.scope);

  @override
  Future<bool> exists() async {
    scope.metadataReads++;
    throw const FileSystemException('native scope already released');
  }

  @override
  Future<int> length() async {
    scope.metadataReads++;
    throw const FileSystemException('native scope already released');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late File source;
  final calls = <MethodCall>[];
  final providerCalls = <MethodCall>[];
  Object? directoryReply;
  Object? pickReply;
  Object? commitReply;
  final apis = <ApiService>[];
  final services = <DownloadService>[];
  List<int>? committedBytes;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    ReaderPlatform.resetForTesting();
    SharedPreferences.setMockInitialValues({
      'windows_download_dir': r'Z:\Windows-only\unchanged',
    });
    root = await Directory.systemTemp.createTemp('mac-download-unit-');
    source = await File('${root.path}/source.epub').writeAsString('完整原文😀');
    AppStorage.documentsOverride = () async => root;
    calls.clear();
    providerCalls.clear();
    committedBytes = null;
    directoryReply = {'status': 'saved', 'path': _nativeDirectory};
    pickReply = {'status': 'saved', 'path': '/native-authorized/自选目录'};
    commitReply = {'status': 'saved', 'path': '$_nativeDirectory/书 (2).epub'};
    messenger.setMockMethodCallHandler(_pathProvider, (call) async {
      providerCalls.add(call);
      return root.path;
    });
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getDownloadDirectory':
          return directoryReply;
        case 'pickDownloadDirectory':
          return pickReply;
        case 'commitDownloadFile':
          committedBytes = await File(
            (call.arguments as Map)['sourcePath'] as String,
          ).readAsBytes();
          return commitReply;
        case 'cancelExport':
          return true;
        case 'saveExportFile':
          return {'status': 'failed', 'error': '下载结束不应使用保存弹窗'};
        default:
          throw MissingPluginException(call.method);
      }
    });
  });

  tearDown(() async {
    for (final service in services) {
      await service.waitForIdle();
      service.dispose();
    }
    services.clear();
    for (final api in apis) {
      api.dispose();
      api.engine.dispose();
    }
    apis.clear();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
    messenger.setMockMethodCallHandler(_pathProvider, null);
    await root.delete(recursive: true);
  });

  test('Mac resolves native authority, not the Windows preference', () async {
    expect(await DesktopDownloadOutput.resolve(), _nativeDirectory);
    expect(calls.map((c) => c.method), ['getDownloadDirectory']);
    expect(providerCalls, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString('windows_download_dir'),
      r'Z:\Windows-only\unchanged',
    );
  });

  test('Mac default directory uses native Downloads resolution', () async {
    expect(await DesktopDownloadOutput.defaultDirectory(), _nativeDirectory);
    expect(providerCalls, isEmpty);
  });

  test(
    'Mac choice is display-only in Dart and preserves Windows prefs',
    () async {
      expect(await DesktopDownloadOutput.choose(), '/native-authorized/自选目录');
      expect(calls.map((c) => c.method), ['pickDownloadDirectory']);
      expect(providerCalls, isEmpty);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'windows_download_dir',
        ),
        r'Z:\Windows-only\unchanged',
      );
    },
  );

  for (final method in ['resolve', 'choose']) {
    test('Mac $method reports stale authority without fallback', () async {
      directoryReply = pickReply = {
        'status': 'failed',
        'error': '保存目录授权已过期，请重新选择保存位置',
      };
      await expectLater(
        method == 'resolve'
            ? DesktopDownloadOutput.resolve()
            : DesktopDownloadOutput.choose(),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'readable native error',
            contains('授权已过期'),
          ),
        ),
      );
      expect(providerCalls, isEmpty);
      expect(calls, hasLength(1));
    });
  }

  test('Mac cancelled picker leaves the remembered directory alone', () async {
    pickReply = {'status': 'cancelled'};
    expect(await DesktopDownloadOutput.choose(), isNull);
    expect(await DesktopDownloadOutput.resolve(), _nativeDirectory);
    expect(calls.map((c) => c.method), [
      'pickDownloadDirectory',
      'getDownloadDirectory',
    ]);
  });

  final malformed = <Object?>[
    null,
    'not a result dictionary',
    {'status': 'unknown', 'path': _nativeDirectory},
    {'status': 'saved'},
    {'status': 'saved', 'path': ''},
    {'status': 'saved', 'path': 'relative/not-authorized'},
    {'status': 'saved', 'path': 42},
    {'status': 'saved', 'path': '/native/\x00invalid'},
    {'status': 'failed', 'error': ''},
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('Mac malformed directory reply $i never becomes a fallback', () async {
      directoryReply = pickReply = malformed[i];
      await expectLater(
        DesktopDownloadOutput.resolve(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        DesktopDownloadOutput.choose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(providerCalls, isEmpty);
    });

    test('Mac malformed commit reply $i is not saved', () async {
      commitReply = malformed[i];
      final result = await DesktopDownloadOutput.commit(source, '书.epub');
      expect(result.status, FileExportStatus.failed);
      expect(result.error, isNotEmpty);
      expect(await source.readAsString(), '完整原文😀');
    });
  }

  test(
    'Mac commits with native directory authority and the shared ID',
    () async {
      final result = await DesktopDownloadOutput.commit(
        source,
        '书.epub',
        requestId: 'job-1',
      );
      expect(result.status, FileExportStatus.saved);
      expect(result.path, '$_nativeDirectory/书 (2).epub');
      expect(calls.map((c) => c.method), ['commitDownloadFile']);
      expect(calls.single.arguments, {
        'id': 'job-1',
        'sourcePath': source.path,
        'fileName': '书.epub',
      });
      expect(providerCalls, isEmpty);
      expect(await source.readAsString(), '完整原文😀');
    },
  );

  test(
    'Mac commit forwards failure and native cancellation distinctly',
    () async {
      commitReply = {'status': 'failed', 'error': '目录授权不可用，未更换目录'};
      final failed = await DesktopDownloadOutput.commit(source, '书.epub');
      expect(failed.status, FileExportStatus.failed);
      expect(failed.error, '目录授权不可用，未更换目录');
      commitReply = {'status': 'cancelled'};
      expect(
        (await DesktopDownloadOutput.commit(source, '书.epub')).status,
        FileExportStatus.cancelled,
      );
      expect(calls.every((c) => c.method == 'commitDownloadFile'), true);
    },
  );

  test(
    'Mac missing bridge fails rather than creating a Dart directory',
    () async {
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
      await expectLater(
        DesktopDownloadOutput.resolve(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        DesktopDownloadOutput.choose(),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await DesktopDownloadOutput.commit(source, '书.epub')).status,
        FileExportStatus.failed,
      );
      expect(providerCalls, isEmpty);
    },
  );

  test('Mac native exception retains a readable permission error', () async {
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (_) async {
      throw PlatformException(code: 'authority', message: '保存目录授权被撤销');
    });
    final result = await DesktopDownloadOutput.commit(source, '书.epub');
    expect(result.status, FileExportStatus.failed);
    expect(result.error, contains('授权被撤销'));
  });

  test('cancellation before dispatch sends no output request', () async {
    final result = await DesktopDownloadOutput.commit(
      source,
      '书.epub',
      requestId: 'not-queued',
      isCancelled: () => true,
    );
    expect(result.status, FileExportStatus.cancelled);
    expect(calls, isEmpty);
    expect(providerCalls, isEmpty);
  });

  test(
    'a saved native result wins over cancellation before its reply',
    () async {
      var cancelled = false;
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        if (call.method == 'commitDownloadFile') cancelled = true;
        return commitReply;
      });
      final result = await DesktopDownloadOutput.commit(
        source,
        '书.epub',
        isCancelled: () => cancelled,
      );
      expect(cancelled, true);
      expect(result.status, FileExportStatus.saved);
    },
  );

  void macWidgets(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  macWidgets('Mac UI remembers native choice when reopened', (tester) async {
    Widget dialog() => MaterialApp(
      home: Scaffold(
        body: DownloadDialog(bookName: '书', onFormatSelected: (_) {}),
      ),
    );
    await tester.pumpWidget(dialog());
    await tester.pumpAndSettle();
    expect(find.text(_nativeDirectory), findsOneWidget);
    expect(find.textContaining('重名自动编号'), findsOneWidget);
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();
    expect(find.text('/native-authorized/自选目录'), findsOneWidget);
    directoryReply = pickReply;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(dialog());
    await tester.pumpAndSettle();
    expect(find.text('/native-authorized/自选目录'), findsOneWidget);
    expect(
      calls.where((c) => c.method == 'pickDownloadDirectory'),
      hasLength(1),
    );
    expect(providerCalls, isEmpty);
  });

  macWidgets('Mac UI surfaces expired authority and can reauthorize', (
    tester,
  ) async {
    directoryReply = {'status': 'failed', 'error': '保存目录授权已过期'};
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadDialog(bookName: '书', onFormatSelected: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('授权已过期'), findsOneWidget);
    pickReply = {'status': 'failed', 'error': '新目录无法授权'};
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法授权'), findsOneWidget);
    pickReply = {'status': 'saved', 'path': '/native-authorized/重新授权'};
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();
    expect(find.text('/native-authorized/重新授权'), findsOneWidget);
    expect(find.textContaining('无法授权'), findsNothing);
  });

  macWidgets('cancelled Mac UI picker retains the displayed directory', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadDialog(bookName: '书', onFormatSelected: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_nativeDirectory), findsOneWidget);
    pickReply = {'status': 'cancelled'};
    await tester.tap(find.text('更改'));
    await tester.pumpAndSettle();
    expect(find.text(_nativeDirectory), findsOneWidget);
  });

  for (final oldReply in [
    {'status': 'saved', 'path': _nativeDirectory},
    {'status': 'failed', 'error': '旧目录授权已过期'},
  ]) {
    macWidgets(
      'late Mac directory lookup cannot undo a new choice: $oldReply',
      (tester) async {
        final lookup = Completer<Object?>();
        messenger.setMockMethodCallHandler(ReaderPlatform.channel, (
          call,
        ) async {
          if (call.method == 'getDownloadDirectory') return lookup.future;
          return pickReply;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DownloadDialog(bookName: '书', onFormatSelected: (_) {}),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('更改'));
        await tester.pumpAndSettle();
        expect(find.text('/native-authorized/自选目录'), findsOneWidget);
        lookup.complete(oldReply);
        await tester.pumpAndSettle();
        expect(find.text('/native-authorized/自选目录'), findsOneWidget);
        expect(find.textContaining('旧目录授权已过期'), findsNothing);
      },
    );
  }

  final book = Book(bookId: 'local_mac', bookName: '书', author: '作者');
  final chapters = [Chapter(itemId: 'one', title: '第一章')];

  Future<DownloadService> offlineDownloads() async {
    final engine = FanqieBackendEngine(
      cache: ReaderCacheService(documents: () async => root),
      chapterDocumentLoader: (_) async => throw StateError('must stay offline'),
    );
    await (await engine.getOfflineChapterFile(
      book.bookId,
      'one',
    )).writeAsString('第一章\n离线完整正文😀');
    final api = ApiService(engine: engine);
    apis.add(api);
    final service = DownloadService.forTesting(
      apiService: api,
      historyService: HistoryService.forTesting(),
      store: DownloadQueueStore(documents: () async => root),
      requestPermission: () async => true,
    );
    services.add(service);
    return service;
  }

  for (final format in ['TXT', 'EPUB']) {
    test('offline Mac $format completes without a native save panel', () async {
      final service = await offlineDownloads();
      final suffix = format.toLowerCase();
      commitReply = {'status': 'saved', 'path': '$_nativeDirectory/书.$suffix'};
      final path = format == 'TXT'
          ? await service.downloadAsTxt(book, chapters)
          : await service.downloadAsEpub(book, chapters);
      expect(path, '$_nativeDirectory/书.$suffix');
      expect(calls.map((c) => c.method), ['commitDownloadFile']);
      expect((calls.single.arguments as Map).containsKey('directory'), false);
      expect(committedBytes, isNotEmpty);
      if (format == 'EPUB') {
        final zip = ZipDecoder().decodeBytes(committedBytes!);
        expect(zip.files.first.name, 'mimetype');
        expect(
          String.fromCharCodes(zip.findFile('mimetype')!.content),
          'application/epub+zip',
        );
        expect(
          utf8.decode(zip.findFile('OEBPS/chapter_1.xhtml')!.content),
          contains('离线完整正文😀'),
        );
      } else {
        expect(utf8.decode(committedBytes!), contains('离线完整正文😀'));
      }
      final history = await HistoryService.forTesting().getHistoryByBookId(
        book.bookId,
      );
      expect(history!.filePath, path);
      expect(history.fileSize, committedBytes!.length);
    });

    test(
      'Mac $format saved remains successful after native scope release',
      () async {
        final service = await offlineDownloads();
        final path = '$_nativeDirectory/书.${format.toLowerCase()}';
        commitReply = {'status': 'saved', 'path': path};
        final releasedScope = _ReleasedMacScope(path);
        final result = await IOOverrides.runWithIOOverrides(
          () => format == 'TXT'
              ? service.downloadAsTxt(book, chapters)
              : service.downloadAsEpub(book, chapters),
          releasedScope,
        );
        expect(result, path);
        expect(releasedScope.metadataReads, 0);
        final history = await HistoryService.forTesting().getHistoryByBookId(
          book.bookId,
        );
        expect(history!.filePath, path);
        expect(history.fileSize, committedBytes!.length);
      },
    );
  }

  for (final saved in [false, true]) {
    test('Mac queued commit shares cancelExport ID; saved=$saved', () async {
      final service = await offlineDownloads();
      final started = Completer<void>();
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        calls.add(call);
        if (call.method == 'commitDownloadFile') {
          started.complete();
          return reply.future;
        }
        if (call.method == 'cancelExport') return true;
        return {'status': 'failed', 'error': 'No save panel for downloads'};
      });
      final task = service.startBackgroundDownload(
        book: book,
        chapters: chapters,
        format: 'TXT',
      );
      try {
        await Future.any([started.future, service.waitForIdle()]);
        expect(started.isCompleted, true);
        service.pauseDownload(task.id);
        reply.complete(
          saved
              ? {'status': 'saved', 'path': '$_nativeDirectory/书.txt'}
              : {'status': 'cancelled'},
        );
        await service.waitForIdle();
        expect(
          task.status,
          saved ? DownloadTaskStatus.completed : DownloadTaskStatus.paused,
        );
        expect(
          calls.where((c) => c.method == 'cancelExport').single.arguments,
          {'id': task.id},
        );
        expect((calls.first.arguments as Map)['id'], task.id);
        expect(calls.where((c) => c.method == 'saveExportFile'), isEmpty);
        final cached = await apis.single.engine.getOfflineChapterFile(
          book.bookId,
          'one',
        );
        expect(await cached.readAsString(), '第一章\n离线完整正文😀');
      } finally {
        if (!reply.isCompleted) reply.complete({'status': 'cancelled'});
      }
    });
  }

  test(
    'Mac verifies the original history path through native authority',
    () async {
      final service = await offlineDownloads();
      const path = '/previously-authorized/书.epub';
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        calls.add(call);
        return {'exists': true, 'size': 123, 'path': path};
      });
      final checked = await service.verifyDownloadedFile(filePath: path);
      expect(checked.exists, true);
      expect(checked.size, 123);
      expect(checked.path, path);
      expect(calls.single.method, 'checkDownloadedFile');
      expect(calls.single.arguments, {'filePath': path, 'contentUri': ''});
    },
  );

  test(
    'Mac native denial cannot fall back to an accessible Dart file',
    () async {
      final service = await offlineDownloads();
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        calls.add(call);
        return {
          'exists': false,
          'size': 0,
          'path': source.path,
          'error': '授权过期',
        };
      });
      expect(await source.exists(), true);
      expect(
        (await service.verifyDownloadedFile(filePath: source.path)).exists,
        false,
      );
      expect(calls.single.method, 'checkDownloadedFile');
    },
  );

  for (final response in [
    null,
    'not metadata',
    {'exists': true, 'size': 0},
    {'exists': true, 'size': -1},
    {'exists': true, 'size': '123'},
    {'exists': true, 'size': 123, 'path': '/another-root/书.epub'},
  ]) {
    test('Mac malformed metadata $response cannot use Dart fallback', () async {
      final service = await offlineDownloads();
      messenger.setMockMethodCallHandler(
        ReaderPlatform.channel,
        (_) async => response,
      );
      final checked = await service.verifyDownloadedFile(filePath: source.path);
      expect(checked.exists, false);
      expect(checked.size, 0);
      expect(checked.path, source.path);
    });
  }

  test('Mac missing metadata bridge does not imply local authority', () async {
    final service = await offlineDownloads();
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
    expect(
      (await service.verifyDownloadedFile(filePath: source.path)).exists,
      false,
    );
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (_) async {
      throw PlatformException(code: 'bookmark', message: '保存目录授权已过期');
    });
    expect(
      (await service.verifyDownloadedFile(filePath: source.path)).exists,
      false,
    );
  });

  test('Mac unverified URI cannot borrow a reused display path', () async {
    final service = await offlineDownloads();
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (_) async {
      return {'exists': true, 'size': 123, 'path': source.path};
    });
    expect(
      (await service.verifyDownloadedFile(
        filePath: source.path,
        contentUri: 'content://media/external/downloads/17',
      )).exists,
      false,
    );
    expect(
      (await service.verifyDownloadedFile(
        filePath: 'content://media/external/downloads/17',
      )).exists,
      false,
    );
  });

  test(
    'Mac history owns book IDs and keeps exact paths across directories',
    () async {
      const previous = '/selected-before-switch/书.epub';
      const current = '/selected-after-switch/书.txt';
      await HistoryService.forTesting().addHistory(
        DownloadHistory(
          bookId: book.bookId,
          bookName: book.bookName,
          author: book.author,
          creationStatus: '完结',
          wordNumber: 1,
          downloadTime: DateTime(2026),
          format: 'EPUB',
          filePath: previous,
          fileSize: 999,
        ),
      );
      await DownloadQueueStore(documents: () async => root).save([
        DownloadTask(
          id: 'completed-txt',
          book: book,
          chapters: chapters,
          format: 'TXT',
          status: DownloadTaskStatus.completed,
          total: 1,
          filePath: current,
        ),
      ]);
      final service = await offlineDownloads();
      await service.initialize();
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        calls.add(call);
        final path = (call.arguments as Map)['filePath'];
        return {
          'exists': path == previous || path == current,
          'size': path == previous ? 11 : 22,
          'path': path,
        };
      });
      final info = await service.checkVerifiedDownload(book);
      expect(info, isNotNull);
      expect(info!.filePath, previous);
      expect(info.fileSize, 11);
      expect(info.availableFormats, {'EPUB', 'TXT'});
      expect(calls.map((c) => (c.arguments as Map)['filePath']), [
        previous,
        current,
      ]);
      calls.clear();
      expect(
        await service.checkVerifiedDownload(
          Book(
            bookId: 'not-the-owner',
            bookName: book.bookName,
            author: '同名作者',
          ),
        ),
        isNull,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'Windows keeps its preference, path formatting and commit routing',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      final expected = '${root.path}\\fanqie';
      expect(await DesktopDownloadOutput.defaultDirectory(), expected);
      expect(await DesktopDownloadOutput.resolve(), expected);
      final chosen = await Directory('${root.path}/windows-choice').create();
      pickReply = {'status': 'saved', 'path': chosen.path};
      expect(await DesktopDownloadOutput.choose(), chosen.path);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'windows_download_dir',
        ),
        chosen.path,
      );
      expect(await DesktopDownloadOutput.resolve(), chosen.path);
      commitReply = {'status': 'saved', 'path': '${chosen.path}\\书.epub'};
      expect(
        (await DesktopDownloadOutput.commit(source, '书.epub')).path,
        '${chosen.path}\\书.epub',
      );
      expect((calls.last.arguments as Map)['directory'], chosen.path);
      expect(calls.where((c) => c.method == 'getDownloadDirectory'), isEmpty);
      expect(calls.where((c) => c.method == 'saveExportFile'), isEmpty);
    },
  );
}
