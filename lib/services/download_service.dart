import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../models/download_history.dart';
import 'api_service.dart';
import 'history_service.dart';

/// 下载进度回调
typedef ProgressCallback =
    void Function(int current, int total, String message);

/// 下载服务 - 负责下载小说并保存到本地
class DownloadService {
  final ApiService _apiService;
  final HistoryService _historyService;
  static const platform = MethodChannel('com.fanqie.fanqie_flutter/download');

  /// 并发下载配置
  static const int _concurrentBatchSize = 10; // 每批并发下载章节数
  static const int _maxRetryCount = 3; // 单章最大重试次数
  static const Duration _batchDelay = Duration(milliseconds: 100); // 批次间延迟

  DownloadService(this._apiService, this._historyService);

  /// 获取书籍缓存目录
  Future<Directory> _getCacheDirectory(String bookId) async {
    final tempDir = await getTemporaryDirectory();
    final cacheDir = Directory('${tempDir.path}/downloads/$bookId');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  /// 获取章节缓存文件
  File _getChapterCacheFile(Directory cacheDir, int index) {
    return File('${cacheDir.path}/$index.txt');
  }

  /// 清理缓存
  Future<void> _clearCache(String bookId) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = Directory('${tempDir.path}/downloads/$bookId');
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      print('清理缓存失败: $e');
    }
  }

  /// 并发分批下载章节内容（支持断点续传）
  Future<void> _downloadChaptersConcurrently(
    String bookId,
    List<Chapter> chapters, {
    ProgressCallback? onProgress,
  }) async {
    final cacheDir = await _getCacheDirectory(bookId);
    final totalChapters = chapters.length;
    int completedCount = 0;

    // 分批处理
    for (
      int batchStart = 0;
      batchStart < chapters.length;
      batchStart += _concurrentBatchSize
    ) {
      final batchEnd = (batchStart + _concurrentBatchSize).clamp(
        0,
        chapters.length,
      );
      final batchChapters = chapters.sublist(batchStart, batchEnd);

      // 批内并发下载
      final batchFutures = batchChapters.asMap().entries.map((entry) async {
        final globalIndex = batchStart + entry.key;
        final chapter = entry.value;
        final cacheFile = _getChapterCacheFile(cacheDir, globalIndex);

        // 检查缓存
        if (await cacheFile.exists()) {
          if (await cacheFile.length() > 0) {
            return; // 已下载
          }
        }

        // 带重试的单章下载
        String? content;
        for (int retry = 0; retry < _maxRetryCount; retry++) {
          try {
            content = await _apiService.getChapterContent(chapter.itemId);
            if (content != null && content.isNotEmpty) break;
          } catch (_) {}

          if (retry < _maxRetryCount - 1) {
            await Future.delayed(Duration(milliseconds: 100 * (retry + 1)));
          }
        }

        // 写入缓存
        if (content != null && content.isNotEmpty) {
          await cacheFile.writeAsString(content);
        }
      });

      await Future.wait(batchFutures);

      // 更新进度
      for (int i = batchStart; i < batchEnd; i++) {
        final cacheFile = _getChapterCacheFile(cacheDir, i);
        // 简单认为即使失败也算处理完，避免死循环。或者这里只统计成功的？
        // 为了进度条能走完，我们统计处理过的。
        // 但为了准确性，我们可以在 status row 显示失败。
        // 这里只更新 count.
        completedCount++;
        // 获取标题
        final title = chapters[i].title;

        // 如果缓存存在，说明是秒传或下载成功
        bool exists = await cacheFile.exists() && await cacheFile.length() > 0;
        String msg = exists
            ? '正在下载: $title'
            : '下载失败: $title'; // 实际上如果是 cached, 显示正在下载可能很快闪过

        onProgress?.call(completedCount, totalChapters, msg);
      }

      // 批次间延迟
      if (batchEnd < chapters.length) {
        await Future.delayed(_batchDelay);
      }
    }
  }

  /// 下载小说并保存为 TXT 格式
  Future<String?> downloadAsTxt(
    Book book,
    List<Chapter> chapters, {
    ProgressCallback? onProgress,
  }) async {
    try {
      // 请求存储权限
      if (!await _requestStoragePermission()) {
        onProgress?.call(0, 0, '需要存储权限才能下载文件');
        return null;
      }

      final totalChapters = chapters.length;

      // 添加书籍标题
      // contentParts removed, using stream

      // 并发分批下载（写入缓存）
      onProgress?.call(0, totalChapters, '开始并发下载...');
      await _downloadChaptersConcurrently(
        book.bookId,
        chapters,
        onProgress: onProgress,
      );

      // 组装文件
      onProgress?.call(totalChapters, totalChapters, '正在合并文件...');

      final tempDir = await getTemporaryDirectory();
      final safeFileName =
          book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '') + '.txt';
      final tempFile = File('${tempDir.path}/$safeFileName');
      final sink = tempFile.openWrite();

      final cacheDir = await _getCacheDirectory(book.bookId);

      sink.writeln('《${book.bookName}》\n作者: ${book.author}\n\n');

      // 顺序读取缓存并写入
      for (int i = 0; i < chapters.length; i++) {
        final cacheFile = _getChapterCacheFile(cacheDir, i);
        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          // 流式读取以节省内存
          await sink.addStream(cacheFile.openRead());
        } else {
          sink.writeln('[章节内容下载失败]');
        }
        // 分隔符
        if (i < chapters.length - 1) {
          sink.writeln(
            '\n\n${'=' * 40}\n${chapters[i + 1].title}\n${'=' * 40}\n\n',
          );
        }
      }

      await sink.close();

      // 保存文件
      onProgress?.call(totalChapters, totalChapters, '正在保存文件...');

      final bool success = await platform.invokeMethod('saveToDownloads', {
        'filePath': tempFile.path,
        'fileName': safeFileName,
        'mimeType': 'text/plain',
      });

      // 删除合并后的临时文件
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (success) {
        // 清理分章缓存
        await _clearCache(book.bookId);

        final filePath = '/storage/emulated/0/Download/fanqie/$safeFileName';

        // 记录下载历史
        final file = File(filePath);
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
            format: 'TXT',
            filePath: filePath,
            fileSize: fileSize,
          ),
        );

        onProgress?.call(totalChapters, totalChapters, '下载完成');
        return filePath;
      }

      return null;
    } catch (e) {
      onProgress?.call(0, 0, '下载失败: $e');
      return null;
    }
  }

  /// 下载小说并保存为 EPUB 格式
  Future<String?> downloadAsEpub(
    Book book,
    List<Chapter> chapters, {
    ProgressCallback? onProgress,
  }) async {
    try {
      // 请求存储权限
      if (!await _requestStoragePermission()) {
        onProgress?.call(0, 0, '需要存储权限才能下载文件');
        return null;
      }

      final totalChapters = chapters.length;
      final chapterContents = <Map<String, String>>[];

      // 并发分批下载（写入缓存）
      onProgress?.call(0, totalChapters, '开始并发下载...');
      await _downloadChaptersConcurrently(
        book.bookId,
        chapters,
        onProgress: onProgress,
      );

      // 从缓存读取内容
      onProgress?.call(totalChapters, totalChapters, '正在读取缓存...');
      final cacheDir = await _getCacheDirectory(book.bookId);

      for (int i = 0; i < chapters.length; i++) {
        final cacheFile = _getChapterCacheFile(cacheDir, i);
        String content = '[章节内容下载失败]';

        if (await cacheFile.exists() && await cacheFile.length() > 0) {
          content = await cacheFile.readAsString();
        }

        chapterContents.add({'title': chapters[i].title, 'content': content});
      }

      // 下载封面图片
      onProgress?.call(totalChapters, totalChapters, '正在下载封面...');
      List<int>? coverImageBytes;
      if (book.thumbUrl != null && book.thumbUrl!.isNotEmpty) {
        try {
          final response = await http.get(Uri.parse(book.thumbUrl!));
          if (response.statusCode == 200) {
            coverImageBytes = response.bodyBytes;
          }
        } catch (e) {
          print('下载封面失败: $e');
        }
      }

      // 生成 EPUB 文件
      onProgress?.call(totalChapters, totalChapters, '正在生成 EPUB...');

      final filePath = await _saveEpubFile(
        book,
        chapterContents,
        coverImageBytes,
      );

      if (filePath != null) {
        // 清理缓存
        await _clearCache(book.bookId);

        // 记录下载历史
        final file = File(filePath);
        final fileSize = await file.length();

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
            filePath: filePath,
            fileSize: fileSize,
          ),
        );

        onProgress?.call(totalChapters, totalChapters, '下载完成');
        return filePath;
      }

      return null;
    } catch (e) {
      onProgress?.call(0, 0, '下载失败: $e');
      return null;
    }
  }

  /// 请求存储权限
  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // 1. 尝试基础存储权限 (Android < 11)
    var status = await Permission.storage.request();
    if (status.isGranted) return true;

    // 2. 尝试所有文件管理权限 (Android 11+)
    // 如果基础权限被永久拒绝或限制，尝试请求管理权限
    if (status.isDenied || status.isRestricted || status.isPermanentlyDenied) {
      status = await Permission.manageExternalStorage.request();
      if (status.isGranted) return true;
    }

    // 3. 如果是永久拒绝，提示用户去设置开启
    if (status.isPermanentlyDenied) {
      openAppSettings();
    }

    return false;
  }

  /// 保存 EPUB 文件 (真正的 EPUB 格式)
  Future<String?> _saveEpubFile(
    Book book,
    List<Map<String, String>> chapters,
    List<int>? coverImageBytes,
  ) async {
    try {
      // 清理文件名
      final safeFileName =
          book.bookName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '') + '.epub';

      // 创建 EPUB 结构
      final archive = Archive();
      final uuid = DateTime.now().millisecondsSinceEpoch.toString();
      final hasCoverImage =
          coverImageBytes != null && coverImageBytes.isNotEmpty;

      // 1. mimetype (必须是第一个文件，不压缩)
      archive.addFile(
        ArchiveFile(
          'mimetype',
          'application/epub+zip'.length,
          utf8.encode('application/epub+zip'),
        ),
      );

      // 2. META-INF/container.xml
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

      // 3. 添加封面图片（如果有）
      if (hasCoverImage) {
        archive.addFile(
          ArchiveFile(
            'OEBPS/Images/cover.jpg',
            coverImageBytes.length,
            coverImageBytes,
          ),
        );
      }

      // 4. 生成章节文件和 manifest/spine 条目
      final manifestItems = StringBuffer();
      final spineItems = StringBuffer();
      final navPoints = StringBuffer();
      final tocLinks = StringBuffer(); // 用于生成目录页中的章节链接

      // 添加封面图片到 manifest
      if (hasCoverImage) {
        manifestItems.writeln(
          '    <item id="cover-image" href="Images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>',
        );
      }

      // 添加封面页
      String coverContent;
      if (hasCoverImage) {
        // 使用 SVG 显示封面图片
        coverContent = '''
<div style="text-align: center; padding: 0; margin: 0;">
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" 
       height="100%" preserveAspectRatio="xMidYMid meet" version="1.1" viewBox="0 0 600 800" width="100%">
    <image width="600" height="800" xlink:href="Images/cover.jpg"/>
  </svg>
</div>
''';
      } else {
        // 没有封面图片时显示文字
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

      // 生成章节链接（用于目录页）
      for (var i = 0; i < chapters.length; i++) {
        final title = chapters[i]['title'] ?? '第${i + 1}章';
        final chapterFile = 'chapter_${i + 1}.xhtml';
        tocLinks.writeln(
          '  <p style="margin: 0.5em 0;"><a href="$chapterFile">${_escapeXml(title)}</a></p>',
        );
      }

      // 添加目录页 (TOC 页面)
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

      // 添加各章节
      for (var i = 0; i < chapters.length; i++) {
        final chapter = chapters[i];
        final chapterId = 'chapter_${i + 1}';
        final chapterFile = '$chapterId.xhtml';
        final title = chapter['title'] ?? '第${i + 1}章';
        final content = chapter['content'] ?? '';

        // 转换内容为段落
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

      // 4. OEBPS/content.opf (元数据和目录)
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
    <dc:publisher>番茄下载</dc:publisher>$coverMeta
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

      // 5. OEBPS/toc.ncx (导航目录)
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

      // 6. 编码为 ZIP 并保存
      final zipData = ZipEncoder().encode(archive);

      // 保存到临时文件
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$safeFileName');
      await tempFile.writeAsBytes(zipData);

      // 调用原生方法保存到 Downloads
      final bool success = await platform.invokeMethod('saveToDownloads', {
        'filePath': tempFile.path,
        'fileName': safeFileName,
        'mimeType': 'application/epub+zip',
      });

      // 删除临时文件
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (success) {
        return '/storage/emulated/0/Download/fanqie/$safeFileName';
      }
      return null;
    } catch (e) {
      print('保存EPUB失败: $e');
      return null;
    }
  }

  /// 生成 XHTML 页面
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

  /// 生成导航点
  String _generateNavPoint(String id, String title, int order, String src) {
    return '''    <navPoint id="$id" playOrder="$order">
      <navLabel><text>${_escapeXml(title)}</text></navLabel>
      <content src="$src"/>
    </navPoint>
''';
  }

  /// 转义 XML 特殊字符
  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// 获取下载目录 - 使用系统 Downloads/fanqie 目录
  Future<Directory?> _getDownloadDirectory() async {
    try {
      if (Platform.isAndroid) {
        // 方法1: 尝试使用 getDownloadsDirectory (需要 path_provider 2.1.0+)
        try {
          final downloadsDir = await getDownloadsDirectory();
          if (downloadsDir != null) {
            final fanqieDir = Directory('${downloadsDir.path}/fanqie');
            if (!await fanqieDir.exists()) {
              await fanqieDir.create(recursive: true);
            }
            return fanqieDir;
          }
        } catch (e) {
          // getDownloadsDirectory 可能不支持
        }

        // 方法2: 使用 getExternalStorageDirectory
        try {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            // 从 /storage/emulated/0/Android/data/xxx 回退到 /storage/emulated/0/Download
            final rootPath = externalDir.path.split('/Android/data')[0];
            final downloadPath = '$rootPath/Download/fanqie';
            final downloadDir = Directory(downloadPath);
            if (!await downloadDir.exists()) {
              await downloadDir.create(recursive: true);
            }
            return downloadDir;
          }
        } catch (e) {
          // 外部存储不可用
        }

        // 方法3: 直接使用硬编码路径
        try {
          const downloadPath = '/storage/emulated/0/Download/fanqie';
          final downloadDir = Directory(downloadPath);
          if (!await downloadDir.exists()) {
            await downloadDir.create(recursive: true);
          }
          return downloadDir;
        } catch (e) {
          // 没有权限
        }
      }

      // 回退到应用私有目录
      final appDir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${appDir.path}/fanqie');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      return downloadDir;
    } catch (e) {
      return null;
    }
  }
}
