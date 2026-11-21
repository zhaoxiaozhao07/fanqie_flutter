import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/models/download_history.dart';
import 'package:fanqie_flutter/screens/book_detail_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/download_queue_store.dart';
import 'package:fanqie_flutter/services/download_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'epub_image_fixture.dart';

class _DetailApi extends ApiService {
  @override
  Future<Book?> getBookDetail(String bookId) async => null;
  @override
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) async => [Chapter(itemId: 'one', title: '第一章')];
  @override
  Future<CommentPageData?> getBookReviews(
    String bookId, {
    int sort = 1,
    String cursor = '',
    int count = 20,
  }) async => null;
}

class _NoGatewayNetwork extends Fake implements HttpClient {
  int attempts = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    attempts++;
    throw const SocketException('cached completion must not require network');
  }

  @override
  Future<HttpClientRequest> postUrl(Uri url) => getUrl(url);
  @override
  set maxConnectionsPerHost(int? value) {}
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  void close({bool force = false}) {}
}

// Compile the actual export function, not a Dart reimplementation or a source
// assertion. Only Android API boundaries are stubbed; copying/cleanup uses real
// files. This is JVM unit evidence, NOT an Android SDK/device build.
List<String>? _kotlinJars() {
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null) return null;
  final modules = '$home/.gradle/caches/modules-2/files-2.1';
  const dependencies = [
    'org.jetbrains.kotlin/kotlin-compiler-embeddable/2.2.20',
    'org.jetbrains.kotlin/kotlin-stdlib/2.2.20',
    'org.jetbrains.kotlin/kotlin-script-runtime/2.2.20',
    'org.jetbrains.kotlin/kotlin-reflect/1.6.10',
    'org.jetbrains.kotlin/kotlin-daemon-embeddable/2.2.20',
    'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
    'org.jetbrains.intellij.deps/trove4j/1.0.20200330',
    'org.jetbrains/annotations/13.0',
  ];
  final jars = <String>[];
  for (final dependency in dependencies) {
    final directory = Directory('$modules/$dependency');
    if (!directory.existsSync()) return null;
    final files = directory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => file.path.endsWith('.jar'))
        .toList();
    if (files.isEmpty) return null;
    jars.add(files.single.path);
  }
  return jars;
}

