import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/reader_illustration.dart';
import 'reader_display_text.dart';

class ReaderContentBlock {
  final int paragraphIndex, start, end;
  final String text;
  final ReaderIllustration? image;
  const ReaderContentBlock(
    this.paragraphIndex,
    this.start,
    this.end,
    this.text, [
    this.image,
  ]);
}

/// Illustrations never become source text: notes/search/TTS retain the original
/// paragraph and UTF-16 offsets on both sides of an inline image.
List<ReaderContentBlock> readerContentBlocks(
  List<String> paragraphs,
  List<ReaderIllustration> illustrations,
) {
  final grouped = <int, List<ReaderIllustration>>{};
  final order = {
    for (var i = 0; i < illustrations.length; i++) illustrations[i].id: i,
  };
  for (final image in illustrations) {
    if (image.paragraphIndex < paragraphs.length) {
      grouped.putIfAbsent(image.paragraphIndex, () => []).add(image);
    }
  }
  final result = <ReaderContentBlock>[];
  for (var p = 0; p < paragraphs.length; p++) {
    final text = paragraphs[p].trim();
    final images = grouped[p] ?? [];
    images.sort((a, b) {
      final delta = a.characterOffset.compareTo(b.characterOffset);
      return delta == 0 ? order[a.id]!.compareTo(order[b.id]!) : delta;
    });
    var cursor = 0;
    for (final image in images) {
      final at = image.characterOffset.clamp(cursor, text.length);
      if (at > cursor) {
        result.add(
          ReaderContentBlock(p, cursor, at, text.substring(cursor, at)),
        );
      }
      result.add(ReaderContentBlock(p, at, at, '', image));
      cursor = at;
    }
    if (cursor < text.length || images.isEmpty) {
      result.add(
        ReaderContentBlock(p, cursor, text.length, text.substring(cursor)),
      );
    }
  }
  return result;
}

class ReaderParagraphGeometry {
  final String source;
  final List<(ReaderContentBlock, double, double)> blocks = [];
  final TextStyle style;
  final TextScaler scaler;
  final double width;
  final double textWidthInset;
  final bool indent;
  final Size inlineCommentSize;
  final String displayScript;
  double height = 0;

  ReaderParagraphGeometry({
    required this.source,
    required List<ReaderIllustration> images,
    required this.style,
    required this.scaler,
    required this.width,
    this.textWidthInset = 0,
    required this.indent,
    required double spacing,
    required double imageHeight,
    this.inlineCommentSize = Size.zero,
    this.displayScript = 'original',
  }) {
    for (final block in readerContentBlocks([
      source,
    ], images.map((e) => e.at(0, e.characterOffset)).toList())) {
      if (blocks.isNotEmpty) height += spacing;
      double h;
      if (block.image != null) {
        h = block.image!.displayHeight(width, imageHeight);
      } else {
        final painter = _painter(
          _display(block),
          paragraphEnd: block.end == source.length,
        );
        h = painter.height;
        painter.dispose();
      }
      blocks.add((block, height, h));
      height += h;
    }
  }

  String _display(ReaderContentBlock block) =>
      '${indent && block.start == 0 ? '\u3000\u3000' : ''}${block.text}';

  TextPainter _painter(String text, {required bool paragraphEnd}) {
    final comment = paragraphEnd && !inlineCommentSize.isEmpty;
    return TextPainter(
        text: TextSpan(
          style: style,
          children: [
            TextSpan(text: ReaderDisplayText.convert(text, displayScript)),
            if (comment)
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.shrink(),
              ),
          ],
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )
      ..setPlaceholderDimensions(
        comment
            ? [
                PlaceholderDimensions(
                  size: inlineCommentSize,
                  alignment: PlaceholderAlignment.middle,
                ),
              ]
            : const [],
      )
      ..layout(maxWidth: math.max(1, width - textWidthInset));
  }

  (int, double, String?) atY(double y) {
    for (final (block, top, h) in blocks) {
      if (y > top + h && block != blocks.last.$1) continue;
      if (block.image != null) return (block.start, top, block.image!.id);
      final painter = _painter(
        _display(block),
        paragraphEnd: block.end == source.length,
      );
      try {
        final position = painter.getPositionForOffset(
          Offset(0, (y - top).clamp(0, h)),
        );
        final prefix = indent && block.start == 0 ? 2 : 0;
        final offset = (painter.getLineBoundary(position).start - prefix).clamp(
          0,
          block.text.length,
        );
        final caret = painter.getOffsetForCaret(
          TextPosition(offset: offset + prefix),
          Rect.zero,
        );
        return (block.start + offset, top + caret.dy, null);
      } finally {
        painter.dispose();
      }
    }
    return (source.length, height, null);
  }

  double yForOffset(int offset, {String? imageId}) {
    if (imageId != null) {
      for (final (block, top, _) in blocks) {
        if (block.image?.id == imageId) return top;
      }
    }
    for (final (block, top, _) in blocks) {
      if (block.image != null ||
          offset < block.start ||
          (offset >= block.end && offset < source.length)) {
        continue;
      }
      final painter = _painter(
        _display(block),
        paragraphEnd: block.end == source.length,
      );
      try {
        final prefix = indent && block.start == 0 ? 2 : 0;
        return top +
            painter
                .getOffsetForCaret(
                  TextPosition(
                    offset:
                        (offset - block.start).clamp(0, block.text.length) +
                        prefix,
                  ),
                  Rect.zero,
                )
                .dy;
      } finally {
        painter.dispose();
      }
    }
    return 0;
  }
}
