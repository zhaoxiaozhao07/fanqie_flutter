import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/download_history.dart';
import 'api_service.dart';
import 'history_service.dart';

/// 下载任务状态
enum DownloadTaskStatus {
  pending,
  downloading,
  saving,
  completed,
  failed,
  cancelled,
}

/// 后台下载任务模型
class DownloadTask {
  final String id;
  final Book book;
  final List<Chapter> chapters;
  final String format; // 'TXT' / 'EPUB'
  DownloadTaskStatus status;
  int current;
  int total;
  String message;
  String? filePath;
  String? error;
  final DateTime startTime;
  bool isCancelled = false;

  DownloadTask({
    required this.id,
    required this.book,
    required this.chapters,
    required this.format,
    this.status = DownloadTaskStatus.pending,
    this.current = 0,
    required this.total,
    this.message = '准备中...',
    this.filePath,
    this.error,
    DateTime? startTime,
  }) : startTime = startTime ?? DateTime.now();

  double get progress => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;

  bool get isActive =>
      status == DownloadTaskStatus.downloading ||
      status == DownloadTaskStatus.saving ||
      status == DownloadTaskStatus.pending;
}

/// 下载进度回调
typedef ProgressCallback = void Function(int current, int total, String message);

/// 下载服务 - 支持后台异步并发下载与直连后端引擎
class DownloadService extends ChangeNotifier {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService([ApiService? apiService, HistoryService? historyService]) {
    if (apiService != null) _instance._apiService = apiService;
    if (historyService != null) _instance._historyService = historyService;
    return _instance;
  }
  DownloadService._internal()
      : _apiService = ApiService(),
        _historyService = HistoryService();

  ApiService _apiService;
  HistoryService _historyService;
  static const platform = MethodChannel('com.fanqie.fanqie_flutter/download');

  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  List<DownloadTask> get activeTasks => _tasks.where((t) => t.isActive).toList();
  bool get hasActiveTasks => _tasks.any((t) => t.isActive);

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

    final task = DownloadTask(
      id: '${book.bookId}_${DateTime.now().millisecondsSinceEpoch}',
      book: book,
      chapters: chapters,
      format: format,
      total: chapters.length,
      status: DownloadTaskStatus.pending,
      message: '正在准备下载...',
    );

    _tasks.insert(0, task);
    notifyListeners();

    // 异步执行下载流程，不阻塞当前调用
    _executeTask(task);