Future<ProcessResult> _runNativeExportUnit(
  Directory root,
  List<String> jars,
  String mode,
) async {
  final source = await File(
    'android/app/src/main/kotlin/com/fanqie/fanqie_flutter/ReaderRuntime.kt',
  ).readAsString();
  final start = source.indexOf('    private fun saveToDownloadsDetailed(');
  final end = source.indexOf('    /// 校验已下载文件', start);
  if (start < 0 || end < 0) {
    throw StateError('Native export function not found');
  }
  final files = <String, String>{
    'Export.kt':
        '''
import android.content.*
import android.os.*
import android.provider.MediaStore
import java.io.File
${source.substring(start, end)}
fun export(context: Context, source: String) =
    saveToDownloadsDetailed(context, source, "book.epub", "application/epub+zip")
''',
    'Content.kt': r'''
package android.content
import android.net.Uri
import android.database.Cursor
import java.io.OutputStream
abstract class Context { abstract val contentResolver: ContentResolver }
class ContentValues {
    fun put(key: String, value: Any?) {}
    fun clear() {}
}
abstract class ContentResolver {
    abstract fun insert(uri: Uri, values: ContentValues): Uri?
    abstract fun openOutputStream(uri: Uri): OutputStream?
    abstract fun update(uri: Uri, values: ContentValues, selection: String?, args: Array<String>?): Int
    abstract fun query(uri: Uri, fields: Array<String>, selection: String?, args: Array<String>?, sort: String?): Cursor?
    abstract fun delete(uri: Uri, selection: String?, args: Array<String>?): Int
}
''',
    'Cursor.kt': r'''
package android.database
import java.io.Closeable
interface Cursor : Closeable {
    fun moveToFirst(): Boolean
    fun getString(index: Int): String?
}
''',
    'Uri.kt': r'''
package android.net
data class Uri(val text: String) { override fun toString() = text }
''',
    'Os.kt': r'''
package android.os
import java.io.File
object Build {
    object VERSION { val SDK_INT = 30 }
    object VERSION_CODES { const val Q = 29 }
}
object Environment {
    const val DIRECTORY_DOWNLOADS = "Download"
    fun getExternalStoragePublicDirectory(name: String) = File(name)
}
''',
    'Media.kt': r'''
package android.provider
import android.net.Uri
object MediaStore {
    object MediaColumns {
        const val DISPLAY_NAME = "name"
        const val MIME_TYPE = "mime"
        const val RELATIVE_PATH = "relative"
        const val IS_PENDING = "pending"
    }
    object Downloads { val EXTERNAL_CONTENT_URI = Uri("content://media/downloads") }
}
''',
    'Harness.kt':
        r'''
import android.content.*
import android.net.Uri
import android.database.Cursor
import java.io.*
class Resolver(val destination: File, val scenario: String) : ContentResolver() {
    val uri = Uri("content://media/external/downloads/42")
    var deleted = 0
    var published = false
    override fun insert(uri: Uri, values: ContentValues): Uri? {
        if (scenario == "insert") return null
        check(destination.createNewFile())
        return this.uri
    }
    override fun openOutputStream(uri: Uri): OutputStream? {
        if (scenario == "open") return null
        if (scenario == "copy") return object : OutputStream() {
            override fun write(value: Int) { throw IOException("copy failed") }
        }
        return destination.outputStream()
    }
    override fun update(uri: Uri, values: ContentValues, selection: String?, args: Array<String>?): Int {
        if (scenario == "publish") return 0
        published = true
        return 1
    }
    override fun query(uri: Uri, fields: Array<String>, selection: String?, args: Array<String>?, sort: String?): Cursor? {
        if (scenario == "query") throw SecurityException("optional name unavailable")
        if (scenario == "empty") return null
        return object : Cursor {
            override fun moveToFirst() = true
            override fun getString(index: Int): String? {
                if (scenario == "cursor") throw IllegalStateException("cursor metadata failed")
                return "secondary-profile-book.epub"
            }
            override fun close() {
                if (scenario == "close") throw IOException("cursor close failed")
            }
        }
    }
    override fun delete(uri: Uri, selection: String?, args: Array<String>?): Int {
        check(uri == this.uri) { "cleanup must target only this attempt's URI" }
        deleted++
        destination.delete()
        return 1
    }
}
fun main(args: Array<String>) {
    val root = File(args[0])
    val source = File(root, "source.epub").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
    val old = File(root, "previous.epub").apply { writeBytes(byteArrayOf(9, 8, 7)) }
    val scenarios = if (args[1] == "path") listOf("name", "empty")
        else listOf("query", "cursor", "close", "insert", "open", "copy", "publish")
    for (scenario in scenarios) {
        val resolver = Resolver(File(root, "$scenario-new.epub"), scenario)
        val context = object : Context() { override val contentResolver = resolver }
        val result = export(context, source.path)
        if (scenario in listOf("insert", "open", "copy", "publish")) {
            check(result["saved"] == false) { "real export failures must not claim success: $result" }
            check(resolver.deleted == if (scenario == "insert") 0 else 1)
            check(!resolver.destination.exists())
        } else {
            check(result["saved"] == true) { "optional $scenario failure discarded published export: $result" }
            check(resolver.published && resolver.deleted == 0 && resolver.destination.exists())
            check(resolver.destination.readBytes().contentEquals(byteArrayOf(1, 2, 3, 4)))
            check(result["uri"] == "content://media/external/downloads/42")
            check(result["size"] == 4L)
            if (args[1] == "path") check(result["path"] == "content://media/external/downloads/42") {
                "physical location must not be guessed from a basename: ${result["path"]}"
            }
        }
        check(old.readBytes().contentEquals(byteArrayOf(9, 8, 7)))
        check(source.readBytes().contentEquals(byteArrayOf(1, 2, 3, 4)))
    }
    println("native export unit $mode passed")
}
'''
            .replaceAll(r'$mode', mode),
  };
  for (final file in files.entries) {
    await File('${root.path}/${file.key}').writeAsString(file.value);
  }
  final separator = Platform.isWindows ? ';' : ':';
  final cp = jars.join(separator);
  final javaHome = Platform.environment['JAVA_HOME'];
  final java =
      Platform.environment['FANQIE_KOTLIN_TEST_JAVA'] ??
      (javaHome == null
          ? 'java'
          : '$javaHome/bin/java${Platform.isWindows ? '.exe' : ''}');
  final jar = '${root.path}/native-unit.jar';
  final compiled = await Process.run(java, [
    '-Xmx768m',
    '-cp',
    cp,
    'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib',
    '-no-reflect',
    '-jvm-target',
    '1.8',
    '-classpath',
    cp,
    '-d',
    jar,
    for (final name in files.keys) '${root.path}/$name',
  ]).timeout(const Duration(seconds: 60));
  expect(
    compiled.exitCode,
    0,
    reason: 'Native unit compiler: ${compiled.stdout}\n${compiled.stderr}',
  );
  return Process.run(java, [
    '-cp',
    '$jar$separator$cp',
    'HarnessKt',
    root.path,
    mode,
  ]).timeout(const Duration(seconds: 15));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FanqieBackendEngine engine;
  late DownloadService downloads;
  late HistoryService history;
  late ApiService api;
  final chapters = [
    Chapter(itemId: 'one', title: '第一章'),
    Chapter(itemId: 'two', title: '第二章'),
  ];
  final book = Book(bookId: 'book', bookName: '同名书籍', author: '作者');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('mainline-download-');
    AppStorage.documentsOverride = () async => root;
    history = HistoryService.forTesting();
  });
  tearDown(() async {
    downloads.dispose();
    api.dispose();
    debugDefaultTargetPlatformOverride = null;
    AppStorage.documentsOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, null);
    await root.delete(recursive: true);
  });

  void configure(
    Future<OnlineChapter?> Function(String)? loader, {
    http.Client? client,
  }) {
    engine = FanqieBackendEngine(
      cache: ReaderCacheService(documents: () async => root),
      chapterDocumentLoader: loader,
      client: client,
    );
    api = ApiService(engine: engine);
    downloads = DownloadService.forTesting(
      apiService: api,
      historyService: history,
      store: DownloadQueueStore(documents: () async => root),
      requestPermission: () async => true,
    );
  }

  final kotlin = _kotlinJars();
  for (final mode in ['query', 'path']) {
    test(
      mode == 'query'
          ? 'R6 optional name-query exceptions preserve a published Android export'
          : 'R7 Android export returns its URI without guessing primary-user storage',
      () async {
        configure((_) async => null);
        final result = await _runNativeExportUnit(root, kotlin!, mode);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
      skip: kotlin == null
          ? 'Cached Kotlin compiler unavailable; no native unit validation'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'R5 remote 20-chapter temporary cache promotes without contacting the gateway',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final network = _NoGatewayNetwork();
      await HttpOverrides.runZoned(() async {
        // No injected chapter loader: exercise the real remote-book branch.
        configure(
          null,
          client: MockClient((_) async => throw StateError('no image HTTP')),
        );
        final cached = [
          for (var i = 0; i < 20; i++)
            Chapter(itemId: 'cached_$i', title: '第$i章'),
        ];
        for (final chapter in cached) {
          final text = '完整临时正文 ${chapter.itemId}';
          await engine.readerCache.write('remote_cached', chapter.itemId, text);
          await engine.onlineImages.saveSources(
            'remote_cached',
            chapter.itemId,
            OnlineChapter(text),
          );
        }
        final progress = <int>[];
        await engine.downloadChapters(
          bookId: 'remote_cached',
          chapters: cached,
          onProgress: (current, _, _) => progress.add(current),
        );
        expect(network.attempts, 0);
        expect(progress.last, 20);
        for (final chapter in cached) {
          expect(
            await (await engine.getOfflineChapterFile(
              'remote_cached',
              chapter.itemId,
            )).readAsString(),
            '完整临时正文 ${chapter.itemId}',
          );
        }
      }, createHttpClient: (_) => network);
    },
  );

  for (final failuresBeforeSuccess in [0, 2]) {
    test(
      'rejected legacy UTF-8 preserves network recovery after $failuresBeforeSuccess failures',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        const text = '网络返回的完整正文，旧缓存不应阻断恢复。';
        var fetches = 0;
        configure((_) async {
          fetches++;
          return fetches <= failuresBeforeSuccess ? null : OnlineChapter(text);
        });
        final legacy = File('${root.path}/fanqie_cache/chapters/one.txt');
        await legacy.parent.create(recursive: true);
        const rejected = [255, 254, 0, 255];
        await legacy.writeAsBytes(rejected);
        final progress = <int>[];
        await engine.downloadChapters(
          bookId: 'book',
          chapters: [chapters.first],
          onProgress: (current, _, _) => progress.add(current),
        );
        expect(
          await (await engine.getOfflineChapterFile(
            'book',
            'one',
          )).readAsString(),
          text,
        );
        expect(fetches, failuresBeforeSuccess + 1);
        expect(progress.last, 1);
        expect(progress.where((current) => current == 1).length, 1);
        expect(await legacy.readAsBytes(), rejected);
      },
    );
  }

  test(
    'genuine protected write failure is not retried as a cache miss',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      var fetches = 0;
      configure((_) async {
        fetches++;
        return OnlineChapter('完整网络正文');
      });
      final target = await engine.getOfflineChapterFile('book', 'one');
      final existingDirectory = Directory(target.path);
      await existingDirectory.create();
      final marker = File('${existingDirectory.path}/keep.txt');
      await marker.writeAsString('existing data');
      await expectLater(
        engine.downloadChapters(bookId: 'book', chapters: [chapters.first]),
        throwsA(
          isA<ChapterDownloadIncomplete>()
              .having((error) => error.diskFailure, 'diskFailure', true)
              .having((error) => error.downloaded, 'downloaded', 0),
        ),
      );
      expect(
        fetches,
        1,
        reason: 'A real write failure suppresses the final sweep',
      );
      expect(await marker.readAsString(), 'existing data');
    },
  );

  for (final fallback in ['temporary', 'fetched']) {
    test(
      'R1 invalid protected UTF-8 is repaired atomically from $fallback content',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        const text = '正确且完整的恢复正文。';
        var fetches = 0;
        configure((_) async {
          fetches++;
          return OnlineChapter(text);
        });
        final protected = await engine.getOfflineChapterFile('book', 'one');
        final rejected = [255, 254, 0, 255];
        await protected.writeAsBytes(rejected);
        if (fallback == 'temporary') {
          await engine.readerCache.write('book', 'one', text);
          await engine.onlineImages.saveSources(
            'book',
            'one',
            OnlineChapter(text),
          );
        }
        await engine.downloadChapters(
          bookId: 'book',
          chapters: [chapters.first],
        );
        expect(await protected.readAsString(), text);
        expect(fetches, fallback == 'temporary' ? 0 : 1);
        final quarantined = await protected.parent
            .list()
            .where(
              (file) =>
                  file.path.contains('one.txt.rejected-') &&
                  !file.path.endsWith('.pending'),
            )
            .toList();
        expect(quarantined.length, 1);
        expect(await File(quarantined.single.path).readAsBytes(), rejected);
      },
    );
  }

  for (final response in ['missing', 'null', 'error']) {
    test(
      'R2 URI plus a nonempty reused path fails closed when bridge is $response',
      () async {
        configure((_) async => null);
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final replacement = File('${root.path}/reused.epub');
        await replacement.writeAsString(
          'another download now occupies this path',
        );
        if (response != 'missing') {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(ReaderPlatform.channel, (_) async {
                if (response == 'error') {
                  throw PlatformException(code: 'provider_error');
                }
                return null;
              });
        }
        const uri = 'content://media/external/downloads/17';
        final checked = await downloads.verifyDownloadedFile(
          filePath: replacement.path,
          contentUri: uri,
        );
        expect(checked.exists, false);
        expect(checked.size, 0);
        // The same file is legitimate for a path-only record.
        expect(
          (await downloads.verifyDownloadedFile(
            filePath: replacement.path,
          )).exists,
          true,
        );
      },
    );
  }

  test(
    'completed book-ID paths restore formats across distinct output directories',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      configure(
        (_) async => throw StateError('verification must not fetch chapters'),
      );
      final first = Directory('${root.path}/first-output');
      final second = Directory('${root.path}/second-output');
      await first.create();
      await second.create();
      final epub = File('${first.path}/同名书籍 (1).epub');
      final txt = File('${second.path}/同名书籍 (3).txt');
      await epub.writeAsString('EPUB output');
      await txt.writeAsString('TXT output');
      await history.addHistory(
        DownloadHistory(
          bookId: book.bookId,
          bookName: book.bookName,
          author: book.author,
          creationStatus: '完结',
          wordNumber: 1,
          downloadTime: DateTime(2026),
          format: 'TXT',
          filePath: txt.path,
          fileSize: 999,
        ),
      );
      await DownloadQueueStore(documents: () async => root).save([
        DownloadTask(
          id: 'completed-epub',
          book: book,
          chapters: chapters,
          format: 'EPUB',
          status: DownloadTaskStatus.completed,
          current: 2,
          total: 2,
          filePath: epub.path,
        ),
      ]);
      await downloads.initialize();
      final info = await downloads.checkVerifiedDownload(book);
      expect(info!.availableFormats, {'TXT', 'EPUB'});
      expect(info.filePath, txt.path);
      expect(info.fileSize, 10);
      expect(
        await downloads.checkVerifiedDownload(
          Book(bookId: 'unknown', bookName: book.bookName, author: '同名的另一本书'),
        ),
        isNull,
      );
      await epub.delete();
      expect((await downloads.checkVerifiedDownload(book))!.availableFormats, {
        'TXT',
      });
    },
  );

  testWidgets(
    'detail opened during saving refreshes when the existing task completes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      configure((_) async => throw StateError('offline only'));
      final activeBook = Book(
        bookId: 'local_active',
        bookName: '保存中的书',
        author: '作者',
      );
      final saved = File('${root.path}/active.epub');
      late Completer<void> entered;
      late Completer<Map<String, Object>> commit;
      final queue = DownloadService(api, history);
      DownloadTask? task;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          if (!commit.isCompleted) commit.complete({'status': 'cancelled'});
          await queue.waitForIdle().timeout(const Duration(seconds: 3));
          if (task != null) queue.removeTask(task!.id);
          await queue.flush();
        });
        DownloadService(ApiService(), HistoryService());
      });
      await tester.runAsync(() async {
        entered = Completer<void>();
        commit = Completer<Map<String, Object>>();
        await (await engine.getOfflineChapterFile(
          activeBook.bookId,
          'one',
        )).writeAsString('已下载正文');
        await (await SharedPreferences.getInstance()).setString(
          'windows_download_dir',
          root.path,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
              if (call.method != 'commitDownloadFile') return true;
              await File(
                call.arguments['sourcePath'] as String,
              ).copy(saved.path);
              entered.complete();
              return commit.future;
            });
        task = queue.startBackgroundDownload(
          book: activeBook,
          chapters: [chapters.first],
          format: 'EPUB',
        );
        await entered.future.timeout(const Duration(seconds: 3));
      });
      tester.view.physicalSize = const Size(1024, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: BookDetailScreen(book: activeBook, apiService: _DetailApi()),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      await tester.runAsync(() async {
        commit.complete({'status': 'saved', 'path': saved.path});
        await queue.waitForIdle().timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(find.text('已下载 (EPUB)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'EPUB refuses an illustration corrupted after successful chapter validation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      configure(
        (_) async => OnlineChapter.parse(
          '<p>原文<img src="https://p3-novel.byteimg.com/image.png"/>不变</p>',
        ),
        client: MockClient((_) async => http.Response.bytes(imagePng(), 200)),
      );
      await engine.downloadChapters(bookId: 'book', chapters: [chapters.first]);
      final text = await (await engine.getOfflineChapterFile(
        'book',
        'one',
      )).readAsString();
      final image = (await engine.onlineImages.read(
        'book',
        'one',
        text,
      )).single;
      final asset = File('${root.path}/offline_books/book/${image.asset}');
      var exports = 0;
      await (await SharedPreferences.getInstance()).setString(
        'windows_download_dir',
        root.path,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
            exports++;
            final saved = File('${root.path}/bad.epub');
            await File(call.arguments['sourcePath'] as String).copy(saved.path);
            return {'status': 'saved', 'path': saved.path};
          });
      final result = await downloads.downloadAsEpub(
        book,
        [chapters.first],
        onProgress: (current, total, message) {
          if (current == total && message.startsWith('正在下载:')) {
            asset.writeAsBytesSync(imagePng().sublist(0, 24));
          }
        },
      );
      expect(result, isNull);
      expect(exports, 0);
      expect(
        await (await engine.getOfflineChapterFile(
          'book',
          'one',
        )).readAsString(),
        text,
      );
    },
  );

  test(
    'Android numbered export persists its exact URI and measured size',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      configure((_) async => throw StateError('offline only'));
      await (await engine.getOfflineChapterFile(
        'local_book',
        'one',
      )).writeAsString('离线正文');
      const uri = 'content://media/external/downloads/17';
      const path = '/storage/emulated/0/Download/fanqie/同名书籍 (1).epub';
      final verifiedUris = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
            switch (call.method) {
              case 'saveToDownloadsDetailed':
                final source = File(call.arguments['filePath'] as String);
                expect(await source.exists(), true);
                return {
                  'saved': true,
                  'path': path,
                  'uri': uri,
                  'size': await source.length(),
                  'fileName': '同名书籍 (1).epub',
                };
              case 'checkDownloadedFile':
                verifiedUris.add(call.arguments['contentUri'] as String);
                return {'exists': true, 'size': 512, 'path': path, 'uri': uri};
              default:
                fail('Unexpected Android operation: ${call.method}');
            }
          });
      final task = downloads.startBackgroundDownload(
        book: Book(
          bookId: 'local_book',
          bookName: book.bookName,
          author: book.author,
        ),
        chapters: [chapters.first],
        format: 'EPUB',
      );
      await downloads.waitForIdle();
      expect(task.status, DownloadTaskStatus.completed);
      expect(task.filePath, path);
      final record = await HistoryService.forTesting().getHistoryByBookId(
        'local_book',
      );
      expect(record!.contentUri, uri);
      expect(record.fileSize, greaterThan(0));
      expect(record.copyWithCover('cover').contentUri, uri);
      final info = await downloads.checkVerifiedDownload(task.book);
      expect(info!.contentUri, uri);
      expect(info.fileSize, 512);
      expect(verifiedUris, [
        uri,
      ], reason: 'Never re-probe an exact URI by a less-specific path');
    },
  );

  test(
    'unsupported URI verification and empty local downloads are not complete',
    () async {
      configure((_) async => null);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        (await downloads.verifyDownloadedFile(
          filePath: '',
          contentUri: 'content://media/external/downloads/17',
        )).exists,
        false,
      );
      final empty = File('${root.path}/empty.epub');
      await empty.writeAsBytes([]);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        (await downloads.verifyDownloadedFile(filePath: empty.path)).exists,
        false,
      );
      expect(
        (await downloads.verifyDownloadedFile(
          filePath: '${root.path}/missing.epub',
        )).exists,
        false,
      );
    },
  );

  testWidgets(
    'detail trusts only persisted book-ID paths, not same-title sibling formats',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      configure((_) async => null);
      final saved = File('${root.path}/同名书籍 (1).epub');
      await tester.runAsync(() async {
        await saved.writeAsString('complete known export');
        await File(
          '${root.path}/同名书籍.txt',
        ).writeAsString('another book with the same title');
        await history.addHistory(
          DownloadHistory(
            bookId: 'book',
            bookName: book.bookName,
            author: book.author,
            creationStatus: '完结',
            wordNumber: 1,
            downloadTime: DateTime(2026),
            format: 'EPUB',
            filePath: saved.path,
            fileSize: 100,
          ),
        );
      });
      DownloadService(api, history);
      addTearDown(() => DownloadService(ApiService(), HistoryService()));
      tester.view.physicalSize = const Size(430, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> open(Book shown) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          MaterialApp(
            home: BookDetailScreen(book: shown, apiService: _DetailApi()),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
      }

      await open(book);
      expect(find.text('已下载 (EPUB)'), findsOneWidget);
      expect(find.textContaining('EPUB/TXT'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('已下载'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('大小：21 B'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await open(
        Book(bookId: 'unknown', bookName: book.bookName, author: '其他作者'),
      );
      expect(find.textContaining('已下载'), findsNothing);
      await tester.runAsync(saved.delete);
      await open(book);
      expect(find.textContaining('已下载'), findsNothing);
      expect(find.text('下载'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'offline-first completion never writes a redundant temporary cache',
    () async {
      configure((id) async => OnlineChapter.parse('<p>$id 完整正文。</p>'));
      await engine.downloadChapters(bookId: 'book', chapters: chapters);
      expect(await engine.readerCache.temporaryBytes(), 0);
      for (final chapter in chapters) {
        expect(
          await (await engine.getOfflineChapterFile(
            'book',
            chapter.itemId,
          )).readAsString(),
          '${chapter.itemId} 完整正文。',
        );
      }
    },
  );

  test(
    'low-concurrency sweep recovers chapters after two failed attempts',
    () async {
      var calls = 0;
      configure((_) async => ++calls <= 2 ? null : OnlineChapter('补齐正文'));
      final progress = <int>[];
      await engine.downloadChapters(
        bookId: 'book',
        chapters: [chapters.first],
        onProgress: (current, _, _) => progress.add(current),
      );
      expect(calls, 3);
      expect(progress.last, 1);
      expect(progress.where((value) => value == 1).length, 1);
    },
  );

  test('unavailable chapters never count as completed progress', () async {
    configure((_) async => null);
    final progress = <int>[];
    await expectLater(
      engine.downloadChapters(
        bookId: 'book',
        chapters: chapters,
        onProgress: (current, _, _) => progress.add(current),
      ),
      throwsA(isA<ChapterDownloadIncomplete>()),
    );
    expect(progress, everyElement(0));
  });

  test(
    'offline Windows EPUB has a first, uncompressed mimetype and numbered output',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      configure((_) async => throw StateError('must remain offline'));
      for (final chapter in chapters) {
        await (await engine.getOfflineChapterFile(
          'local_book',
          chapter.itemId,
        )).writeAsString('离线正文 ${chapter.itemId}');
      }
      final output = Directory('${root.path}/custom-output');
      await output.create();
      await (await SharedPreferences.getInstance()).setString(
        'windows_download_dir',
        output.path,
      );
      final oldFile = File('${output.path}/同名书籍.epub');
      await oldFile.writeAsString('previous complete export');
      final saved = File('${output.path}/同名书籍 (1).epub');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
            if (call.method != 'commitDownloadFile') {
              fail('Windows must not show a save panel: ${call.method}');
            }
            expect(call.arguments['directory'], output.path);
            expect(call.arguments['fileName'], '同名书籍.epub');
            await File(call.arguments['sourcePath'] as String).copy(saved.path);
            return {'status': 'saved', 'path': saved.path};
          });
      final path = await downloads.downloadAsEpub(
        Book(
          bookId: 'local_book',
          bookName: book.bookName,
          author: book.author,
        ),
        chapters,
      );
      expect(path, saved.path);
      expect(await oldFile.readAsString(), 'previous complete export');
      final bytes = await saved.readAsBytes();
      final header = ByteData.sublistView(bytes);
      expect(header.getUint32(0, Endian.little), 0x04034b50);
      expect(utf8.decode(bytes.sublist(30, 38)), 'mimetype');
      expect(
        header.getUint16(8, Endian.little),
        0,
        reason: 'EPUB requires the mimetype entry to be stored, not deflated',
      );
      final zip = ZipDecoder().decodeBytes(bytes);
      expect(
        utf8.decode(zip.findFile('mimetype')!.content),
        'application/epub+zip',
      );
      expect(
        utf8.decode(zip.findFile('OEBPS/chapter_1.xhtml')!.content),
        contains('离线正文 one'),
      );
      final restoredHistory = HistoryService.forTesting();
      final record = await restoredHistory.getHistoryByBookId('local_book');
      expect(record!.filePath, saved.path);
      expect(record.fileSize, bytes.length);
    },
  );
}
