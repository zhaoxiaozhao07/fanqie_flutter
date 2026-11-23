import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
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
  late String temporaryParent;
  late String ownedRoot;
  Future<Directory> Function()? previousDocuments;

  setUp(() async {
    previousDocuments = AppStorage.documentsOverride;
    SharedPreferences.setMockInitialValues({});
    ReaderPlatform.resetForTesting();
    temporaryParent = await Directory.systemTemp.resolveSymbolicLinks();
    root = await Directory(temporaryParent).createTemp('chapter-overlay-');
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
      AppStorage.documentsOverride = previousDocuments;
      ReaderPlatform.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderPlatform.channel, null);
      expect(await root.resolveSymbolicLinks(), ownedRoot);
      expect(path.dirname(ownedRoot), temporaryParent);
      expect(path.basename(ownedRoot).startsWith('chapter-overlay-'), isTrue);
      await root.delete(recursive: true);
    }
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final mode in [
      'scroll',
      'cover',
      'slide',
      'fade',
      'none',
      'simulation',
    ]) {
      testWidgets('${platform.name} $mode has no persistent chapter overlay', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1480, 1280);
        addTearDown(tester.view.reset);
        try {
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [readerRouteObserver],
              home: ReaderScreen(
                book: Book(
                  bookId: 'local_chapter_overlay',
                  bookName: '正文不应被重复章节标签挡住',
                  author: '测试',
                ),
                chapters: [
                  Chapter(
                    itemId: 'c',
                    title: '很长的章节名，必须只出现在正文标题和按需打开的阅读界面中',
                    content: List.generate(
                      140,
                      (i) => '第$i段正文。底部的每一行都应正常阅读，不能被悬浮章节标签覆盖。' * 3,
                    ).join('\n\n'),
                  ),
                ],
                bookDocuments: () async => root,
                initialSettings: ReaderSettingsRecord(
                  ReaderSettings(
                    pageMode: mode != 'scroll',
                    pureMode: false,
                    showHeader: true,
                    showStatus: true,
                    commentBubbles: false,
                    desktopColumns: 'single',
                    pageAnimation: mode == 'scroll' ? 'none' : mode,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (var i = 0; i < 2; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
            await tester.pumpAndSettle();
          }
          await ReaderSystemService.flushParticipants();
          final before = await ReaderPositionService().load(
            'local_chapter_overlay',
          );
          expect(before!.paragraphIndex, greaterThan(0));
          final status = tester.getRect(
            find.byKey(const ValueKey('reader-status-bar')),
          );
          if (mode != 'scroll') {
            expect(
              tester.getRect(find.byType(ReaderPageView)).bottom,
              lessThanOrEqualTo(status.top),
            );
          }

          await tester.sendKeyEvent(LogicalKeyboardKey.f11);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('desktop-immersive-chapter-title')),
            findsNothing,
            reason: 'IgnorePointer prevents clicks, not visual text occlusion',
          );
          expect(find.byKey(const ValueKey('reader-status-bar')), findsNothing);
          await ReaderSystemService.flushParticipants();
          final immersed = await ReaderPositionService().load(
            'local_chapter_overlay',
          );
          expect(immersed!.toJson(), before.toJson());

          final viewport = tester.getRect(
            find.byKey(const ValueKey('desktop-reader-viewport')),
          );
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: viewport.center);
          await mouse.moveTo(Offset(viewport.left + 160, viewport.top + 6));
          await tester.pumpAndSettle();
          expect(find.byTooltip('退出阅读全屏').hitTestable(), findsOneWidget);
          final contextTitle = tester.widget<Tooltip>(
            find
                .byKey(const ValueKey('desktop-reader-chapter-context'))
                .hitTestable(),
          );
          expect(contextTitle.message, contains('很长的章节名'));
          expect(
            find.byKey(const ValueKey('desktop-immersive-chapter-title')),
            findsNothing,
          );
          await mouse.moveTo(viewport.center);
          await tester.pumpAndSettle();
          await mouse.removePointer();
          await tester.sendKeyEvent(LogicalKeyboardKey.f11);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('reader-status-bar')),
            findsOneWidget,
          );
          await ReaderSystemService.flushParticipants();
          final returned = await ReaderPositionService().load(
            'local_chapter_overlay',
          );
          expect(returned!.toJson(), before.toJson());
          expect(tester.takeException(), isNull);
        } finally {
          try {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      });
    }
  }
}
