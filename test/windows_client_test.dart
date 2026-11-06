@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:flutter/gestures.dart';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/screens/main_screen.dart';
import 'package:fanqie_flutter/screens/bookshelf_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_download_output.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  final calls = <MethodCall>[];
  Map<String, Object?> exportResponse = {'status': 'cancelled'};
  Map<String, Object?> commitResponse = {
    'status': 'saved',
    'path': 'C:\\Downloads\\fanqie\\book.txt',
  };
  var fullScreenReply = false;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ReaderPlatform.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('windows-client-unit-');
    AppStorage.documentsOverride = () async => directory;
    calls.clear();
    fullScreenReply = false;
    messenger.setMockMethodCallHandler(
      _pathProviderChannel,
      (call) async => directory.path,
    );
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getReaderCapabilities':
          return {
            'tts': false,
            'secureStorage': false,
            'battery': true,
            'keepAwake': true,
            'networkType': true,
            'textDecoder': true,
            'fileExport': true,
          };
        case 'saveExportFile':
          return exportResponse;
        case 'commitDownloadFile':
          return commitResponse;
        case 'toggleFullScreen':
          // The native side returns the resulting state.
          fullScreenReply = !fullScreenReply;
          return fullScreenReply;
        default:
          return null;
      }
    });
    await ReaderPlatform.initialize();
  });

  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
    messenger.setMockMethodCallHandler(_pathProviderChannel, null);
    await directory.delete(recursive: true);
  });

  test('windows capabilities never call Android-only system methods', () async {
    expect(ReaderPlatform.capabilities.tts, false);
    expect(ReaderPlatform.capabilities.volumeKeys, false);
    expect(ReaderPlatform.capabilities.windowBrightness, false);
    expect(ReaderPlatform.capabilities.textDecoder, true);
    expect(ReaderPlatform.capabilities.fileExport, true);
    expect(ReaderPlatform.isWindows, true);
    expect(ReaderPlatform.isDesktop, true);
    final owner = Object();
    await ReaderSystemService.setWindowBrightness(owner, .5);
    await ReaderSystemService.setVolumeKeyScrollEnabled(true);
    expect(await ReaderSystemService.getBatteryLevel(), isNotNull);
    expect(
      calls.map((c) => c.method).where((m) => m != 'getBatteryLevel').toList(),
      ['getReaderCapabilities'],
    );
  });

  test(
    'missing native Windows initialization fails instead of pretending support',
    () async {
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
      await expectLater(ReaderPlatform.initialize(), throwsStateError);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await ReaderPlatform.initialize(); // Older Android bridge stays compatible.
      expect(ReaderPlatform.capabilities.tts, true);
      expect(ReaderPlatform.capabilities.windowBrightness, true);
    },
  );

  test(
    'storage failure does not silently redirect durable Windows data',
    () async {
      AppStorage.documentsOverride = () async =>
          throw const FileSystemException('denied');
      await expectLater(
        AppStorage.documents(),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('windows download output defaults and preference round-trip', () async {
    final resolved = await DesktopDownloadOutput.resolve();
    expect(resolved, endsWith('fanqie'));
    expect(await Directory(resolved).exists(), true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DesktopDownloadOutput.prefKey,
      '${directory.path}\\chosen-dir',
    );
    expect(await DesktopDownloadOutput.resolve(), contains('chosen-dir'));
  });

  test(
    'windows downloads commit to the output directory without a save panel',
    () async {
      final source = await File(
        '${directory.path}/download.txt',
      ).writeAsString('整本书');
      final result = await DesktopDownloadOutput.commit(
        source,
        '书 (1).txt',
        requestId: 'commit-1',
      );
      expect(result.status, FileExportStatus.saved);
      expect(result.path, 'C:\\Downloads\\fanqie\\book.txt');
      final request = calls.last.arguments as Map;
      expect(request['sourcePath'], source.path);
      expect(request['fileName'], '书 (1).txt');
      expect(request['directory'], isNotEmpty);
      expect(
        calls.where((c) => c.method == 'saveExportFile'),
        isEmpty,
      );
      commitResponse = {'status': 'cancelled'};
      expect(
        (await DesktopDownloadOutput.commit(source, '书 (1).txt')).status,
        FileExportStatus.cancelled,
      );
      commitResponse = {'status': 'failed', 'error': '目录不可用'};
      final failed = await DesktopDownloadOutput.commit(source, '书 (1).txt');
      expect(failed.status, FileExportStatus.failed);
      expect(failed.error, '目录不可用');
      // Cancellation before the native request never touches the channel.
      calls.clear();
      expect(
        (await DesktopDownloadOutput.commit(
          source,
          '书 (1).txt',
          isCancelled: () => true,
        )).status,
        FileExportStatus.cancelled,
      );
      expect(calls, isEmpty);
      expect(await source.readAsString(), '整本书');
    },
  );

  test(
    'exports distinguish saved, cancelled, failed and missing bridge',
    () async {
      final source = await File(
        '${directory.path}/book.txt',
      ).writeAsString('原正文');
      final service = FileExportService();
      exportResponse = {
        'status': 'saved',
        'path': '${directory.path}\\chosen.txt',
      };
      final saved = await service.save(
        source,
        name: '../book.txt',
        mimeType: 'text/plain',
      );
      expect(saved.status, FileExportStatus.saved);
      expect(saved.path, '${directory.path}\\chosen.txt');
      final request = calls.last.arguments as Map;
      expect(request['fileName'], '.._book.txt');
      exportResponse = {'status': 'cancelled'};
      expect(
        (await service.save(
          source,
          name: 'book.txt',
          mimeType: 'text/plain',
        )).status,
        FileExportStatus.cancelled,
      );
      exportResponse = {'status': 'saved', 'path': ''};
      expect(
        (await service.save(
          source,
          name: 'book.txt',
          mimeType: 'text/plain',
        )).status,
        FileExportStatus.failed,
      );
      exportResponse = {'status': 'failed', 'error': '磁盘已满'};
      expect(
        (await service.save(
          source,
          name: 'book.txt',
          mimeType: 'text/plain',
        )).error,
        '磁盘已满',
      );
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
      expect(
        (await service.save(
          source,
          name: 'book.txt',
          mimeType: 'text/plain',
        )).status,
        FileExportStatus.failed,
      );
      expect(await source.readAsString(), '原正文');
    },
  );

  test('desktop commands prefer the active route and clean up handlers', () {
    final library = Object();
    final reader = Object();
    final received = <String>[];
    DesktopCommands.register(library, (command) {
      received.add('library:$command');
      return true;
    });
    DesktopCommands.register(reader, (command) {
      if (command == 'import') return false;
      received.add('reader:$command');
      return true;
    });
    try {
      expect(DesktopCommands.dispatch('find'), true);
      expect(DesktopCommands.dispatch('import'), true);
      expect(received, ['reader:find', 'library:import']);
      DesktopCommands.register(reader, null);
      DesktopCommands.dispatch('find');
      expect(received.last, 'library:find');
    } finally {
      DesktopCommands.register(reader, null);
      DesktopCommands.register(library, null);
    }
    expect(DesktopCommands.dispatch('find'), false);
  });

  test('quit waits for participants and refuses failed durable writes', () async {
    final owner = Object();
    ReaderSystemService.registerSaveParticipant(
      owner,
      () async => throw StateError('disk full'),
    );
    expect(await AppLifecycleService.prepareToQuit(), false);
    var saved = false;
    ReaderSystemService.registerSaveParticipant(owner, () async {
      saved = true;
    });
    try {
      expect(await AppLifecycleService.prepareToQuit(), true);
      expect(saved, true);
    } finally {
      ReaderSystemService.registerSaveParticipant(owner, null);
    }
  });

  Future<void> mountReader(
    WidgetTester tester,
    String id,
    ReaderSettings settings, {
    int chapterCount = 3,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(bookId: 'win_$id', bookName: '桌面测试', author: '测试'),
          chapters: List.generate(
            chapterCount,
            (index) => Chapter(
              itemId: 'c$index',
              title: '第${index + 1}章',
              content: List.generate(
                140,
                (i) =>
                    '第${index + 1}章第${i.toString().padLeft(3, '0')}段。这是一段足够长的原文用于测试窗口重新排版、字符锚点和鼠标选择操作。',
              ).join('\n\n'),
            ),
          ),
          resumeSavedPosition: false,
          bookDocuments: () async => directory,
          initialSettings: ReaderSettingsRecord(settings),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void windowsWidgets(String name, WidgetTesterCallback body) {
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

  windowsWidgets(
    'desktop navigation retains bookshelf state across rail widths',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: MainScreen()));
      await tester.pumpAndSettle();
      final shelf = tester.state(
        find.byType(BookshelfScreen, skipOffstage: false),
      );
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      rail.onDestinationSelected!(1);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(720, 540);
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(BookshelfScreen, skipOffstage: false)),
        same(shelf),
      );
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        false,
      );
      expect(DesktopCommands.dispatch('find'), true);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus!.debugLabel,
        'desktop-library-search',
      );
      expect(tester.takeException(), isNull);
    },
  );

  windowsWidgets(
    'windows paged mode supports keys, 840px viewport and anchor resize',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      await mountReader(
        tester,
        'paged',
        const ReaderSettings(
          pageMode: true,
          pageAnimation: 'slide',
          commentBubbles: false,
          pureMode: true,
        ),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('desktop-reader-viewport')))
            .width,
        840,
      );
      final pageState = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final first = pageState.currentPageId;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ReaderPageView)),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(pageState.currentPageId, isNot(first));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('win_paged');
      expect(before, isNotNull);
      tester.view.physicalSize = const Size(720, 540);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('win_paged');
      expect(after!.chapterId, before!.chapterId);
      expect(after.paragraphIndex, lessThanOrEqualTo(before.paragraphIndex));
      expect(tester.takeException(), isNull);
    },
  );

  windowsWidgets('Ctrl+arrow chapter navigation stays within bounds', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.reset);
    await mountReader(
      tester,
      'chapter',
      const ReaderSettings(
        pageMode: false,
        commentBubbles: false,
        pureMode: true,
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await ReaderSystemService.flushParticipants();
    expect(
      (await ReaderPositionService().load('win_chapter'))!.chapterId,
      'c1',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await ReaderSystemService.flushParticipants();
    expect(
      (await ReaderPositionService().load('win_chapter'))!.chapterId,
      'c0',
    );
    // Before the first chapter the navigation is a no-op.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    await ReaderSystemService.flushParticipants();
    expect(
      (await ReaderPositionService().load('win_chapter'))!.chapterId,
      'c0',
    );
    expect(tester.takeException(), isNull);
  });

  windowsWidgets('F11 toggles native full-screen and Esc leaves it first', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.reset);
    await mountReader(
      tester,
      'fullscreen',
      const ReaderSettings(
        pageMode: false,
        commentBubbles: false,
        pureMode: true,
      ),
    );
    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(ReaderSystemService.isFullScreen, true);
    expect(calls.map((c) => c.method), contains('toggleFullScreen'));
    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(ReaderSystemService.isFullScreen, false);
    expect(calls.map((c) => c.method), contains('toggleFullScreen'));
    expect(tester.takeException(), isNull);
  });

  windowsWidgets('Esc closes the reader menu before navigating back', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.reset);
    await mountReader(
      tester,
      'esc-menu',
      const ReaderSettings(
        pageMode: false,
        commentBubbles: false,
        pureMode: true,
      ),
    );
    // Simulate the reader menu being visible (center tap in scroll mode).
    await tester.tap(
      find.byKey(const ValueKey('desktop-reader-viewport')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    // Esc should be consumed by the menu/page layer without popping the route.
    expect(
      find.byWidgetPredicate((w) => w is ReaderScreen),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is ReaderScreen),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  windowsWidgets(
    'windows scroll mode: mouse drag selects and never turns the page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1024, 768);
      addTearDown(tester.view.reset);
      await mountReader(
        tester,
        'scroll',
        const ReaderSettings(
          pageMode: false,
          commentBubbles: false,
          pureMode: true,
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
      }
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load('win_scroll');
      expect(before!.paragraphIndex, greaterThan(0));
      final text = find.byType(SelectableText).hitTestable().first;
      final rect = tester.getRect(text);
      final point = Offset(rect.left + 120, rect.top + 12);
      final gesture = await tester.startGesture(
        point - const Offset(50, 0),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(point + const Offset(60, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      final editable = tester.widgetList<EditableText>(find.byType(EditableText));
      expect(editable.any((e) => !e.controller.selection.isCollapsed), true);
      final secondary = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.up();
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      await ReaderSystemService.flushParticipants();
      expect(
        (await ReaderPositionService().load('win_scroll'))!.paragraphIndex,
        before.paragraphIndex,
      );
      expect(tester.takeException(), isNull);
    },
  );

  windowsWidgets(
    'windows settings hide ineffective device options at double text scale',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(720, 540),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: ReaderSettingsSheet(
                bookId: 'local_settings',
                settings: const ReaderSettings(),
                bookOverride: false,
                onChanged: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('亮度跟随系统'), findsNothing);
      expect(find.text('音量键翻页'), findsNothing);
      expect(find.text('翻页触感反馈'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

