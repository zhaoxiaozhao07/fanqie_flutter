import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import 'bookshelf_service.dart';

/// 本地书籍导入结果
class LocalImportResult {
  final Book book;
  final List<Chapter> chapters;
  final int chapterCount;

  LocalImportResult({
    required this.book,
    required this.chapters,
    required this.chapterCount,
  });
}

/// 本地 TXT / EPUB 小说导入服务
class LocalBookService {
  static final LocalBookService _instance = LocalBookService._internal();
  factory LocalBookService() => _instance;
  LocalBookService._internal();

  /// 导入本地书籍文件 (.txt 或 .epub)
  Future<LocalImportResult> importLocalFile(File file) async {
    final ext = file.path.toLowerCase();
    if (ext.endsWith('.epub')) {
      return importLocalEpub(file);
    } else {
      return importLocalTxt(file);
    }
  }

  /// 导入并解析本地 TXT 电子书
  Future<LocalImportResult> importLocalTxt(File file) async {
    final bytes = await file.readAsBytes();
    String rawContent;
    try {
      rawContent = utf8.decode(bytes);
    } catch (_) {
      // Fallback: 宽松解码
      rawContent = latin1.decode(bytes);
    }

    final fileName = file.uri.pathSegments.last;
    final bookName = fileName.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '').trim();
    final bookId = 'local_txt_${bookName.hashCode.abs()}';

    // 智能章节切分正则
    final chapterRegex = RegExp(
      r'(?:^|\r?\n)[ \t]*(第\s*[0-9一二三四五六七八九十百千万零两]+\s*[章回节卷集部篇幕][^\r\n]*)',
      caseSensitive: false,
    );

    final matches = chapterRegex.allMatches(rawContent).toList();
    final chapters = <Chapter>[];

    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final bookDir = Directory('${baseDir.path}/offline_books/$bookId');
    if (!await bookDir.exists()) {
      await bookDir.create(recursive: true);
    }

    if (matches.isNotEmpty) {
      // 存在前言/序章
      if (matches.first.start > 0) {
        final preContent = rawContent.substring(0, matches.first.start).trim();
        if (preContent.isNotEmpty) {
          const itemId = '1000000000000000';
          chapters.add(Chapter(itemId: itemId, title: '序言', order: 1));
          await File('${bookDir.path}/$itemId.txt').writeAsString(preContent);
        }
      }

      for (int i = 0; i < matches.length; i++) {
        final match = matches[i];
        final title = (match.group(1) ?? '第${chapters.length + 1}章').trim();
        final start = match.end;
        final end = (i < matches.length - 1) ? matches[i + 1].start : rawContent.length;
        final body = rawContent.substring(start, end).trim();

        final itemId = '1000000000000${chapters.length + 1}';
        chapters.add(Chapter(itemId: itemId, title: title, order: chapters.length + 1));
        await File('${bookDir.path}/$itemId.txt').writeAsString(body);
      }
    } else {
      // 未匹配到明显章节标识，智能按长度分块（每 3000 字一块）
      const chunkSize = 3000;
      int partIndex = 1;
      for (int i = 0; i < rawContent.length; i += chunkSize) {
        final end = (i + chunkSize < rawContent.length) ? i + chunkSize : rawContent.length;
        final chunk = rawContent.substring(i, end).trim();
        if (chunk.isNotEmpty) {
          final itemId = '1000000000000$partIndex';
          chapters.add(Chapter(itemId: itemId, title: '第 $partIndex 部分', order: partIndex));
          await File('${bookDir.path}/$itemId.txt').writeAsString(chunk);
          partIndex++;
        }
      }
    }

    // 持久化目录索引 JSON
    final dirJson = chapters.map((c) => c.toJson()).toList();
    await File('${bookDir.path}/directory.json').writeAsString(json.encode(dirJson));

    final book = Book(
      bookId: bookId,
      bookName: bookName.isNotEmpty ? bookName : '本地书籍',
      author: '本地导入',
      category: '本地图书',
      creationStatus: '已完结',
      abstract: '本地导入的 TXT 小说，共 ${chapters.length} 章。',
    );

