import 'dart:io';
import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
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
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ReaderPlatform.resetForTesting();
    root = await Directory.systemTemp.createTemp('windows-reading-regression-');
    AppStorage.documentsOverride = () async => root;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, (_) async => null);
  });
  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, null);
    await root.delete(recursive: true);
  });

  void windowsTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> open(
    WidgetTester tester,
    ReaderSettings settings, {
    int chapters = 1,
    double devicePixelRatio = 1,
    List<Chapter>? data,
    Future<String?> Function(Chapter)? loader,
  }) async {
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = Size(
      1200 * devicePixelRatio,
      850 * devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    await ReaderSettingsRepository().save(settings);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(
            bookId: 'local_windows_reading_regression',
            bookName: '阅读体验回归',
            author: '测试',
          ),
          chapters:
              data ??
              List.generate(
                chapters,
                (chapter) => Chapter(
                  itemId: 'c$chapter',
                  title: '第${chapter + 1}章',
                  content: List.generate(
                    90,
                    (paragraph) =>
                        '第$paragraph段，Reading words for selection。'
                            '这是用于验证配色刷新与连续阅读位置的正文，保持原文坐标。' *
                        3,
                  ).join('\n\n'),
                ),
              ),
          chapterContentLoader: loader,
          initialSettings: ReaderSettingsRecord(settings),
          resumeSavedPosition: false,
          offlineOnly: true,
          bookDocuments: () async => root,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ReaderPageViewState pager(WidgetTester tester) =>
      tester.state<ReaderPageViewState>(find.byType(ReaderPageView));

  dynamic address(WidgetTester tester) =>
      tester.widget<ReaderPageView>(find.byType(ReaderPageView)).currentPageId;

  Finder column(WidgetTester tester) => find
      .byKey(
        ValueKey(
          'reader-column-c${address(tester).chapterIndex}-'
          '${address(tester).pageIndex}',
        ),
      )
      .hitTestable();

  Color background(WidgetTester tester) =>
      tester.widget<ColoredBox>(column(tester)).color;

  Color foreground(WidgetTester tester) => tester
      .widget<DesktopSelectableParagraph>(
        find
            .descendant(
              of: column(tester),
              matching: find.byType(DesktopSelectableParagraph),
            )
            .first,
      )
      .style
      .color!;

  Future<void> changePaint(WidgetTester tester, ReaderSettings settings) async {
    expect(DesktopCommands.dispatch('settings'), isTrue);
    await tester.pumpAndSettle();
    final sheet = find.byType(ReaderSettingsSheet);
    await ReaderSettingsRepository().save(settings);
    await tester.widget<ReaderSettingsSheet>(sheet).onChanged(settings, false);
    await tester.pump();
    Navigator.of(tester.element(sheet)).pop();
    await tester.pumpAndSettle();
  }

  for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
    windowsTest(
      '$mode custom paint updates current and cached pages without reflow',
      (tester) async {
        final settings = ReaderSettings(
          pageMode: true,
          pageAnimation: mode,
          desktopColumns: 'single',
          commentBubbles: false,
          showHeader: false,
          showStatus: false,
        );
        await open(tester, settings);
        final measured = address(tester).layout;
        final original = address(tester).page.position('c0');
        expect(background(tester), const Color(0xFFF5EEDC));
        await changePaint(
          tester,
          settings.copyWith(
            customBackground: 0xFFE3EBEF,
            customText: 0xFF293840,
          ),
        );
        expect(background(tester), const Color(0xFFE3EBEF));
        expect(foreground(tester), const Color(0xFF293840));
        expect(address(tester).layout, same(measured));
        final current = address(tester).page.position('c0');
        expect(current.paragraphIndex, original.paragraphIndex);
        expect(current.characterOffset, original.characterOffset);
        pager(tester).turnToNextPage();
        await tester.pumpAndSettle();
        expect(background(tester), const Color(0xFFE3EBEF));
        expect(foreground(tester), const Color(0xFF293840));
        pager(tester).turnToPreviousPage();
        await tester.pumpAndSettle();
        expect(background(tester), const Color(0xFFE3EBEF));
        expect(address(tester).layout, same(measured));
        expect(tester.takeException(), isNull);
      },
    );

    windowsTest(
      '$mode explicit edge click responds without text selection delay',
      (tester) async {
        await open(
          tester,
          ReaderSettings(
            pageMode: true,
            pageAnimation: mode,
            desktopColumns: 'single',
            commentBubbles: false,
            showHeader: false,
            showStatus: false,
          ),
        );
        final before = pager(tester).currentPageId;
        final next = find.byKey(const ValueKey('reader-next-page-edge'));
        expect(next, findsOneWidget);
        await tester.tap(next, kind: PointerDeviceKind.mouse);
        await tester.pump();
        if (mode == 'none') {
          expect(pager(tester).currentPageId, isNot(before));
        } else {
          expect(pager(tester).isBusy, isTrue);
          await tester.pump(const Duration(milliseconds: 40));
          final pageView = find.byType(PageView);
          if (pageView.evaluate().isNotEmpty) {
            expect(
              tester.widget<PageView>(pageView).controller!.page,
              greaterThan(0),
            );
          }
        }
        await tester.pumpAndSettle();
        expect(address(tester).pageIndex, 1);
        expect(
          tester
              .widgetList<DesktopReaderSelection>(
                find.byType(DesktopReaderSelection),
              )
              .any((region) => region.controller.hasSelection),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  windowsTest('dark desktop history controls inherit the reader palette', (
    tester,
  ) async {
    await open(
      tester,
      const ReaderSettings(
        pageMode: true,
        themeIndex: 3,
        commentBubbles: false,
      ),
    );
    for (final key in ['desktop-history-back', 'desktop-history-forward']) {
      final context = tester.element(find.byKey(ValueKey(key)));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(
        Theme.of(context).colorScheme.onSurface,
        ReaderTheme.presets[3].textColor,
      );
    }
  });

  for (final mode in ['cover', 'simulation']) {
    windowsTest('$mode wheel continues across a delayed chapter boundary', (
      tester,
    ) async {
      final ready = Completer<String?>();
      var loads = 0;
      await open(
        tester,
        ReaderSettings(
          pageMode: true,
          pageAnimation: mode,
          desktopColumns: 'single',
          commentBubbles: false,
          showHeader: false,
          showStatus: false,
        ),
        data: [
          Chapter(itemId: 'c0', title: '第一章', content: '第一章短正文，只有一页。'),
          Chapter(itemId: 'c1', title: '第二章'),
        ],
        loader: (_) {
          loads++;
          return ready.future;
        },
      );
      Future<void> signal(int milliseconds) => tester.sendEventToBinding(
        PointerScrollEvent(
          timeStamp: Duration(milliseconds: milliseconds),
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(ReaderPageView)),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await signal(1000);
      await tester.pump(const Duration(milliseconds: 70));
      await signal(1070);
      await tester.pump(const Duration(milliseconds: 70));
      ready.complete(
        List.generate(
          90,
          (index) => '第二章第$index段，继续阅读原文而不丢失滚轮意图。' * 4,
        ).join('\n\n'),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      for (var index = 0; index < 16; index++) {
        await tester.pump(const Duration(milliseconds: 70));
        await signal(1140 + index * 70);
      }
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(address(tester).chapterIndex, 1);
      expect(address(tester).pageIndex, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  }

  windowsTest(
    'text double-click retains word selection without a queued turn',
    (tester) async {
      await open(
        tester,
        const ReaderSettings(
          pageMode: true,
          pageAnimation: 'cover',
          desktopColumns: 'single',
          commentBubbles: false,
        ),
      );
      final before = pager(tester).currentPageId;
      final paragraph = tester.getRect(
        find.byType(DesktopSelectableParagraph).hitTestable().first,
      );
      final point = Offset(paragraph.center.dx, paragraph.top + 8);
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(point, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<DesktopReaderSelection>(
              find.byType(DesktopReaderSelection),
            )
            .any((region) => region.controller.hasSelection),
        isTrue,
      );
      expect(pager(tester).currentPageId, before);
      expect(pager(tester).isBusy, isFalse);
    },
  );

  windowsTest('2x DPI double-to-single resize retains the canonical anchor', (
    tester,
  ) async {
    await open(
      tester,
      const ReaderSettings(
        pageMode: true,
        pageAnimation: 'cover',
        desktopColumns: 'double',
        commentBubbles: false,
      ),
      devicePixelRatio: 2,
    );
    expect(
      find.byKey(const ValueKey('reader-double-column-spread')).hitTestable(),
      findsOneWidget,
    );
    for (var turn = 0; turn < 3; turn++) {
      await tester.tap(
        find.byKey(const ValueKey('reader-next-page-edge')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
    }
    final original = address(tester).page.position('c0');
    tester.view.physicalSize = const Size(1480, 1280);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reader-double-column-spread')),
      findsNothing,
    );
    expect(address(tester).layout.pageFor(original), address(tester).pageIndex);
    expect(tester.takeException(), isNull);
  });

  windowsTest('fullscreen chapter text keeps normal text contrast', (
    tester,
  ) async {
    await open(
      tester,
      const ReaderSettings(
        pageMode: true,
        themeIndex: 2,
        commentBubbles: false,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('desktop-immersive-chapter-title')),
    );
    final bg = ReaderTheme.presets[2].backgroundColor;
    final fg = Color.alphaBlend(text.style!.color!, bg);
    final a = fg.computeLuminance(), b = bg.computeLuminance();
    final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
    expect(ratio, greaterThanOrEqualTo(4.5));
  });
}
