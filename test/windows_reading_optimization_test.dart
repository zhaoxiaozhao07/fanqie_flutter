import 'dart:io';
import 'dart:async';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String ownedRoot;
  late String temporaryParent;
  Future<Directory> Function()? previousDocuments;
  TargetPlatform? previousPlatform;
  setUp(() async {
    previousDocuments = AppStorage.documentsOverride;
    previousPlatform = debugDefaultTargetPlatformOverride;
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ReaderPlatform.resetForTesting();
    temporaryParent = await Directory.systemTemp.resolveSymbolicLinks();
    root = await Directory(
      temporaryParent,
    ).createTemp('windows-reading-regression-');
    ownedRoot = await root.resolveSymbolicLinks();
    AppStorage.documentsOverride = () async => root;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, (_) async => null);
  });
  tearDown(() async {
    try {
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      await DesktopReaderPreferences.flush();
    } finally {
      try {
        expect(
          await FileSystemEntity.type(root.path, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(await root.resolveSymbolicLinks(), ownedRoot);
        expect(path.isWithin(temporaryParent, ownedRoot), isTrue);
        expect(path.dirname(ownedRoot), temporaryParent);
        expect(
          path.basename(ownedRoot).startsWith('windows-reading-regression-'),
          isTrue,
        );
        await root.delete(recursive: true);
      } finally {
        AppStorage.documentsOverride = previousDocuments;
        ReaderPlatform.resetForTesting();
        debugDefaultTargetPlatformOverride = previousPlatform;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ReaderPlatform.channel, null);
      }
    }
  });

  void desktopTest(
    String name,
    WidgetTesterCallback body, {
    TargetPlatform platform = TargetPlatform.windows,
  }) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          // testWidgets checks foundation overrides before outer tearDown runs.
          debugDefaultTargetPlatformOverride = null;
        }
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

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    final prefix = platform == TargetPlatform.macOS ? 'Mac ' : '';
    for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
      desktopTest(
        '$prefix$mode custom paint updates current and cached pages without reflow',
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
          expect(pager(tester).widget.mode, mode);
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
        platform: platform,
      );

      desktopTest(
        '$prefix$mode explicit edge click responds without text selection delay',
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
          expect(pager(tester).widget.mode, mode);
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
        platform: platform,
      );
    }
  }

  desktopTest(
    'Mac mounted 104k single paragraph preserves every canonical range',
    (tester) async {
      final text =
          '超长段落不可截断，保留中文 English words 0123 与 👨‍👩‍👧‍👦 原文锚点。' * 2000;
      expect(text.length, 104000);
      await open(
        tester,
        const ReaderSettings(
          pageMode: true,
          pageAnimation: 'none',
          desktopColumns: 'single',
          commentBubbles: false,
          showHeader: false,
          showStatus: false,
        ),
        data: [Chapter(itemId: 'c0', title: '超长段落', content: text)],
      );
      final pages = address(tester).layout as ReaderChapterPages;
      expect(pages.sourceParagraphs, [text]);
      expect(pages.pages.length, greaterThan(22));
      final fragments = pages.pages.expand((page) => page.fragments).toList();
      final boundaries = <int>{0};
      var boundary = 0;
      for (final cluster in text.characters) {
        boundary += cluster.length;
        boundaries.add(boundary);
      }
      var cursor = 0;
      for (final fragment in fragments) {
        expect(fragment.paragraphIndex, 0);
        expect(fragment.startOffset, cursor);
        expect(boundaries.contains(fragment.startOffset), isTrue);
        expect(boundaries.contains(fragment.endOffset), isTrue);
        expect(
          fragment.text,
          '${cursor == 0 ? "\u3000\u3000" : ""}'
          '${text.substring(cursor, fragment.endOffset)}',
        );
        cursor = fragment.endOffset;
      }
      expect(cursor, 104000);
      pager(tester).turnToNextPage();
      await tester.pumpAndSettle();
      expect(address(tester).pageIndex, 1);
      expect(address(tester).page.position('c0').paragraphIndex, 0);
      expect(
        address(tester).page.position('c0').characterOffset,
        fragments.first.endOffset,
      );
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.macOS,
  );

  desktopTest(
    'Mac short-chapter fixture commits two warmups and twenty real transitions',
    (tester) async {
      await open(
        tester,
        const ReaderSettings(
          pageMode: true,
          pageAnimation: 'cover',
          desktopColumns: 'single',
          commentBubbles: false,
          showHeader: false,
          showStatus: false,
        ),
        data: [
          for (var chapter = 0; chapter < 40; chapter++)
            Chapter(
              itemId: 'c$chapter',
              title: '第${chapter + 1}章',
              content: '第$chapter章隔离正文。跨章完成后必须提交正确章节与原文锚点。',
            ),
        ],
      );
      expect(address(tester).chapterIndex, 0);
      for (var completed = 1; completed <= 22; completed++) {
        expect(address(tester).layout.pages.length, 1);
        pager(tester).turnToNextPage();
        await tester.pumpAndSettle();
        expect(pager(tester).isBusy, isFalse);
        expect(address(tester).chapterIndex, completed);
        expect(address(tester).layout.chapterId, 'c$completed');
        expect(address(tester).layout.sourceParagraphs, [
          '第$completed章隔离正文。跨章完成后必须提交正确章节与原文锚点。',
        ]);
        expect(address(tester).pageIndex, 0);
        expect(pager(tester).currentPageId, address(tester));
      }
      await ReaderSystemService.flushParticipants();
      final saved = await ReaderPositionService().loadSnapshot(
        'local_windows_reading_regression',
      );
      expect(saved!.chapterIndex, 22);
      expect(saved.position.chapterId, 'c22');
      expect(saved.position.paragraphIndex, 0);
      expect(saved.position.characterOffset, 0);
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.macOS,
  );

  desktopTest('dark desktop history controls inherit the reader palette', (
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
    desktopTest('$mode wheel continues across a delayed chapter boundary', (
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

  desktopTest(
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

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    desktopTest(
      '${platform == TargetPlatform.macOS ? "Mac" : "Windows"} 2x DPI double-to-single resize retains the canonical anchor',
      (tester) async {
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
          find
              .byKey(const ValueKey('reader-double-column-spread'))
              .hitTestable(),
          findsOneWidget,
        );
        expect(tester.view.devicePixelRatio, 2);
        for (var turn = 0; turn < 3; turn++) {
          await tester.tap(
            find.byKey(const ValueKey('reader-next-page-edge')),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pumpAndSettle();
        }
        final original = address(tester).page.position('c0');
        await ReaderSystemService.flushParticipants();
        final beforeResize = await ReaderPositionService().load(
          'local_windows_reading_regression',
        );
        expect(beforeResize!.chapterId, 'c0');
        expect(beforeResize.paragraphIndex, original.paragraphIndex);
        expect(beforeResize.characterOffset, original.characterOffset);
        tester.view.physicalSize = const Size(1480, 1280);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('reader-double-column-spread')),
          findsNothing,
        );
        expect(address(tester).chapterIndex, 0);
        expect(
          address(tester).layout.pageFor(original),
          address(tester).pageIndex,
        );
        await ReaderSystemService.flushParticipants();
        final afterResize = await ReaderPositionService().load(
          'local_windows_reading_regression',
        );
        expect(afterResize!.chapterId, 'c0');
        expect(afterResize.paragraphIndex, original.paragraphIndex);
        expect(afterResize.characterOffset, original.characterOffset);
        expect(tester.takeException(), isNull);
      },
      platform: platform,
    );
  }

  desktopTest('fullscreen chapter text keeps normal text contrast', (
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
