import 'dart:async';

import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_navigation_test.dart' as fixture;

const native = MethodChannel('com.fanqie.fanqie_flutter/download');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (_) async => null);
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null),
  );

  testWidgets('directory jump returns to the original source anchor', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await fixture.openReader(
      tester,
      'none',
      chapters: List.generate(
        25,
        (i) => Chapter(
          itemId: 'jump-$i',
          title: '第${i + 1}章',
          content: fixture.chapterText(i),
        ),
      ),
    );
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    for (var i = 0; i < 3; i++) {
      view.turnToNextPage();
      await fixture.settleReader(tester);
    }
    final originalChapter = fixture.address(tester).chapterIndex as int;
    final origin = fixture.address(tester).page.position('jump-$originalChapter');
    await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
    await fixture.settleReader(tester);
    await tester.tap(find.text('目录'));
    await fixture.settleReader(tester);
    await tester.enterText(find.byType(TextField), '第20章');
    await tester.pump(const Duration(milliseconds: 200));
    await fixture.settleReader(tester);
    await tester.tap(
      find.descendant(of: find.byType(ListTile), matching: find.text('第20章')),
    );
    await fixture.settleReader(tester);
    await fixture.settleReader(tester);
    expect(fixture.address(tester).chapterIndex, 19);
    await tester.tap(find.byKey(const ValueKey('reader_jump_back')));
    await fixture.settleReader(tester);
    await fixture.settleReader(tester);
    expect(fixture.address(tester).chapterIndex, originalChapter);
    expect(
      fixture.address(tester).layout.pageFor(origin),
      fixture.address(tester).pageIndex,
    );
    expect(find.byKey(const ValueKey('reader_jump_back')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('second identical search hit locates its own character range', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final content = '${'甲' * 50}目标${'乙' * 50}目标${'丙' * 40}';
    final book = await fixture.openReader(
      tester,
      'none',
      chapters: [
        Chapter(itemId: 'search-current', title: '第一章', content: content),
      ],
    );
    await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
    await fixture.settleReader(tester);
    await tester.tap(find.byTooltip('更多选项'));
    await fixture.settleReader(tester);
    await tester.tap(find.text('正文搜索'));
    await fixture.settleReader(tester);
    await tester.enterText(find.byType(TextField), '目标');
    await tester.pump(const Duration(milliseconds: 250));
    await fixture.settleReader(tester);
    await fixture.settleReader(tester);
    expect(find.byType(ListTile), findsNWidgets(2));
    await tester.tap(find.byType(ListTile).last);
    await fixture.settleReader(tester);
    await fixture.settleReader(tester);
    await tester.pump(const Duration(milliseconds: 600));
    final saved = await ReaderPositionService().load(book.bookId);
    expect(saved!.chapterId, 'search-current');
    expect(saved.paragraphIndex, 0);
    expect(saved.characterOffset, 102);
    expect(find.byKey(const ValueKey('reader_jump_back')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets('cancelling an unready jump ignores the late chapter result', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<String?>();
    await fixture.openReader(
      tester,
      'none',
      chapters: [
        Chapter(itemId: 'ready', title: '第一章', content: fixture.chapterText(0)),
        Chapter(itemId: 'late', title: '第二章'),
      ],
      loader: (_) => pending.future,
    );
    await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
    await fixture.settleReader(tester);
    await tester.tap(find.text('目录'));
    await fixture.settleReader(tester);
    await tester.tap(find.text('第二章'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('取消跳转'), findsOneWidget);
    await tester.tap(find.byTooltip('取消跳转'));
    pending.complete(fixture.chapterText(1));
    await fixture.settleReader(tester);
    await fixture.settleReader(tester);
    expect(fixture.address(tester).chapterIndex, 0);
    expect(find.byKey(const ValueKey('reader_jump_back')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });
}