    return task;
  }

  /// 取消下载任务
  void cancelDownload(String bookId) {
    for (final task in _tasks) {
      if (task.book.bookId == bookId && task.isActive) {
        task.isCancelled = true;
        task.status = DownloadTaskStatus.cancelled;
        task.message = '已取消下载';
      }
    }
    notifyListeners();
  }

  /// 移除已完成或失败的任务
  void removeTask(String taskId) {
    _tasks.removeWhere((t) => t.id == taskId);
    notifyListeners();
  }

  /// 执行后台任务
  Future<void> _executeTask(DownloadTask task) async {
    try {
      // 检查权限
      if (!await _requestStoragePermission()) {
        task.status = DownloadTaskStatus.failed;
        task.error = '需要存储权限才能下载文件';
        task.message = '存储权限不足';
        notifyListeners();
        return;
      }

      task.status = DownloadTaskStatus.downloading;
      task.message = '开始并发下载...';
      notifyListeners();

      DateTime lastNotifyTime = DateTime.now();

      // 直接调用内置后端引擎高性能并发下载，前端不设人为延迟
      await _apiService.downloadChapters(
        bookId: task.book.bookId,
        chapters: task.chapters,
        isCancelled: () => task.isCancelled,
        concurrency: 12,
        onProgress: (current, total, message) {
          if (task.isCancelled) return;
          task.current = current;
          task.total = total;
          task.message = message;

          // 节流通知，避免界面刷新过频
          final now = DateTime.now();
          if (now.difference(lastNotifyTime).inMilliseconds >= 80 || current == total) {
            lastNotifyTime = now;
            notifyListeners();
          }
        },
      );

      if (task.isCancelled) {
        task.status = DownloadTaskStatus.cancelled;
        task.message = '下载已取消';
        notifyListeners();
        return;
      }

      // 下载阶段结束，立即切换为保存阶段，彻底消除停留在最后一章卡死的问题
      task.status = DownloadTaskStatus.saving;
      task.message = '章节下载完毕，正在生成 ${task.format} 文件...';
      notifyListeners();

      String? filePath;
      if (task.format == 'TXT') {
        filePath = await _assembleAndSaveTxt(task.book, task.chapters);
      } else {
        filePath = await _assembleAndSaveEpub(task.book, task.chapters);
      }

      if (filePath != null) {
        task.status = DownloadTaskStatus.completed;
        task.filePath = filePath;
        task.message = '下载完成';
      } else {
        task.status = DownloadTaskStatus.failed;
        task.error = '保存文件失败';
        task.message = '保存文件失败';
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('DownloadTask error: $e');
      }
      task.status = DownloadTaskStatus.failed;
      task.error = e.toString();
      task.message = '下载异常: $e';
    } finally {
      notifyListeners();
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
  Future<String?> _assembleAndSaveTxt(Book book, List<Chapter> chapters) async {
    try {
      final offlineDir = await _apiService.engine.getOfflineBookDir(book.bookId);
      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      final safeFileName = '${book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.txt';
      final tempFile = File('${tempDir.path}/$safeFileName');
      final sink = tempFile.openWrite();

      sink.writeln('《${book.bookName}》\n作者: ${book.author}\n\n');

      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        final cacheFile = File('${offlineDir.path}/${ch.itemId}.txt');
        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          await sink.addStream(cacheFile.openRead());
        } else {
          sink.writeln('[章节内容下载失败]');
        }
        if (i < chapters.length - 1) {
          sink.writeln('\n\n${'=' * 40}\n${chapters[i + 1].title}\n${'=' * 40}\n\n');
        }
      }
      await sink.close();

      final savedPath = await _saveFileViaPlatform(tempFile.path, safeFileName, 'text/plain');

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (savedPath != null) {
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
      if (kDebugMode) debugPrint('_assembleAndSaveTxt error: $e');
    }
    return null;
  }

  /// 组装并保存 EPUB 文件
  Future<String?> _assembleAndSaveEpub(Book book, List<Chapter> chapters) async {
    try {
      final offlineDir = await _apiService.engine.getOfflineBookDir(book.bookId);
      final safeFileName = '${book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '')}.epub';

      final chapterContents = <Map<String, String>>[];
      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        final cacheFile = File('${offlineDir.path}/${ch.itemId}.txt');
        String content = '[章节内容下载失败]';
        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          content = await cacheFile.readAsString();
        }
        chapterContents.add({'title': chapters[i].title, 'content': content});
      }

      // 下载封面
      List<int>? coverImageBytes;
      if (book.thumbUrl != null && book.thumbUrl!.isNotEmpty) {
        try {
          final res = await http.get(Uri.parse(book.thumbUrl!)).timeout(const Duration(seconds: 15));
          if (res.statusCode == 200) {
            coverImageBytes = res.bodyBytes;
          }
        } catch (_) {}
      }

      final archive = Archive();
      final uuid = DateTime.now().millisecondsSinceEpoch.toString();
      final hasCoverImage = coverImageBytes != null && coverImageBytes.isNotEmpty;

      archive.addFile(
        ArchiveFile('mimetype', 'application/epub+zip'.length, utf8.encode('application/epub+zip')),
      );

      final containerXml = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
      archive.addFile(
        ArchiveFile('META-INF/container.xml', utf8.encode(containerXml).length, utf8.encode(containerXml)),
      );

      if (hasCoverImage) {
        archive.addFile(ArchiveFile('OEBPS/Images/cover.jpg', coverImageBytes.length, coverImageBytes));
      }

      final manifestItems = StringBuffer();
      final spineItems = StringBuffer();
      final navPoints = StringBuffer();
      final tocLinks = StringBuffer();

      if (hasCoverImage) {
        manifestItems.writeln(
          '    <item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
        );
      }

      String coverContent;
      if (hasCoverImage) {
        coverContent = '''
<div style="text-align: center; padding: 0; margin: 0;">
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" 
       height="100%" preserveAspectRatio="xMidYMid meet" version="1.1" viewBox="0 0 600 800" width="100%">
    <image width="600" height="800" xlink:href="Images/cover.jpg"/>
  </svg>
</div>
''';
      } else {
        coverContent = '''
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
        ArchiveFile('OEBPS/cover.xhtml', utf8.encode(coverHtml).length, utf8.encode(coverHtml)),
      );
      manifestItems.writeln('    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>');
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
        ArchiveFile('OEBPS/toc_page.xhtml', utf8.encode(tocPageHtml).length, utf8.encode(tocPageHtml)),
      );
      manifestItems.writeln('    <item id="toc_page" href="toc_page.xhtml" media-type="application/xhtml+xml"/>');
      spineItems.writeln('    <itemref idref="toc_page"/>');
      navPoints.writeln(_generateNavPoint('toc_page', '目录', 2, 'toc_page.xhtml'));

      for (var i = 0; i < chapters.length; i++) {
        final chapter = chapterContents[i];
        final chapterId = 'chapter_${i + 1}';
        final chapterFile = '$chapterId.xhtml';
        final title = chapter['title'] ?? '第${i + 1}章';
        final content = chapter['content'] ?? '';

        final paragraphs = content
            .split('\n')
            .where((p) => p.trim().isNotEmpty)
            .map((p) => '<p>${_escapeXml(p.trim())}</p>')
            .join('\n');

        final chapterHtml = _generateXhtml(title, '''
<h1>${_escapeXml(title)}</h1>
$paragraphs
''');
        archive.addFile(
          ArchiveFile('OEBPS/$chapterFile', utf8.encode(chapterHtml).length, utf8.encode(chapterHtml)),
        );

        manifestItems.writeln('    <item id="$chapterId" href="$chapterFile" media-type="application/xhtml+xml"/>');
        spineItems.writeln('    <itemref idref="$chapterId"/>');
        navPoints.writeln(_generateNavPoint(chapterId, title, i + 3, chapterFile));
      }

      final coverMeta = hasCoverImage ? '\n    <meta name="cover" content="cover-image"/>' : '';
      final contentOpf = '''<?xml version="1.0" encoding="UTF-8"?>
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
        ArchiveFile('OEBPS/content.opf', utf8.encode(contentOpf).length, utf8.encode(contentOpf)),
      );

      final tocNcx = '''<?xml version="1.0" encoding="UTF-8"?>
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
        ArchiveFile('OEBPS/toc.ncx', utf8.encode(tocNcx).length, utf8.encode(tocNcx)),
      );

      final zipData = ZipEncoder().encode(archive);

      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      final tempFile = File('${tempDir.path}/$safeFileName');
      await tempFile.writeAsBytes(zipData);

      final savedPath = await _saveFileViaPlatform(tempFile.path, safeFileName, 'application/epub+zip');

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (savedPath != null) {
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
      if (kDebugMode) debugPrint('_assembleAndSaveEpub error: $e');
    }
    return null;
  }

  /// 通过平台通道将临时文件保存到 Android 的 Downloads/fanqie，非 Android 环境保存到文档目录
  Future<String?> _saveFileViaPlatform(String tempFilePath, String safeFileName, String mimeType) async {
    if (Platform.isAndroid) {
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
        final docDir = await getApplicationDocumentsDirectory();
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
