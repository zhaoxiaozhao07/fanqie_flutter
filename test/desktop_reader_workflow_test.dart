import 'helpers/desktop_selection.dart';
import 'dart:async';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_directory.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:fanqie_flutter/widgets/reader_chapter_jump_dialog.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:fanqie_flutter/widgets/reader_search_sheet.dart';
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
    root = await Directory.systemTemp.createTemp('desktop-reader-workflow-');
    AppStorage.documentsOverride = () async => root;
    ReaderPlatform.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderPlatform.channel, (_) async => null);
  });
  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
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
      tester.view.physicalSize = const Size(1400, 900);
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

  List<Chapter> chapters([int count = 6]) => List.generate(
    count,
    (index) => Chapter(
      itemId: 'c$index',
      title: '第${index + 1}章 桌面阅读',
      volumeTitle: index < 3 ? '第一卷' : '第二卷',
      content: List.generate(
        80,
        (paragraph) => '正文第$paragraph段，章节$index。保留阅读锚点、自然滚动、快捷操作。' * 3,
      ).join('\n\n'),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    bool pageMode = true,
    bool reduceMotion = false,
    double textScale = 1,
    String animation = 'none',
    List<Chapter>? data,
    Future<String?> Function(Chapter)? loader,
  }) async {
    final settings = ReaderSettings(
      pageMode: pageMode,
      pageAnimation: animation,
      commentBubbles: false,
      showHeader: false,
      showStatus: false,
    );
    await ReaderSettingsRepository().save(settings);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        builder: (context, child) => DesktopShortcuts(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
        ),
        home: ReaderScreen(
          book: Book(
            bookId: 'local_desktop_workflow',
            bookName: '桌面阅读工作流',
            author: '测试',
          ),
          chapters: data ?? chapters(),
          resumeSavedPosition: false,
          initialSettings: ReaderSettingsRecord(settings),
          bookDocuments: () async => root,
          chapterContentLoader: loader,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
    bool meta = false,
  }) async {
    if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
  }

  Future<ReadingPosition> savedPosition() async {
    await ReaderSystemService.flushParticipants();
    return (await ReaderPositionService().load('local_desktop_workflow'))!;
  }

  void expectAnchor(ReadingPosition actual, ReadingPosition expected) {
    expect(actual.chapterId, expected.chapterId);
    expect(actual.paragraphIndex, expected.paragraphIndex);
    expect(actual.characterOffset, expected.characterOffset);
  }

  ReaderPageViewState pager(WidgetTester tester) =>
      tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
  dynamic address(WidgetTester tester) => pager(tester).currentPageId;
  ScrollController scroll(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller!;

  for (final pageMode in [true, false]) {
    desktopTest(
      '${pageMode ? 'paged' : 'scroll'} directory docking and closing preserve exact anchor',
      (tester) async {
        // Opening the directory changes the effective text width in both modes.
        tester.view.physicalSize = const Size(1060, 800);
        await open(tester, pageMode: pageMode);
        for (var i = 0; i < 4; i++) {
          await shortcut(tester, LogicalKeyboardKey.pageDown);
        }
        final before = await savedPosition();
        final readerState = tester.state(find.byType(ReaderScreen));
        await shortcut(
          tester,
          LogicalKeyboardKey.keyD,
          meta: true,
          shift: true,
        );
        expect(find.byType(DesktopReaderDirectory), findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-directory-scrim')),
          findsNothing,
        );
        final readerRect = tester.getRect(
          find.byKey(const ValueKey('desktop-reader-viewport')),
        );
        expect(readerRect.left, 304);
        expect(readerRect.width, 756);
        expectAnchor(await savedPosition(), before);
        await tester.tap(find.byTooltip('关闭目录'));
        await tester.pumpAndSettle();
        expect(find.byType(DesktopReaderDirectory), findsNothing);
        expect(tester.state(find.byType(ReaderScreen)), same(readerState));
        expectAnchor(await savedPosition(), before);
        final resumed = await savedPosition();
        await shortcut(tester, LogicalKeyboardKey.space);
        final after = await savedPosition();
        expect(
          after.paragraphIndex,
          greaterThanOrEqualTo(resumed.paragraphIndex),
        );
        expect((
          after.paragraphIndex,
          after.characterOffset,
        ), isNot((resumed.paragraphIndex, resumed.characterOffset)));
        expect(tester.takeException(), isNull);
      },
    );
  }

  desktopTest('directory retains query across resize and immersion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(950, 700);
    await open(tester);
    await tester.tap(find.byTooltip('目录（⌘⇧D）'));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(DesktopReaderDirectory));
    expect(
      find.byKey(const ValueKey('desktop-directory-scrim')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('desktop-directory-search')),
      '第5章',
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(DesktopReaderDirectory)), same(state));
    expect(find.byKey(const ValueKey('desktop-directory-scrim')), findsNothing);
    expect(find.byKey(const ValueKey('desktop-directory-4')), findsOneWidget);
    await tester.tap(find.byTooltip('阅读全屏'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopReaderDirectory), findsNothing);
    expect(
      tester.getRect(find.byType(ReaderPageView)),
      const Rect.fromLTWH(0, 0, 1400, 900),
    );
    await shortcut(tester, LogicalKeyboardKey.escape);
    expect(tester.state(find.byType(DesktopReaderDirectory)), same(state));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('desktop-directory-search')),
          )
          .controller!
          .text,
      '第5章',
    );
    await tester.tap(find.byTooltip('关闭目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录（⌘⇧D）'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus!.debugLabel,
      'desktop-reader-directory',
    );
    await shortcut(tester, LogicalKeyboardKey.escape);
    expect(find.byType(DesktopReaderDirectory), findsNothing);
    expect(tester.takeException(), isNull);
  });

  desktopTest('directory jump stays docked and returns to the source anchor', (
    tester,
  ) async {
    await open(tester);
    await shortcut(tester, LogicalKeyboardKey.pageDown);
    await shortcut(tester, LogicalKeyboardKey.pageDown);
    final before = await savedPosition();
    await tester.tap(find.byTooltip('目录（⌘⇧D）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('desktop-directory-4')));
    await tester.pumpAndSettle();
    expect(address(tester).chapterIndex, 4);
    expect(find.byType(DesktopReaderDirectory), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('desktop-directory-4')))
          .selected,
      true,
    );
    await tester.tap(find.byKey(const ValueKey('reader_jump_back')));
    await tester.pumpAndSettle();
    expectAnchor(await savedPosition(), before);
    expect(tester.takeException(), isNull);
  });

  desktopTest(
    'narrow directory jump closes overlay and restores keyboard focus',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      await open(tester);
      await tester.tap(find.byTooltip('目录（⌘⇧D）'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-directory-2')));
      await tester.pumpAndSettle();
      expect(address(tester).chapterIndex, 2);
      expect(find.byType(DesktopReaderDirectory), findsNothing);
      final before = address(tester).pageIndex;
      await shortcut(tester, LogicalKeyboardKey.space);
      expect(address(tester).pageIndex, before + 1);
    },
  );

  desktopTest(
    'chapter jump validates range, Enter confirms and Escape cancels',
    (tester) async {
      await open(tester);
      final first = pager(tester).currentPageId;
      await shortcut(tester, LogicalKeyboardKey.keyJ, meta: true);
      expect(find.byType(ReaderChapterJumpDialog), findsOneWidget);
      final field = find.byKey(const ValueKey('reader-chapter-number'));
      await tester.enterText(field, '99');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('reader-confirm-chapter-jump')),
            )
            .onPressed,
        isNull,
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderChapterJumpDialog), findsOneWidget);
      expect(pager(tester).currentPageId, first);
      await shortcut(tester, LogicalKeyboardKey.escape);
      expect(find.byType(ReaderChapterJumpDialog), findsNothing);
      expect(pager(tester).currentPageId, first);
      await shortcut(tester, LogicalKeyboardKey.keyJ, meta: true);
      await tester.enterText(field, '4');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(address(tester).chapterIndex, 3);
      expect(find.byKey(const ValueKey('reader_jump_back')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('failed chapter jump keeps the original content and anchor', (
    tester,
  ) async {
    final data = [
      chapters(1).first,
      Chapter(itemId: 'missing', title: '内容不可用'),
    ];
    await open(tester, data: data, loader: (_) async => null);
    await shortcut(tester, LogicalKeyboardKey.pageDown);
    final before = await savedPosition();
    await shortcut(tester, LogicalKeyboardKey.keyJ, meta: true);
    await tester.enterText(
      find.byKey(const ValueKey('reader-chapter-number')),
      '2',
    );
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(address(tester).chapterIndex, 0);
    expectAnchor(await savedPosition(), before);
    expect(find.byKey(const ValueKey('reader_jump_back')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  desktopTest(
    'Escape cancels a pending quick jump and ignores its late result',
    (tester) async {
      final pending = Completer<String?>();
      await open(
        tester,
        data: [
          chapters(1).first,
          Chapter(itemId: 'slow', title: '延迟加载章节'),
        ],
        loader: (_) => pending.future,
      );
      await shortcut(tester, LogicalKeyboardKey.space);
      final before = await savedPosition();
      await shortcut(tester, LogicalKeyboardKey.keyJ, meta: true);
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-number')),
        '2',
      );
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byTooltip('取消跳转'), findsOneWidget);
      await shortcut(tester, LogicalKeyboardKey.escape);
      pending.complete('迟到的正文不应替换用户正在阅读的内容。' * 50);
      await tester.pumpAndSettle();
      expect(address(tester).chapterIndex, 0);
      expectAnchor(await savedPosition(), before);
      expect(find.byTooltip('取消跳转'), findsNothing);
    },
  );

  for (final mode in ['none', 'cover', 'simulation']) {
    desktopTest('$mode Space, Shift-Space and Home/End navigate predictably', (
      tester,
    ) async {
      await open(tester, animation: mode);
      await shortcut(tester, LogicalKeyboardKey.space);
      expect(address(tester).pageIndex, 2);
      await shortcut(tester, LogicalKeyboardKey.space, shift: true);
      expect(address(tester).pageIndex, 0);
      await shortcut(tester, LogicalKeyboardKey.end);
      final last = address(tester);
      expect(last.chapterIndex, 0);
      expect(last.pageIndex, (last.layout.pages.length - 1) ~/ 2 * 2);
      await shortcut(tester, LogicalKeyboardKey.home);
      expect(address(tester).pageIndex, 0);
      expect(tester.takeException(), isNull);
    });
  }

  desktopTest(
    'font shortcuts retain the canonical anchor and save preferences',
    (tester) async {
      await open(tester);
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      final before = await savedPosition();
      await shortcut(tester, LogicalKeyboardKey.equal, meta: true);
      expect((await ReaderSettingsRepository().load()).settings.fontSize, 19);
      expectAnchor(await savedPosition(), before);
      await shortcut(tester, LogicalKeyboardKey.minus, meta: true);
      expectAnchor(await savedPosition(), before);
      await shortcut(tester, LogicalKeyboardKey.equal, meta: true, shift: true);
      await shortcut(tester, LogicalKeyboardKey.digit0, meta: true);
      await ReaderSettingsRepository.flush();
      expect((await ReaderSettingsRepository().load()).settings.fontSize, 18);
      expectAnchor(await savedPosition(), before);
    },
  );

  desktopTest(
    'font commands queued during a page turn retain every increment',
    (tester) async {
      await open(tester, animation: 'cover');
      final target =
          address(tester).layout.pages[2].position('c0') as ReadingPosition;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 60));
      expect(pager(tester).isBusy, true);
      DesktopCommands.dispatch('fontIncrease');
      DesktopCommands.dispatch('fontIncrease');
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      expect((await ReaderSettingsRepository().load()).settings.fontSize, 20);
      expectAnchor(await savedPosition(), target);
    },
  );

  desktopTest('desktop measured text fits every visible page after reflow', (
    tester,
  ) async {
    await open(tester);
    for (final width in [720.0, 950.0, 1060.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpAndSettle();
      for (var turn = 0; turn < 3; turn++) {
        await shortcut(tester, LogicalKeyboardKey.pageDown);
        final columns = find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox &&
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'reader-column-',
              ),
        );
        for (final element in columns.hitTestable().evaluate()) {
          final page = find.byWidget(element.widget);
          final body = find
              .descendant(
                of: page,
                matching: find.byType(SingleChildScrollView),
              )
              .first;
          final state = tester.state<ScrollableState>(
            find.descendant(of: body, matching: find.byType(Scrollable)).first,
          );
          expect(
            state.position.maxScrollExtent,
            lessThanOrEqualTo(.5),
            reason: '${element.widget.key} at $width must not clip text',
          );
        }
      }
    }
  });

  desktopTest(
    'directory IME input has priority over reading and font shortcuts',
    (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('目录（⌘⇧D）'));
      await tester.pumpAndSettle();
      final page = pager(tester).currentPageId;
      final field = find.byKey(const ValueKey('desktop-directory-search'));
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'zhang',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      await shortcut(tester, LogicalKeyboardKey.space);
      await shortcut(tester, LogicalKeyboardKey.home);
      await shortcut(tester, LogicalKeyboardKey.equal, meta: true);
      await shortcut(tester, LogicalKeyboardKey.f11);
      expect(pager(tester).currentPageId, page);
      expect(find.byType(DesktopReaderDirectory), findsOneWidget);
      expect((await ReaderSettingsRepository().load()).settings.fontSize, 18);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('selected text wins over Space, Home/End and font adjustment', (
    tester,
  ) async {
    await open(tester);
    final text = find.byType(DesktopSelectableParagraph).hitTestable().first;
    final rect = tester.getRect(text);
    final gesture = await tester.startGesture(
      Offset(rect.left + 30, rect.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + 100, rect.top + 12));
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + 200, rect.top + 12));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(desktopSelectionValue(tester, text).selection.isCollapsed, false);
    final before = pager(tester).currentPageId;
    await shortcut(tester, LogicalKeyboardKey.space);
    await shortcut(tester, LogicalKeyboardKey.home);
    await shortcut(tester, LogicalKeyboardKey.end);
    await shortcut(tester, LogicalKeyboardKey.equal, meta: true);
    expect(pager(tester).currentPageId, before);
    expect((await ReaderSettingsRepository().load()).settings.fontSize, 18);
  });

  desktopTest(
    'settings dialog is centered, traps keys, and leaves viewport unchanged',
    (tester) async {
      await open(tester);
      final viewport = tester.getRect(find.byType(ReaderPageView));
      final first = pager(tester).currentPageId;
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      final dialogRect = tester.getRect(find.byType(ReaderSettingsSheet));
      expect(dialogRect.width, 640);
      expect(dialogRect.center.dx, 700);
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      await shortcut(tester, LogicalKeyboardKey.space);
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      expect(pager(tester).currentPageId, first);
      await shortcut(tester, LogicalKeyboardKey.escape);
      expect(find.byType(ReaderSettingsSheet), findsNothing);
      await shortcut(tester, LogicalKeyboardKey.space);
      expect(pager(tester).currentPageId, isNot(first));
    },
  );

  desktopTest('bookmark and notes remain reachable from the directory', (
    tester,
  ) async {
    await open(tester);
    DesktopCommands.dispatch('bookmark');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录（⌘⇧D）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书签与笔记'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-reader-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookmarks')), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    await shortcut(tester, LogicalKeyboardKey.escape);
    expect(find.byType(DesktopReaderDirectory), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  desktopTest('repeated scroll keys accumulate instead of dropping input', (
    tester,
  ) async {
    await open(tester, pageMode: false);
    final controller = scroll(tester);
    final start = controller.offset;
    final screen = controller.position.viewportDimension * .85;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(start + screen * 3, 1));
    final after = controller.offset;
    await shortcut(tester, LogicalKeyboardKey.arrowUp);
    expect(controller.offset, closeTo(after - 18 * 1.8, 1));
    expect(tester.takeException(), isNull);
  });

  desktopTest('opposite scroll input reverses immediately during animation', (
    tester,
  ) async {
    await open(tester, pageMode: false);
    final controller = scroll(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final turningPoint = controller.offset;
    expect(turningPoint, greaterThan(0));
    await shortcut(tester, LogicalKeyboardKey.arrowUp);
    expect(controller.offset, closeTo(turningPoint - 18 * 1.8, 1));
  });

  desktopTest(
    'window resize safely interrupts keyboard scrolling at its anchor',
    (tester) async {
      await open(tester, pageMode: false);
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final before = await savedPosition();
      tester.view.physicalSize = const Size(720, 540);
      await tester.pumpAndSettle();
      expectAnchor(await savedPosition(), before);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('reduced motion scroll keys finish without animated frames', (
    tester,
  ) async {
    await open(tester, pageMode: false, reduceMotion: true);
    final controller = scroll(tester);
    final start = controller.offset;
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(
      controller.offset,
      closeTo(start + controller.position.viewportDimension * .85, 1),
    );
    expect(controller.position.isScrollingNotifier.value, false);
    expect(
      tester.widget<Scrollbar>(find.byType(Scrollbar).first).thumbVisibility,
      true,
    );
  });

  desktopTest(
    'mouse wheel pauses auto-scroll without replacing native scrolling',
    (tester) async {
      await open(tester, pageMode: false);
      await tester.tapAt(
        tester.getCenter(find.byType(CustomScrollView)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动阅读'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      final controller = scroll(tester);
      final before = controller.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(CustomScrollView)),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      final afterWheel = controller.offset;
      expect(afterWheel, greaterThan(before));
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offset, closeTo(afterWheel, .5));
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'narrow large-text desktop panels and shortcut help remain usable',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      await open(tester, textScale: 2);
      await shortcut(tester, LogicalKeyboardKey.f1);
      expect(find.text('阅读快捷键'), findsOneWidget);
      await shortcut(tester, LogicalKeyboardKey.escape);
      await tester.tap(find.byTooltip('目录（⌘⇧D）'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-directory-search')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('跳转章节（⌘J）').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ReaderChapterJumpDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'repeating F11 toggles immersion only once with global shortcuts',
    (tester) async {
      await open(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f11);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-reader-toolbar')).hitTestable(),
        findsNothing,
      );
      await shortcut(tester, LogicalKeyboardKey.escape);
      expect(find.byTooltip('阅读全屏'), findsOneWidget);
    },
  );

  desktopTest(
    'directory virtualizes thousands of chapters and handles IME safely',
    (tester) async {
      final active = ValueNotifier<int>(3500);
      final opened = <int>[];
      final data = List.generate(
        5000,
        (i) => Chapter(itemId: '$i', title: '第${i + 1}章 Chapter $i'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 304,
              child: DesktopReaderDirectory(
                chapters: data,
                activeIndex: active,
                theme: ReaderTheme.presets[1],
                onOpenChapter: opened.add,
                onClose: () {},
                onJump: () {},
                onAnnotations: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(35));
      expect(
        find.byKey(const ValueKey('desktop-directory-3500')).hitTestable(),
        findsOneWidget,
      );
      final field = find.byKey(const ValueKey('desktop-directory-search'));
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'zhang',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('desktop-directory-3500')),
        findsOneWidget,
      );
      await tester.enterText(field, '20');
      // Enter before debounce expires must use the newly committed query.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(opened, [19]);
      expect(find.byType(ListTile), findsOneWidget);
      await tester.enterText(field, 'CHAPTER 4999');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-directory-4999')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('定位当前章节'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-directory-3500')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('倒序'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-directory-3500')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      active.dispose();
    },
  );

  desktopTest(
    'search sidebar retains query, result selection and next/previous',
    (tester) async {
      await open(
        tester,
        data: [
          Chapter(
            itemId: 'c0',
            title: '本地搜索',
            content: '${'甲' * 50}目标${'乙' * 50}目标${'丙' * 80}',
          ),
        ],
      );
      await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(ReaderSearchSheet), findsOneWidget);
      final query = find.byKey(const ValueKey('reader-search-query'));
      await tester.enterText(query, '目标');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsNWidgets(2));
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect((await savedPosition()).characterOffset, 50);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('reader-search-hit-0')))
            .selected,
        true,
      );
      await shortcut(tester, LogicalKeyboardKey.keyG, meta: true);
      expect((await savedPosition()).characterOffset, 102);
      await shortcut(tester, LogicalKeyboardKey.f3);
      expect((await savedPosition()).characterOffset, 50);
      await shortcut(tester, LogicalKeyboardKey.keyG, meta: true, shift: true);
      expect((await savedPosition()).characterOffset, 102);
      await shortcut(tester, LogicalKeyboardKey.escape);
      expect(find.byType(ReaderSearchSheet), findsNothing);
      await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
      expect(tester.widget<TextField>(query).controller!.text, '目标');
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('reader-search-hit-1')))
            .selected,
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest(
    'reopening search during a page animation focuses the committed panel',
    (tester) async {
      await open(tester, animation: 'cover');
      await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump(const Duration(milliseconds: 60));
      expect(pager(tester).isBusy, true);
      DesktopCommands.dispatch('find');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('reader-search-query')),
      );
      expect(field.focusNode!.hasFocus, true);
      expect(pager(tester).isBusy, false);
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('search IME and unrelated input have priority over find-next', (
    tester,
  ) async {
    await open(tester);
    await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
    final query = find.byKey(const ValueKey('reader-search-query'));
    await tester.enterText(query, '正文');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final before = pager(tester).currentPageId;
    await tester.showKeyboard(query);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhengwen',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await shortcut(tester, LogicalKeyboardKey.keyG, meta: true);
    await shortcut(tester, LogicalKeyboardKey.f3);
    await shortcut(tester, LogicalKeyboardKey.pageDown);
    expect(pager(tester).currentPageId, before);
    await tester.enterText(query, '正文');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录（⌘⇧D）'));
    await tester.pumpAndSettle();
    await tester.showKeyboard(
      find.byKey(const ValueKey('desktop-directory-search')),
    );
    final docked = pager(tester).currentPageId;
    await shortcut(tester, LogicalKeyboardKey.keyG, meta: true);
    expect(pager(tester).currentPageId, docked);
    expect(tester.takeException(), isNull);
  });

  desktopTest('search docking and overlay preserve results and exact anchor', (
    tester,
  ) async {
    await open(tester);
    await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
    await tester.enterText(
      find.byKey(const ValueKey('reader-search-query')),
      '正文',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-search-hit-2')));
    await tester.pumpAndSettle();
    final before = await savedPosition();
    tester.view.physicalSize = const Size(950, 700);
    await tester.pumpAndSettle();
    expectAnchor(await savedPosition(), before);
    expect(
      find.byKey(const ValueKey('desktop-directory-scrim')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reader-search-hit-3')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderSearchSheet), findsNothing);
    await shortcut(tester, LogicalKeyboardKey.keyF, meta: true);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('reader-search-hit-3')))
          .selected,
      true,
    );
    expect(tester.takeException(), isNull);
  });

  for (final pageMode in [true, false]) {
    desktopTest(
      '${pageMode ? 'paged' : 'scroll'} sidebar resize previews once and remembers width',
      (tester) async {
        await open(tester, pageMode: pageMode);
        await shortcut(tester, LogicalKeyboardKey.pageDown);
        await tester.tap(find.byTooltip('目录（⌘⇧D）'));
        await tester.pumpAndSettle();
        final before = await savedPosition();
        final viewport = tester.getRect(
          find.byKey(const ValueKey('desktop-reader-viewport')),
        );
        final resize = find.byKey(const ValueKey('desktop-sidebar-resize'));
        final start = tester.getCenter(resize);
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(start + const Offset(100, 0));
        await tester.pump();
        expect(
          tester.getRect(find.byKey(const ValueKey('desktop-reader-viewport'))),
          viewport,
          reason:
              'Dragging previews the sidebar without repaginating each event',
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expectAnchor(await savedPosition(), before);
        expect((await DesktopReaderPreferences.load()).sidebarWidth, 404);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await open(tester, pageMode: pageMode);
        expect(find.byType(DesktopReaderDirectory), findsOneWidget);
        expect(tester.getSize(find.byType(DesktopReaderDirectory)).width, 404);
        final handle = tester.getCenter(resize);
        await tester.tapAt(handle, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 70));
        await tester.tapAt(handle, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect((await DesktopReaderPreferences.load()).sidebarWidth, 304);
        expect(tester.takeException(), isNull);
      },
    );
  }

  desktopTest(
    'back/forward keep exact anchors and new jumps clear the branch',
    (tester) async {
      await open(tester);
      await shortcut(tester, LogicalKeyboardKey.pageDown);
      final origin = await savedPosition();
      Future<void> jump(int chapter) async {
        await shortcut(tester, LogicalKeyboardKey.keyJ, meta: true);
        await tester.enterText(
          find.byKey(const ValueKey('reader-chapter-number')),
          '$chapter',
        );
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await tester.pumpAndSettle();
      }

      await jump(3);
      final third = await savedPosition();
      await jump(5);
      final fifth = await savedPosition();
      await shortcut(tester, LogicalKeyboardKey.bracketLeft, meta: true);
      expectAnchor(await savedPosition(), third);
      await shortcut(tester, LogicalKeyboardKey.bracketLeft, meta: true);
      expectAnchor(await savedPosition(), origin);
      await shortcut(tester, LogicalKeyboardKey.bracketRight, meta: true);
      expectAnchor(await savedPosition(), third);
      final forward = await tester.startGesture(
        tester.getCenter(find.byType(ReaderPageView)),
        kind: PointerDeviceKind.mouse,
        buttons: kForwardMouseButton,
      );
      await forward.up();
      await tester.pumpAndSettle();
      expectAnchor(await savedPosition(), fifth);
      await shortcut(tester, LogicalKeyboardKey.bracketLeft, meta: true);
      await jump(2);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('desktop-history-forward')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  desktopTest('cross-paragraph native selection copies canonical text only', (
    tester,
  ) async {
    final first = '第一段，前后位置必须准确。👩🏽‍💻复制只保留原文，不包含缩进或章节标题。' * 3;
    final second = '第二段，跨段复制保留段落分隔，不允许直接创建跨段批注。' * 3;
    await open(
      tester,
      pageMode: false,
      data: [
        Chapter(itemId: 'c0', title: '不应复制的章名', content: '$first\n\n$second'),
      ],
    );
    final paragraphs = find.byType(DesktopSelectableParagraph).hitTestable();
    final a = tester.getRect(paragraphs.first);
    final b = tester.getRect(paragraphs.last);
    final gesture = await tester.startGesture(
      Offset(a.left + 80, a.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveTo(Offset(a.left + 160, a.top + 12));
    await tester.pump();
    await gesture.moveTo(Offset(b.left + 150, b.top + 12));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final valueA = desktopSelectionValue(tester, paragraphs.first);
    final valueB = desktopSelectionValue(tester, paragraphs.last);
    expect(valueA.selection.isCollapsed || valueB.selection.isCollapsed, false);
    final expected =
        '${valueA.selection.textInside(valueA.text).trim()}\n\n'
        '${valueB.selection.textInside(valueB.text).trim()}';
    final controller = tester
        .widget<DesktopReaderSelection>(find.byType(DesktopReaderSelection))
        .controller;
    expect(controller.segments.length, 2);
    expect(controller.selectedText, expected);
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': copied};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await shortcut(tester, LogicalKeyboardKey.keyC, meta: true);
    expect((await Clipboard.getData(Clipboard.kTextPlain))!.text, expected);
    final secondary = await tester.startGesture(
      Offset(a.left + 120, a.top + 12),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.up();
    await tester.pumpAndSettle();
    expect(find.text('同章跨段选区 · 原文坐标保持'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('desktop-highlight-range')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('desktop-note-range')), findsOneWidget);
    expect(find.text('划线'), findsNothing);
    expect(find.text('笔记'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('desktop-copy-paragraphs')));
    await tester.pumpAndSettle();
    expect((await Clipboard.getData(Clipboard.kTextPlain))!.text, expected);
    expect(controller.hasSelection, false);
    final again = await tester.startGesture(
      Offset(a.left + 80, a.top + 12),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await again.moveTo(Offset(a.left + 160, a.top + 12));
    await tester.pump();
    await again.moveTo(Offset(b.left + 150, b.top + 12));
    await tester.pump();
    await again.up();
    await tester.pumpAndSettle();
    final secondaryAgain = await tester.startGesture(
      Offset(a.left + 120, a.top + 12),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondaryAgain.up();
    await tester.pumpAndSettle();
    final parts = controller.segments;
    await tester.tap(find.byKey(const ValueKey('desktop-highlight-range')));
    await tester.pumpAndSettle();
    final note = (await BookmarkService().getNotes(
      'local_desktop_workflow',
    )).single;
    expect(note.text, expected);
    expect(note.paragraphIndex, parts.first.paragraphIndex);
    expect(note.endParagraphIndex, parts.last.paragraphIndex);
    expect(note.startOffset, parts.first.start);
    expect(note.endOffset, parts.last.end);
    expect((await Clipboard.getData(Clipboard.kTextPlain))!.text, expected);
    expect(controller.hasSelection, false);
    expect(tester.takeException(), isNull);
  });
}
