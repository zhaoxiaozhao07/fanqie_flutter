// Isolated AOT Profile entry, never the packaged application's main target.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/main.dart' as application;
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'macos_reader_performance.dart' as performance;

const _foregroundRequired = bool.fromEnvironment(
  'WINDOWS_REQUIRE_FOREGROUND',
  defaultValue: false,
);

Future<Map> _native() async =>
    await ReaderPlatform.invoke<Map>('getReaderCapabilities') ?? {};

Future<void> _waitForForeground() async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (true) {
    if ((await _native())['foreground'] == true) return;
    performance.require(
      DateTime.now().isBefore(deadline),
      'Foreground window was not acquired; do not report this run as '
      'foreground performance.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  ui.PlatformDispatcher.instance.onError = (error, _) {
    errors.add(error.toString());
    return true;
  };
  Directory? root;
  Directory? support;
  var result = 1;
  try {
    performance.require(
      Platform.isWindows && kProfileMode,
      'Run this target on Windows with --profile.',
    );
    SharedPreferences.setMockInitialValues({});
    support = await AppStorage.documents();
    root = await support.createTemp('isolated-windows-reading-performance-');
    AppStorage.documentsOverride = () async => root!;
    await application.initializeReaderApplication();
    runApp(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Color(0xFFECE8E0),
          body: Center(child: Text('Windows 阅读性能验证\n请保持此窗口在前台，测试数据不会写入日常书库。')),
        ),
      ),
    );
    await ReaderPlatform.invoke('showMainWindow');
    await performance.nextFrame();
    stdout.writeln('WINDOWS_READER_PERF_READY');
    if (_foregroundRequired) await _waitForForeground();
    final report = <String, Object?>{
      'mode': 'AOT Profile',
      'system': Platform.operatingSystemVersion,
      'foregroundRequired': _foregroundRequired,
      'native': await _native(),
      'latencyDefinition':
          'Dart command to submitted frame, not physical input',
    };

    final longParagraph =
        '这是一个没有空行的超长中文段落，English words 123。👨‍👩‍👧‍👦' * 2000;
    final measuring = Stopwatch()..start();
    final measured = ReaderPaginationCache().paginate(
      chapterId: 'long-paragraph',
      title: '超长段落',
      content: longParagraph,
      indent: true,
      layout: const ReaderLayout(
        size: Size(420, 760),
        bodyStyle: TextStyle(
          fontSize: 18,
          height: 1.8,
          fontFamily: 'Microsoft YaHei',
        ),
        titleStyle: TextStyle(fontSize: 22, height: 1.4),
        textScaler: TextScaler.noScaling,
        horizontalPadding: 20,
        paragraphSpacing: 14,
      ),
    );
    measuring.stop();
    performance.require(
      measuring.elapsedMilliseconds < 1000,
      '90k-character single-paragraph cold layout exceeded one second.',
    );
    performance.require(
      measured.pages
              .expand((page) => page.fragments)
              .map(
                (fragment) => fragment.startOffset == 0
                    ? fragment.text.substring(2)
                    : fragment.text,
              )
              .join() ==
          longParagraph,
      'Long-paragraph measurement changed canonical text.',
    );
    report['longParagraph'] = {
      'characters': longParagraph.length,
      'pages': measured.pages.length,
      'coldMs': measuring.elapsedMilliseconds,
    };

    final text = List.generate(
      500,
      (index) => '第$index段。性能验收使用隔离正文，分页、选择与返回必须保持原文锚点。' * 6,
    ).join('\n\n');
    final scenarios = <Map<String, Object?>>[
      for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation'])
        {
          'name': mode,
          'mode': mode,
          'columns': 'single',
          'theme': mode == 'simulation' ? 8 : 5,
        },
      {
        'name': 'double-cover',
        'mode': 'cover',
        'columns': 'double',
        'theme': 6,
      },
      {
        'name': 'cross-chapter-cover',
        'mode': 'cover',
        'columns': 'single',
        'theme': 7,
        'crossChapter': true,
      },
    ];
    final metrics = <Map<String, Object?>>[];
    for (final scenario in scenarios) {
      final name = scenario['name'] as String;
      final mode = scenario['mode'] as String;
      final crossing = scenario['crossChapter'] == true;
      runApp(const SizedBox.shrink());
      await performance.nextFrame();
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      final cold = Stopwatch()..start();
      runApp(
        MaterialApp(
          key: ValueKey(name),
          builder: (context, child) => DesktopShortcuts(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: false),
              child: child!,
            ),
          ),
          home: ReaderScreen(
            book: Book(
              bookId: 'local_windows_perf_$name',
              bookName: 'Windows 阅读性能验证',
              author: '隔离测试',
            ),
            chapters: [
              if (crossing)
                for (var chapter = 0; chapter < 26; chapter++)
                  Chapter(
                    itemId: 'c$chapter',
                    title: '第${chapter + 1}章 跨章连续阅读',
                    content: '第$chapter章。${'跨章翻页必须保持页面缓存和原文位置。' * 5}',
                  )
              else
                Chapter(itemId: 'c', title: '第一章 性能隔离正文', content: text),
            ],
            bookDocuments: () async => root!,
            offlineOnly: true,
            resumeSavedPosition: false,
            initialSettings: ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: mode,
                desktopColumns: scenario['columns'] as String,
                themeIndex: scenario['theme'] as int,
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await performance.nextFrame();
      await performance.until(
        () => performance.pager() != null && !performance.pager()!.isBusy,
      );
      final effectiveMode = performance.pager()!.widget.mode;
      final doubleSpread =
          performance.findElement(
            WidgetsBinding.instance.rootElement!,
            (element) =>
                element.widget.key ==
                    const ValueKey('reader-double-column-spread')
                ? true
                : null,
          ) ==
          true;
      final effectiveColumns = doubleSpread ? 2 : 1;
      final viewport =
          performance.pager()!.context.findRenderObject() as RenderBox;
      performance.require(
        effectiveMode == mode,
        '$name effective page mode mismatch',
      );
      if (scenario['columns'] == 'double') {
        performance.require(
          effectiveColumns == 2,
          '$name cannot measure double columns at viewport ${viewport.size}; '
          'widen the test window instead of reporting single-column timings.',
        );
      }
      cold.stop();
      performance.require(cold.elapsedMilliseconds < 1500, '$name cold layout');
      await performance.turn();
      await performance.turn();
      await Future<void>.delayed(const Duration(seconds: 1));
      final startNative = await _native();
      if (_foregroundRequired) {
        performance.require(
          startNative['foreground'] == true,
          '$name window is not foreground before measuring.',
        );
      }
      final timings = <ui.FrameTiming>[];
      void listener(List<ui.FrameTiming> frames) => timings.addAll(frames);
      SchedulerBinding.instance.addTimingsCallback(listener);
      final memory = ProcessInfo.currentRss;
      final submissions = <int>[];
      final elapsed = Stopwatch()..start();
      try {
        for (var turn = 0; turn < 20; turn++) {
          submissions.add(await performance.turn());
        }
        elapsed.stop();
        await Future<void>.delayed(const Duration(seconds: 1));
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(listener);
      }
      final endNative = await _native();
      if (_foregroundRequired) {
        performance.require(
          endNative['foreground'] == true,
          '$name window lost foreground while measuring.',
        );
      }
      performance.require(timings.length >= 20, '$name missing native timings');
      final build95 = performance.percentile(
        timings.map((frame) => frame.buildDuration.inMicroseconds).toList(),
        .95,
      );
      final raster95 = performance.percentile(
        timings.map((frame) => frame.rasterDuration.inMicroseconds).toList(),
        .95,
      );
      performance.require(build95 <= 16.7, '$name build P95 $build95 >16.7ms');
      performance.require(
        raster95 <= 16.7,
        '$name raster P95 $raster95 >16.7ms',
      );
      final growth = ProcessInfo.currentRss - memory;
      performance.require(growth < 128 * 1024 * 1024, '$name unbounded memory');
      final dynamic finalPage = performance.pager()!.currentPageId;
      if (crossing) {
        performance.require(finalPage.chapterIndex == 22, 'Lost chapter turns');
      }
      final metric = <String, Object?>{
        'scenario': name,
        'effectiveMode': effectiveMode,
        'effectiveColumns': effectiveColumns,
        'viewportWidth': viewport.size.width,
        'viewportHeight': viewport.size.height,
        'characters': crossing ? null : text.length,
        'turns': 20,
        'turnsMs': elapsed.elapsedMilliseconds,
        'coldMs': cold.elapsedMilliseconds,
        'frames': timings.length,
        'buildP95Ms': build95,
        'rasterP95Ms': raster95,
        'commandToSubmittedFrameP95Ms': performance.percentile(
          submissions,
          .95,
        ),
        'buildOver16_7Ms': timings
            .where((frame) => frame.buildDuration.inMicroseconds > 16700)
            .length,
        'rasterOver16_7Ms': timings
            .where((frame) => frame.rasterDuration.inMicroseconds > 16700)
            .length,
        'foregroundAtStart': startNative['foreground'],
        'foregroundAtEnd': endNative['foreground'],
        'devicePixelRatio': WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .first
            .devicePixelRatio,
        'rssGrowthBytes': growth,
      };
      metrics.add(metric);
      stdout.writeln('WINDOWS_READER_PERF_MODE ${jsonEncode(metric)}');
    }
    performance.require(errors.isEmpty, 'Framework errors: $errors');
    report['pagination'] = metrics;
    report['rssBytes'] = ProcessInfo.currentRss;
    stdout.writeln('WINDOWS_READER_PERF_OK ${jsonEncode(report)}');
    await stdout.flush();
    result = 0;
  } catch (error, stack) {
    stderr.writeln('WINDOWS_READER_PERF_FAILED $error\n$stack');
  } finally {
    runApp(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
    AppStorage.documentsOverride = null;
    if (root != null &&
        support != null &&
        path.isWithin(support.absolute.path, root.absolute.path) &&
        path
            .basename(root.path)
            .startsWith('isolated-windows-reading-performance-') &&
        await root.exists()) {
      await root.delete(recursive: true);
    }
  }
  exit(result);
}
