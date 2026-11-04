import '../models/reader_illustration.dart';
import 'reader_content.dart';
import 'reader_text.dart';

String escapeEpubText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Shared with export regression tests: an EPUB is rich content, unlike TXT.
String epubChapterContent(
  String text,
  String title,
  List<ReaderIllustration> images,
) {
  final paragraphs = ReaderText.paragraphs(text, chapterTitle: title);
  final output = StringBuffer();
  for (var i = 0; i < paragraphs.length; i++) {
    final blocks = readerContentBlocks(
      [paragraphs[i]],
      images
          .where((image) => image.paragraphIndex == i)
          .map((image) => image.at(0, image.characterOffset))
          .toList(),
    );
    output.write('<p>');
    for (final block in blocks) {
      final image = block.image;
      if (image == null) {
        output.write(escapeEpubText(block.text));
      } else if (image.asset == null || image.error != null) {
        output.write(escapeEpubText(image.error ?? '插图缺失'));
      } else {
        output.write(
          '<img src="${escapeEpubText(image.asset!)}" '
          'alt="${escapeEpubText(image.alt)}" style="display:block;max-width:100%;height:auto"/>',
        );
      }
    }
    output.writeln('</p>');
  }
  return output.toString();
}
