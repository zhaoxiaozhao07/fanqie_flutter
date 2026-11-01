import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/widgets/paragraph_comment_sheet.dart';
import 'package:fanqie_flutter/widgets/reader_comment_bubble.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_navigation_test.dart' as fixture;

const _native = MethodChannel('com.fanqie.fanqie_flutter/download');
const _shortText = '青山依旧，故事继续。';
var _sequence = 0;

Future<void> openInlineReader(
  WidgetTester tester,
  String mode, {
  String content = _shortText,
  double scale = 1,
  Future<ChapterCommentStats?>? stats,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('reader_is_page_mode', mode != 'scroll');
  await prefs.setBool('reader_show_comment_bubbles', true);
  await prefs.setString('reader_page_turn_animation', mode);
  await prefs.setDouble('reader_horizontal_padding', 20);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: ReaderScreen(
        book: Book(
          bookId: 'inline-test-${_sequence++}',
          bookName: '段尾气泡测试',
          author: '测试',
        ),
        chapters: [Chapter(itemId: 'inline', title: '第一章', content: content)],
        chapterCommentStatsLoader: (_) =>
            stats ??
            Future.value(
              const ChapterCommentStats(
                chapterId: 'inline',
                counts: {0: 12},
                totalCount: 12,
              ),
            ),
      ),
    ),
  );
  for (var attempt = 0; attempt < 30; attempt++) {
    await fixture.settleReader(tester);
    if (find.byType(ReaderPageView).evaluate().isNotEmpty ||
        find.byType(CustomScrollView).evaluate().isNotEmpty) {
      break;
    }
  }
  expect(tester.takeException(), isNull);
}

Finder paragraphText(String mode, {int page = 0, int paragraph = 0}) =>
    find.byKey(
      ValueKey(
        mode == 'scroll'
            ? 'reader-paragraph-inline_$paragraph'
            : 'reader-paragraph-page_inline_${page}_$paragraph',
      ),
    );

Finder bubble(int paragraph) =>
    find.byKey(ValueKey('paragraph-comment-inline-$paragraph'));

RenderParagraph paragraphRender(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)).first,
    );

