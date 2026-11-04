import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/reading_position.dart';
import '../models/reader_illustration.dart';
import 'reader_content.dart';

class ReaderLayout {
  final Size size;
  final TextStyle bodyStyle;
  final TextStyle titleStyle;
  final TextScaler textScaler;
  final double horizontalPadding;
  final double paragraphSpacing;
  final Size inlineCommentSize;
  final bool showPageNumber;

  const ReaderLayout({
    required this.size,
    required this.bodyStyle,
    required this.titleStyle,
    required this.textScaler,
    required this.horizontalPadding,
    required this.paragraphSpacing,
    this.inlineCommentSize = Size.zero,
    this.showPageNumber = true,
  });

  Object get key => (
    size,
    _metrics(bodyStyle),
    _metrics(titleStyle),
    textScaler,
    horizontalPadding,
    paragraphSpacing,
    inlineCommentSize,
    showPageNumber,
  );

  // Paint-only changes (night theme, highlights) must reuse measured pages.
  static TextStyle _metrics(TextStyle style) => TextStyle(
    inherit: style.inherit,
    fontSize: style.fontSize,
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    letterSpacing: style.letterSpacing,
    wordSpacing: style.wordSpacing,
    textBaseline: style.textBaseline,
    height: style.height,
    leadingDistribution: style.leadingDistribution,
    locale: style.locale,
    fontFeatures: style.fontFeatures,
    fontVariations: style.fontVariations,
  );
}

class ReaderPageFragment {
  final int paragraphIndex;
  final int startOffset;
  final int endOffset;
  final String text;
  final double height;
  final ReaderIllustration? image;

  const ReaderPageFragment({
    required this.paragraphIndex,
    required this.startOffset,
    required this.endOffset,
    required this.text,
    required this.height,
    this.image,
  });
}

class ReaderPage {
  final List<ReaderPageFragment> fragments;
  final double availableHeight;
  final bool oversized;
  final double titleHeight;

  const ReaderPage({
    required this.fragments,
    required this.availableHeight,
    this.oversized = false,
    this.titleHeight = 0,
  });

  String get text =>
      fragments.where((f) => f.image == null).map((f) => f.text).join('\n\n');

  ReadingPosition position(String chapterId) => ReadingPosition(
    chapterId: chapterId,
    paragraphIndex: fragments.isEmpty ? 0 : fragments.first.paragraphIndex,
    characterOffset: fragments.isEmpty ? 0 : fragments.first.startOffset,
    imageId: fragments.isEmpty ? null : fragments.first.image?.id,
  );
}

class ReaderChapterPages {
  final Object key;
  final String chapterId;
  final List<ReaderPage> pages;
  final List<String> sourceParagraphs;

  const ReaderChapterPages({
    required this.key,
    required this.chapterId,
    required this.pages,
    required this.sourceParagraphs,
  });

  int pageFor(ReadingPosition position) {
    if (position.imageId != null) {
      for (var index = 0; index < pages.length; index++) {
        if (pages[index].fragments.any(
          (f) => f.image?.id == position.imageId,
        )) {
          return index;
        }
      }
    }
    for (var index = 0; index < pages.length; index++) {
      for (final fragment in pages[index].fragments) {
        if (fragment.image != null) continue;
        if (fragment.paragraphIndex > position.paragraphIndex ||
            (fragment.paragraphIndex == position.paragraphIndex &&
                fragment.endOffset > position.characterOffset)) {
          return index;
        }
      }
    }
    return pages.length - 1;
  }
}

/// 限量缓存多章排版；原文段落和字符范围随分页保留，不再反向搜索段落。
class ReaderPaginationCache {
  final int capacity;
  final LinkedHashMap<Object, ReaderChapterPages> _cache = LinkedHashMap();

  ReaderPaginationCache({this.capacity = 7});

  ReaderChapterPages? lookup(Object key) {
    final value = _cache.remove(key);
    if (value != null) _cache[key] = value;
    return value;
  }

