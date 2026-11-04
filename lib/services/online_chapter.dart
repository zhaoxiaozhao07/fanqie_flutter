import 'package:html/parser.dart' as html;

import 'reader_text.dart';

/// Text stays byte-for-byte compatible with the old mobile cleaner. Image
/// anchors are separate: they must never become speech/search/note characters.
class OnlineChapter {
  final String text;
  final List<OnlineImage> images;
  const OnlineChapter(this.text, [this.images = const []]);

  static String stripHtml(String value) => value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  factory OnlineChapter.parse(String source) {
    final body = source.replaceAll(
      RegExp(r'<header[\s\S]*?</header>', caseSensitive: false),
      '',
    );
    final heading = RegExp(
      r'<h1[^>]*>([\s\S]*?)</h1>',
      caseSensitive: false,
    ).firstMatch(body);
    final title = heading == null ? null : stripHtml(heading[1]!).trim();
    final paragraphs = RegExp(r'<p\b[^>]*>([\s\S]*?)</p>', caseSensitive: false)
        .allMatches(body)
        .where((p) => stripHtml(p[1]!).trim().isNotEmpty)
        .toList();
    if (paragraphs.isNotEmpty) {
      final first = stripHtml(paragraphs.first[1]!).trim();
      final a = first.replaceAll(RegExp(r'\s+'), '');
      final b = title?.replaceAll(RegExp(r'\s+'), '') ?? '';
      if (b.isNotEmpty
          ? a == b || (a.length < 35 && a.contains(b))
          : first.length < 30 &&
                RegExp(r'^第[0-9一二三四五六七八九十百千万]+[章卷回节集]').hasMatch(first)) {
        paragraphs.removeAt(0);
      }
    }
    final values = paragraphs.map((p) => stripHtml(p[1]!).trim()).toList();
    var text = values.isNotEmpty
        ? values.join('\n\n')
        : stripHtml(body)
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .join('\n\n');
    final images = <OnlineImage>[];
    for (final match in RegExp(
      r'<img\b[^>]*>',
      caseSensitive: false,
    ).allMatches(body)) {
      if (images.length >= 2000) throw const FormatException('插图数量超过限制');
      final element = html.parseFragment(match[0]!).querySelector('img')!;
      final attrs = element.attributes;
      final url =
          [
            attrs['data-src'],
            attrs['data-original'],
            attrs['src'],
          ].whereType<String>().where((s) => s.trim().isNotEmpty).firstOrNull ??
          '';
      // Official copyright pages use this app-owned ornamental divider, not
      // a downloadable illustration. Unknown references still get a warning.
      if (url == r'$bdCopyrightDivider') continue;
      var offset = 0;
      if (paragraphs.isEmpty) {
        offset = stripHtml(body.substring(0, match.start))
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .join('\n\n')
            .length;
      } else {
        for (var i = 0; i < paragraphs.length; i++) {
          final p = paragraphs[i];
          if (match.start < p.start) break;
          if (match.start < p.end) {
            final start = body.indexOf('>', p.start) + 1;
            offset += stripHtml(
              body.substring(start, match.start),
            ).trimLeft().length.clamp(0, values[i].length);
            break;
          }
          offset += values[i].length + (i < values.length - 1 ? 2 : 0);
        }
      }
      images.add(
        OnlineImage(
          source: url.length <= 8192 ? url.trim() : '',
          alt: String.fromCharCodes((attrs['alt'] ?? '').runes.take(200)),
          offset: offset.clamp(0, text.length),
        ),
      );
    }
    // An image chapter often has only an h1 outside its pictures.
    if (images.isNotEmpty &&
        (text.isEmpty || (paragraphs.isEmpty && text == title))) {
      text = ReaderText.imageOnlyMarker;
      return OnlineChapter(text, [
        for (final image in images)
          OnlineImage(source: image.source, alt: image.alt, offset: 0),
      ]);
    }
    return OnlineChapter(text, images);
  }
}

class OnlineImage {
  final String source, alt;
  final int offset;
  const OnlineImage({required this.source, this.alt = '', this.offset = 0});
}
