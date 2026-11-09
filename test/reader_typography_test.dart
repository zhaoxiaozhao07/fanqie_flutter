import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reader_theme.dart';
import 'package:fanqie_flutter/services/desktop_reader_layout.dart';
import 'package:fanqie_flutter/services/reader_display_text.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ReaderDisplayText.ensureLoaded);
  test('offline script conversion preserves UTF-16 and source spans', () {
    const source = '软件开发阅读，風書頁👨‍👩‍👧‍👦e\u0301𠮷。';
    final converted = ReaderDisplayText.convert(source, 'traditional');
    expect(converted, contains('軟件開發閱讀'));
    expect(converted, contains('👨‍👩‍👧‍👦e\u0301𠮷'));
    expect(converted.length, source.length);
    expect(ReaderDisplayText.convert('風書頁', 'simplified'), '风书页');
    expect(ReaderDisplayText.convert(source, 'original'), source);
    const span = TextSpan(
      text: '软件',
      style: TextStyle(color: Colors.red),
      children: [
        TextSpan(text: '阅读'),
        WidgetSpan(child: SizedBox()),
      ],
    );
    final result = ReaderDisplayText.span(span, 'traditional') as TextSpan;
    expect(result.text, '軟件');
    expect(result.style, span.style);
    expect(result.children!.last, same(span.children!.last));
  });
  test('punctuation boundaries only retreat and never split graphemes', () {
    expect(ReaderTypography.safePageEnd('春风（故事', 3), 2);
    expect(ReaderTypography.safePageEnd('春风故事。继续', 4), 3);
    const text = '👨‍👩‍👧‍👦e\u0301故事。';
    for (var i = 0; i <= text.length; i++) {
      final end = ReaderTypography.safePageEnd(text, i);
      expect(end, lessThanOrEqualTo(i));
      expect(
        text.substring(0, end).characters.join() +
            text.substring(end).characters.join(),
        text,
      );
      final boundaries = {0};
      var offset = 0;
      for (final g in text.characters) {
        offset += g.length;
        boundaries.add(offset);
      }
      expect(boundaries.contains(end), true);
    }
  });
  test('smart pagination and display script retain every canonical range', () {
    const paragraph = '春风（故事继续），书页轻响。👨‍👩‍👧‍👦e\u0301软件开发閱讀！';
    for (final width in [50.0, 180.0, 360.0]) {
      for (final height in [50.0, 230.0, 600.0]) {
        for (final script in ['original', 'simplified', 'traditional']) {
          final pages = ReaderPaginationCache().paginate(
            chapterId: 'c',
            title: '章节',
            content: '$paragraph$paragraph\n\n${paragraph * 12}',
            layout: ReaderLayout(
              size: Size(width, height),
              bodyStyle: const TextStyle(fontSize: 18, height: 1.8),
              titleStyle: const TextStyle(fontSize: 22),
              textScaler: TextScaler.noScaling,
              horizontalPadding: 8,
              paragraphSpacing: 10,
              smartTypography: true,
              displayScript: script,
            ),
            indent: true,
          );
          for (var p = 0; p < pages.sourceParagraphs.length; p++) {
            final parts = pages.pages
                .expand((e) => e.fragments)
                .where((e) => e.paragraphIndex == p)
                .toList();
            var offset = 0;
            for (final part in parts) {
              expect(part.startOffset, offset);
              expect(part.endOffset, greaterThan(part.startOffset));
              final prefix = part.startOffset == 0 ? 2 : 0;
              expect(
                part.text.substring(prefix),
                pages.sourceParagraphs[p].substring(
                  part.startOffset,
                  part.endOffset,
                ),
              );
              offset = part.endOffset;
            }
            expect(offset, pages.sourceParagraphs[p].length);
          }
          for (final page in pages.pages.where((e) => !e.oversized)) {
            final used =
                page.fragments.fold(0.0, (sum, f) => sum + f.height) +
                (page.fragments.length - 1) * 10;
            expect(used, lessThanOrEqualTo(page.availableHeight + .02));
          }
        }
      }
    }
  });
  test('column gap and target width honor available size and large text', () {
    const settings = ReaderSettings(
      pageMode: true,
      desktopColumns: 'double',
      columnGap: 64,
      lineCharacters: 24,
    );
    final layout = DesktopReaderLayout.resolve(
      2000,
      settings,
      TextScaler.noScaling,
    );
    expect(layout.columns, 2);
    expect(layout.width, lessThan(2000));
    expect((layout.width - 64) / 2, greaterThanOrEqualTo(360));
    expect(
      DesktopReaderLayout.resolve(600, settings, TextScaler.linear(2)).columns,
      1,
    );
  });
  test('custom themes derive readable secondary colors and brightness', () {
    final custom = ReaderTheme.presets.first.withColors(
      background: 0xFF000000,
      text: 0xFFFFFFFF,
    );
    expect(custom.systemBrightness, Brightness.dark);
    expect(custom.contrastRatio, closeTo(21, .01));
    expect(custom.secondaryColor, isNot(custom.textColor));
    expect(
      ReaderTheme.presets.first.withColors(),
      same(ReaderTheme.presets.first),
    );
  });
}
