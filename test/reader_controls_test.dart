import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/reader_font_service.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_navigation_test.dart' as fixture;

const _native = MethodChannel('com.fanqie.fanqie_flutter/download');

Future<void> choose(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.tap(find.text(label).last);
  await fixture.settleReader(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
  });

  test(
    'both bundled fonts load once and contain actual TrueType data',
    () async {
      for (final entry in {
        'kaiti': 'assets/fonts/LXGWWenKaiLite-Regular.ttf',
        'serif': 'assets/fonts/ZCOOLXiaoWei-Regular.ttf',
      }.entries) {
        final data = await rootBundle.load(entry.value);
        expect(data.getUint32(0), 0x00010000);
        await ReaderFontService.ensureLoaded(entry.key);
        await ReaderFontService.ensureLoaded(entry.key);
      }
    },
  );

  testWidgets(
    'font, theme and mode changes retain the source anchor and update the panel',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final book = await fixture.openReader(
        tester,
        'cover',
        chapters: [
          Chapter(
            itemId: 'settings',
            title: '第一章',
            content: fixture.chapterText(0, paragraphs: 40),
          ),
        ],
      );
      final view = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      for (var index = 0; index < 3; index++) {
        view.turnToNextPage();
        await fixture.settleReader(tester);
      }
      final original = fixture.address(tester).page.position('settings');
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
      await fixture.settleReader(tester);
      await tester.tap(find.text('排版设置'));
      await fixture.settleReader(tester);
      await choose(tester, '宋体');
      final preview = tester.widget<Text>(find.text('春风轻拂书页，故事从这里继续。'));
      expect(preview.style?.fontFamily, 'ReaderSongTi');
      expect(
        fixture.address(tester).layout.pageFor(original),
        fixture.address(tester).pageIndex,
      );
      await choose(tester, '暗夜');
      final darkPreview = tester.widget<Text>(find.text('春风轻拂书页，故事从这里继续。'));
      expect(darkPreview.style?.color, const Color(0xFFB8B8B8));
      await choose(tester, '上下滚动');
      await tester.pump(const Duration(milliseconds: 600));
      await fixture.settleReader(tester);
      expect(find.byType(CustomScrollView), findsOneWidget);
      final scrollPosition = await ReaderPositionService().load(book.bookId);
      expect(scrollPosition?.chapterId, 'settings');
      expect(scrollPosition?.paragraphIndex, original.paragraphIndex);
      await choose(tester, '左右翻页');
      expect(
        fixture.address(tester).layout.pageFor(scrollPosition!),
        fixture.address(tester).pageIndex,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    },
  );

  testWidgets(
    'large volume directory remains lazy and search does not force a return jump',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await fixture.openReader(
        tester,
        'slide',
        chapters: List.generate(
          1000,
          (index) => Chapter(
            itemId: 'directory-$index',
            title: '第${index + 1}章',
            volumeTitle: '正文',
            content: fixture.chapterText(index, paragraphs: 1),
          ),
        ),
      );
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
      await fixture.settleReader(tester);
      await tester.tap(find.text('目录'));
      await fixture.settleReader(tester);
      await tester.tap(find.byTooltip('按卷折叠'));
      await fixture.settleReader(tester);
      expect(
        tester.widgetList<ListTile>(find.byType(ListTile)).length,
        lessThan(30),
      );
      await tester.enterText(find.byType(TextField), '第888章');
      await tester.pump(const Duration(milliseconds: 150));
      await fixture.settleReader(tester);
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('第888章'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    },
  );

  testWidgets(
    'auto reading pauses on manual input and uses frame time without restarting it',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await fixture.openReader(
        tester,
        'slide',
        chapters: [
          Chapter(
            itemId: 'auto',
            title: '第一章',
            content: fixture.chapterText(0, paragraphs: 50),
          ),
        ],
      );
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
      await fixture.settleReader(tester);
      await tester.tap(find.text('自动阅读'));
      // A running ticker deliberately never settles.
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(scroll.offset, greaterThan(0));
      await tester.tapAt(const Offset(200, 300));
      await tester.pump();
      final paused = scroll.offset;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(scroll.offset, closeTo(paused, 0.1));
      expect(find.byTooltip('继续'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    },
  );
}
