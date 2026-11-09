import 'dart:async';
import 'dart:io';

import 'package:fanqie_flutter/screens/main_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/external_book_import_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/widgets/local_book_import_dialog.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'cold and overlapping inbox drains deduplicate IDs and serialize ownership',
    () async {
      final first = Completer<Object?>();
      var reads = 0;
      final released = <String>[];
      final service = ExternalBookImportService.forTesting(
        invoke: (method, args) async {
          if (method == 'takeExternalImports') {
            reads++;
            return reads == 1
                ? first.future
                : [
                    {
                      'id': 'one',
                      'name': 'book.txt',
                      'path': '/staging/book.txt',
                    },
                    {
                      'id': 'two',
                      'name': 'other.EPUB',
                      'path': '/staging/other.EPUB',
                    },
                  ];
          }
          if (method == 'releaseExternalImport') {
            released.add(args!['id'] as String);
          }
          return false;
        },
      );
      final initialization = service.initialize();
      final overlap = service.drain();
      first.complete([
        {'id': 'one', 'name': 'book.txt', 'path': '/staging/book.txt'},
      ]);
      await initialization;
      await overlap;
      expect(service.pendingCount, 2);
      final one = service.takeNext()!;
      expect(service.takeNext(), isNull);
      expect(await service.canQuit(), false);
      await service.complete(one);
      expect(service.takeNext()!.id, 'two');
      await service.complete(
        const ExternalBookImportRequest(id: 'two', name: 'other.EPUB'),
      );
      expect(released, ['one', 'two']);
      expect(await service.canQuit(), true);
      service.dispose();
    },
  );

  test(
    'malformed paths become visible errors and release never receives a path',
    () async {
      final releases = <Map<String, Object?>?>[];
      final service = ExternalBookImportService.forTesting(
        invoke: (method, args) async {
          if (method == 'takeExternalImports') {
            return [
              {'id': 'relative', 'name': '../bad.txt', 'path': 'relative.txt'},
              {'id': 'type', 'name': 'bad.pdf', 'path': '/tmp/bad.pdf'},
              {'id': 'denied', 'name': 'book.txt', 'error': '权限不足'},
            ];
          }
          if (method == 'releaseExternalImport') releases.add(args);
          return false;
        },
      );
      await service.initialize();
      final request = service.takeNext()!;
      expect(request.name, 'bad.txt');
      expect(request.filePath, isNull);
      expect(request.error, contains('无效'));
      await service.complete(request);
      await service.releasePending();
      expect(releases, [
        {'id': 'relative'},
        {'id': 'type'},
        {'id': 'denied'},
      ]);
      expect(service.pendingCount, 0);
      service.dispose();
    },
  );

  testWidgets(
    'Finder requests wait behind an existing modal and then show one at a time',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      final records = <Map<String, Object?>>[];
      final released = <String>[];
      final service = ExternalBookImportService.forTesting(
        invoke: (method, args) async {
          if (method == 'takeExternalImports') {
            final next = List<Map<String, Object?>>.from(records);
            records.clear();
            return next;
          }
          if (method == 'releaseExternalImport') {
            released.add(args!['id'] as String);
          }
          return false;
        },
      );
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('external-dialog-'),
      ))!;
      AppStorage.documentsOverride = () async => root;
      try {
        await service.initialize();
        await tester.pumpWidget(
          MaterialApp(home: MainScreen(externalImports: service)),
        );
        await tester.pumpAndSettle();
        DesktopCommands.dispatch('settings');
        await tester.pumpAndSettle();
        expect(find.byType(ReaderSettingsSheet), findsOneWidget);
        records.addAll([
          {'id': 'one', 'name': 'one.txt', 'error': '第一个文件权限不足'},
          {'id': 'two', 'name': 'two.epub', 'error': '第二个文件格式损坏'},
        ]);
        await service.drain();
        await tester.pumpAndSettle();
        expect(find.byType(LocalBookImportDialog), findsNothing);
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        expect(find.byType(LocalBookImportDialog), findsOneWidget);
        expect(find.text('第一个文件权限不足'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭导入'));
        await tester.pumpAndSettle();
        expect(released, ['one']);
        expect(find.byType(LocalBookImportDialog), findsOneWidget);
        expect(find.text('第二个文件格式损坏'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭导入'));
        await tester.pumpAndSettle();
        expect(released, ['one', 'two']);
        expect(find.byType(LocalBookImportDialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        service.dispose();
        tester.view.reset();
        debugDefaultTargetPlatformOverride = null;
        ReaderPlatform.resetForTesting();
        AppStorage.documentsOverride = null;
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'staged file auto-previews but requires explicit import confirmation',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('finder-preview-'),
      ))!;
      AppStorage.documentsOverride = () async => root;
      final source = File('${root.path}/book.txt');
      await tester.runAsync(
        () => source.writeAsString('第一章 开始\n${'完整正文与原文件必须保留。' * 20}'),
      );
      final local = LocalBookService.forTesting(documents: () async => root);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LocalBookImportDialog(
                initialFile: source,
                autoPreview: true,
                service: local,
              ),
            ),
          ),
        );
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find
              .byKey(const ValueKey('local-import-confirm'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        expect(
          find.byKey(const ValueKey('local-import-confirm')),
          findsOneWidget,
        );
        expect(await tester.runAsync(source.exists), true);
        final offline = Directory('${root.path}/offline_books');
        expect(
          await tester.runAsync(offline.exists),
          false,
          reason: 'Preview must not commit a book',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        expect(await tester.runAsync(source.exists), true);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        AppStorage.documentsOverride = null;
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