void expectAtParagraphEnd(WidgetTester tester, Finder text, Finder comment) {
  final paragraph = paragraphRender(tester, text);
  final plain = paragraph.text.toPlainText(includePlaceholders: false);
  final glyph = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: plain.length - 1, extentOffset: plain.length),
      )
      .last;
  final glyphRect = glyph.toRect().shift(paragraph.localToGlobal(Offset.zero));
  final tapRect = tester.getRect(
    find.descendant(of: comment, matching: find.byType(GestureDetector)),
  );
  expect(tapRect.left - glyphRect.right, closeTo(6, 1));
  expect((tapRect.center.dy - glyphRect.center.dy).abs(), lessThan(12));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  for (final mode in [
    'scroll',
    'cover',
    'simulation',
    'slide',
    'fade',
    'none',
  ]) {
    testWidgets('$mode puts the bubble immediately after the paragraph', (
      tester,
    ) async {
      await openInlineReader(tester, mode);
      final text = paragraphText(mode);
      final span = tester.widget<Text>(text).textSpan! as TextSpan;
      expect(span.children!.last, isA<WidgetSpan>());
      expect(
        paragraphRender(tester, text).constraints.maxWidth,
        closeTo(360, 0.01),
      );
      expectAtParagraphEnd(tester, text, bubble(0));
      final before = mode == 'scroll' ? null : fixture.address(tester);
      await tester.tap(
        find.descendant(of: bubble(0), matching: find.byType(GestureDetector)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final sheet = tester.widget<ParagraphCommentSheet>(
        find.byType(ParagraphCommentSheet),
      );
      expect(sheet.paraIndex, 0);
      expect(sheet.paraText, _shortText);
      if (before != null) expect(fixture.address(tester), before);
      expect(find.text('排版设置'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    });
  }

  testWidgets('late counts fill the tail without reflowing pages', (
    tester,
  ) async {
    final stats = Completer<ChapterCommentStats?>();
    await openInlineReader(tester, 'simulation', stats: stats.future);
    final page = fixture.address(tester);
    final before = tester.getRect(paragraphText('simulation'));
    expect(tester.widget<ReaderCommentBubble>(bubble(0)).count, 0);
    stats.complete(
      const ChapterCommentStats(
        chapterId: 'inline',
        counts: {0: 9999},
        totalCount: 9999,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<ReaderCommentBubble>(bubble(0)).count, 9999);
    expect(fixture.address(tester).layout, same(page.layout));
    expect(tester.getRect(paragraphText('simulation')), before);
    expectAtParagraphEnd(tester, paragraphText('simulation'), bubble(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('a split paragraph has one bubble only at its true ending', (
    tester,
  ) async {
    final original = '青山依旧，故事继续。' * 130;
    await openInlineReader(tester, 'simulation', content: original);
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    final layout = fixture.address(tester).layout;
    final count = layout.pages.length as int;
    expect(count, greaterThan(2));
    for (var index = 0; index < count; index++) {
      final text = tester.widget<Text>(
        paragraphText('simulation', page: index),
      );
      final span = text.textSpan! as TextSpan;
      expect(
        span.children!.whereType<WidgetSpan>().length,
        index == count - 1 ? 1 : 0,
      );
      if (index < count - 1) {
        view.turnToNextPage();
        await fixture.settleReader(tester);
      }
    }
    await tester.tap(
      find.descendant(of: bubble(0), matching: find.byType(GestureDetector)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final sheet = tester.widget<ParagraphCommentSheet>(
      find.byType(ParagraphCommentSheet),
    );
    expect(sheet.paraText, original);
    expect(sheet.paraIndex, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('long press keeps inline geometry and copies only body text', (
    tester,
  ) async {
    await openInlineReader(tester, 'simulation');
    final text = paragraphText('simulation');
    final paragraphBefore = tester.getRect(text);
    final bubbleBefore = tester.getRect(bubble(0));
    final body = tester
        .widget<Text>(text)
        .textSpan!
        .toPlainText(includePlaceholders: false);
    await tester.longPressAt(
      Offset(paragraphBefore.left + 80, paragraphBefore.center.dy),
    );
    await fixture.settleReader(tester);
    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(selectable.textSpan!.toPlainText(), body);
    expect(selectable.textSpan!.children!.whereType<WidgetSpan>(), isEmpty);
    expect(tester.getRect(bubble(0)), bubbleBefore);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('scaled inline bubbles are measured without bottom overflow', (
    tester,
  ) async {
    await openInlineReader(
      tester,
      'simulation',
      content: '青山依旧，故事继续。' * 40,
      scale: 2,
    );
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    final count = fixture.address(tester).layout.pages.length as int;
    for (var index = 0; index < count; index++) {
      final page = fixture.address(tester).page;
      final fragment = page.fragments.single;
      final paragraph = paragraphRender(
        tester,
        paragraphText('simulation', page: index),
      );
      expect(
        paragraph.size.height,
        closeTo(fragment.height, 0.01),
        reason: 'The tail placeholder must scale exactly once on page $index.',
      );
      expect(
        paragraph.size.height,
        lessThanOrEqualTo(page.availableHeight + 0.01),
      );
      if (index < count - 1) {
        view.turnToNextPage();
        await fixture.settleReader(tester);
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('replacing a reader does not notify the disposing page UI', (
    tester,
  ) async {
    await openInlineReader(tester, 'simulation');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          key: const ValueKey('replacement'),
          book: Book(bookId: 'replacement', bookName: '下一本书', author: '测试'),
          chapters: [
            Chapter(itemId: 'next-inline', title: '下一章', content: _shortText),
          ],
          chapterCommentStatsLoader: (_) async => const ChapterCommentStats(
            chapterId: 'next-inline',
            counts: {0: 3},
          ),
        ),
      ),
    );
    await fixture.settleReader(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });
}
