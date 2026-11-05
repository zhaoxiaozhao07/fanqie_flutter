import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const soakSeconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 1800);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS continuous reading, resize, bounded memory and progress ($soakSeconds seconds)',
    (tester) async {
      expect(soakSeconds, inInclusiveRange(5, 3600));
      SharedPreferences.setMockInitialValues({});
      await ReaderPlatform.initialize();
      AppLifecycleService.initialize();
      final root = await (await AppStorage.documents()).createTemp(
        'isolated-reading-soak-',
      );
      AppStorage.documentsOverride = () async => root;
      try {
        await ReaderPlatform.invoke('setTestWindowSize', {
          'width': 1024.0,
          'height': 768.0,
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [readerRouteObserver],
            home: ReaderScreen(
              book: Book(
                bookId: 'local_macos_soak',
                bookName: '长时阅读验证',
                author: '隔离数据',
              ),
              chapters: List.generate(
                3,
                (c) => Chapter(
                  itemId: 'chapter_$c',
                  title: '第${c + 1}章',
                  content: List.generate(
                    1500,
                    (p) => '第$c章第$p段。长时阅读过程使用本地正文，验证滚动和窗口重排，阅读进度必须持久保存。' * 3,
                  ).join('\n\n'),
                ),
              ),
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
        final start = DateTime.now();
        final memory = <int>[];
        var samples = 0;
        debugPrint('FANQIE_MACOS_SOAK_READY seconds=$soakSeconds pid=$pid');
        while (DateTime.now().difference(start).inSeconds < soakSeconds) {
          await Future<void>.delayed(const Duration(seconds: 4));
          await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
          await tester.pumpAndSettle();
          await ReaderSystemService.flushParticipants();
          final position = await ReaderPositionService().load(
            'local_macos_soak',
          );
          expect(position, isNotNull);
          if (samples % 15 == 0) {
            final narrow = samples % 30 == 0;
            await ReaderPlatform.invoke('setTestWindowSize', {
              'width': narrow ? 720.0 : 1400.0,
              'height': narrow ? 540.0 : 900.0,
            });
            await tester.pumpAndSettle();
            await ReaderSystemService.flushParticipants();
            final resized = await ReaderPositionService().load(
              'local_macos_soak',
            );
            expect(resized!.chapterId, position!.chapterId);
            expect(resized.paragraphIndex, position.paragraphIndex);
          }
          memory.add(ProcessInfo.currentRss);
          samples++;
          if (samples % 15 == 0) {
            debugPrint(
              'FANQIE_MACOS_SOAK_SAMPLE elapsed=${DateTime.now().difference(start).inSeconds} rss=${memory.last} paragraph=${position!.paragraphIndex}',
            );
          }
          expect(tester.takeException(), isNull);
        }
        // Ignore startup warm-up; sustained growth must not exceed a generous
        // 64 MiB budget for this fixed, virtualized local reading workload.
        if (memory.length >= 30) {
          final early = memory.sublist(memory.length ~/ 4, memory.length ~/ 2)
            ..sort();
          final late = memory.sublist(memory.length * 3 ~/ 4)..sort();
          expect(
            late[late.length ~/ 2] - early[early.length ~/ 2],
            lessThan(64 * 1024 * 1024),
          );
        }
        expect(
          (await ReaderPositionService().load(
            'local_macos_soak',
          ))!.paragraphIndex,
          greaterThan(0),
        );
        final cachedBytes = await ReaderCacheService().trim(32 * 1024 * 1024);
        expect(cachedBytes, lessThanOrEqualTo(32 * 1024 * 1024));
        debugPrint(
          'FANQIE_MACOS_SOAK_COMPLETE samples=$samples rssFirst=${memory.first} rssLast=${memory.last}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await ReaderPositionService.flush();
        await ReaderSettingsRepository.flush();
        AppStorage.documentsOverride = null;
        await root.delete(recursive: true);
      }
    },
    timeout: Timeout(Duration(seconds: soakSeconds + 180)),
  );
}
