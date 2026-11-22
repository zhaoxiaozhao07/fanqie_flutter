// Dedicated AOT Profile entry. No everyday preferences or reading files are
// used; do not package this target as the client.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/notes_workspace_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_display_text.dart';
import 'package:fanqie_flutter/services/reader_font_service.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

T? findElement<T>(Element element, T? Function(Element) read) {
  final found = read(element);
  if (found != null) return found;
  T? child;
  element.visitChildren((element) => child ??= findElement(element, read));
  return child;
}

ReaderPageViewState? pager() => findElement(
  WidgetsBinding.instance.rootElement!,
  (element) =>
      element is StatefulElement && element.state is ReaderPageViewState
      ? element.state as ReaderPageViewState
      : null,
);

TextField? queryField(String key) => findElement(
  WidgetsBinding.instance.rootElement!,
  (element) =>
      element.widget is TextField && element.widget.key == ValueKey(key)
      ? element.widget as TextField
      : null,
);

int mountedNotes() {
  var count = 0;
  void visit(Element element) {
    if (element.widget is Card &&
        element.widget.key.toString().contains('workspace-note-')) {
      count++;
    }
    element.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return count;
}

bool searchReady() =>
    findElement(
      WidgetsBinding.instance.rootElement!,
      (element) =>
          element.widget is ListTile &&
              element.widget.key == const ValueKey('reader-search-hit-0')
          ? true
          : null,
    ) ==
    true;

Future<void> until(bool Function() ready, {int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ready()) {
    require(DateTime.now().isBefore(end), 'Profile UI did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await nextFrame();
  }
}

Future<void> nextFrame() => WidgetsBinding.instance.endOfFrame.timeout(
  const Duration(seconds: 5),
  onTimeout: () => throw StateError(
    'Native frame was not submitted: lifecycle='
    '${WidgetsBinding.instance.lifecycleState}, framesEnabled=${SchedulerBinding.instance.framesEnabled}',
  ),
);

double percentile(List<int> values, double percentile) {
  final sorted = values.toList()..sort();
  require(sorted.isNotEmpty, 'No native frame timing samples');
  return sorted[((sorted.length - 1) * percentile).round()] / 1000;
}

Future<int> turn() async {
  final state = pager()!;
  final before = state.currentPageId;
  final submitted = Stopwatch()..start();
  state.turnToNextPage();
  await nextFrame();
  submitted.stop();
  // An asynchronous chapter boundary can be idle while its target is still
  // being prepared. Wait for the actual page commit, not just idle motion.
  await until(() => !state.isBusy && state.currentPageId != before);
  require(state.currentPageId != before, 'Profile page turn did not commit');
  return submitted.elapsedMicroseconds;
}

const _foregroundRequired = bool.fromEnvironment('MACOS_REQUIRE_FOREGROUND');
const _rssGrowthBudget = 128 * 1024 * 1024;
const _processRssBudget = 512 * 1024 * 1024;
const _scenarios = [
  (name: 'cover', mode: 'cover', columns: 1, crossChapter: false),
  (name: 'slide', mode: 'slide', columns: 1, crossChapter: false),
  (name: 'fade', mode: 'fade', columns: 1, crossChapter: false),
  (name: 'none', mode: 'none', columns: 1, crossChapter: false),
  (name: 'simulation', mode: 'simulation', columns: 1, crossChapter: false),
  (name: 'double-cover', mode: 'cover', columns: 2, crossChapter: false),
  (name: 'cross-chapter-cover', mode: 'cover', columns: 1, crossChapter: true),
];
var _stopRequested = false;

void _checkRunning() =>
    require(!_stopRequested, 'AOT Profile benchmark was interrupted');

Future<Map> _native() async {
  _checkRunning();
  final values = await ReaderPlatform.invoke<Map>(
    'getReaderCapabilities',
  ).timeout(const Duration(seconds: 5));
  require(
    values?['platform'] == 'macos' && values?['architecture'] == 'arm64',
    'Expected the real macOS arm64 bridge',
  );
  return values!;
}

void _checkForeground(Map native, String phase) {
  if (_foregroundRequired) {
    require(
      native['foreground'] == true,
      '$phase is not a key window; do not report foreground performance',
    );
  }
}

Future<void> _waitForForeground() async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  const failure =
      'No key window within 30 seconds; strict foreground gate failed';
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    require(remaining > Duration.zero, failure);
    final native = await _native().timeout(
      remaining,
      onTimeout: () => throw StateError(failure),
    );
    require(DateTime.now().isBefore(deadline), failure);
    if (native['foreground'] == true) return;
    final pause = deadline.difference(DateTime.now());
    await Future<void>.delayed(
      pause < const Duration(milliseconds: 200)
          ? pause
          : const Duration(milliseconds: 200),
    );
  }
}

