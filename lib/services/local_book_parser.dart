import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../models/chapter.dart';
import 'epub_images.dart';
import 'reader_text.dart';
import 'safe_zip_reader.dart';

enum LocalChapterRule { automatic, chinese, english, length }

class LocalImportCancelled implements Exception {
  const LocalImportCancelled();
  @override
  String toString() => '导入已取消';
}

class LocalParseRequest {
  final String inputPath, stagingPath, title, idPrefix;
  final bool epub;
  final LocalChapterRule rule;
  final SendPort? progress;
  const LocalParseRequest({
    required this.inputPath,
    required this.stagingPath,
    required this.title,
    required this.idPrefix,
    required this.epub,
    this.rule = LocalChapterRule.automatic,
    this.progress,
  });
}

class ParsedLocalBook {
  final String title, author;
  final List<Chapter> chapters;
  final String? coverFile;
  const ParsedLocalBook(this.title, this.author, this.chapters, this.coverFile);
}

Future<ParsedLocalBook> parseLocalBook(LocalParseRequest request) async {
  var cancelled = false;
  final control = ReceivePort();
  final subscription = control.listen((_) => cancelled = true);
  request.progress?.send(control.sendPort);
  void check() {
    if (cancelled) throw const LocalImportCancelled();
  }

  final writer = _ChapterWriter(request, check);
  try {
    if (request.epub) return await _parseEpub(request, writer, check);
    await _parseTxt(request, writer, check);
    if (writer.chapters.isEmpty) throw const FormatException('没有检测到可阅读正文');
    return ParsedLocalBook(request.title, '本地导入', writer.chapters, null);
  } finally {
    await subscription.cancel();
    control.close();
  }
}

String _shortLabel(String value) {
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= 200
      ? text
      : '${text.substring(0, ReaderText.safeOffset(text, 200))}…';
}

class _ChapterWriter {
  final LocalParseRequest request;
  final void Function() check;
  final chapters = <Chapter>[];
  final _parts = <int, int>{};
  int _textCount = 0, _imageCount = 0;
  _ChapterWriter(this.request, this.check);

  Future<void> add(
    String title,
    String text, {
    String volume = '',
    int maxChars = 20000,
    int? continuation,
    List<ExtractedIllustration> images = const [],
  }) async {
    title = _shortLabel(title);
    volume = _shortLabel(volume);
    var remaining = text.trim();
    var consumed = text.length - text.trimLeft().length;
    if (images.isNotEmpty &&
        ReaderText.paragraphs(
          remaining,
          chapterTitle: title,
        ).join('').trim().isEmpty) {
      for (var i = 0; i < images.length; i++) {
        check();
        if (chapters.length >= 20000) throw const FormatException('章节数量超过安全限制');
        final id = '${request.idPrefix}_i${++_imageCount}';
        await File(
          '${request.stagingPath}/$id.txt',
        ).writeAsString(ReaderText.imageOnlyMarker);
        chapters.add(
          Chapter(
            itemId: id,
            title: title.isEmpty
                ? '插图 ${i + 1}'
                : images.length == 1
                ? title
                : '$title（插图 ${i + 1}）',
            order: chapters.length + 1,
            volumeTitle: volume.isEmpty ? '正文' : volume,
            illustrations: [images[i].image.at(0, 0)],
          ),
        );
      }
      return;
    }
    var part = continuation == null ? 0 : _parts[continuation] ?? 0;
    while (remaining.isNotEmpty) {
      check();
      if (chapters.length >= 20000) throw const FormatException('章节数量超过安全限制');
      var end = math.min(maxChars, remaining.length);
      if (end < remaining.length) {
        final paragraphEnd = remaining.lastIndexOf('\n', end);
        if (paragraphEnd > maxChars ~/ 2) end = paragraphEnd;
        end = ReaderText.safeOffset(remaining, end);
        if (end == 0) throw const FormatException('正文包含异常超长字符序列');
      }
      final chunkStart = consumed;
      final rawChunk = remaining.substring(0, end);
      final body = rawChunk.trim();
      final leading = rawChunk.length - rawChunk.trimLeft().length;
      final last = end == remaining.length;
      final tail = remaining.substring(end);
      remaining = tail.trimLeft();
      consumed += end + tail.length - remaining.length;
      if (body.isEmpty) continue;
      if (body.contains('\x00')) throw const FormatException('文本含空字节，请检查编码');
      part++;
      if (continuation != null) _parts[continuation] = part;
      final id = '${request.idPrefix}_c${++_textCount}';
      final label = title.isEmpty
          ? '第 ${chapters.length + 1} 部分'
          : part == 1
          ? title
          : '$title（$part）';
      await File('${request.stagingPath}/$id.txt').writeAsString(body);
      chapters.add(
        Chapter(
          itemId: id,
          title: label,
          order: chapters.length + 1,
          volumeTitle: volume.isEmpty ? '正文' : volume,
          illustrations: images
              .where(
                (e) =>
                    e.offset >= chunkStart &&
                    (e.offset < chunkStart + end ||
                        (last && e.offset <= chunkStart + end)),
              )
              .map((e) {
                final p = ReaderText.positionInRaw(
                  body,
                  e.offset - chunkStart - leading,
                  chapterTitle: label,
                );
                return e.image.at(p.paragraphIndex, p.characterOffset);
              })
              .toList(),
        ),
      );
      request.progress?.send({
        'chapters': chapters.length,
        'message': '已解析 ${chapters.length} 章',
      });
    }
  }
}