  int get length => _cache.length;

  ReaderChapterPages paginate({
    required String chapterId,
    required String title,
    required String content,
    required ReaderLayout layout,
    required bool indent,
    List<ReaderIllustration> illustrations = const [],
  }) {
    final key = (chapterId, title, content, layout.key, indent, illustrations);
    final cached = lookup(key);
    if (cached != null) return cached;
    final result = _paginate(
      key: key,
      chapterId: chapterId,
      title: title,
      content: content,
      layout: layout,
      indent: indent,
      illustrations: illustrations,
    );
    _cache[key] = result;
    while (_cache.length > capacity) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  Object cacheKey({
    required String chapterId,
    required String title,
    required String content,
    required ReaderLayout layout,
    required bool indent,
    List<ReaderIllustration> illustrations = const [],
  }) => (chapterId, title, content, layout.key, indent, illustrations);

  ReaderChapterPages _paginate({
    required Object key,
    required String chapterId,
    required String title,
    required String content,
    required ReaderLayout layout,
    required bool indent,
    List<ReaderIllustration> illustrations = const [],
  }) {
    final width = math.max(
      1.0,
      layout.size.width - layout.horizontalPadding * 2,
    );
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: layout.textScaler,
    );
    double measure(
      String text,
      TextStyle style,
      double maxWidth, {
      bool paragraphEnd = false,
    }) {
      final hasComment = paragraphEnd && !layout.inlineCommentSize.isEmpty;
      painter.text = TextSpan(
        style: style,
        children: [
          TextSpan(text: text),
          if (hasComment)
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: SizedBox.shrink(),
            ),
        ],
      );
      painter.setPlaceholderDimensions(
        hasComment
            ? [
                PlaceholderDimensions(
                  size: layout.inlineCommentSize,
                  alignment: PlaceholderAlignment.middle,
                ),
              ]
            : const [],
      );
      painter.layout(maxWidth: maxWidth);
      return painter.height;
    }

    final measuredTitleHeight = measure(
      title,
      layout.titleStyle,
      math.max(1, layout.size.width - layout.horizontalPadding * 2).toDouble(),
    );
    final titleHeight = math.min(
      measuredTitleHeight,
      layout.size.height * 0.22,
    );
    final footerHeight = layout.showPageNumber
        ? measure(
            '第 1 / 1 页',
            const TextStyle(fontSize: 11, height: 1, letterSpacing: 1),
            layout.size.width,
          )
        : 0.0;
    final normalHeight = math.max(
      1.0,
      layout.size.height - 16 - footerHeight - (layout.showPageNumber ? 6 : 0),
    );
    final firstHeight = math.max(1.0, normalHeight - titleHeight - 10);
    final pages = <ReaderPage>[];
    final fragments = <ReaderPageFragment>[];
    var usedHeight = 0.0;
    var oversized = false;
    double available() => pages.isEmpty ? firstHeight : normalHeight;
    void flush() {
      if (fragments.isEmpty) return;
      pages.add(
        ReaderPage(
          fragments: List.unmodifiable(fragments),
          availableHeight: available(),
          oversized: oversized,
          titleHeight: pages.isEmpty ? titleHeight : 0,
        ),
      );
      fragments.clear();
      usedHeight = 0;
      oversized = false;
    }

