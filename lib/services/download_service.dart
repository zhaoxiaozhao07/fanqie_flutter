import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/download_history.dart';
import 'api_service.dart';
import 'history_service.dart';
import 'epub_chapter_content.dart';
import 'cover_cache_service.dart';
import 'book_image_fetcher.dart';
import 'app_storage.dart';
import 'file_export_service.dart';
import 'reader_platform.dart';
import 'download_queue_store.dart';
import 'reader_cache_service.dart';
import '../models/download_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fanqie_backend_engine.dart';

export '../models/download_task.dart';

/// 下载进度回调
typedef ProgressCallback =
    void Function(int current, int total, String message);

/// 下载服务 - 支持后台异步并发下载与直连后端引擎
class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService([
    ApiService? apiService,
    HistoryService? historyService,
  ]) {
    if (apiService != null) _instance._apiService = apiService;
    if (historyService != null) _instance._historyService = historyService;
    return _instance;
  }
  DownloadService._internal()
    : _apiService = ApiService(),
      _historyService = HistoryService(),
      _store = DownloadQueueStore(),
      _exportTask = null,
      _requestPermission = null,
      _forcePersistence = false,
      maxConcurrentTasks = 2,
      chapterConcurrency = 12,
      retryBase = const Duration(seconds: 2);

  @visibleForTesting
  DownloadService.forTesting({
    required ApiService apiService,
    HistoryService? historyService,
    required DownloadQueueStore store,
    Future<String?> Function(DownloadTask)? exportTask,
    Future<bool> Function()? requestPermission,
    this.maxConcurrentTasks = 2,
    this.chapterConcurrency = 12,
    this.retryBase = const Duration(seconds: 2),
  }) : _apiService = apiService,
       _historyService = historyService ?? HistoryService(),
       _store = store,
       _exportTask = exportTask,
       _requestPermission = requestPermission,
       _forcePersistence = true,
       assert(maxConcurrentTasks > 0);

  ApiService _apiService;
  HistoryService _historyService;
  final DownloadQueueStore _store;
  final Future<String?> Function(DownloadTask)? _exportTask;
  final Future<bool> Function()? _requestPermission;
  final bool _forcePersistence;
  int maxConcurrentTasks, chapterConcurrency;
  final Duration retryBase;
  static const preferencesKey = 'reader_download_queue_settings_v1';
  static const platform = MethodChannel('com.fanqie.fanqie_flutter/download');

  final List<DownloadTask> _tasks = [];
  final Map<String, Future<void>> _executions = {};
  Future<void>? _initializing, _writes;
  Future<void>? _settingsWrites;
  Timer? _checkpointTimer;
  Timer? _retryTimer;
  bool _initialized = false, _suspended = false, _closed = false;
  bool _persistenceBlocked = false;
  int _sequence = 0;
  String? queueError;
  bool get _persistent => _forcePersistence || ReaderPlatform.isMacOS;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  List<DownloadTask> get activeTasks =>
      _tasks.where((t) => t.isActive).toList();
  bool get hasActiveTasks => _tasks.any((t) => t.isActive);
  bool isRunning(String id) => _executions.containsKey(id);

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _loadQueue();
  }

  Future<void> _loadQueue() async {
    if (_persistent) {
      try {
        final raw = (await SharedPreferences.getInstance()).getString(
          preferencesKey,
        );
        if (raw != null) {
          final json = jsonDecode(raw) as Map;
          if (json['version'] != 1 ||
              ![1, 2, 3, 4].contains(json['books']) ||
              ![3, 6, 12].contains(json['chapters'])) {
            throw const FormatException('并行设置无效');
          }
          maxConcurrentTasks = json['books'];
          chapterConcurrency = json['chapters'];
        }
      } catch (_) {
        queueError = '并行设置不可读，暂用默认值；原设置未覆盖';
      }
    }
    try {
      if (_persistent) {
        final restored = await _store.load();
        for (final task in restored) {
          if (_tasks.any((current) => current.id == task.id)) continue;
          if (task.isActive) {
            task.status = DownloadTaskStatus.paused;
            task.message = '上次下载中断，点击继续；已下载章节会复用';
            task.nextRetryAt = null;
          }
          _tasks.add(task);
        }
      }
      _initialized = true;
    } catch (error) {
      // Reading remains available. Never overwrite an unreadable queue.
      _persistenceBlocked = true;
      queueError = '下载队列无法读取，原文件已保留：$error';
      _initialized = true;
    } finally {
      if (!_closed) notifyListeners();
    }
  }

  Future<void> retryLoadQueue() async {
    if (_executions.isNotEmpty) return;
    _initialized = false;
    _initializing = null;
    _persistenceBlocked = false;
    queueError = null;
    await initialize();
  }

  Future<void> _persist() {
    if (!_persistent) return Future.value();
    if (_persistenceBlocked) {
      return Future.error(StateError(queueError ?? '下载队列不可写'));
    }
    // Serialize snapshots, not mutable task references observed after an await.
    final snapshot = [
      for (final task in _tasks) DownloadTask.fromJson(task.toJson()),
    ];
    late final Future<void> write;
    write = (_writes ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => _store.save(snapshot))
        .then((_) => queueError = null)
        .then<void>((_) {})
        .whenComplete(() {
          if (identical(_writes, write)) _writes = null;
        });
    _writes = write;
    return write;
  }

  void _checkpoint() {
    if (!_persistent || _checkpointTimer != null || _closed) return;
    _checkpointTimer = Timer(const Duration(milliseconds: 500), () {
      _checkpointTimer = null;
      unawaited(_persist().catchError(_persistenceError));
    });
  }

  void _persistenceError(Object error) {
    queueError = '下载队列未保存，请检查存储空间：$error';
    if (!_closed) notifyListeners();
  }

  Future<void> flush() async {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    await _settingsWrites;
    await initialize();
    await _persist();
    await _writes;
  }

  void _schedule() {
    if (_closed || _suspended) return;
    unawaited(
      initialize().then((_) {
        if (_closed || _suspended) return;
        final limit = _persistent
            ? maxConcurrentTasks
            : DownloadQueueStore.maxTasks;
        final runningBooks = {
          for (final task in _tasks)
            if (isRunning(task.id)) task.book.bookId,
        };
        for (final task in _tasks.reversed.toList()) {
          if (_executions.length >= limit) break;
          if (task.status != DownloadTaskStatus.pending ||
              isRunning(task.id) ||
              runningBooks.contains(task.book.bookId)) {
            continue;
          }
          if (task.nextRetryAt != null &&
              task.nextRetryAt!.isAfter(DateTime.now())) {
            continue;
          }
          task.nextRetryAt = null;
          late final Future<void> execution;
          execution = _executeTask(task).whenComplete(() {
            _executions.remove(task.id);
            if (!_closed) {
              notifyListeners();
              _schedule();
            }
          });
          _executions[task.id] = execution;
          runningBooks.add(task.book.bookId);
          unawaited(execution.catchError(_persistenceError));
        }
        _retryTimer?.cancel();
        final deadlines =
            _tasks
                .where(
                  (e) =>
                      e.status == DownloadTaskStatus.pending &&
                      e.nextRetryAt != null &&
                      e.nextRetryAt!.isAfter(DateTime.now()),
                )
                .map((e) => e.nextRetryAt!)
                .toList()
              ..sort();
        if (deadlines.isNotEmpty) {
          final delay = deadlines.first.difference(DateTime.now());
          _retryTimer = Timer(
            delay.isNegative ? Duration.zero : delay,
            _schedule,
          );
        }
      }),
    );
  }

  Future<void> setConcurrency({int? books, int? chapters}) {
    late final Future<void> pending;
    pending = (_settingsWrites ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => _setConcurrency(books: books, chapters: chapters))
        .whenComplete(() {
          if (identical(_settingsWrites, pending)) _settingsWrites = null;
        });
    _settingsWrites = pending;
    return pending;
  }

  Future<void> _setConcurrency({int? books, int? chapters}) async {
    final count = books ?? maxConcurrentTasks,
        perBook = chapters ?? chapterConcurrency;
    if (![1, 2, 3, 4].contains(count) || ![3, 6, 12].contains(perBook)) {
      throw ArgumentError('并行书籍须为 1–4，每书并行章节须为 3 / 6 / 12');
    }
    if (!await (await SharedPreferences.getInstance()).setString(
      preferencesKey,
      jsonEncode({'version': 1, 'books': count, 'chapters': perBook}),
    )) {
      throw StateError('并行设置未保存');
    }
    maxConcurrentTasks = count;
    chapterConcurrency = perBook;
    if (!_closed) notifyListeners();
    _schedule(); // Existing runs finish; lowering the limit does not destroy work.
  }

  Future<void> prioritize(String id) async {
    await initialize();
    final task = _tasks.where((e) => e.id == id).firstOrNull;
    if (task == null ||
        task.status != DownloadTaskStatus.pending ||
        isRunning(id)) {
      return;
    }
    _tasks.remove(task);
    _tasks.add(
      task,
    ); // Stored newest-first; the scheduler consumes the reverse.
    await _persist();
    notifyListeners();
    _schedule();
  }

  DownloadTask? getActiveTask(String bookId) {
    for (final task in _tasks) {
      if (task.book.bookId == bookId && task.isActive) {
        return task;
      }
    }
    return null;
  }

  bool isDownloading(String bookId) {
    return getActiveTask(bookId) != null;
  }

  /// 启动后台下载任务（非阻塞 UI，下载在后台执行）
  DownloadTask startBackgroundDownload({
    required Book book,
    required List<Chapter> chapters,
    required String format,
  }) {
    final existing = getActiveTask(book.bookId);
    if (existing != null) {
      return existing;
    }
    if (chapters.isEmpty ||
        chapters.length > 50000 ||
        (format != 'TXT' && format != 'EPUB')) {
      throw ArgumentError('下载目录为空、过大或文件格式不受支持');
    }
    for (final previous in _tasks) {
      if (previous.canResume &&
          previous.book.bookId == book.bookId &&
          previous.format == format &&
          listEquals(
            previous.chapters.map((chapter) => chapter.itemId).toList(),
            chapters.map((chapter) => chapter.itemId).toList(),
          )) {
        unawaited(resumeDownload(previous.id).catchError(_persistenceError));
        return previous;
      }
    }
    if (_tasks.length >= DownloadQueueStore.maxTasks) {
      final old = _tasks.lastWhere(
        (task) => !task.isActive && !isRunning(task.id),
        orElse: () => throw StateError('下载队列已满，请先完成或取消任务'),
      );
      _tasks.remove(old);
    }

    final task = DownloadTask(
      id: '${book.bookId}_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
      book: book,
      chapters: chapters,
      format: format,
      total: chapters.length,
      status: DownloadTaskStatus.pending,
      message: '排队等待下载...',
    );

    _tasks.insert(0, task);
    notifyListeners();

    // A task waiting behind the concurrency limit must also be durable, even
    // when the running book is stalled and emits no further progress events.
    unawaited(
      initialize().then((_) => _persist()).catchError((Object error) {
        if (task.status == DownloadTaskStatus.pending && !isRunning(task.id)) {
          task.status = DownloadTaskStatus.failed;
          task.error = error.toString();
          task.message = '下载队列未能保存，未开始下载';
        }
        _persistenceError(error);
      }),
    );
    _schedule();

    return task;
  }

  /// 取消下载任务
  void cancelDownload(String bookId) {
    for (final task in _tasks) {
      if (task.book.bookId == bookId &&
          (task.isActive || task.status == DownloadTaskStatus.paused)) {
        _stopTask(task, paused: false);
      }
    }
    notifyListeners();
    _checkpoint();
  }

  void _stopTask(DownloadTask task, {required bool paused}) {
    task.isCancelled = true;
    task.status = paused
        ? DownloadTaskStatus.paused
        : DownloadTaskStatus.cancelled;
    task.message = paused ? '已暂停，已下载章节会保留' : '已取消，已下载章节仍保留';
    task.nextRetryAt = null;
    if (ReaderPlatform.isMacOS) {
      unawaited(
        ReaderPlatform.invoke('cancelExport', {
          'id': task.id,
        }).catchError((_) => null),
      );
    }
  }

  void pauseDownload(String taskId) {
    final task = _tasks.where((task) => task.id == taskId).firstOrNull;
    if (task == null || !task.isActive) return;
    _stopTask(task, paused: true);
    notifyListeners();
    _checkpoint();
  }

  Future<void> resumeDownload(String taskId) async {
    final task = _tasks.where((task) => task.id == taskId).firstOrNull;
    if (task == null || !task.canResume) return;
    // Never reset the stop flag of a still-running request. Rapid pause/resume
    // waits for that run to unwind, rather than resurrecting its stale response.
    await _executions[taskId];
    if (_closed || !_tasks.contains(task) || !task.canResume) return;
    task.isCancelled = false;
    task.error = null;
    task.errorKind = null;
    task.failedChapterIds = [];
    task.retryCount = 0;
    task.nextRetryAt = null;
    task.status = DownloadTaskStatus.pending;
    task.message = '排队继续，将校验并复用已下载章节';
    await _persist();
    notifyListeners();
    _schedule();
  }

  /// 移除已完成或失败的任务
  Future<void> cancelAllAndWait() async {
    for (final task in activeTasks.toList()) {
      cancelDownload(task.book.bookId);
    }
    await Future.wait(_executions.values.toList());
    if (_initialized && _persistent) await flush();
  }

  Future<void> pauseAllAndWait() async {
    await initialize();
    _suspended = true;
    try {
      for (final task in activeTasks) {
        _stopTask(task, paused: true);
      }
      notifyListeners();
      // Durable interruption state precedes waiting for slow network requests.
      await flush();
      await Future.wait(_executions.values.toList());
      await flush();
    } finally {
      _suspended = false;
    }
  }

  Future<void> prepareToQuit() async {
    if (!_persistent) return cancelAllAndWait();
    await initialize();
    // An unreadable queue never started work. Preserve it verbatim, but do not
    // trap the rest of the reader in an application that cannot be quit.
    if (_persistenceBlocked && !hasActiveTasks && _executions.isEmpty) return;
    _suspended = true;
    try {
      final saving = {
        for (final task in activeTasks)
          if (task.status == DownloadTaskStatus.saving) task.id,
      };
      for (final task in activeTasks) {
        _stopTask(task, paused: true);
      }
      notifyListeners();
      await flush();
      // Cache writes are atomic. A blocked HTTP response need not hold Cmd-Q
      // hostage; its task is already paused durably. Native exports, however,
      // must finish/cancel so an already committed file remains authoritative.
      await Future.wait([
        for (final id in saving)
          if (_executions[id] case final execution?) execution,
      ]);
      await flush();
    } finally {
      _suspended = false;
    }
  }

  Future<void> waitForIdle() async {
    await initialize();
    while (hasActiveTasks || _executions.isNotEmpty) {
      _schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await _writes;
  }

  /// 移除已完成或失败的任务
  void removeTask(String taskId) {
    _tasks.removeWhere(
      (task) => task.id == taskId && !task.isActive && !isRunning(task.id),
    );
    notifyListeners();
    _checkpoint();
  }

  @override
  void dispose() {
    _closed = true;
    _checkpointTimer?.cancel();
    _retryTimer?.cancel();
    for (final task in activeTasks) {
      _stopTask(task, paused: true);
    }
    super.dispose();
  }

  /// 执行后台任务
  Future<void> _executeTask(DownloadTask task) async {
    try {
      await _persist();
      if (task.isCancelled || _closed) return;
      // 检查权限
      if (!await (_requestPermission?.call() ?? _requestStoragePermission())) {
        if (task.isCancelled) return;
        task.status = DownloadTaskStatus.failed;
        task.error = '需要存储权限才能下载文件';
        task.message = '存储权限不足';
        notifyListeners();
        return;
      }
      if (task.isCancelled || _closed) return;

      task.status = DownloadTaskStatus.downloading;
      task.message = '开始并发下载...';
      notifyListeners();
      await _persist();

      DateTime lastNotifyTime = DateTime.now();

      // 直接调用内置后端引擎高性能并发下载，前端不设人为延迟
      await _apiService.downloadChapters(
        bookId: task.book.bookId,
        chapters: task.chapters,
        isCancelled: () => task.isCancelled,
        concurrency: chapterConcurrency,
        onProgress: (current, total, message) {
          if (task.isCancelled) return;
          task.current = current;
          task.total = total;
          task.message = message;
          _checkpoint();

          // 节流通知，避免界面刷新过频
          final now = DateTime.now();
          if (now.difference(lastNotifyTime).inMilliseconds >= 80 ||
              current == total) {
            lastNotifyTime = now;
            notifyListeners();
          }
        },
      );

      if (task.isCancelled) {
        return;
      }

      // 下载阶段结束，立即切换为保存阶段，彻底消除停留在最后一章卡死的问题
      task.status = DownloadTaskStatus.saving;
      task.message = '章节下载完毕，正在生成 ${task.format} 文件...';
      notifyListeners();
      await _persist();
      if (task.isCancelled || _closed) return;

      String? filePath;
      if (_exportTask != null) {
        filePath = await _exportTask(task);
      } else if (task.format == 'TXT') {
        filePath = await _assembleAndSaveTxt(
          task.book,
          task.chapters,
          requestId: task.id,
          isCancelled: () => task.isCancelled,
        );
      } else {
        filePath = await _assembleAndSaveEpub(
          task.book,
          task.chapters,
          requestId: task.id,
          isCancelled: () => task.isCancelled,
        );
      }

      // A saved native result is authoritative: cancellation after the atomic
      // commit cannot turn an existing exported file into a cancelled task.
      if (task.isCancelled && !(ReaderPlatform.isMacOS && filePath != null)) {
        if (task.status != DownloadTaskStatus.paused) {
          task.status = DownloadTaskStatus.cancelled;
          task.message = '导出已取消，已下载正文仍保留';
        }
      } else if (filePath != null) {
        task.status = DownloadTaskStatus.completed;
        task.filePath = filePath;
        task.message = '下载完成';
        task.error = null;
        task.errorKind = null;
        task.failedChapterIds = [];
        task.nextRetryAt = null;
      } else {
        task.status = DownloadTaskStatus.failed;
        task.error = '保存文件失败';
        task.message = '保存文件失败';
        task.errorKind = 'export';
      }
    } catch (e) {
      if (e is FileExportCancelled) {
        task.isCancelled = true;
        if (task.status != DownloadTaskStatus.paused) {
          task.status = DownloadTaskStatus.cancelled;
          task.message = '导出已取消，已下载正文仍保留';
        }
        return;
      }
      if (kDebugMode) {
        debugPrint('DownloadTask error: $e');
      }
      if (!task.isCancelled) {
        task.errorKind = e is ChapterDownloadIncomplete
            ? (e.diskFailure ? 'disk' : 'unavailable')
            : e is FileSystemException
            ? 'disk'
            : e is SocketException ||
                  e is TimeoutException ||
                  e is HttpException
            ? 'network'
            : 'other';
        if (e is ChapterDownloadIncomplete) {
          task.failedChapterIds = e.failedChapterIds;
          task.current = e.downloaded;
        }
        task.error = e.toString();
        if (task.errorKind == 'network' && task.retryCount < 2) {
          task.retryCount++;
          task.nextRetryAt = DateTime.now().add(
            retryBase * (1 << (task.retryCount - 1)),
          );
          task.status = DownloadTaskStatus.pending;
          task.message = '网络错误，${task.retryCount}/2 次退避重试；已下载章节保留';
        } else {
          task.status = DownloadTaskStatus.failed;
          task.message =
              '${task.errorKind == 'disk'
                  ? '存储写入失败'
                  : task.errorKind == 'unavailable'
                  ? '部分章节未完整提供'
                  : '下载未完成'}；成功缓存保留，可查看详情后重试';
        }
      }
    } finally {
      if (!_closed) {
        notifyListeners();
        await _persist();
      }
    }
  }

  /// 保持向后兼容的同步 TXT 下载方法
  Future<String?> downloadAsTxt(
    Book book,
    List<Chapter> chapters, {
    ProgressCallback? onProgress,
  }) async {
    try {
      if (!await _requestStoragePermission()) {
        onProgress?.call(0, 0, '需要存储权限才能下载文件');
        return null;
      }

      final totalChapters = chapters.length;
      onProgress?.call(0, totalChapters, '开始并发下载...');

      // 直接使用后端下载接口，无批次人为限制
      await _apiService.downloadChapters(
        bookId: book.bookId,
        chapters: chapters,
        concurrency: 12,
        onProgress: onProgress,
      );

      onProgress?.call(totalChapters, totalChapters, '正在合并文件...');
      final filePath = await _assembleAndSaveTxt(book, chapters);
      if (filePath != null) {
        onProgress?.call(totalChapters, totalChapters, '下载完成');
        return filePath;
      }
      return null;
    } catch (e) {
      onProgress?.call(0, 0, '下载失败: $e');
      return null;
    }
  }

  /// 保持向后兼容的同步 EPUB 下载方法
  Future<String?> downloadAsEpub(
    Book book,
    List<Chapter> chapters, {
    ProgressCallback? onProgress,
  }) async {
    try {
      if (!await _requestStoragePermission()) {
        onProgress?.call(0, 0, '需要存储权限才能下载文件');
        return null;
      }

      final totalChapters = chapters.length;
      onProgress?.call(0, totalChapters, '开始并发下载...');

      // 直接使用后端下载接口，无批次人为限制
      await _apiService.downloadChapters(
        bookId: book.bookId,
        chapters: chapters,
        concurrency: 12,
        onProgress: onProgress,
      );

      onProgress?.call(totalChapters, totalChapters, '正在生成 EPUB...');
      final filePath = await _assembleAndSaveEpub(book, chapters);
      if (filePath != null) {
        onProgress?.call(totalChapters, totalChapters, '下载完成');
        return filePath;
      }
      return null;
    } catch (e) {
      onProgress?.call(0, 0, '下载失败: $e');
      return null;
    }
  }

  /// 组装并保存 TXT 文件
  Future<String?> _assembleAndSaveTxt(
    Book book,
    List<Chapter> chapters, {
    String? requestId,
    bool Function()? isCancelled,
  }) async {
    Directory? staging;
    try {
      final offlineDir = await _apiService.engine.getOfflineBookDir(
        book.bookId,
      );
      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      final safeFileName =
          '${book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.txt';
      staging = await tempDir.createTemp('reader-download-');
      final tempFile = File('${staging.path}/$safeFileName');
      final sink = tempFile.openWrite();

      sink.writeln('《${book.bookName}》\n作者: ${book.author}\n\n');

      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        final cacheFile = File(
          '${offlineDir.path}/${ReaderCacheService.segment(ch.itemId)}.txt',
        );
        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          await sink.addStream(cacheFile.openRead());
        } else {
          await sink.close();
          throw const FileSystemException('已下载章节不完整，未生成占位正文');
        }
        if (i < chapters.length - 1) {
          sink.writeln(
            '\n\n${'=' * 40}\n${chapters[i + 1].title}\n${'=' * 40}\n\n',
          );
        }
      }
      await sink.close();
      if (isCancelled?.call() == true) throw const FileExportCancelled();

      final savedPath = await _saveFileViaPlatform(
        tempFile.path,
        safeFileName,
        'text/plain',
        requestId: requestId,
        isCancelled: isCancelled,
      );

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (savedPath != null) {
        if (!ReaderPlatform.isMacOS && isCancelled?.call() == true) {
          throw const FileExportCancelled();
        }
        int fileSize = 0;
        final file = File(savedPath);
        if (await file.exists()) {
          fileSize = await file.length();
        }

        await _historyService.addHistory(
          DownloadHistory(
            bookId: book.bookId,
            bookName: book.bookName,
            author: book.author,
            thumbUrl: book.thumbUrl,
            category: book.category,
            creationStatus: book.creationStatus,
            wordNumber: book.wordNumber,
            downloadTime: DateTime.now(),
            format: 'TXT',
            filePath: savedPath,
            fileSize: fileSize,
          ),
        );
        return savedPath;
      }
    } catch (e) {
      if (e is FileExportCancelled) rethrow;
      if (kDebugMode) debugPrint('_assembleAndSaveTxt error: $e');
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
    return null;
  }

  /// 组装并保存 EPUB 文件
  Future<String?> _assembleAndSaveEpub(
    Book book,
    List<Chapter> chapters, {
    String? requestId,
    bool Function()? isCancelled,
  }) async {
    Directory? staging;
    try {
      final offlineDir = await _apiService.engine.getOfflineBookDir(
        book.bookId,
      );
      final safeFileName =
          '${book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.epub';

      final chapterContents = <Map<String, String>>[];
      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        final cacheFile = File(
          '${offlineDir.path}/${ReaderCacheService.segment(ch.itemId)}.txt',
        );
        if (!await cacheFile.exists()) {
          throw const FileSystemException('已下载章节不完整，未生成占位正文');
        }
        final content = await cacheFile.readAsString();
        if (!ReaderCacheService.isReadable(content)) {
          throw const FileSystemException('已下载正文无效，未生成占位正文');
        }
        chapterContents.add({'title': chapters[i].title, 'content': content});
      }

      // 下载封面
      List<int>? coverImageBytes;
      var coverExtension = 'jpg';
      if (book.thumbUrl != null && book.thumbUrl!.isNotEmpty) {
        try {
          final file = await CoverCacheService().cacheNetworkCover(
            book.bookId,
            book.thumbUrl!,
          );
          if (file != null) {
            final image = await BookImageFetcher.validate(
              await file.readAsBytes(),
            );
            coverImageBytes = image.bytes;
            coverExtension = image.extension;
          }
        } catch (_) {}
      }

      final archive = Archive();
      final uuid = DateTime.now().millisecondsSinceEpoch.toString();
      final hasCoverImage =
          coverImageBytes != null && coverImageBytes.isNotEmpty;

      archive.addFile(
        ArchiveFile(
          'mimetype',
          'application/epub+zip'.length,
          utf8.encode('application/epub+zip'),
        ),
      );

      final containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
      archive.addFile(
        ArchiveFile(
          'META-INF/container.xml',
          utf8.encode(containerXml).length,
          utf8.encode(containerXml),
        ),
      );

      if (hasCoverImage) {
        archive.addFile(
          ArchiveFile(
            'OEBPS/Images/cover.$coverExtension',
            coverImageBytes.length,
            coverImageBytes,
          ),
        );
      }

      final manifestItems = StringBuffer();
      final spineItems = StringBuffer();
      final navPoints = StringBuffer();
      final tocLinks = StringBuffer();
      final imageAssets = <String>{};

      if (hasCoverImage) {
        manifestItems.writeln(
          '    <item id="cover-image" href="Images/cover.$coverExtension" media-type="image/${coverExtension == 'jpg' ? 'jpeg' : coverExtension}" properties="cover-image"/>',
        );
      }

      String coverContent;
      if (hasCoverImage) {
        coverContent =
            '''
<div style="text-align: center; padding: 0; margin: 0;">
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" 
       height="100%" preserveAspectRatio="xMidYMid meet" version="1.1" viewBox="0 0 600 800" width="100%">
    <image width="600" height="800" xlink:href="Images/cover.$coverExtension"/>
  </svg>
</div>
''';
      } else {
        coverContent =
            '''
<div style="text-align: center; padding-top: 30%;">
  <h1 style="font-size: 2em; margin-bottom: 0.5em;">${_escapeXml(book.bookName)}</h1>
  <p style="font-size: 1.2em; color: #666;">作者：${_escapeXml(book.author)}</p>
  <p>分类：${_escapeXml(book.category ?? '未分类')}</p>
  <p>字数：${_escapeXml(book.formattedWordCount)}</p>
  <p>状态：${_escapeXml(book.creationStatus)}</p>
  <hr style="margin: 2em auto; width: 50%;"/>
  <h2>简介</h2>
  <p style="text-align: left; text-indent: 2em;">${_escapeXml(book.abstract ?? '暂无简介')}</p>
</div>
''';
      }
      final coverHtml = _generateXhtml('封面', coverContent);
      archive.addFile(
        ArchiveFile(
          'OEBPS/cover.xhtml',
          utf8.encode(coverHtml).length,
          utf8.encode(coverHtml),
        ),
      );
      manifestItems.writeln(
        '    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>',
      );
      spineItems.writeln('    <itemref idref="cover"/>');
      navPoints.writeln(_generateNavPoint('cover', '封面', 1, 'cover.xhtml'));

      for (var i = 0; i < chapters.length; i++) {
        final title = chapters[i].title;
        final chapterFile = 'chapter_${i + 1}.xhtml';
        tocLinks.writeln(
          '  <p style="margin: 0.5em 0;"><a href="$chapterFile">${_escapeXml(title)}</a></p>',
        );
      }

      final tocPageHtml = _generateXhtml('目录', '''
<h1 style="text-align: center;">目录</h1>
<div style="padding: 1em;">
$tocLinks</div>
''');
      archive.addFile(
        ArchiveFile(
          'OEBPS/toc_page.xhtml',
          utf8.encode(tocPageHtml).length,
          utf8.encode(tocPageHtml),
        ),
      );
      manifestItems.writeln(
        '    <item id="toc_page" href="toc_page.xhtml" media-type="application/xhtml+xml"/>',
      );
      spineItems.writeln('    <itemref idref="toc_page"/>');
      navPoints.writeln(
        _generateNavPoint('toc_page', '目录', 2, 'toc_page.xhtml'),
      );

      for (var i = 0; i < chapters.length; i++) {
        final chapter = chapterContents[i];
        final chapterId = 'chapter_${i + 1}';
        final chapterFile = '$chapterId.xhtml';
        final title = chapter['title'] ?? '第${i + 1}章';
        final content = chapter['content'] ?? '';

        final images = await _apiService.engine.onlineImages.read(
          book.bookId,
          chapters[i].itemId,
          content,
          title: title,
        );
        for (final image in images) {
          final asset = image.asset;
          if (asset == null || image.error != null || !imageAssets.add(asset)) {
            continue;
          }
          final file = File('${offlineDir.path}/$asset');
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile('OEBPS/$asset', bytes.length, bytes));
          final extension = asset.split('.').last;
          final mime = extension == 'jpg' ? 'jpeg' : extension;
          manifestItems.writeln(
            '    <item id="illustration-${imageAssets.length}" href="$asset" media-type="image/$mime"/>',
          );
        }
        final paragraphs = epubChapterContent(content, title, images);

        final chapterHtml = _generateXhtml(title, '''
<h1>${_escapeXml(title)}</h1>
$paragraphs
''');
        archive.addFile(
          ArchiveFile(
            'OEBPS/$chapterFile',
            utf8.encode(chapterHtml).length,
            utf8.encode(chapterHtml),
          ),
        );

        manifestItems.writeln(
          '    <item id="$chapterId" href="$chapterFile" media-type="application/xhtml+xml"/>',
        );
        spineItems.writeln('    <itemref idref="$chapterId"/>');
        navPoints.writeln(
          _generateNavPoint(chapterId, title, i + 3, chapterFile),
        );
      }

      final coverMeta = hasCoverImage
          ? '\n    <meta name="cover" content="cover-image"/>'
          : '';
      final contentOpf =
          '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>${_escapeXml(book.bookName)}</dc:title>
    <dc:creator opf:role="aut">${_escapeXml(book.author)}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:identifier id="BookId">urn:uuid:$uuid</dc:identifier>
    <dc:publisher>番茄Reader</dc:publisher>$coverMeta
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
$manifestItems  </manifest>
  <spine toc="ncx">