Future<void> _parseTxt(
  LocalParseRequest request,
  _ChapterWriter writer,
  void Function() check,
) async {
  final chinese = RegExp(r'^第\s*[0-9一二三四五六七八九十百千万零两]+\s*[章回节卷集部篇幕].{0,80}$');
  final english = RegExp(
    r'^(?:chapter|part|book)\s+[0-9ivxlcdm]+(?:[\s:.-].*)?$',
    caseSensitive: false,
  );
  var title = '';
  var volume = '';
  var sawHeading = false;
  var headingNumber = 0;
  var body = StringBuffer();
  var tail = '';
  var continued = false;
  Future<void> flush({bool preface = false}) async {
    if (body.isEmpty) return;
    await writer.add(
      preface ? '序言' : title,
      body.toString(),
      volume: volume,
      maxChars: sawHeading ? 20000 : 3000,
      continuation: headingNumber,
    );
    body = StringBuffer();
  }

  Future<void> line(
    String value, {
    required bool complete,
    required bool continuation,
  }) async {
    check();
    final text = continuation ? value : value.trim();
    final isHeading =
        complete &&
        !continuation &&
        text.length <= 100 &&
        request.rule != LocalChapterRule.length &&
        ((request.rule != LocalChapterRule.english && chinese.hasMatch(text)) ||
            (request.rule != LocalChapterRule.chinese &&
                english.hasMatch(text)));
    if (isHeading) {
      await flush(preface: !sawHeading);
      if (!sawHeading) {
        for (var i = 0; i < writer.chapters.length; i++) {
          final old = writer.chapters[i];
          writer.chapters[i] = Chapter(
            itemId: old.itemId,
            order: old.order,
            title: writer.chapters.length == 1 ? '序言' : '序言（${i + 1}）',
            volumeTitle: old.volumeTitle,
          );
        }
      }
      sawHeading = true;
      headingNumber++;
      title = text;
      if (RegExp(r'^第\s*[0-9一二三四五六七八九十百千万零两]+\s*卷').hasMatch(text) ||
          RegExp(r'^(part|book)\b', caseSensitive: false).hasMatch(text)) {
        volume = text;
      }
    } else if (text.isNotEmpty) {
      body.write(text);
      if (complete) body.write('\n\n');
      if (body.length >= (sawHeading ? 20000 : 3000)) await flush();
    }
  }

  await for (final chunk in File(
    request.inputPath,
  ).openRead().transform(utf8.decoder)) {
    check();
    tail += chunk;
    while (true) {
      final newline = tail.indexOf('\n');
      if (newline >= 0 && newline <= 8192) {
        await line(
          tail.substring(0, newline).replaceAll('\r', ''),
          complete: true,
          continuation: continued,
        );
        tail = tail.substring(newline + 1);
        continued = false;
      } else if (tail.length > 8192) {
        final end = ReaderText.safeOffset(tail, 4096);
        if (end == 0) throw const FormatException('正文包含异常超长字符序列');
        await line(tail.substring(0, end), complete: false, continuation: true);
        tail = tail.substring(end);
        continued = true;
      } else {
        break;
      }
    }
  }
  if (tail.isNotEmpty) {
    await line(tail, complete: true, continuation: continued);
  }
  await flush();
}