// Start at the committed page's column, not a cached/offstage spread elsewhere
// in the tree. A double layout must actually paint two non-empty page cards.
int _columns(dynamic address) {
  final column = findElement<Element>(
    WidgetsBinding.instance.rootElement!,
    (element) =>
        element.widget.key ==
            ValueKey(
              'reader-column-${address.layout.chapterId}-${address.pageIndex}',
            )
        ? element
        : null,
  );
  require(column != null, 'Committed page column is not mounted');
  final box = column!.findRenderObject();
  require(
    box is RenderBox && box.hasSize && !box.size.isEmpty,
    'Committed column has no rendered viewport',
  );
  Element? spread;
  column.visitAncestorElements((element) {
    if (element.widget.key == const ValueKey('reader-double-column-spread')) {
      spread = element;
      return false;
    }
    return true;
  });
  if (spread == null) return 1;
  var count = 0;
  void visit(Element element) {
    final key = element.widget.key;
    if (element.widget is ColoredBox &&
        key is ValueKey<String> &&
        key.value.startsWith('reader-column-')) {
      final box = element.findRenderObject();
      require(
        box is RenderBox && box.hasSize && !box.size.isEmpty,
        'Double spread contains an unrendered column',
      );
      count++;
    }
    element.visitChildren(visit);
  }

  visit(spread!);
  return count;
}

void _verifySource(ReaderChapterPages pages, String content) {
  final paragraphs = content.split('\n\n');
  require(
    listEquals(pages.sourceParagraphs, paragraphs),
    'Pagination changed canonical paragraphs',
  );
  final fragments = pages.pages.expand((page) => page.fragments).toList();
  require(
    fragments.every(
      (fragment) =>
          fragment.image == null &&
          fragment.paragraphIndex >= 0 &&
          fragment.paragraphIndex < paragraphs.length,
    ),
    'Pagination inserted a foreign paragraph/image fragment',
  );
  for (var paragraph = 0; paragraph < paragraphs.length; paragraph++) {
    final source = paragraphs[paragraph];
    final boundaries = <int>{0};
    var offset = 0;
    for (final cluster in source.characters) {
      offset += cluster.length;
      boundaries.add(offset);
    }
    var cursor = 0;
    for (final fragment in fragments.where(
      (fragment) => fragment.paragraphIndex == paragraph,
    )) {
      require(
        fragment.image == null &&
            fragment.startOffset == cursor &&
            fragment.endOffset > cursor &&
            fragment.endOffset <= source.length &&
            boundaries.contains(cursor) &&
            boundaries.contains(fragment.endOffset),
        'Paragraph $paragraph lost a contiguous grapheme range',
      );
      require(
        fragment.text ==
            '${cursor == 0 ? "\u3000\u3000" : ""}'
                '${source.substring(cursor, fragment.endOffset)}',
        'Paragraph $paragraph changed canonical text',
      );
      cursor = fragment.endOffset;
    }
    require(cursor == source.length, 'Paragraph $paragraph was truncated');
  }
}