$spineItems  </spine>
  <guide>
    <reference type="cover" title="封面" href="cover.xhtml"/>
    <reference type="toc" title="目录" href="toc_page.xhtml"/>
  </guide>
</package>''';
      archive.addFile(
        ArchiveFile(
          'OEBPS/content.opf',
          utf8.encode(contentOpf).length,
          utf8.encode(contentOpf),
        ),
      );

      final tocNcx =
          '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:$uuid"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>${_escapeXml(book.bookName)}</text>
  </docTitle>
  <navMap>
$navPoints  </navMap>
</ncx>''';
      archive.addFile(
        ArchiveFile(
          'OEBPS/toc.ncx',
          utf8.encode(tocNcx).length,
          utf8.encode(tocNcx),
        ),
      );

      final zipData = ZipEncoder().encode(archive);

      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      staging = await tempDir.createTemp('reader-download-');
      final tempFile = File('${staging.path}/$safeFileName');
      await tempFile.writeAsBytes(zipData);
      if (isCancelled?.call() == true) throw const FileExportCancelled();

      final savedPath = await _saveFileViaPlatform(
        tempFile.path,
        safeFileName,
        'application/epub+zip',
        requestId: requestId,
        isCancelled: isCancelled,
      );

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (savedPath != null) {
        if (!ReaderPlatform.isMacOS && isCancelled?.call() == true) {
          throw const FileExportCancelled();
        }
        final file = File(savedPath);
        int fileSize = 0;
        if (await file.exists()) {
          fileSize = await file.length();
        }

        await _historyService.addHistory(
          DownloadHistory(
            bookId: book.bookId,
            bookName: book.bookName,
            author: book.author,
            thumbUrl: book.thumbUrl,
            category: book.category,
            creationStatus: book.creationStatus,
            wordNumber: book.wordNumber,
            downloadTime: DateTime.now(),
            format: 'EPUB',
            filePath: savedPath,
            fileSize: fileSize,
          ),
        );
        return savedPath;
      }
    } catch (e) {
      if (e is FileExportCancelled) rethrow;
      if (kDebugMode) debugPrint('_assembleAndSaveEpub error: $e');
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
    return null;
  }

  /// 通过平台通道将临时文件保存到 Android 的 Downloads/fanqie，非 Android 环境保存到文档目录
  Future<String?> _saveFileViaPlatform(
    String tempFilePath,
    String safeFileName,
    String mimeType, {
    String? requestId,
    bool Function()? isCancelled,
  }) async {
    if (ReaderPlatform.isMacOS) {
      final result = await FileExportService().save(
        File(tempFilePath),
        name: safeFileName,
        mimeType: mimeType,
        requestId: requestId,
        isCancelled: isCancelled,
      );
      if (result.status == FileExportStatus.cancelled) {
        throw const FileExportCancelled();
      }
      if (result.status == FileExportStatus.failed) {
        throw FileSystemException(result.error ?? '导出保存失败');
      }
      return result.path;
    } else if (Platform.isAndroid) {
      try {
        final bool success = await platform.invokeMethod('saveToDownloads', {
          'filePath': tempFilePath,
          'fileName': safeFileName,
          'mimeType': mimeType,
        });
        if (success) {
          return '/storage/emulated/0/Download/fanqie/$safeFileName';
        }
      } catch (e) {
        if (kDebugMode) debugPrint('saveToDownloads platform error: $e');
      }
    } else {
      try {
        final docDir = await AppStorage.documents();
        final saveDir = Directory('${docDir.path}/fanqie_downloads');
        if (!await saveDir.exists()) {
          await saveDir.create(recursive: true);
        }
        final target = File('${saveDir.path}/$safeFileName');
        final src = File(tempFilePath);
        await src.copy(target.path);
        return target.path;
      } catch (e) {
        if (kDebugMode) debugPrint('Non-android file save error: $e');
      }
    }
    return null;
  }

  /// 请求存储权限
  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    var status = await Permission.storage.request();
    if (status.isGranted) return true;

    if (status.isDenied || status.isRestricted || status.isPermanentlyDenied) {
      status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
    }

    if (status.isPermanentlyDenied) {
      openAppSettings();
    }
    return false;
  }

  String _generateXhtml(String title, String bodyContent) {
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
  <title>${_escapeXml(title)}</title>
  <style type="text/css">
    body { font-family: serif; line-height: 1.6; margin: 1em; }
    h1 { text-align: center; margin-bottom: 1em; }
    p { text-indent: 2em; margin: 0.5em 0; }
  </style>
</head>
<body>
$bodyContent
</body>
</html>''';
  }

  String _generateNavPoint(String id, String title, int order, String src) {
    return '''    <navPoint id="$id" playOrder="$order">
      <navLabel><text>${_escapeXml(title)}</text></navLabel>
      <content src="$src"/>
    </navPoint>
''';
  }

  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