String _resource(String base, String href) {
  final uri = Uri.parse(href);
  if (uri.hasScheme || uri.hasAuthority) {
    throw const FormatException('EPUB 正文不支持外部资源');
  }
  final decoded = Uri.decodeComponent(uri.path).replaceAll('\\', '/');
  if (decoded.startsWith('/')) throw const FormatException('EPUB 资源路径非法');
  return SafeZipReader.safeName(
    path.posix.normalize(path.posix.join(path.posix.dirname(base), decoded)),
  );
}

String _decode(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) throw const FormatException('UTF-16 数据截断');
    final data = ByteData.sublistView(bytes);
    final endian = bytes[0] == 0xff ? Endian.little : Endian.big;
    final units = [
      for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
    ];
    for (var i = 0; i < units.length; i++) {
      if (units[i] >= 0xd800 && units[i] <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          throw const FormatException('UTF-16 字符序列损坏');
        }
      } else if (units[i] >= 0xdc00 && units[i] <= 0xdfff) {
        throw const FormatException('UTF-16 字符序列损坏');
      }
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes);
}

Iterable<XmlElement> _elements(XmlNode node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == local);

class _NavLabel {
  final String title, volume, fragment;
  const _NavLabel(this.title, this.volume, this.fragment);
}

class _HtmlText {
  final String text;
  final Map<String, (int, int)> anchors;
  final List<ExtractedIllustration> images;
  _HtmlText(this.text, this.anchors, this.images);
}

