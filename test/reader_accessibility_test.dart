import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
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

  for (final mode in ['slide', 'simulation']) {
    testWidgets('$mode left-hand taps reverse sides but not drag direction', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await ReaderSettingsRepository().save(
        const ReaderSettings(tapLayout: 'left_hand'),
      );
      await fixture.openReader(
        tester,
        mode,
        chapters: [
          Chapter(
            itemId: 'left',
            title: '章节',
            content: fixture.chapterText(0, paragraphs: 30),
          ),
        ],
      );
      final rect = tester.getRect(find.byType(ReaderPageView));
      await tester.tapAt(Offset(rect.left + 20, rect.center.dy));
      await fixture.settleReader(tester);
      expect(fixture.address(tester).pageIndex, 1);
      await tester.tapAt(Offset(rect.right - 20, rect.center.dy));
      await fixture.settleReader(tester);
      expect(fixture.address(tester).pageIndex, 0);
      await tester.drag(find.byType(ReaderPageView), const Offset(-300, 0));
      await fixture.settleReader(tester);
      expect(fixture.address(tester).pageIndex, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    });
  }

  testWidgets('pure reading retains anchor and restores original preferences', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await fixture.openReader(
      tester,
      'none',
      chapters: [
        Chapter(
          itemId: 'pure',
          title: '章节',
          content: fixture.chapterText(0, paragraphs: 30),
        ),
      ],
    );
    final view = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    view.turnToNextPage();
    await fixture.settleReader(tester);
    final anchor = fixture.address(tester).page.position('pure');
    Future<void> toggle(String label) async {
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
      await fixture.settleReader(tester);
      await tester.tap(find.byTooltip('更多选项'));
      await fixture.settleReader(tester);
      await tester.tap(find.text(label));
      await fixture.settleReader(tester);
    }

    await toggle('纯净阅读');
    expect((await ReaderSettingsRepository().load()).settings.pureMode, true);
    expect(
      fixture.address(tester).layout.pageFor(anchor),
      fixture.address(tester).pageIndex,
    );
    expect(find.textContaining('第 1 /'), findsNothing);
    await toggle('退出纯净阅读');
    final settings = (await ReaderSettingsRepository().load()).settings;
    expect(settings.pureMode, false);
    expect(settings.showHeader, true);
    expect(settings.showStatus, true);
    expect(
      fixture.address(tester).layout.pageFor(anchor),
      fixture.address(tester).pageIndex,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.settleReader(tester);
  });

  testWidgets(
    '320dp reader menu and settings support 2x text without overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await fixture.openReader(
        tester,
        'none',
        scale: 2,
        width: 320,
        height: 700,
      );
      await tester.tapAt(tester.getCenter(find.byType(ReaderPageView)));
      await fixture.settleReader(tester);
      await tester.tap(find.text('排版设置'));
      await fixture.settleReader(tester);
      await tester.ensureVisible(find.text('高级排版与操作'));
      await tester.tap(find.text('高级排版与操作'));
      await fixture.settleReader(tester);
      await tester.ensureVisible(find.text('休息提醒'));
      await fixture.settleReader(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.settleReader(tester);
    },
  );
}