    try {
      final paragraphs = content.split('\n\n');
      for (final block in readerContentBlocks(paragraphs, illustrations)) {
        final paragraphIndex = block.paragraphIndex;
        final original = paragraphs[paragraphIndex].trim();
        if (block.image != null) {
          var spacing = fragments.isEmpty ? 0.0 : layout.paragraphSpacing;
          var height = block.image!.displayHeight(width, available());
          if (fragments.isNotEmpty &&
              usedHeight + spacing + height > available()) {
            flush();
            spacing = 0;
            height = block.image!.displayHeight(width, available());
          }
          fragments.add(
            ReaderPageFragment(
              paragraphIndex: paragraphIndex,
              startOffset: block.start,
              endOffset: block.start,
              text: '',
              height: height,
              image: block.image,
            ),
          );
          usedHeight += spacing + height;
          continue;
        }
        var cursor = block.start;
        while (cursor < block.end) {
          final spacing = fragments.isEmpty ? 0.0 : layout.paragraphSpacing;
          final room = available() - usedHeight - spacing;
          final prefix = indent && cursor == 0 ? '\u3000\u3000' : '';
          final display = '$prefix${original.substring(cursor, block.end)}';
          final fullHeight = measure(
            display,
            layout.bodyStyle,
            width,
            paragraphEnd: block.end == original.length,
          );
          var end = display.length;
          var height = fullHeight;
          if (height > room + 0.01) {
            final lines = painter.computeLineMetrics();
            var candidate = 0;
            for (final line in lines) {
              if (line.baseline + line.descent > room + 0.01) break;
              final position = painter.getPositionForOffset(
                Offset(0, line.baseline),
              );
              candidate = painter.getLineBoundary(position).end;
            }
            if (candidate <= prefix.length && fragments.isNotEmpty) {
              flush();
              continue;
            }
            if (candidate <= prefix.length) {
              candidate =
                  prefix.length +
                  original.substring(cursor).characters.first.length;
              oversized = true;
            }
            // 气泡单独溢出时，最后一个完整字素随气泡留到续页；
            // 不生成丢失原文位置的“仅气泡页”，也不切断 emoji。
            if (candidate >= display.length &&
                block.end == original.length &&
                !layout.inlineCommentSize.isEmpty) {
              candidate =
                  display.length -
                  original.substring(cursor).characters.last.length;
              if (candidate <= prefix.length && fragments.isNotEmpty) {
                flush();
                continue;
              }
            }
            end = candidate.clamp(prefix.length + 1, display.length);
            if (candidate <= prefix.length) {
              end =
                  prefix.length +
                  original.substring(cursor).characters.first.length;
              oversized = true;
            }
            height = measure(
              display.substring(0, end),
              layout.bodyStyle,
              width,
              paragraphEnd:
                  end == display.length && block.end == original.length,
            );
            // 少数字体/词边界的独立续页重排可能多出一行，退回上一行再核对。
            while (height > room + 0.01 &&
                !oversized &&
                end > prefix.length + 1) {
              final remainingLines = painter.computeLineMetrics();
              if (remainingLines.length <= 1) break;
              final previous = remainingLines[remainingLines.length - 2];
              end = painter
                  .getLineBoundary(
                    painter.getPositionForOffset(Offset(0, previous.baseline)),
                  )
                  .end;
              height = measure(
                display.substring(0, end),
                layout.bodyStyle,
                width,
                paragraphEnd:
                    end == display.length && block.end == original.length,
              );
            }
          }
          final consumed = (end - prefix.length).clamp(1, block.end - cursor);
          fragments.add(
            ReaderPageFragment(
              paragraphIndex: paragraphIndex,
              startOffset: cursor,
              endOffset: cursor + consumed,
              text: '$prefix${original.substring(cursor, cursor + consumed)}',
              height: height,
            ),
          );
          usedHeight += spacing + height;
          cursor += consumed;
          if (cursor < block.end) flush();
        }
      }
      flush();
      if (pages.isEmpty) {
        pages.add(
          ReaderPage(
            fragments: const [],
            availableHeight: firstHeight,
            titleHeight: titleHeight,
          ),
        );
      }
      return ReaderChapterPages(
        key: key,
        chapterId: chapterId,
        pages: List.unmodifiable(pages),
        sourceParagraphs: List.unmodifiable(
          content.split('\n\n').map((paragraph) => paragraph.trim()),
        ),
      );
    } finally {
      painter.dispose();
    }
  }
}