Future<_HtmlText> _extract(
  dom.Element body,
  EpubImages resources,
  String chapterPath,
) async {
  final output = StringBuffer();
  final anchors = <String, (int, int)>{};
  final images = <ExtractedIllustration>[];
  const blocks = {
    'p',
    'div',
    'section',
    'article',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'blockquote',
    'pre',
    'figcaption',
  };
  Future<void> walk(dom.Node node, [bool pre = false]) async {
    if (node is dom.Text) {
      output.write(pre ? node.text : node.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (const {'script', 'style', 'head', 'nav', 'iframe'}.contains(tag) ||
        node.attributes.containsKey('hidden')) {
      return;
    }
    if (node.id.isNotEmpty) {
      anchors.putIfAbsent(node.id, () => (output.length, images.length));
    }
    if (tag == 'img' || tag == 'svg' || tag == 'object') {
      if (tag == 'object' &&
          !(node.attributes['type'] ?? '').startsWith('image/')) {
        return;
      }
      final src =
          node.attributes['src'] ??
          node.attributes['data-src'] ??
          node.attributes['data'] ??
          (node.attributes['srcset'] ?? '')
              .split(',')
              .first
              .trim()
              .split(' ')
              .first;
      final alt =
          node.attributes['alt'] ??
          node.attributes['aria-label'] ??
          (tag == 'svg' ? node.querySelector('title,desc')?.text : null) ??
          '';
      if (tag == 'svg') {
        node.attributes['xmlns'] = 'http://www.w3.org/2000/svg';
        node.attributes['xmlns:xlink'] = 'http://www.w3.org/1999/xlink';
      }
      images.add(
        ExtractedIllustration(
          output.length,
          await resources.extract(
            chapterPath,
            src,
            alt,
            inlineSvg: tag == 'svg' ? node.outerHtml : null,
          ),
        ),
      );
      return;
    }
    if (tag == 'br') {
      output.write('\n');
      return;
    }
    if (blocks.contains(tag)) output.write('\n\n');
    for (final child in node.nodes) {
      await walk(child, pre || tag == 'pre');
    }
    if (blocks.contains(tag)) output.write('\n\n');
  }

  await walk(body);
  return _HtmlText(output.toString(), anchors, images);
}

Future<ParsedLocalBook> _parseEpub(
  LocalParseRequest request,
  _ChapterWriter writer,
  void Function() check,
) async {
  final zip = await SafeZipReader.open(
    File(request.inputPath),
    checkCancelled: check,
  );
  Future<String> text(String name, {int limit = 2 * 1024 * 1024}) async =>
      _decode(await zip.read(name, maxBytes: limit, checkCancelled: check));
  if (zip.entries.containsKey('mimetype') &&
      (await text('mimetype', limit: 128)).trim() != 'application/epub+zip') {
    throw const FormatException('不是 EPUB 文件');
  }
  final container = XmlDocument.parse(await text('META-INF/container.xml'));
  final roots = _elements(container, 'rootfile').toList();
  if (roots.isEmpty) throw const FormatException('EPUB 缺少 OPF 入口');
  final opfPath = SafeZipReader.safeName(
    roots.first.getAttribute('full-path') ?? '',
  );
  final package = XmlDocument.parse(await text(opfPath));
  final title =
      _elements(package, 'title').firstOrNull?.innerText.trim() ??
      request.title;
  final author = _elements(
    package,
    'creator',
  ).map((e) => e.innerText.trim()).where((s) => s.isNotEmpty).join('、');
  final manifest = {
    for (final item in _elements(package, 'item'))
      if (item.getAttribute('id') != null) item.getAttribute('id')!: item,
  };
  final spine = _elements(package, 'spine').firstOrNull;
  if (spine == null) throw const FormatException('EPUB 缺少阅读顺序');
  final ordered = _elements(
    spine,
    'itemref',
  ).where((e) => e.getAttribute('linear') != 'no').toList();
  final paths = <String>[];
  for (final ref in ordered) {
    final item = manifest[ref.getAttribute('idref')];
    if (item == null) throw const FormatException('EPUB 阅读顺序引用了缺失章节');
    paths.add(_resource(opfPath, item.getAttribute('href') ?? ''));
  }
  final encrypted = <String>{};
  if (zip.entries.containsKey('META-INF/encryption.xml')) {
    final encryption = XmlDocument.parse(await text('META-INF/encryption.xml'));
    for (final entry in _elements(encryption, 'CipherReference')) {
      encrypted.add(_resource('root.xml', entry.getAttribute('URI') ?? ''));
    }
    if (paths.any(encrypted.contains)) {
      throw const FormatException('EPUB 正文已加密，无法导入；不支持 DRM 解密');
    }
  }
  final resources = EpubImages(
    zip: zip,
    staging: request.stagingPath,
    encrypted: encrypted,
    resolve: _resource,
    check: check,
  );
  final labels = <String, List<_NavLabel>>{};
  void label(String base, String href, String name, String volume) {
    if (href.isEmpty || name.isEmpty) return;
    final target = _resource(base, href);
    labels
        .putIfAbsent(target, () => [])
        .add(_NavLabel(name.trim(), volume, Uri.parse(href).fragment));
  }

  final navItem = manifest.values
      .where(
        (e) => (e.getAttribute('properties') ?? '').split(' ').contains('nav'),
      )
      .firstOrNull;
  if (navItem != null) {
    final navPath = _resource(opfPath, navItem.getAttribute('href') ?? '');
    final document = html.parse(await text(navPath));
    final nav =
        document.querySelector('nav[epub\\:type="toc"]') ??
        document.querySelector('nav');
    void traverse(dom.Element parent, String volume) {
      for (final li in parent.children) {
        if (li.localName != 'li') {
          traverse(li, volume);
          continue;
        }
        final anchor = li.children.where((e) => e.localName == 'a').firstOrNull;
        final name =
            anchor?.text ??
            li.children.where((e) => e.localName == 'span').firstOrNull?.text ??
            '';
        if (anchor != null) {
          label(navPath, anchor.attributes['href'] ?? '', name, volume);
        }
        for (final nested in li.children.where(
          (e) => e.localName == 'ol' || e.localName == 'ul',
        )) {
          traverse(nested, name.trim().isEmpty ? volume : name.trim());
        }
      }
    }

    if (nav != null) traverse(nav, '');
  } else {
    final ncx =
        manifest[spine.getAttribute('toc')] ??
        manifest.values
            .where(
              (e) => e.getAttribute('media-type') == 'application/x-dtbncx+xml',
            )
            .firstOrNull;
    if (ncx != null) {
      final ncxPath = _resource(opfPath, ncx.getAttribute('href') ?? '');
      final document = XmlDocument.parse(await text(ncxPath));
      void traverse(XmlElement point, String volume) {
        final name =
            point.childElements
                .where((e) => e.name.local == 'navLabel')
                .firstOrNull
                ?.innerText
                .trim() ??
            '';
        final source =
            point.childElements
                .where((e) => e.name.local == 'content')
                .firstOrNull
                ?.getAttribute('src') ??
            '';
        label(ncxPath, source, name, volume);
        for (final child in point.childElements.where(
          (e) => e.name.local == 'navPoint',
        )) {
          traverse(child, name.isEmpty ? volume : name);
        }
      }

      final navMap = _elements(document, 'navMap').firstOrNull;
      if (navMap != null) {
        for (final point in navMap.childElements.where(
          (e) => e.name.local == 'navPoint',
        )) {
          traverse(point, '');
        }
      }
    }
  }
  String? coverFile;
  final coverId = _elements(package, 'meta')
      .where((e) => e.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final cover =
      manifest[coverId] ??
      manifest.values
          .where(
            (e) => (e.getAttribute('properties') ?? '')
                .split(' ')
                .contains('cover-image'),
          )
          .firstOrNull;
  if (cover != null) {
    final coverPath = _resource(opfPath, cover.getAttribute('href') ?? '');
    if (!encrypted.contains(coverPath)) {
      final bytes = await zip.read(
        coverPath,
        maxBytes: 5 * 1024 * 1024,
        checkCancelled: check,
      );
      if (bytes.length > 8 &&
          ((bytes[0] == 0xff && bytes[1] == 0xd8) ||
              (bytes[0] == 0x89 && bytes[1] == 0x50))) {
        coverFile =
            'cover.jpg'; // Flutter decodes the actual JPEG/PNG signature.
        await File('${request.stagingPath}/$coverFile').writeAsBytes(bytes);
      }
    }
  }
  for (final chapterPath in paths) {
    check();
    final document = html.parse(
      await text(chapterPath, limit: 8 * 1024 * 1024),
    );
    final body = document.body;
    if (body == null) continue;
    final content = await _extract(body, resources, chapterPath);
    final navLabels = labels[chapterPath] ?? [];
    final anchored =
        navLabels
            .where(
              (e) =>
                  e.fragment.isNotEmpty &&
                  content.anchors.containsKey(e.fragment),
            )
            .toList()
          ..sort((a, b) {
            final left = content.anchors[a.fragment]!;
            final right = content.anchors[b.fragment]!;
            final textOrder = left.$1.compareTo(right.$1);
            return textOrder == 0 ? left.$2.compareTo(right.$2) : textOrder;
          });
    final heading = body.querySelector('h1,h2,h3')?.text.trim();
    final defaultTitle =
        navLabels.firstOrNull?.title ??
        heading ??
        document.querySelector('title')?.text.trim() ??
        '第 ${writer.chapters.length + 1} 章';
    Future<void> addRegion(
      String label,
      int start,
      int end, {
      String volume = '',
      int imageStart = 0,
      int? imageEnd,
    }) async {
      final raw = content.text.substring(start, end);
      final normalized = ReaderText.paragraphs(raw).join('\n\n');
      final images = content.images
          .sublist(imageStart, imageEnd ?? content.images.length)
          .map((e) {
            final position = ReaderText.positionInRaw(raw, e.offset - start);
            return ExtractedIllustration(
              ReaderText.offsetForPosition(normalized, position),
              e.image,
            );
          })
          .toList();
      await writer.add(label, normalized, volume: volume, images: images);
    }

    if (anchored.isEmpty) {
      await addRegion(
        defaultTitle,
        0,
        content.text.length,
        volume: navLabels.firstOrNull?.volume ?? '',
      );
    } else {
      final first = content.anchors[anchored.first.fragment]!;
      if (content.text.substring(0, first.$1).trim().isNotEmpty ||
          first.$2 > 0) {
        await addRegion(defaultTitle, 0, first.$1, imageEnd: first.$2);
      }
      for (var i = 0; i < anchored.length; i++) {
        final start = content.anchors[anchored[i].fragment]!;
        final end = i + 1 < anchored.length
            ? content.anchors[anchored[i + 1].fragment]!
            : (content.text.length, content.images.length);
        await addRegion(
          anchored[i].title,
          start.$1,
          end.$1,
          volume: anchored[i].volume,
          imageStart: start.$2,
          imageEnd: end.$2,
        );
      }
    }
  }
  if (writer.chapters.isEmpty ||
      !await _hasReadableContent(writer, request.stagingPath)) {
    throw const FormatException('EPUB 未包含可阅读文字或有效插图');
  }
  return ParsedLocalBook(
    _shortLabel(title.isEmpty ? request.title : title),
    _shortLabel(author.isEmpty ? '本地导入' : author),
    writer.chapters,
    coverFile,
  );
}

Future<bool> _hasReadableContent(_ChapterWriter writer, String staging) async {
  for (final chapter in writer.chapters) {
    if (chapter.illustrations.any((e) => e.asset != null && e.error == null)) {
      return true;
    }
    if (ReaderText.paragraphs(
      await File('$staging/${chapter.itemId}.txt').readAsString(),
      chapterTitle: chapter.title,
    ).join('').trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}