    // 自动加入书架
    await BookshelfService().addToBookshelf(book, totalChapters: chapters.length);

    return LocalImportResult(book: book, chapters: chapters, chapterCount: chapters.length);
  }

  /// 导入并解析本地 EPUB 电子书
  Future<LocalImportResult> importLocalEpub(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final fileName = file.uri.pathSegments.last;
    var bookName = fileName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '').trim();
    var author = '本地导入';
    final chapters = <Chapter>[];

    Directory baseDir;
    try {
      baseDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }

    final bookId = 'local_epub_${bookName.hashCode.abs()}';
    final bookDir = Directory('${baseDir.path}/offline_books/$bookId');
    if (!await bookDir.exists()) {
      await bookDir.create(recursive: true);
    }

    // 提取 HTML/XHTML 正文文件
    final htmlFiles = archive.files.where((f) {
      final name = f.name.toLowerCase();
      return (name.endsWith('.html') || name.endsWith('.xhtml') || name.endsWith('.htm')) &&
          !name.contains('nav') &&
          !name.contains('toc');
    }).toList();

    // 排序保证按阅读顺序
    htmlFiles.sort((a, b) => a.name.compareTo(b.name));

    // 提取封面图片
    for (final f in archive.files) {
      final name = f.name.toLowerCase();
      if ((name.contains('cover') || name.contains('thumb')) &&
          (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png'))) {
        final coverBytes = f.content as List<int>;
        await File('${bookDir.path}/cover.jpg').writeAsBytes(coverBytes);
        break;
      }
    }

    int order = 1;
    for (final hf in htmlFiles) {
      final contentRaw = utf8.decode(hf.content as List<int>, allowMalformed: true);
      // 正则提取标题
      String title = '第 $order 章';
      final titleMatch = RegExp(r'<title>(.*?)<\/title>', caseSensitive: false).firstMatch(contentRaw);
      if (titleMatch != null && titleMatch.group(1)!.trim().isNotEmpty) {
        title = titleMatch.group(1)!.trim();
      } else {
        final hMatch = RegExp(r'<h[1-3][^>]*>(.*?)<\/h[1-3]>', caseSensitive: false).firstMatch(contentRaw);
        if (hMatch != null && hMatch.group(1)!.trim().isNotEmpty) {
          title = _stripHtml(hMatch.group(1)!.trim());
        }
      }

      final cleanText = _stripHtml(contentRaw).trim();
      if (cleanText.length > 20) {
        final itemId = '2000000000000$order';
        chapters.add(Chapter(itemId: itemId, title: title, order: order));
        await File('${bookDir.path}/$itemId.txt').writeAsString(cleanText);
        order++;
      }
    }

    if (chapters.isEmpty) {
      chapters.add(Chapter(itemId: '20000000000001', title: '正文', order: 1));
      await File('${bookDir.path}/20000000000001.txt').writeAsString('EPUB 解析成功，未检测到独立章节。');
    }

    // 持久化目录索引 JSON
    final dirJson = chapters.map((c) => c.toJson()).toList();
    await File('${bookDir.path}/directory.json').writeAsString(json.encode(dirJson));

    final hasLocalCover = await File('${bookDir.path}/cover.jpg').exists();
    final book = Book(
      bookId: bookId,
      bookName: bookName.isNotEmpty ? bookName : '本地 EPUB',
      author: author,
      thumbUrl: hasLocalCover ? '${bookDir.path}/cover.jpg' : null,
      category: '本地图书',
      creationStatus: '已完结',
      abstract: '本地导入的 EPUB 电子书，共 ${chapters.length} 章节。',
    );

    await BookshelfService().addToBookshelf(book, totalChapters: chapters.length);
    return LocalImportResult(book: book, chapters: chapters, chapterCount: chapters.length);
  }

  /// 清洗 HTML 标签还原纯文本段落
  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?<\/script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<(?:p|div|br|h[1-6])[^>]*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"');
  }
}
