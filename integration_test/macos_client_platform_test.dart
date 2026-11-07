import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/screens/notes_workspace_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/cover_cache_service.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/external_book_import_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import '../test/epub_image_fixture.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_selection.dart';
import 'package:fanqie_flutter/widgets/desktop_reader_directory.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:fanqie_flutter/widgets/tts_player_panel.dart';
import '../test/helpers/tts_audio.dart';

const manualSave = bool.fromEnvironment('MACOS_SAVE_PANEL_TEST');
const nativeFullScreen = bool.fromEnvironment('MACOS_NATIVE_FULLSCREEN_TEST');
const readerScreenshots = bool.fromEnvironment('MACOS_READER_SCREENSHOTS');

Future<void> saveReaderScreenshot(
  GlobalKey key,
  Directory folder,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = boundary.toImageSync(pixelRatio: 1);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${folder.path}/$name.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('MACOS_READER_SCREENSHOT ${file.path}');
  } finally {
    image.dispose();
  }
}

Future<void> fullScreen(WidgetTester tester, bool enabled) async {
  await ReaderPlatform.invoke('setTestFullScreen', {'enabled': enabled});
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  Map? lastState;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final state = await ReaderPlatform.invoke<Map>('getTestWindowState');
    lastState = state;
    if (state!['fullScreen'] == enabled &&
        state['fullScreenTransitioning'] == false) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Native full-screen transition did not complete: $lastState');
}