Future<int> _checkedTurn(
  String name,
  List<Chapter> chapters, {
  required String mode,
  required int columns,
  required bool crossChapter,
  required Size viewportSize,
  required double dpi,
}) async {
  _checkRunning();
  void verifyConfiguration() {
    final state = pager()!;
    require(
      state.widget.mode == mode &&
          (state.context.findRenderObject() as RenderBox).size ==
              viewportSize &&
          View.of(state.context).devicePixelRatio == dpi,
      '$name changed its actual mode, viewport or backing scale during turns',
    );
  }

  verifyConfiguration();
  final dynamic before = pager()!.widget.currentPageId;
  final ReadingPosition beforeAnchor = before.page.position(
    before.layout.chapterId,
  );
  final submitted = await turn(); // Keep the helper's Windows-facing API.
  await until(() {
    _checkRunning();
    final state = pager();
    return state != null &&
        !state.isBusy &&
        state.widget.currentPageId == state.currentPageId;
  });
  verifyConfiguration();
  final dynamic after = pager()!.widget.currentPageId;
  require(_columns(after) == columns, '$name actual column count changed');
  require(
    after.layout.chapterId == chapters[after.chapterIndex as int].itemId,
    '$name committed a mismatched chapter identity',
  );
  final ReadingPosition afterAnchor = after.page.position(
    after.layout.chapterId,
  );
  if (crossChapter) {
    _verifySource(
      after.layout as ReaderChapterPages,
      chapters[after.chapterIndex as int].content!,
    );
    require(
      before.layout.pages.length == 1 &&
          after.layout.pages.length == 1 &&
          after.chapterIndex == before.chapterIndex + 1 &&
          after.pageIndex == 0 &&
          afterAnchor.paragraphIndex == 0 &&
          afterAnchor.characterOffset == 0,
      '$name did not complete exactly one real chapter transition',
    );
  } else {
    require(
      after.chapterIndex == before.chapterIndex &&
          after.pageIndex == before.pageIndex + columns &&
          (afterAnchor.paragraphIndex > beforeAnchor.paragraphIndex ||
              (afterAnchor.paragraphIndex == beforeAnchor.paragraphIndex &&
                  afterAnchor.characterOffset > beforeAnchor.characterOffset)),
      '$name did not advance the canonical anchor by one actual spread',
    );
  }
  return submitted;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  final previousDocuments = AppStorage.documentsOverride;
  final previousFlutterError = FlutterError.onError;
  final previousPlatformError = ui.PlatformDispatcher.instance.onError;
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  ui.PlatformDispatcher.instance.onError = (error, _) {
    errors.add(error.toString());
    return true;
  };
  Directory? root;
  String? ownedRoot;
  String? temporaryParent;
  Map<String, Object?>? report;
  final signals = <StreamSubscription<ProcessSignal>>[];
  var result = 1;
  try {
    require(
      Platform.isMacOS && kProfileMode,
      'Run this benchmark on macOS arm64 with --profile',
    );
    _stopRequested = false;
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(signal.watch().listen((_) => _stopRequested = true));
    }
    // The preferences backend lives only in this dedicated process. Never read,
    // back up, clear or rewrite the user's native preferences domain.
    SharedPreferences.setMockInitialValues({});
    temporaryParent = await Directory.systemTemp.resolveSymbolicLinks();
    root = await Directory(
      temporaryParent,
    ).createTemp('isolated-workspace-perf-');
    ownedRoot = await root.resolveSymbolicLinks();
    AppStorage.documentsOverride = () async => root!;
    stdout.writeln('FANQIE_WORKSPACE_PERF_ROOT $ownedRoot');
    // Reader-only setup avoids draining the real Finder inbox or starting
    // unrelated queue/auto-backup services in this synthetic workload.
    AppLifecycleService.initialize();
    await ReaderPlatform.initialize().timeout(const Duration(seconds: 15));
    await ReaderDisplayText.ensureLoaded().timeout(const Duration(seconds: 5));
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Mac 阅读性能验证\n隔离正文与内存偏好；请勿调整窗口或阅读设置。')),
        ),
      ),
    );
    await ReaderPlatform.invoke(
      'showMainWindow',
    ).timeout(const Duration(seconds: 5));
    await nextFrame();
    stdout.writeln('FANQIE_WORKSPACE_PERF_READY');
    if (_foregroundRequired) await _waitForForeground();
    report = <String, Object?>{
      'mode': 'AOT Profile',
      'system': Platform.operatingSystemVersion,
      'foregroundRequired': _foregroundRequired,
      'native': await _native(),
      'latencyDefinition':
          'Dart command to submitted frame, not physical input',
      'foregroundDefinition':
          'NSWindow.isKeyWindow at sampled endpoints, not continuous visibility',
      'budgets': {
        'longParagraphColdMs': 1000,
        'readerColdMs': 3000,
        'buildP95Ms': 33.4,
        'rasterP95Ms': 33.4,
        'commandToSubmittedFrameP95Ms': 1000,
        'twentyTurnsMs': 30000,
        'rssPeakGrowthBytes': _rssGrowthBudget,
        'processPeakRssBytes': _processRssBudget,
        'localSearchReadyMs': 3000,
        'notesReadyMs': 3000,
        'minimumNativeFramesPerScenario': 20,
      },
    };
    final longParagraph =
        '超长段落不可截断，保留中文 English words 0123 与 👨‍👩‍👧‍👦 原文锚点。' * 2000;
    require(longParagraph.length == 104000, 'Expected the full 104k paragraph');
    final style = ReaderFontService.bodyStyle(
      fontFamily: 'system',
      fontSize: 18,
      lineHeight: 1.8,
    );
    require(
      style.fontFamily == 'Roboto' &&
          listEquals(style.fontFamilyFallback, const ['sans-serif', 'Roboto']),
      'Mac system text must not use a Windows-specific face',
    );
    final measuring = Stopwatch()..start();
    final measured = ReaderPaginationCache().paginate(
      chapterId: 'long-paragraph',
      title: '超长段落',
      content: longParagraph,
      indent: true,
      layout: ReaderLayout(
        size: const Size(420, 760),
        bodyStyle: style,
        titleStyle: style.copyWith(
          fontSize: 22,
          height: 1.4,
          fontWeight: FontWeight.bold,
        ),
        textScaler: TextScaler.noScaling,
        horizontalPadding: 20,
        paragraphSpacing: 14,
        textWidthInset: ReaderLayout.selectableTextInset,
      ),
    );
    measuring.stop();
    require(
      measuring.elapsedMilliseconds < 1000,
      '104k single-paragraph cold CPU layout exceeded one second',
    );
    _verifySource(measured, longParagraph);
    report['longParagraph'] = {
      'characters': longParagraph.length,
      'pages': measured.pages.length,
      'coldMs': measuring.elapsedMilliseconds,
      'layoutWidth': 420,
      'layoutHeight': 760,
      'definition': 'Cold TextPainter pagination, not a submitted viewport',
      'canonicalTextAndGraphemeRangesPreserved': true,
    };
    final baseText = List.generate(
      500,
      (i) => '第$i段。性能验收使用隔离正文，分页、选择与返回必须保持原文锚点。' * 6,
    ).join('\n\n');
    require(baseText.length >= 100000, 'Keep the existing 100k fixture intact');
    final text = '$baseText\n\n$longParagraph';
    report['baseCharacters'] = baseText.length;
    report['characters'] = text.length;
    final modes = <Map<String, Object?>>[];
    require(_scenarios.length == 7, 'All seven AOT scenarios are required');
    for (final scenario in _scenarios) {
      _checkRunning();
      final name = scenario.name;
      final mode = scenario.mode;
      final bookId = 'local_perf_$name';
      final chapters = scenario.crossChapter
          ? [
              for (var chapter = 0; chapter < 40; chapter++)
                Chapter(
                  itemId: 'c$chapter',
                  title: '第${chapter + 1}章',
                  content: '第$chapter章隔离正文。跨章完成后必须提交正确章节与原文锚点。',
                ),
            ]
          : [Chapter(itemId: 'c', title: '第一章', content: text)];
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $name detach');
      // Do not mistake a still-mounted previous route for the next mode.
      runApp(const SizedBox.shrink());
      await nextFrame();
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $name detached');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ReaderPositionService.flush().timeout(const Duration(seconds: 5));
      await ReaderSettingsRepository.flush().timeout(
        const Duration(seconds: 5),
      );
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $name mount');
      final coldRss = ProcessInfo.currentRss;
      var peakRss = coldRss;
      void sampleMemory() {
        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;
      }

      final cold = Stopwatch()..start();
      runApp(
        MaterialApp(
          key: ValueKey('profile-$name'),
          builder: (context, child) => DesktopShortcuts(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: false),
              child: child!,
            ),
          ),
          home: ReaderScreen(
            key: ValueKey(name),
            book: Book(bookId: bookId, bookName: '性能隔离正文', author: '测试'),
            chapters: chapters,
            bookDocuments: () async => root!,
            offlineOnly: true,
            resumeSavedPosition: false,
            initialSettings: ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: mode,
                desktopColumns: scenario.columns == 2 ? 'double' : 'single',
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await nextFrame();
      await until(() {
        _checkRunning();
        return pager() != null &&
            !pager()!.isBusy &&
            pager()!.widget.currentPageId == pager()!.currentPageId;
      });
      cold.stop();
      final dynamic firstPage = pager()!.widget.currentPageId;
      final viewport = pager()!.context.findRenderObject() as RenderBox;
      final viewportSize = viewport.size;
      final dpi = View.of(pager()!.context).devicePixelRatio;
      final ReadingPosition firstAnchor = firstPage.page.position(
        firstPage.layout.chapterId,
      );
      require(
        firstPage.chapterIndex == 0 &&
            firstPage.pageIndex == 0 &&
            firstAnchor.paragraphIndex == 0 &&
            firstAnchor.characterOffset == 0,
        '$name must start at the fixture origin, not a saved/cached position',
      );
      require(pager()!.widget.mode == mode, '$name effective mode mismatch');
      require(
        _columns(firstPage) == scenario.columns,
        '$name requires ${scenario.columns} actual populated columns at '
        '$viewportSize; do not substitute a pretend viewport or single columns',
      );
      require(
        cold.elapsedMilliseconds < 3000,
        '$name cold layout exceeded 3 seconds',
      );
      _verifySource(
        firstPage.layout as ReaderChapterPages,
        chapters.first.content!,
      );
      for (var warmup = 0; warmup < 2; warmup++) {
        await _checkedTurn(
          name,
          chapters,
          mode: mode,
          columns: scenario.columns,
          crossChapter: scenario.crossChapter,
          viewportSize: viewportSize,
          dpi: dpi,
        );
        sampleMemory();
      }
      // Drain the engine's batched warm-up timings before measuring steady turns.
      await Future<void>.delayed(const Duration(seconds: 1));
      final startNative = await _native();
      _checkForeground(startNative, '$name start');
      final timings = <ui.FrameTiming>[];
      void listener(List<ui.FrameTiming> frames) {
        timings.addAll(frames);
        sampleMemory();
      }

      SchedulerBinding.instance.addTimingsCallback(listener);
      final rss = ProcessInfo.currentRss;
      final submitLatency = <int>[];
      var completedChapterTransitions = 0;
      late Map endNative;
      final phase = Stopwatch()..start();
      try {
        for (var i = 0; i < 20; i++) {
          submitLatency.add(
            await _checkedTurn(
              name,
              chapters,
              mode: mode,
              columns: scenario.columns,
              crossChapter: scenario.crossChapter,
              viewportSize: viewportSize,
              dpi: dpi,
            ),
          );
          if (scenario.crossChapter) completedChapterTransitions++;
          sampleMemory();
        }
        phase.stop();
        endNative = await _native();
        _checkForeground(endNative, '$name end');
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(listener);
      }
      sampleMemory();
      require(
        submitLatency.length == 20 && timings.length >= 20,
        '$name requires twenty committed turns and native timing samples',
      );
      require(
        phase.elapsedMilliseconds < 30000,
        '$name twenty committed turns exceeded thirty seconds',
      );
      if (mode != 'none') {
        require(
          phase.elapsedMilliseconds >=
              20 * (mode == 'simulation' ? 360 : 320) * .8,
          '$name did not finish the requested animation workload',
        );
      }
      final build95 = percentile(
        timings.map((frame) => frame.buildDuration.inMicroseconds).toList(),
        .95,
      );
      final raster95 = percentile(
        timings.map((frame) => frame.rasterDuration.inMicroseconds).toList(),
        .95,
      );
      final command95 = percentile(submitLatency, .95);
      require(build95 <= 33.4, '$name build P95 exceeded 33.4ms: $build95');
      require(raster95 <= 33.4, '$name raster P95 exceeded 33.4ms: $raster95');
      require(
        command95 < 1000,
        '$name Dart command to submitted-frame P95 exceeded one second',
      );
      require(
        peakRss - coldRss < _rssGrowthBudget &&
            peakRss - rss < _rssGrowthBudget &&
            ProcessInfo.currentRss - rss < _rssGrowthBudget &&
            ProcessInfo.maxRss < _processRssBudget,
        '$name exceeded cold/steady sampled RSS growth or process peak budget',
      );
      final dynamic finalPage = pager()!.widget.currentPageId;
      final ReadingPosition anchor = finalPage.page.position(
        finalPage.layout.chapterId,
      );
      require(
        pager()!.widget.mode == mode &&
            _columns(finalPage) == scenario.columns &&
            (pager()!.context.findRenderObject() as RenderBox).size ==
                viewportSize &&
            View.of(pager()!.context).devicePixelRatio == dpi,
        '$name mode, actual viewport, columns or backing scale changed',
      );
      if (scenario.crossChapter) {
        require(
          completedChapterTransitions == 20 && finalPage.chapterIndex == 22,
          '$name lost one of twenty measured chapter transitions or two warmups',
        );
      } else {
        require(
          finalPage.chapterIndex == 0 &&
              finalPage.pageIndex == 22 * scenario.columns,
          '$name must commit two warmups and twenty exact spreads from origin',
        );
      }
      await ReaderSystemService.flushParticipants().timeout(
        const Duration(seconds: 5),
      );
      await ReaderPositionService.flush().timeout(const Duration(seconds: 5));
      final snapshot = await ReaderPositionService().loadSnapshot(bookId);
      final position = snapshot?.position;
      require(
        snapshot != null &&
            position != null &&
            snapshot.chapterIndex == finalPage.chapterIndex &&
            position.chapterId == anchor.chapterId &&
            position.paragraphIndex == anchor.paragraphIndex &&
            position.characterOffset == anchor.characterOffset &&
            finalPage.layout.pageFor(position) == finalPage.pageIndex &&
            (scenario.crossChapter || position.paragraphIndex > 0),
        '$name did not persist the exact committed canonical anchor',
      );
      final metric = <String, Object?>{
        'scenario': name,
        'mode': mode,
        'effectiveMode': pager()!.widget.mode,
        'effectiveColumns': _columns(finalPage),
        'viewportWidth': viewportSize.width,
        'viewportHeight': viewportSize.height,
        'characters': scenario.crossChapter
            ? chapters.fold<int>(
                0,
                (sum, chapter) => sum + chapter.content!.length,
              )
            : text.length,
        'turns': 20,
        'warmupTurns': 2,
        'completedChapterTransitions': completedChapterTransitions,
        'warmupChapterTransitions': scenario.crossChapter ? 2 : 0,
        'finalChapterIndex': finalPage.chapterIndex,
        'finalPageIndex': finalPage.pageIndex,
        'canonicalAnchor': position!.toJson(),
        'turnsMs': phase.elapsedMilliseconds,
        'coldMs': cold.elapsedMilliseconds,
        'frames': timings.length,
        'buildP95Ms': build95,
        'rasterP95Ms': raster95,
        // This measures Dart command -> submitted frame, not physical input
        // -> visible pixel latency. Occluded/headless results are not FPS proof.
        'commandToSubmittedFrameP95Ms': command95,
        'frameTotalSpanP95Ms': percentile(
          timings.map((frame) => frame.totalSpan.inMicroseconds).toList(),
          .95,
        ),
        'rasterOver16_7Ms': timings
            .where((frame) => frame.rasterDuration.inMicroseconds > 16700)
            .length,
        'buildOver16_7Ms': timings
            .where((frame) => frame.buildDuration.inMicroseconds > 16700)
            .length,
        'foregroundAtStart': startNative['foreground'],
        'foregroundAtEnd': endNative['foreground'],
        'windowVisibleAtStart': startNative['windowVisible'],
        'windowVisibleAtEnd': endNative['windowVisible'],
        'devicePixelRatio': dpi,
        'coldRssStartBytes': coldRss,
        'rssStartBytes': rss,
        'rssEndBytes': ProcessInfo.currentRss,
        'rssSampledPeakBytes': peakRss,
        'rssSampledColdPeakGrowthBytes': peakRss - coldRss,
        'rssSampledSteadyPeakGrowthBytes': peakRss - rss,
        'rssGrowthBytes': ProcessInfo.currentRss - rss,
      };
      final timestamps =
          timings
              .map(
                (frame) =>
                    frame.timestampInMicroseconds(ui.FramePhase.buildStart),
              )
              .toList()
            ..sort();
      final gaps = <int>[
        for (var i = 1; i < timestamps.length; i++)
          timestamps[i] - timestamps[i - 1],
      ];
      if (gaps.isNotEmpty) {
        metric['frameStartGapP95Ms'] = percentile(gaps, .95);
        metric['frameStartGapMaxMs'] =
            gaps.reduce((a, b) => a > b ? a : b) / 1000;
      }
      modes.add(metric);
      stdout.writeln('FANQIE_WORKSPACE_PERF_MODE ${jsonEncode(metric)}');
      if (name == 'double-cover') {
        // Preserve the large-body search workload. The last scenario is a
        // short-chapter fixture and must not silently make this index cheaper.
        require(
          text.length >= 100000,
          'Search requires the full large fixture',
        );
        require(
          DesktopCommands.dispatch('find'),
          'Search command was not routed',
        );
        await nextFrame();
        await until(() {
          _checkRunning();
          return queryField('reader-search-query') != null;
        });
        final search = queryField('reader-search-query')!;
        final searching = Stopwatch()..start();
        search.controller!.text = '原文锚点';
        search.onChanged?.call(search.controller!.text);
        await until(() {
          _checkRunning();
          return searchReady();
        });
        searching.stop();
        require(
          searching.elapsedMilliseconds < 3000,
          'Local search exceeded three seconds',
        );
        report['localSearchReadyMs'] = searching.elapsedMilliseconds;
        report['localSearchCharacters'] = text.length;
      }
    }
    require(
      modes.length == 7 &&
          modes.map((mode) => mode['scenario']).toSet().length == 7,
      'Do not report a reduced or duplicated seven-scenario workload',
    );
    report['pagination'] = modes;
    await ReaderSystemService.flushParticipants().timeout(
      const Duration(seconds: 5),
    );
    runApp(const SizedBox.shrink());
    await nextFrame();
    final prefs = await SharedPreferences.getInstance();
    final notes = List.generate(
      5000,
      (i) => ReadingNote(
        id: 'n$i',
        bookId: 'local_perf_notes',
        chapterIndex: 0,
        chapterId: 'c',
        chapterTitle: '笔记章节',
        text: '摘录 $i，保留原文范围。',
        note: '笔记内容 $i',
        createdAt: DateTime.utc(2026, 11, 1),
      ),
    );
    await BookmarkService().rememberBook(
      Book(bookId: 'local_perf_notes', bookName: '5000 条笔记', author: '隔离数据'),
    );
    await prefs.setString(
      'notes_local_perf_notes',
      jsonEncode(notes.map((note) => note.toJson()).toList()),
    );
    BookmarkService().invalidate();
    final notesReady = Stopwatch()..start();
    runApp(const MaterialApp(home: NotesWorkspaceScreen()));
    await nextFrame();
    await until(() {
      _checkRunning();
      return mountedNotes() > 0;
    });
    notesReady.stop();
    require(
      notesReady.elapsedMilliseconds < 3000,
      '5000-note index exceeded 3 seconds',
    );
    require(mountedNotes() < 30, 'Notes workspace did not virtualize cards');
    report['notesReadyMs'] = notesReady.elapsedMilliseconds;
    report['mountedNoteCards'] = mountedNotes();
    require(errors.isEmpty, 'Profile framework errors: $errors');
    require(
      ProcessInfo.maxRss < _processRssBudget,
      'Notes/index process peak RSS exceeded 512 MiB',
    );
    report['rssBytes'] = ProcessInfo.currentRss;
    report['processPeakRssBytes'] = ProcessInfo.maxRss;
    result = 0;
  } catch (error, stack) {
    result = 1;
    stderr.writeln('FANQIE_WORKSPACE_PERF_FAILED $error\n$stack');
  } finally {
    Future<void> cleanupStep(
      String name,
      Future<void> Function() action,
    ) async {
      try {
        await action();
      } catch (error, stack) {
        result = 1;
        stderr.writeln(
          'FANQIE_WORKSPACE_PERF_CLEANUP_FAILED $name: $error\n$stack',
        );
      }
    }

    try {
      final ownedDirectory = root;
      if (ownedDirectory != null) {
        await cleanupStep('detach', () async {
          runApp(const SizedBox.shrink());
          await nextFrame();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        // A failed frame must not skip the writers or safe root cleanup. Keep
        // isolation installed; if writers cannot finish, retain only that root.
        var writersFinished = false;
        await cleanupStep('flush owned writers', () async {
          await Future.wait([
            ReaderSystemService.flushParticipants(),
            BookmarkService().flush(),
            ReaderPositionService.flush(),
            ReaderSettingsRepository.flush(),
            DesktopReaderPreferences.flush(),
          ]).timeout(const Duration(seconds: 5));
          writersFinished = true;
        });
        if (writersFinished) {
          await cleanupStep('owned temporary root', () async {
            if (await ownedDirectory.exists()) {
              final resolved = await ownedDirectory.resolveSymbolicLinks();
              require(
                await FileSystemEntity.type(
                          ownedDirectory.path,
                          followLinks: false,
                        ) ==
                        FileSystemEntityType.directory &&
                    ownedRoot != null &&
                    temporaryParent != null &&
                    path.equals(resolved, ownedRoot) &&
                    path.isWithin(temporaryParent, resolved) &&
                    path.equals(path.dirname(resolved), temporaryParent) &&
                    path
                        .basename(resolved)
                        .startsWith('isolated-workspace-perf-'),
                'Refusing to delete a non-owned/symlink benchmark root',
              );
              await ownedDirectory
                  .delete(recursive: true)
                  .timeout(const Duration(seconds: 5));
            }
            require(
              !await ownedDirectory.exists(),
              'Owned benchmark root remains',
            );
            report?['isolation'] = {
              'storage': 'owned OS temporary directory, absent after cleanup',
              'preferences':
                  'process-local in-memory backend; native domain untouched',
            };
          });
        } else {
          stderr.writeln(
            'FANQIE_WORKSPACE_PERF_ROOT_RETAINED $ownedRoot (writers not settled)',
          );
        }
      }
      for (final signal in signals) {
        await cleanupStep('signal subscription', signal.cancel);
      }
      if (result == 0) {
        _checkRunning();
        require(errors.isEmpty, 'Framework errors during cleanup: $errors');
        require(
          ProcessInfo.maxRss < _processRssBudget,
          'Cleanup process peak RSS exceeded 512 MiB',
        );
        report?['processPeakRssBytes'] = ProcessInfo.maxRss;
        // Success is emitted only after cleanup, not before a failing finally.
        stdout.writeln('FANQIE_WORKSPACE_PERF_OK ${jsonEncode(report)}');
        await stdout.flush();
      }
    } catch (error, stack) {
      result = 1;
      stderr.writeln('FANQIE_WORKSPACE_PERF_CLEANUP_FAILED $error\n$stack');
    } finally {
      AppStorage.documentsOverride = previousDocuments;
      FlutterError.onError = previousFlutterError;
      ui.PlatformDispatcher.instance.onError = previousPlatformError;
    }
  }
  exit(result);
}
