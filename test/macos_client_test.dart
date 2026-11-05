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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  final calls = <MethodCall>[];
  Map<String, Object?> exportResponse = {'status': 'cancelled'};

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    ReaderPlatform.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('macos-client-unit-');
    AppStorage.documentsOverride = () async => directory;
    calls.clear();
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      calls.add(call);
      if (call.method == 'getReaderCapabilities') {
        return {
          'tts': false,
          'secureStorage': false,
          'battery': false,
          'keepAwake': true,
          'networkType': true,
          'textDecoder': true,
          'fileExport': true,
        };
      }
      if (call.method == 'saveExportFile') return exportResponse;
      return null;
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
    await directory.delete(recursive: true);
  });

  test('macOS capabilities never call Android-only system methods', () async {
    expect(ReaderPlatform.capabilities.tts, false);
    expect(ReaderPlatform.capabilities.volumeKeys, false);
    expect(ReaderPlatform.capabilities.windowBrightness, false);
    final owner = Object();
    await ReaderSystemService.setWindowBrightness(owner, .5);
    await ReaderSystemService.setVolumeKeyScrollEnabled(true);
    expect(await ReaderSystemService.getBatteryLevel(), -1);
    expect(calls.map((c) => c.method), ['getReaderCapabilities']);
  });

  test(
    'missing native macOS initialization fails instead of pretending support',
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
    'storage failure does not silently redirect durable macOS data',
    () async {
      AppStorage.documentsOverride = () async =>
          throw const FileSystemException('denied');
      await expectLater(
        AppStorage.documents(),
        throwsA(isA<FileSystemException>()),
      );
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
        'path': '${directory.path}/chosen.txt',
      };
      final saved = await service.save(
        source,
        name: '../book.txt',
        mimeType: 'text/plain',
      );
      expect(saved.status, FileExportStatus.saved);
      expect(saved.path, '${directory.path}/chosen.txt');
      final request = calls.last.arguments as Map;
      expect(request['filePath'], source.path);
      expect(request['fileName'], '.._book.txt');
      expect(request.containsKey('bytes'), false);
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

  test(
    'export preflight cancellation and native committed outcome are distinct',
    () async {
      final source = await File(
        '${directory.path}/cancel-race.txt',
      ).writeAsString('正文');
      var cancelled = false;
      final service = FileExportService();
      final pending = service.save(
        source,
        name: 'book.txt',
        mimeType: 'text/plain',
        isCancelled: () => cancelled,
      );
      cancelled =
          true; // Arrives while source.exists is awaiting filesystem I/O.
      expect((await pending).status, FileExportStatus.cancelled);
      expect(calls.where((c) => c.method == 'saveExportFile'), isEmpty);
      cancelled = false;
      messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
        cancelled = true; // Too late: native has already atomically committed.
        return {'status': 'saved', 'path': '${directory.path}/saved.txt'};
      });
      expect(
        (await service.save(
          source,
          name: 'book.txt',
          mimeType: 'text/plain',
          isCancelled: () => cancelled,
        )).status,
        FileExportStatus.saved,
      );
      expect(await source.readAsString(), '正文');
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

  test(
    'quit waits for participants and refuses failed durable writes',
    () async {
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
    },
  );

  Future<void> mountReader(
    WidgetTester tester,
    String id,
    ReaderSettings settings,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(bookId: 'local_$id', bookName: '桌面测试', author: '测试'),
          chapters: [
            Chapter(
              itemId: 'c',
              title: '正文',
              content: List.generate(
                140,
                (i) =>
                    '正文第${i.toString().padLeft(3, '0')}段。这是一段足够长的原文用于测试窗口重新排版、字符锚点和鼠标选择操作。',
              ).join('\n\n'),
            ),
          ],
          resumeSavedPosition: false,
          bookDocuments: () async => directory,
          initialSettings: ReaderSettingsRecord(settings),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void macWidgets(String name, WidgetTesterCallback body) {
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

  macWidgets(
    'desktop navigation retains bookshelf state across rail widths and search focus',
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

  for (final mode in ['cover', 'simulation', 'slide', 'fade', 'none']) {
    macWidgets(
      'desktop $mode supports keys, 840px viewport and anchor-preserving resize',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1400, 900);
        addTearDown(tester.view.reset);
        await mountReader(
          tester,
          mode,
          ReaderSettings(
            pageMode: true,
            pageAnimation: mode,
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
        expect(pageState.currentPageId, isNot(first));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final before = await ReaderPositionService().load('local_$mode');
        expect(before, isNotNull);
        tester.view.physicalSize = const Size(720, 540);
        await tester.pumpAndSettle();
        await ReaderSystemService.flushParticipants();
        final after = await ReaderPositionService().load('local_$mode');
        expect(after!.chapterId, before!.chapterId);
        expect(after.paragraphIndex, lessThanOrEqualTo(before.paragraphIndex));
        // A narrower page contains the anchor, even when its visible start moves.
        final texts = tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        );
        expect(
          texts.any(
            (t) => t.textSpan!.toPlainText().contains(
              '正文第${before.paragraphIndex.toString().padLeft(3, '0')}段',
            ),
          ),
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  macWidgets(
    'desktop scroll resize preserves paragraph and mouse drag never pages',
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
      final before = await ReaderPositionService().load('local_scroll');
      expect(before!.paragraphIndex, greaterThan(0));
      tester.view.physicalSize = const Size(720, 540);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('local_scroll');
      expect(after!.paragraphIndex, before.paragraphIndex);
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
      final editable = tester.widgetList<EditableText>(
        find.byType(EditableText),
      );
      expect(editable.any((e) => !e.controller.selection.isCollapsed), true);
      final secondary = await tester.startGesture(
        point,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.up();
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('划线'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      expect(
        (await ReaderPositionService().load('local_scroll'))!.paragraphIndex,
        after.paragraphIndex,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  macWidgets('repeated height changes retain exact idle character anchors', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.reset);
    await mountReader(
      tester,
      'repeated_reflow',
      const ReaderSettings(
        pageMode: false,
        commentBubbles: false,
        pureMode: true,
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final before = await ReaderPositionService().load(
        'local_repeated_reflow',
      );
      tester.view.physicalSize = i.isEven
          ? const Size(720, 540)
          : const Size(1400, 900);
      await tester.pumpAndSettle();
      await ReaderSystemService.flushParticipants();
      final after = await ReaderPositionService().load('local_repeated_reflow');
      expect(after!.paragraphIndex, before!.paragraphIndex);
      expect(after.characterOffset, before.characterOffset);
      expect(after.chapterId, before.chapterId);
      expect(tester.takeException(), isNull);
    }
  });

  macWidgets('context search and IME composition never turn the reading page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
    addTearDown(tester.view.reset);
    await mountReader(
      tester,
      'ime',
      const ReaderSettings(
        pageMode: true,
        commentBubbles: false,
        pureMode: true,
      ),
    );
    final page = tester.state<ReaderPageViewState>(find.byType(ReaderPageView));
    final original = page.currentPageId;
    expect(DesktopCommands.dispatch('find'), true);
    await tester.pumpAndSettle();
    final input = find.byType(TextField).first;
    await tester.tap(input);
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'zhongwen',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(input).controller!.value.composing.isValid,
      true,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(page.currentPageId, original);
    expect(tester.takeException(), isNull);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
  });

  macWidgets('compact desktop home remains usable at double text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 540);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const MainScreen(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  macWidgets(
    'macOS settings hide ineffective device options at double text scale',
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
