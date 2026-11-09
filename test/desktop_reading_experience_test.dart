import 'helpers/desktop_selection.dart';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/services/desktop_reader_layout.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('desktop-reading-regression-');
    AppStorage.documentsOverride = () async => root;
    ReaderPlatform.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, (_) async => null);
  });
  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, null);
    await root.delete(recursive: true);
  });

  void desktopTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 700);
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        tester.view.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> open(
    WidgetTester tester,
    String mode, {
    String columns = 'auto',
    bool pageMode = true,
    bool showChrome = false,
    bool reduceMotion = false,
    List<Chapter>? chapters,
  }) async {
    final settings = ReaderSettings(
      pageMode: pageMode,
      pageAnimation: mode,
      desktopColumns: columns,
      commentBubbles: false,
      showHeader: showChrome,
      showStatus: showChrome,
    );
    await ReaderSettingsRepository().save(settings);
    await tester.pumpWidget(
      MaterialApp(
        builder: reduceMotion
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              )
            : null,
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(bookId: 'local_tap_$mode', bookName: '点击回归', author: '测试'),
          chapters:
              chapters ??
              [
                Chapter(
                  itemId: 'c',
                  title: '正文',
                  content: List.generate(
                    100,
                    (i) => '第$i段。桌面正文单击必须可以翻页或打开控制栏，同时仍能拖动选择原文。' * 3,
                  ).join('\n\n'),
                ),
              ],
          resumeSavedPosition: false,
          bookDocuments: () async => root,
          initialSettings: ReaderSettingsRecord(settings),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
    desktopTest('$mode mouse taps on text keep paging and controls usable', (
      tester,
    ) async {
      await open(tester, mode);
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final first = pager.currentPageId;
      final text = tester.getRect(
        find.byType(DesktopSelectableParagraph).hitTestable().first,
      );
      await tester.tapAt(
        Offset(text.right - 20, text.top + 12),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        pager.currentPageId,
        isNot(first),
        reason: 'SelectableText must not swallow the page hotspot',
      );
      final nextText = tester.getRect(
        find.byType(DesktopSelectableParagraph).hitTestable().first,
      );
      await tester.tapAt(
        Offset(nextText.center.dx, nextText.top + 12),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('排版设置'), findsOneWidget);
      await tester.tap(find.text('排版设置'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPageView), findsOneWidget);
      expect(pager.isBusy, false);
      expect(tester.takeException(), isNull);
    });
  }

  desktopTest(
    'reduced motion still turns immediately and coalesces wheel input',
    (tester) async {
      await open(tester, 'simulation', reduceMotion: true);
      expect(
        tester.widget<ReaderPageView>(find.byType(ReaderPageView)).mode,
        'none',
      );
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      for (var event = 0; event < 3; event++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(find.byType(ReaderPageView)),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 35));
      }
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).pageIndex, 1);
      expect(pager.isBusy, false);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('simulation mouse taps on blank page margins can turn pages', (
    tester,
  ) async {
    await open(tester, 'simulation');
    final pager = tester.state<ReaderPageViewState>(
      find.byType(ReaderPageView),
    );
    final first = pager.currentPageId;
    final rect = tester.getRect(find.byType(ReaderPageView));
    await tester.tapAt(
      Offset(rect.right - 4, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(pager.currentPageId, isNot(first));
    expect(pager.isBusy, false);
  });
  test('desktop column preference persists and validates old settings', () {
    expect(ReaderSettings.fromJson({'version': 2}).desktopColumns, 'auto');
    expect(
      ReaderSettings.fromJson({'desktopColumns': 'bad'}).desktopColumns,
      'auto',
    );
    expect(
      ReaderSettings.fromJson(
        const ReaderSettings(desktopColumns: 'double').toJson(),
      ).desktopColumns,
      'double',
    );
    expect(
      DesktopReaderLayout.resolve(
        1400,
        const ReaderSettings(pageMode: true),
        TextScaler.noScaling,
      ).columns,
      2,
    );
    expect(
      DesktopReaderLayout.resolve(
        720,
        const ReaderSettings(pageMode: true, desktopColumns: 'double'),
        TextScaler.noScaling,
      ).columns,
      1,
    );
    expect(
      DesktopReaderLayout.resolve(
        1280,
        const ReaderSettings(pageMode: true, fontSize: 36),
        const TextScaler.linear(2),
      ).columns,
      1,
    );
  });

  desktopTest('wide desktop shows two consecutive pages and turns one spread', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    await open(tester, 'none');
    final pager = tester.state<ReaderPageViewState>(
      find.byType(ReaderPageView),
    );
    final left = find.byKey(const ValueKey('reader-column-c-0')).hitTestable();
    final right = find.byKey(const ValueKey('reader-column-c-1')).hitTestable();
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);
    expect(
      tester.getRect(right).left - tester.getRect(left).right,
      closeTo(DesktopReaderLayout.gutter, 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect((pager.currentPageId as dynamic).pageIndex, 2);
    await ReaderSystemService.flushParticipants();
    final before = await ReaderPositionService().load('local_tap_none');
    await tester.tap(find.byTooltip('切换单栏阅读'));
    await tester.pumpAndSettle();
    await ReaderSystemService.flushParticipants();
    final after = await ReaderPositionService().load('local_tap_none');
    expect(after!.paragraphIndex, before!.paragraphIndex);
    expect(after.characterOffset, before.characterOffset);
    expect(
      find.byKey(const ValueKey('reader-double-column-spread')).hitTestable(),
      findsNothing,
    );
    expect(
      (await ReaderSettingsRepository().load()).settings.desktopColumns,
      'single',
    );
    expect(tester.takeException(), isNull);
  });

  desktopTest('double/single resize preserves the exact canonical position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    await open(tester, 'cover');
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
    }
    await ReaderSystemService.flushParticipants();
    final before = await ReaderPositionService().load('local_tap_cover');
    for (final size in [const Size(720, 540), const Size(1400, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('local_tap_cover');
      expect(after!.chapterId, before!.chapterId);
      expect(after.paragraphIndex, before.paragraphIndex);
      expect(after.characterOffset, before.characterOffset);
      expect(tester.takeException(), isNull);
    }
  });

  desktopTest(
    'a short last spread does not duplicate text and crosses chapters',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      await open(
        tester,
        'none',
        chapters: [
          Chapter(itemId: 'a', title: '第一章', content: '第一章短篇正文。' * 10),
          Chapter(itemId: 'b', title: '第二章', content: '第二章正文。' * 10),
        ],
      );
      expect(
        find.byKey(const ValueKey('reader-empty-right-column')).hitTestable(),
        findsOneWidget,
      );
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).chapterIndex, 1);
      expect((pager.currentPageId as dynamic).pageIndex, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).chapterIndex, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final mode in ['cover', 'simulation']) {
    desktopTest('$mode double click and mouse selection do not turn the page', (
      tester,
    ) async {
      await open(tester, mode);
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final initial = pager.currentPageId;
      final text = tester.getRect(
        find.byType(DesktopSelectableParagraph).hitTestable().first,
      );
      final point = Offset(text.right - 100, text.top + 14);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(pager.currentPageId, initial);
      expect(hasDesktopSelection(tester), true);
      expect(tester.takeException(), isNull);
    });
  }

  desktopTest('settings stay accessible while a page turn is running', (
    tester,
  ) async {
    await open(tester, 'simulation');
    final pager = tester.state<ReaderPageViewState>(
      find.byType(ReaderPageView),
    );
    pager.turnToNextPage();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('桌面阅读栏数'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expect(pager.isBusy, false);
    final before = pager.currentPageId;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(pager.currentPageId, isNot(before));
    expect(tester.takeException(), isNull);
  });

  desktopTest(
    'reading full-screen hides chrome without changing the application window',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        calls.add(call);
        return null;
      });
      await open(tester, 'none', showChrome: true);
      expect(
        find.byKey(const ValueKey('reader-chapter-header')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-status-bar')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('local_tap_none');
      await tester.tap(find.byTooltip('阅读全屏'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-reader-toolbar')).hitTestable(),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('reader-chapter-header')), findsNothing);
      expect(find.byKey(const ValueKey('reader-status-bar')), findsNothing);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('desktop-reader-viewport')),
      );
      expect(viewport, const Rect.fromLTWH(0, 0, 1920, 1080));
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      await ReaderSystemService.flushParticipants();
      final immersed = await ReaderPositionService().load('local_tap_none');
      expect(immersed!.paragraphIndex, before!.paragraphIndex);
      expect(immersed.characterOffset, before.characterOffset);
      await tester.tapAt(viewport.center, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('排版设置'), findsOneWidget);
      expect(find.byTooltip('退出阅读全屏'), findsOneWidget);
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      await tester.tap(find.byTooltip('退出阅读全屏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读全屏'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-chapter-header')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reader-status-bar')), findsOneWidget);
      await ReaderSystemService.flushParticipants();
      final returned = await ReaderPositionService().load('local_tap_none');
      expect(returned!.paragraphIndex, before.paragraphIndex);
      expect(returned.characterOffset, before.characterOffset);
      final settings = (await ReaderSettingsRepository().load()).settings;
      expect(settings.showHeader, true);
      expect(settings.showStatus, true);
      expect(
        calls.where((call) => call.method.contains('FullScreen')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
    desktopTest('$mode wheel gesture advances one dual-page spread, not two', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      await open(tester, mode);
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      for (var event = 0; event < 3; event++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(find.byType(ReaderPageView)),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump(const Duration(milliseconds: 35));
      }
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).pageIndex, 2);
      expect(
        find.byKey(const ValueKey('reader-column-c-2')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-column-c-3')).hitTestable(),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(ReaderPageView)),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).pageIndex, 0);
      expect(pager.isBusy, false);
      expect(tester.takeException(), isNull);
    });

    desktopTest(
      '$mode dual-column repeated turns and settings stay responsive',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        await open(tester, mode);
        final pager = tester.state<ReaderPageViewState>(
          find.byType(ReaderPageView),
        );
        final right = find
            .byKey(const ValueKey('reader-column-c-1'))
            .hitTestable();
        final text = tester.getRect(
          find
              .descendant(
                of: right,
                matching: find.byType(DesktopSelectableParagraph),
              )
              .hitTestable()
              .first,
        );
        await tester.tapAt(
          Offset(text.right - 24, text.top + 12),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 0);
        final rect = tester.getRect(find.byType(ReaderPageView));
        for (var i = 0; i < 2; i++) {
          await tester.tapAt(
            Offset(rect.right - 4, rect.center.dy),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 40));
        }
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 4);
        await tester.tap(find.byTooltip('阅读设置'));
        await tester.pumpAndSettle();
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 2);
        expect(pager.isBusy, false);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['cover', 'simulation']) {
    desktopTest('$mode dismissing a word selection does not also turn pages', (
      tester,
    ) async {
      await open(tester, mode);
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final first = pager.currentPageId;
      final text = tester.getRect(
        find.byType(DesktopSelectableParagraph).hitTestable().first,
      );
      final point = Offset(text.right - 100, text.top + 14);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(pager.currentPageId, first);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(pager.currentPageId, first);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(pager.currentPageId, isNot(first));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();
      expect(pager.currentPageId, first);
      expect(tester.takeException(), isNull);
    });

    desktopTest(
      '$mode resize during a turn preserves the target source anchor',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        await open(tester, mode);
        final pager = tester.state<ReaderPageViewState>(
          find.byType(ReaderPageView),
        );
        pager.turnToNextPage();
        await tester.pumpAndSettle();
        final source = pager.currentPageId as dynamic;
        final target = source.layout.pages[source.pageIndex + 2].position('c');
        pager.turnToNextPage();
        await tester.pump(const Duration(milliseconds: 40));
        tester.view.physicalSize = const Size(720, 540);
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final after = await ReaderPositionService().load('local_tap_$mode');
        expect(after!.paragraphIndex, target.paragraphIndex);
        expect(after.characterOffset, target.characterOffset);
        expect(pager.isBusy, false);
        tester.view.physicalSize = const Size(1400, 900);
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final returned = await ReaderPositionService().load('local_tap_$mode');
        expect(returned!.paragraphIndex, target.paragraphIndex);
        expect(returned.characterOffset, target.characterOffset);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(pager.isBusy, false);
        expect(tester.takeException(), isNull);
      },
    );
  }

  desktopTest(
    'a right-column highlight keeps exact original character offsets',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      final original = List.generate(
        500,
        (i) => '原文${i.toString().padLeft(4, '0')}。',
      ).join();
      await open(
        tester,
        'none',
        chapters: [Chapter(itemId: 'c', title: '正文', content: original)],
      );
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final before = pager.currentPageId;
      final right = find
          .byKey(const ValueKey('reader-column-c-1'))
          .hitTestable();
      final selectable = find
          .descendant(
            of: right,
            matching: find.byType(DesktopSelectableParagraph),
          )
          .hitTestable()
          .first;
      final rect = tester.getRect(selectable);
      final gesture = await tester.startGesture(
        Offset(rect.left + 15, rect.top + 12),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(Offset(rect.left + 90, rect.top + 12));
      await tester.pump();
      await gesture.moveTo(Offset(rect.left + 170, rect.top + 12));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(pager.currentPageId, before);
      final value = desktopSelectionValue(tester, selectable);
      expect(value.selection.isCollapsed, false);
      final fragmentStart = original.indexOf(value.text);
      expect(fragmentStart, greaterThan(0));
      final selected = value.selection.textInside(value.text);
      expect(selected.trim(), isNotEmpty);
      final expectedStart =
          fragmentStart +
          value.selection.start +
          selected.length -
          selected.trimLeft().length;
      final expectedEnd =
          fragmentStart +
          value.selection.end -
          (selected.length - selected.trimRight().length);
      final secondary = await tester.startGesture(
        Offset(rect.left + 70, rect.top + 12),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      final notes = await BookmarkService().getNotes('local_tap_none');
      expect(notes.single.startOffset, expectedStart);
      expect(notes.single.endOffset, expectedEnd);
      expect(notes.single.text, original.substring(expectedStart, expectedEnd));
      expect(notes.single.paragraphIndex, 0);
      expect(pager.currentPageId, before);
      expect(tester.takeException(), isNull);
    },
  );
  desktopTest('dual-column selection flows left-to-right in canonical order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    final original = List.generate(
      600,
      (i) => '原文${i.toString().padLeft(4, '0')}。',
    ).join();
    await open(
      tester,
      'none',
      chapters: [Chapter(itemId: 'c', title: '正文', content: original)],
    );
    Finder paragraph(int page) => find
        .descendant(
          of: find.byKey(ValueKey('reader-column-c-$page')).hitTestable(),
          matching: find.byType(DesktopSelectableParagraph),
        )
        .hitTestable()
        .first;
    final left = tester.getRect(paragraph(0));
    final right = tester.getRect(paragraph(1));
    final pager = tester.state<ReaderPageViewState>(
      find.byType(ReaderPageView),
    );
    final before = pager.currentPageId;
    final gesture = await tester.startGesture(
      Offset(left.left + 80, left.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset(left.left + 160, left.top + 12));
    await tester.pump();
    await gesture.moveTo(Offset(right.left + 120, right.top + 12));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final selection = tester
        .widget<DesktopReaderSelection>(
          find
              .ancestor(
                of: paragraph(0),
                matching: find.byType(DesktopReaderSelection),
              )
              .first,
        )
        .controller;
    expect(selection.segments, hasLength(1));
    final range = selection.segments.single;
    expect(range.start, greaterThan(0));
    expect(
      range.end,
      greaterThan(
        original.indexOf(
          tester
              .widget<DesktopSelectableParagraph>(paragraph(1))
              .span
              .toPlainText(),
        ),
      ),
    );
    expect(selection.selectedText, original.substring(range.start, range.end));
    expect(selection.selectedText.contains('\u3000'), false);
    expect(pager.currentPageId, before);
    expect(tester.takeException(), isNull);
  });
  desktopTest('layout changes cancel a pending text click at old coordinates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(840, 700);
    await open(tester, 'none');
    final pager = tester.state<ReaderPageViewState>(
      find.byType(ReaderPageView),
    );
    final text = tester.getRect(
      find.byType(DesktopSelectableParagraph).hitTestable().first,
    );
    await tester.tapAt(
      Offset(text.right - 24, text.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byTooltip('切换双栏阅读'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect((pager.currentPageId as dynamic).pageIndex, 0);
    final right = tester.getRect(
      find
          .descendant(
            of: find.byKey(const ValueKey('reader-column-c-1')).hitTestable(),
            matching: find.byType(DesktopSelectableParagraph),
          )
          .hitTestable()
          .first,
    );
    await tester.tapAt(
      Offset(right.right - 24, right.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 80));
    tester.view.physicalSize = const Size(720, 540);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect((pager.currentPageId as dynamic).pageIndex, 0);
    expect(pager.isBusy, false);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1920.0, 2560.0]) {
    desktopTest(
      'dual pages use the $width wide window without outer blank bands',
      (tester) async {
        tester.view.physicalSize = Size(width, 1080);
        await open(tester, 'none');
        final viewport = tester.getRect(
          find.byKey(const ValueKey('desktop-reader-viewport')),
        );
        final left = tester.getRect(
          find.byKey(const ValueKey('reader-column-c-0')).hitTestable(),
        );
        final right = tester.getRect(
          find.byKey(const ValueKey('reader-column-c-1')).hitTestable(),
        );
        expect(viewport.left, 0);
        expect(viewport.width, width);
        expect(left.left, 0);
        expect(right.right, width);
        expect(right.left - left.right, DesktopReaderLayout.gutter);
        final leftText = tester.getRect(
          find.byType(DesktopSelectableParagraph).hitTestable().first,
        );
        expect(leftText.left, lessThanOrEqualTo(28));
        expect(leftText.width, greaterThan(width / 2 - 80));
        expect(tester.takeException(), isNull);
      },
    );
  }

  desktopTest(
    'immersive hover toolbar and center controls overlay without reflow',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      await open(tester, 'simulation', showChrome: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final viewport = tester.getRect(find.byType(ReaderPageView));
      expect(viewport, const Rect.fromLTWH(0, 0, 1400, 900));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: viewport.center);
      await mouse.moveTo(Offset(viewport.left + 160, viewport.top + 6));
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出阅读全屏').hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('桌面阅读栏数'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await mouse.moveTo(viewport.center);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      final firstPage = (pager.currentPageId as dynamic).pageIndex;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).pageIndex, firstPage + 2);
      await mouse.moveTo(Offset(viewport.left + 160, viewport.top + 6));
      await tester.pumpAndSettle();
      await tester.tapAt(viewport.center);
      await tester.pumpAndSettle();
      await mouse.moveTo(viewport.center);
      await tester.tapAt(viewport.center);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      await tester.tapAt(viewport.center, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('排版设置'), findsOneWidget);
      expect(find.byTooltip('退出阅读全屏').hitTestable(), findsOneWidget);
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读全屏').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reader-chapter-header')),
        findsOneWidget,
      );
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'scroll immersion expands the reading viewport and preserves the anchor',
    (tester) async {
      await open(tester, 'none', pageMode: false, showChrome: true);
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
      }
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('local_tap_none');
      expect(before!.paragraphIndex, greaterThan(0));
      await tester.tap(find.byTooltip('阅读全屏'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(CustomScrollView)),
        const Rect.fromLTWH(0, 0, 950, 700),
      );
      await ReaderSystemService.flushParticipants();
      final immersed = await ReaderPositionService().load('local_tap_none');
      expect(immersed!.paragraphIndex, before.paragraphIndex);
      expect(immersed.characterOffset, before.characterOffset);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final returned = await ReaderPositionService().load('local_tap_none');
      expect(returned!.paragraphIndex, before.paragraphIndex);
      expect(returned.characterOffset, before.characterOffset);
      expect(find.byTooltip('阅读全屏').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'F11 ignores repeats and modal input retains priority over immersion',
    (tester) async {
      await open(tester, 'none');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f11);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-reader-toolbar')).hitTestable(),
        findsNothing,
      );
      final page = tester.getRect(find.byType(ReaderPageView));
      await tester.tapAt(page.center, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排版设置'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(find.text('桌面阅读栏数'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出阅读全屏'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读全屏').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('reading immersion does not leak into the next reader session', (
    tester,
  ) async {
    await open(tester, 'none');
    await tester.tap(find.byTooltip('阅读全屏'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await open(tester, 'cover');
    expect(find.byTooltip('阅读全屏').hitTestable(), findsOneWidget);
    expect(find.byTooltip('退出阅读全屏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
    desktopTest(
      '$mode immersion requested during a turn keeps the target anchor',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        await open(tester, mode, showChrome: true);
        final pager = tester.state<ReaderPageViewState>(
          find.byType(ReaderPageView),
        );
        pager.turnToNextPage();
        await tester.pumpAndSettle();
        final source = pager.currentPageId as dynamic;
        final target = source.layout.pages[source.pageIndex + 2].position('c');
        pager.turnToNextPage();
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.byTooltip('阅读全屏'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(ReaderPageView)),
          const Rect.fromLTWH(0, 0, 1400, 900),
        );
        await ReaderSystemService.flushParticipants();
        final immersed = await ReaderPositionService().load('local_tap_$mode');
        expect(immersed!.paragraphIndex, target.paragraphIndex);
        expect(immersed.characterOffset, target.characterOffset);
        expect(pager.isBusy, false);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final returned = await ReaderPositionService().load('local_tap_$mode');
        expect(returned!.paragraphIndex, target.paragraphIndex);
        expect(returned.characterOffset, target.characterOffset);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