void expectDesktopPagesFit(WidgetTester tester) {
  final columns = find.byWidgetPredicate(
    (widget) =>
        widget is ColoredBox &&
        widget.key is ValueKey<String> &&
        (widget.key as ValueKey<String>).value.startsWith('reader-column-'),
  );
  for (final element in columns.hitTestable().evaluate()) {
    final page = find.byWidget(element.widget);
    final scroll = find
        .descendant(of: page, matching: find.byType(SingleChildScrollView))
        .first;
    final state = tester.state<ScrollableState>(
      find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
    );
    expect(
      state.position.maxScrollExtent,
      lessThanOrEqualTo(.5),
      reason: 'Every line must fit without clipping: ${element.widget.key}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookshelfService().reload();
    await ReaderPlatform.initialize();
    AppLifecycleService.initialize();
    final support = await AppStorage.documents();
    expect(support.path, (await getApplicationSupportDirectory()).path);
    root = await support.createTemp('isolated-platform-test-');
    AppStorage.documentsOverride = () async => root;
  });

  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
    await ReaderPlatform.invoke('showMainWindow');
    AppStorage.documentsOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
    'actual native capabilities, streaming import and same-platform restore',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('macOS 原生验证'))),
      );
      expect(ReaderPlatform.isMacOS, true);
      expect(ReaderPlatform.capabilities.tts, true);
      expect(ReaderPlatform.capabilities.mediaPlayback, true);
      expect(ReaderPlatform.capabilities.secureStorage, true);
      expect(ReaderPlatform.capabilities.textDecoder, true);
      expect(ReaderPlatform.capabilities.fileExport, true);
      expect(
        await ReaderSystemService.getNetworkType(),
        isIn(['wifi', 'ethernet', 'offline', 'mobile', 'unknown']),
      );
      final importer = LocalBookService.forTesting(documents: () async => root);
      for (final fixture in encodingFixtures.entries) {
        final source = await File(
          '${root.path}/${fixture.key}.txt',
        ).writeAsBytes(fixture.value);
        final result = await importer.importLocalFile(
          source,
          options: LocalImportOptions(encoding: fixture.key),
        );
        expect(result.chapters, isNotEmpty);
        final content = (await Future.wait(
          result.chapters.map(
            (c) => File(
              '${root.path}/offline_books/${result.book.bookId}/${c.itemId}.txt',
            ).readAsString(),
          ),
        )).join();
        expect(content, contains('中文'));
        if (fixture.key == 'GB18030') expect(content, contains('😀'));
        expect(await source.readAsBytes(), fixture.value);
        expect(
          await Directory(
            '${root.path}/offline_books/${result.book.bookId}',
          ).exists(),
          true,
        );
        final duplicate = await importer.importLocalFile(
          source,
          options: LocalImportOptions(encoding: fixture.key),
        );
        expect(duplicate.alreadyExists, true);
        expect(duplicate.book.bookId, result.book.bookId);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reader_settings_v2',
        jsonEncode(const ReaderSettings(fontSize: 22).toJson()),
      );
      final backup = ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      );
      final archive = await backup.create(includeBooks: true);
      await prefs.remove('reader_settings_v2');
      await backup.restore(archive, mode: ReaderRestoreMode.replace);
      expect(prefs.getString('reader_settings_v2'), contains('22'));
      expect(ReaderBackupService.hasActiveTransaction, false);
      await backup.recover();
      expect(
        await File('${root.path}/reader_restore_journal.json').exists(),
        false,
      );
    },
  );

  testWidgets(
    'real desktop double-column paging, text clicks and resize remain usable',
    (tester) async {
      const settings = ReaderSettings(
        pageMode: true,
        pageAnimation: 'simulation',
        pureMode: true,
        commentBubbles: false,
        showHeader: false,
        showStatus: false,
      );
      await ReaderSettingsRepository().save(settings);
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1280.0,
        'height': 900.0,
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          home: ReaderScreen(
            book: Book(
              bookId: 'local_native_spread',
              bookName: '双栏与点击验收',
              author: '隔离测试',
            ),
            chapters: [
              Chapter(
                itemId: 'c',
                title: '正文',
                content: List.generate(
                  150,
                  (i) => '正文第$i段。双栏连续阅读与鼠标点击必须可以翻页，缩放后仍应保留原文锚点。' * 3,
                ).join('\n\n'),
              ),
            ],
            bookDocuments: () async => root,
            resumeSavedPosition: false,
            initialSettings: const ReaderSettingsRecord(settings),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final right = find
          .byKey(const ValueKey('reader-column-c-1'))
          .hitTestable();
      expect(right, findsOneWidget);
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
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('桌面阅读栏数'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).pageIndex, 4);
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('local_native_spread');
      for (final size in [const Size(720, 540), const Size(1280, 900)]) {
        await ReaderPlatform.invoke('setTestWindowSize', {
          'width': size.width,
          'height': size.height,
        });
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final after = await ReaderPositionService().load('local_native_spread');
        expect(after!.chapterId, before!.chapterId);
        expect(after.paragraphIndex, before.paragraphIndex);
        expect(after.characterOffset, before.characterOffset);
        expect(pager.isBusy, false);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'real desktop directory, quick jump and centered settings preserve reading',
    (tester) async {
      const settings = ReaderSettings(
        pageMode: true,
        pageAnimation: 'cover',
        commentBubbles: false,
      );
      await ReaderSettingsRepository().save(settings);
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1440.0,
        'height': 900.0,
      });
      final paint = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: paint,
          child: MaterialApp(
            navigatorObservers: [readerRouteObserver],
            builder: (_, child) => DesktopShortcuts(child: child!),
            home: ReaderScreen(
              book: Book(
                bookId: 'local_native_desktop_workflow',
                bookName: '雨后书房 · 桌面阅读',
                author: '隔离测试',
              ),
              chapters: List.generate(
                30,
                (chapter) => Chapter(
                  itemId: 'chapter-$chapter',
                  title:
                      '第${chapter + 1}章 ${chapter.isEven ? '雨后的书房' : '窗边的灯光'}',
                  volumeTitle: chapter < 15 ? '第一卷 · 晨光' : '第二卷 · 夜读',
                  content: List.generate(
                    100,
                    (paragraph) =>
                        '第$paragraph段。雨声渐渐远去，书房里只剩翻动纸页的轻响。'
                            '窗边的灯光照着一行行文字，让人愿意慢慢读下去。'
                            '打开目录、调整排版之后，故事仍从原来的地方继续。' *
                        3,
                  ).join('\n\n'),
                ),
              ),
              bookDocuments: () async => root,
              resumeSavedPosition: false,
              initialSettings: const ReaderSettingsRecord(settings),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load(
        'local_native_desktop_workflow',
      );
      await tester.tap(find.byTooltip('目录（⌘⇧D）'));
      await tester.pumpAndSettle();
      final directory = tester.state(find.byType(DesktopReaderDirectory));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('desktop-reader-viewport')))
            .left,
        304,
      );
      await ReaderSystemService.flushParticipants();
      final docked = await ReaderPositionService().load(
        'local_native_desktop_workflow',
      );
      expect(docked!.paragraphIndex, before!.paragraphIndex);
      expect(docked.characterOffset, before.characterOffset);
      expectDesktopPagesFit(tester);
      final visual = readerScreenshots
          ? await root.parent.createTemp('isolated-desktop-workflow-visual-')
          : null;
      if (visual != null) {
        await saveReaderScreenshot(paint, visual, 'reading-directory');
      }
      final viewport = tester.getRect(find.byType(ReaderPageView));
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      final dialog = tester.getRect(find.byType(ReaderSettingsSheet));
      expect(dialog.width, 640);
      expect(dialog.center.dx, closeTo(720, 1));
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      if (visual != null) {
        await saveReaderScreenshot(paint, visual, 'reading-settings-dialog');
      }
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      for (var turn = 0; turn < 5; turn++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expectDesktopPagesFit(tester);
      }
      await tester.enterText(
        find.byKey(const ValueKey('desktop-directory-search')),
        '第20章',
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 950.0,
        'height': 700.0,
      });
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(DesktopReaderDirectory)),
        same(directory),
      );
      expect(
        find.byKey(const ValueKey('desktop-directory-scrim')),
        findsOneWidget,
      );
      if (visual != null) {
        await saveReaderScreenshot(paint, visual, 'reading-directory-compact');
      }
      await tester.tap(find.byKey(const ValueKey('desktop-directory-19')));
      await tester.pumpAndSettle();
      expectDesktopPagesFit(tester);
      final pager = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      expect((pager.currentPageId as dynamic).chapterIndex, 19);
      expect(find.byType(DesktopReaderDirectory), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expectDesktopPagesFit(tester);
      expect((pager.currentPageId as dynamic).pageIndex, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-chapter-number')),
        '3',
      );
      await tester.tap(
        find.byKey(const ValueKey('reader-confirm-chapter-jump')),
      );
      await tester.pumpAndSettle();
      expect((pager.currentPageId as dynamic).chapterIndex, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'real wheel bursts and momentum turn only one spread in all page modes',
    (tester) async {
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1280.0,
        'height': 900.0,
      });
      for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
        final settings = ReaderSettings(
          pageMode: true,
          pageAnimation: mode,
          desktopColumns: 'double',
          pureMode: true,
          commentBubbles: false,
        );
        await ReaderSettingsRepository().save(settings);
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey('native-wheel-$mode'),
            navigatorObservers: [readerRouteObserver],
            home: ReaderScreen(
              book: Book(
                bookId: 'local_native_wheel_$mode',
                bookName: '滚轮单次翻页验收',
                author: '隔离测试',
              ),
              chapters: [
                Chapter(
                  itemId: 'c',
                  title: '正文',
                  content: List.generate(
                    150,
                    (i) => '第$i段。滚轮一次操作产生的连续事件与惯性尾声不能排队补翻，不跳过正文。' * 3,
                  ).join('\n\n'),
                ),
              ],
              bookDocuments: () async => root,
              resumeSavedPosition: false,
              initialSettings: ReaderSettingsRecord(settings),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final pager = tester.state<ReaderPageViewState>(
          find.byType(ReaderPageView),
        );
        for (var event = 0; event < 12; event++) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              // Real native events carry source timestamps. pump() may take
              // longer than 70ms on a busy real renderer, unlike widget tests.
              timeStamp: Duration(milliseconds: 1000 + event * 70),
              kind: PointerDeviceKind.mouse,
              position: tester.getCenter(find.byType(ReaderPageView)),
              scrollDelta: Offset(0, event == 0 ? 120 : 12 - event.toDouble()),
            ),
          );
          await tester.pump(const Duration(milliseconds: 70));
        }
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 2, reason: mode);
        expect(pager.isBusy, false, reason: mode);
        await tester.pump(const Duration(milliseconds: 220));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            timeStamp: const Duration(milliseconds: 2100),
            kind: PointerDeviceKind.mouse,
            position: tester.getCenter(find.byType(ReaderPageView)),
            scrollDelta: const Offset(0, -120),
          ),
        );
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 0, reason: mode);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect((pager.currentPageId as dynamic).pageIndex, 2, reason: mode);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'reader-only immersion fills the viewport without changing NSWindow',
    (tester) async {
      const settings = ReaderSettings(
        pageMode: true,
        pageAnimation: 'cover',
        commentBubbles: false,
      );
      await ReaderSettingsRepository().save(settings);
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1920.0,
        'height': 1080.0,
      });
      final paint = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: paint,
          child: MaterialApp(
            navigatorObservers: [readerRouteObserver],
            home: ReaderScreen(
              book: Book(
                bookId: 'local_native_immersive',
                bookName: '阅读沉浸与双页布局',
                author: '隔离测试',
              ),
              chapters: [
                Chapter(
                  itemId: 'c',
                  title: '正文',
                  content: List.generate(
                    200,
                    (i) =>
                        '第$i段。晨光越过窗沿，落在摊开的书页上。文字沿着两页连续铺开，'
                            '阅读应充分利用窗口，不在左右留下大片空白。隐藏工具栏之后，'
                            '仍可以翻页、选词和打开设置，回来时原文位置保持不变。' *
                        3,
                  ).join('\n\n'),
                ),
              ],
              bookDocuments: () async => root,
              resumeSavedPosition: false,
              initialSettings: const ReaderSettingsRecord(settings),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final windowBefore = await ReaderPlatform.invoke<Map>(
        'getTestWindowState',
      );
      final viewport = tester.getRect(
        find.byKey(const ValueKey('desktop-reader-viewport')),
      );
      expect(viewport.width, closeTo(windowBefore!['width'] as num, 1));
      expect(viewport.height, closeTo(windowBefore['height'] as num, 1));
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('reader-column-c-0')).hitTestable(),
            )
            .left,
        viewport.left,
      );
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('reader-column-c-1')).hitTestable(),
            )
            .right,
        viewport.right,
      );
      for (var i = 0; i < 2; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
      }
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load(
        'local_native_immersive',
      );
      final visual = readerScreenshots
          ? await root.parent.createTemp('isolated-reader-visual-')
          : null;
      if (visual != null) {
        // Opt-in snapshots contain only the synthetic book, and are retained
        // in this owned folder for visual inspection, never user content.
        await saveReaderScreenshot(paint, visual, 'reading-windowed');
      }
      await tester.tap(find.byTooltip('阅读全屏'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(ReaderPageView)), viewport);
      expect(find.byKey(const ValueKey('reader-chapter-header')), findsNothing);
      expect(find.byKey(const ValueKey('reader-status-bar')), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-reader-toolbar')).hitTestable(),
        findsNothing,
      );
      final immersedWindow = await ReaderPlatform.invoke<Map>(
        'getTestWindowState',
      );
      for (final key in ['width', 'height', 'styleMask', 'fullScreen']) {
        expect(immersedWindow![key], windowBefore[key]);
      }
      await ReaderSystemService.flushParticipants();
      final immersed = await ReaderPositionService().load(
        'local_native_immersive',
      );
      expect(immersed!.paragraphIndex, before!.paragraphIndex);
      expect(immersed.characterOffset, before.characterOffset);
      if (visual != null) {
        await saveReaderScreenshot(paint, visual, 'reading-immersed');
      }
      await tester.tapAt(viewport.center, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出阅读全屏'), findsOneWidget);
      await tester.tap(find.text('排版设置'));
      await tester.pumpAndSettle();
      expect(find.text('桌面阅读栏数'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读全屏').hitTestable(), findsOneWidget);
      await ReaderSystemService.flushParticipants();
      final returned = await ReaderPositionService().load(
        'local_native_immersive',
      );
      expect(returned!.paragraphIndex, before.paragraphIndex);
      expect(returned.characterOffset, before.characterOffset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'same-platform EPUB restore resolves cover and illustrations against the new root',
    (tester) async {
      final source = await imageEpub(
        root,
        ['<p>恢复前正文。</p><img src="../Images/图%201.png"/><p>恢复后正文。</p>'],
        resources: {
          'OPS/book.opf': utf8.encode(
            '''<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>恢复插图</dc:title><dc:creator>测试</dc:creator></metadata>
<manifest><item id="c0" href="Text/0.xhtml" media-type="application/xhtml+xml"/>
<item id="cover" href="Images/图%201.png" media-type="image/png" properties="cover-image"/></manifest>
<spine><itemref idref="c0"/></spine></package>''',
          ),
        },
      );
      final imported = await LocalBookService.forTesting(
        documents: () async => root,
      ).importLocalEpub(source);
      expect(imported.book.thumbUrl, startsWith(root.path));
      final backup = await ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      ).create(includeBooks: true);
      final restored = await (await getApplicationSupportDirectory())
          .createTemp('isolated-restored-epub-');
      try {
        await ReaderBackupService(
          documents: () async => restored,
          notifyServices: false,
        ).restore(backup, mode: ReaderRestoreMode.replace);
        await root.delete(
          recursive: true,
        ); // Old absolute paths can no longer work.
        AppStorage.documentsOverride = () async => restored;
        final folder = '${restored.path}/offline_books/${imported.book.bookId}';
        final chapters =
            (jsonDecode(await File('$folder/directory.json').readAsString())
                    as List)
                .asMap()
                .entries
                .map(
                  (e) => Chapter.fromDirectoryJson(
                    Map<String, dynamic>.from(e.value as Map),
                    e.key,
                  ),
                )
                .toList();
        final asset = chapters.expand((c) => c.illustrations).first.asset!;
        expect(await File('$folder/$asset').readAsBytes(), imagePng());
        expect(
          await CoverCacheService.forTesting(
            documents: () async => restored,
            client: null,
          ).hasLocalCover(imported.book.bookId),
          true,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [readerRouteObserver],
            home: ReaderScreen(
              book: imported.book,
              chapters: chapters,
              bookDocuments: () async => restored,
              resumeSavedPosition: false,
              initialSettings: const ReaderSettingsRecord(
                ReaderSettings(
                  pageMode: false,
                  pureMode: true,
                  commentBubbles: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        AppStorage.documentsOverride = () async => root;
        await restored.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'real save panel cancellation has no success or source deletion',
    (tester) async {
      final source = await File(
        '${root.path}/cancel-source.txt',
      ).writeAsString('保留正文');
      final result = FileExportService().save(
        source,
        name: 'fanqie-platform-test.txt',
        mimeType: 'text/plain',
        requestId: 'cancel-panel',
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await ReaderPlatform.invoke('cancelExport', {'id': 'cancel-panel'});
      expect((await result).status, FileExportStatus.cancelled);
      expect(await source.readAsString(), '保留正文');
    },
  );

  testWidgets(
    'real window resize, hidden-window save and power assertion release',
    (tester) async {
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1024.0,
        'height': 768.0,
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          home: ReaderScreen(
            book: Book(
              bookId: 'local_native_window',
              bookName: '原生窗口验收',
              author: '测试',
            ),
            chapters: [
              Chapter(
                itemId: 'c',
                title: '正文',
                content: List.generate(
                  200,
                  (i) =>
                      '正文第${i.toString().padLeft(3, '0')}段。窗口大小变化后仍然应该保留阅读位置，不能返回开头。',
                ).join('\n\n'),
              ),
            ],
            bookDocuments: () async => root,
            initialSettings: const ReaderSettingsRecord(
              ReaderSettings(
                pageMode: false,
                pureMode: true,
                commentBubbles: false,
                keepScreenOn: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
      }
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('local_native_window');
      expect(before!.paragraphIndex, greaterThan(0));
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 720.0,
        'height': 540.0,
      });
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('local_native_window');
      expect(after!.paragraphIndex, before.paragraphIndex);
      await ReaderPlatform.invoke('hideTestWindow');
      await tester.pump(const Duration(milliseconds: 300));
      final hidden = await ReaderPlatform.invoke<Map>('getTestWindowState');
      expect(hidden!['visible'], false);
      expect(hidden['displayAssertion'], false);
      expect(
        (await ReaderPositionService().load(
          'local_native_window',
        ))!.paragraphIndex,
        after.paragraphIndex,
      );
      await ReaderPlatform.invoke('showMainWindow');
      await tester.pumpAndSettle();
      expect(
        (await ReaderPlatform.invoke<Map>('getTestWindowState'))!['visible'],
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'native Finder inbox stages, previews and releases without changing the original',
    (tester) async {
      expect(ReaderPlatform.capabilities.fileImport, true);
      final inbox = ExternalBookImportService();
      await inbox.initialize();
      await inbox.releasePending();
      final original = await File(
        '${root.path}/Finder 小说.TXT',
      ).writeAsString('第一章 导入\n${'Finder 导入的隔离正文必须先预览并保留原文件。' * 20}');
      final originalBytes = await original.readAsBytes();
      await ReaderPlatform.invoke('stageTestExternalFiles', {
        'paths': [original.path, original.path],
      });
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (inbox.pendingCount == 0) {
        if (DateTime.now().isAfter(deadline)) fail('原生导入没有交付文件');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      expect(inbox.pendingCount, 1);
      final request = inbox.takeNext()!;
      expect(request.error, isNull);
      expect(request.filePath, isNot(original.path));
      expect(await File(request.filePath!).readAsBytes(), originalBytes);
      expect(await AppLifecycleService.prepareToQuit(), false);
      final importer = LocalBookService.forTesting(documents: () async => root);
      final preview = await importer.prepare(File(request.filePath!));
      expect(preview.chapters, isNotEmpty);
      expect(preview.sample, contains('Finder 导入'));
      await preview.dispose();
      await inbox.complete(request);
      while (await File(request.filePath!).exists()) {
        if (DateTime.now().isAfter(deadline)) fail('原生暂存未清理');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(await original.readAsBytes(), originalBytes);
      expect(await inbox.canQuit(), true);
    },
  );

  testWidgets(
    'actual search sidebar, remembered width and cross-book note source workflow',
    (tester) async {
      await ReaderPlatform.invoke('setTestWindowSize', {
        'width': 1440.0,
        'height': 900.0,
      });
      final screenshotKey = GlobalKey();
      final screenshots = readerScreenshots
          ? await root.parent.createTemp('isolated-reader-workspace-visual-')
          : null;
      final source = List.generate(
        100,
        (i) => '第$i段。工作台目标原文与窗口重排必须保持精确位置。' * 3,
      ).join('\n\n');
      final book = Book(
        bookId: 'local_native_workspace',
        bookName: '阅读工作空间',
        author: '隔离测试',
      );
      final offline = Directory('${root.path}/offline_books/${book.bookId}');
      await offline.create(recursive: true);
      await File('${offline.path}/directory.json').writeAsString(
        jsonEncode([Chapter(itemId: 'c', title: '第一章', order: 1).toJson()]),
      );
      await File('${offline.path}/c.txt').writeAsString(source);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          builder: (_, child) => DesktopShortcuts(
            child: RepaintBoundary(key: screenshotKey, child: child!),
          ),
          home: ReaderScreen(
            book: book,
            chapters: [Chapter(itemId: 'c', title: '第一章', content: source)],
            resumeSavedPosition: false,
            bookDocuments: () async => root,
            initialSettings: const ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: 'none',
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('正文搜索（⌘F）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('reader-search-query')),
        '目标原文',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-search-hit-1')));
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load(book.bookId);
      expect(before, isNotNull);
      final handle = tester.getCenter(
        find.byKey(const ValueKey('desktop-sidebar-resize')),
      );
      final drag = await tester.startGesture(
        handle,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(handle + const Offset(64, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect((await DesktopReaderPreferences.load()).sidebarWidth, 368);
      await ReaderSystemService.flushParticipants();
      final resized = (await ReaderPositionService().load(book.bookId))!;
      expect(resized.chapterId, before!.chapterId);
      expect(resized.paragraphIndex, before.paragraphIndex);
      expect(resized.characterOffset, before.characterOffset);
      if (screenshots != null) {
        await saveReaderScreenshot(
          screenshotKey,
          screenshots,
          'reading-search-sidebar',
        );
      }
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pumpAndSettle();
      DesktopCommands.dispatch('forward');
      await tester.pumpAndSettle();
      DesktopCommands.dispatch('back');
      await tester.pumpAndSettle();
      final paragraph = source.split('\n\n').first;
      final start = paragraph.indexOf('目标原文');
      await BookmarkService().rememberBook(book);
      await BookmarkService().addNote(
        bookId: book.bookId,
        chapterId: 'c',
        chapterIndex: 0,
        chapterTitle: '第一章',
        paragraphIndex: 0,
        text: '目标原文',
        startOffset: start,
        endOffset: start + 4,
        chapterHash: NoteAnchorResolver.digest(source.split('\n\n')),
        prefix: paragraph.substring(0, start),
        suffix: paragraph.substring(start + 4),
        note: '跨书笔记工作台的隔离验证',
        tags: ['工作空间'],
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          builder: (_, child) =>
              RepaintBoundary(key: screenshotKey, child: child!),
          home: const NotesWorkspaceScreen(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('跨书笔记工作台的隔离验证'), findsOneWidget);
      if (screenshots != null) {
        await saveReaderScreenshot(
          screenshotKey,
          screenshots,
          'notes-workspace',
        );
      }
      await tester.tap(find.text('定位原文'));
      await tester.pumpAndSettle();
      // The source came from embedded test text, not a remote full-book request.
      expect(find.byType(ReaderScreen), findsOneWidget);
      await ReaderSystemService.flushParticipants();
      final located = await ReaderPositionService().load(book.bookId);
      expect(located!.paragraphIndex, 0);
      expect(located.characterOffset, start);
      expect(
        (await BookmarkService().getNotes(book.bookId)).single.startOffset,
        start,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  // A real Aqua/foreground session is required. This is a mandatory manual
  // acceptance gate, not covered by the ordinary CI/window-resize result.
  testWidgets('native full-screen preserves exact reading anchors', (
    tester,
  ) async {
    await ReaderPlatform.invoke('setTestWindowSize', {
      'width': 1024.0,
      'height': 768.0,
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(
            bookId: 'local_native_window',
            bookName: '全屏验收',
            author: '隔离测试',
          ),
          chapters: [
            Chapter(
              itemId: 'c',
              title: '正文',
              content: List.generate(
                200,
                (i) => '正文第$i段。全屏与窗口切换必须保持当前原文字符锚点，而不是返回章节开头。',
              ).join('\n\n'),
            ),
          ],
          bookDocuments: () async => root,
          initialSettings: const ReaderSettingsRecord(
            ReaderSettings(
              pageMode: false,
              pureMode: true,
              commentBubbles: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
    }
    await ReaderSystemService.flushParticipants();
    final after = await ReaderPositionService().load('local_native_window');
    expect(after!.paragraphIndex, greaterThan(0));
    try {
      await fullScreen(tester, true);
      await ReaderSystemService.flushParticipants();
      final enlarged = await ReaderPositionService().load(
        'local_native_window',
      );
      expect(enlarged!.paragraphIndex, after.paragraphIndex);
      expect(enlarged.characterOffset, after.characterOffset);
      final state = await ReaderPlatform.invoke<Map>('getTestWindowState');
      debugPrint(
        'MACOS_NATIVE_DISPLAY backingScale=${state!['backingScaleFactor']}',
      );
    } finally {
      await fullScreen(tester, false);
    }
    await ReaderSystemService.flushParticipants();
    final returned = await ReaderPositionService().load('local_native_window');
    expect(returned!.paragraphIndex, after.paragraphIndex);
    expect(returned.characterOffset, after.characterOffset);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, skip: !nativeFullScreen);

  testWidgets('manual native save panel round-trip', (tester) async {
    final source = await File(
      '${root.path}/source.txt',
    ).writeAsString('macOS 真实保存验证');
    debugPrint(
      'FANQIE_MACOS_SAVE_PANEL_READY: save to a new isolated test path',
    );
    final result = await FileExportService().save(
      source,
      name: 'fanqie-native-export-test.txt',
      mimeType: 'text/plain',
    );
    expect(result.status, FileExportStatus.saved);
    final saved = File(result.path!);
    expect(await saved.readAsString(), 'macOS 真实保存验证');
    // Keep the chosen output for inspection. Only the isolated input directory
    // is automatically cleaned, never an arbitrary external destination.
  }, skip: !manualSave);
  testWidgets(
    'OpenAI-compatible loopback audio uses real native playback without user secrets',
    (tester) async {
      final caps = await ReaderPlatform.invoke<Map>('getReaderCapabilities');
      if (caps?['audioOutput'] != true) {
        // Keep this explicit: a machine without an output cannot pass audio QA.
        debugPrint('MACOS_NATIVE_AUDIO_SKIPPED no output device');
        return;
      }
      final temporary = await (await getTemporaryDirectory()).createTemp(
        'isolated-native-tts-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = <Map>[];
      server.listen((request) async {
        final json = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(request.uri.path, '/v1/audio/speech');
        expect(
          request.headers.value('authorization'),
          'Bearer synthetic-native-test',
        );
        received.add(json);
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(silentTtsWav(milliseconds: 1500));
        await request.response.close();
      });
      var secret = '';
      // Never read or overwrite the production Keychain account in an integration test.
      final tts = TtsService.forTesting(
        invoke: (method, args) async {
          if (method == 'readTtsSecret') return secret;
          if (method == 'writeTtsSecret') {
            secret = args!['value'] as String;
            return true;
          }
          return ReaderPlatform.invoke<Object?>(method, args);
        },
        temporary: () async => temporary,
        bindPlatformEvents: true,
        nativeSpeechAvailable: ReaderPlatform.capabilities.nativeSpeech,
      );
      try {
        await tts.saveSettings(
          engineType: TtsEngineType.openAi,
          openAiBaseUrl: 'http://127.0.0.1:${server.port}/v1',
          openAiApiKey: 'synthetic-native-test',
          openAiModel: 'local-compatible-model',
          openAiVoice: 'local-compatible-voice',
          speechRate: 1.25,
        );
        await tts.startChapter('隔离接口测试', '这是一段隔离接口测试。');
        expect(tts.isPlaying, true, reason: tts.errorMessage ?? tts.notice);
        expect(tts.actualEngine, TtsEngineType.openAi);
        final token = tts.currentPlaybackToken;
        await tts.pause();
        expect(
          (await ReaderPlatform.invoke<Map>('getPlaybackState'))!['playing'],
          false,
        );
        expect(received.single['model'], 'local-compatible-model');
        expect(received.single['voice'], 'local-compatible-voice');
        expect(received.single['input'], '这是一段隔离接口测试。');
        expect(received.single['response_format'], 'mp3');
        expect(received.single['speed'], 1.25);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TtsPlayerPanel(onClose: () {}, service: tts),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-tts-player')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('发音与接口设置'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('desktop-reader-dialog')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('保存配置'));
        await tester.tap(find.text('保存配置'));
        await tester.pumpAndSettle();
        expect(tts.currentPlaybackToken, token);
        await tts.resume();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (tts.isActive && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(tts.isActive, false, reason: tts.errorMessage);
        expect(
          (await ReaderPlatform.invoke<Map>('getPlaybackState'))!['playing'],
          false,
        );
        expect(received.length, 1);
        debugPrint(
          'MACOS_NATIVE_AUDIO_OK compatible protocol / WAV decoder / pause-resume / completion',
        );
      } finally {
        await tts.stop();
        tts.dispose();
        await server.close(force: true);
        await tester.pumpWidget(const SizedBox.shrink());
        await temporary.delete(recursive: true);
      }
    },
  );
}

// Byte fixtures exercise the actual Swift decoder, not a mock bridge.
const encodingFixtures = <String, List<int>>{
  'UTF-8': [
    231,
    172,
    172,
    228,
    184,
    128,
    231,
    171,
    160,
    32,
    233,
    150,
    139,
    231,
    175,
    135,
    10,
    228,
    184,
    173,
    230,
    150,
    135,
    230,
    173,
    163,
    230,
    150,
    135,
    227,
    128,
    130,
    10,
    231,
    172,
    172,
    228,
    186,
    140,
    231,
    171,
    160,
    32,
    231,
    181,
    144,
    229,
    176,
    190,
    10,
    228,
    184,
    173,
    230,
    150,
    135,
    231,
    181,
    144,
    229,
    176,
    190,
    227,
    128,
    130,
  ],
  'UTF-16LE': [
    255,
    254,
    44,
    123,
    0,
    78,
    224,
    122,
    32,
    0,
    139,
    149,
    199,
    123,
    10,
    0,
    45,
    78,
    135,
    101,
    99,
    107,
    135,
    101,
    2,
    48,
    10,
    0,
    44,
    123,
    140,
    78,
    224,
    122,
    32,
    0,
    80,
    125,
    62,
    92,
    10,
    0,
    45,
    78,
    135,
    101,
    80,
    125,
    62,
    92,
    2,
    48,
  ],
  'UTF-16BE': [
    254,
    255,
    123,
    44,
    78,
    0,
    122,
    224,
    0,
    32,
    149,
    139,
    123,
    199,
    0,
    10,
    78,
    45,
    101,
    135,
    107,
    99,
    101,
    135,
    48,
    2,
    0,
    10,
    123,
    44,
    78,
    140,
    122,
    224,
    0,
    32,
    125,
    80,
    92,
    62,
    0,
    10,
    78,
    45,
    101,
    135,
    125,
    80,
    92,
    62,
    48,
    2,
  ],
  'GB18030': [
    181,
    218,
    210,
    187,
    213,
    194,
    32,
    233,
    95,
    198,
    170,
    10,
    214,
    208,
    206,
    196,
    213,
    253,
    206,
    196,
    161,
    163,
    148,
    57,
    252,
    54,
    10,
    181,
    218,
    182,
    254,
    213,
    194,
    32,
    189,
    89,
    206,
    178,
    10,
    214,
    208,
    206,
    196,
    189,
    89,
    206,
    178,
    161,
    163,
  ],
  'GBK': [
    181,
    218,
    210,
    187,
    213,
    194,
    32,
    233,
    95,
    198,
    170,
    10,
    214,
    208,
    206,
    196,
    213,
    253,
    206,
    196,
    161,
    163,
    10,
    181,
    218,
    182,
    254,
    213,
    194,
    32,
    189,
    89,
    206,
    178,
    10,
    214,
    208,
    206,
    196,
    189,
    89,
    206,
    178,
    161,
    163,
  ],
  'Big5': [
    178,
    196,
    164,
    64,
    179,
    185,
    32,
    182,
    125,
    189,
    103,
    10,
    164,
    164,
    164,
    229,
    165,
    191,
    164,
    229,
    161,
    67,
    10,
    178,
    196,
    164,
    71,
    179,
    185,
    32,
    181,
    178,
    167,
    192,
    10,
    164,
    164,
    164,
    229,
    181,
    178,
    167,
    192,
    161,
    67,
  ],
};
