// Dedicated AOT Profile entry. No everyday preferences or reading files are
// used; do not package this target as the client.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/main.dart' as application;
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/notes_workspace_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/desktop_commands.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/desktop_shortcuts.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  await until(() => !state.isBusy);
  require(state.currentPageId != before, 'Profile page turn did not commit');
  return submitted.elapsedMicroseconds;
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
  var result = 1;
  try {
    require(kProfileMode, 'This benchmark requires --profile');
    SharedPreferences.setMockInitialValues({});
    root = await (await AppStorage.documents()).createTemp(
      'isolated-workspace-perf-',
    );
    AppStorage.documentsOverride = () async => root!;
    await application.initializeReaderApplication();
    await ReaderPlatform.invoke('showMainWindow');
    final text = List.generate(
      500,
      (i) => '第$i段。性能验收使用隔离正文，分页、选择与返回必须保持原文锚点。' * 6,
    ).join('\n\n');
    require(text.length >= 100000, 'Expected a 100k-character fixture');
    final report = <String, Object?>{
      'mode': 'AOT Profile',
      'system': Platform.operatingSystemVersion,
      'characters': text.length,
      'native': await ReaderPlatform.invoke<Map>('getReaderCapabilities'),
    };
    final modes = <Map<String, Object?>>[];
    for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $mode detach');
      // Do not mistake a still-mounted previous route for the next mode.
      runApp(const SizedBox.shrink());
      await nextFrame();
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $mode detached');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ReaderPositionService.flush();
      await ReaderSettingsRepository.flush();
      stdout.writeln('FANQIE_WORKSPACE_PERF_PHASE $mode mount');
      final cold = Stopwatch()..start();
      runApp(
        MaterialApp(
          key: ValueKey('profile-$mode'),
          builder: (context, child) => DesktopShortcuts(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: false),
              child: child!,
            ),
          ),
          home: ReaderScreen(
            key: ValueKey(mode),
            book: Book(
              bookId: 'local_perf_$mode',
              bookName: '性能隔离正文',
              author: '测试',
            ),
            chapters: [Chapter(itemId: 'c', title: '第一章', content: text)],
            bookDocuments: () async => root!,
            resumeSavedPosition: false,
            initialSettings: ReaderSettingsRecord(
              ReaderSettings(
                pageMode: true,
                pageAnimation: mode,
                commentBubbles: false,
                showHeader: false,
                showStatus: false,
              ),
            ),
          ),
        ),
      );
      await nextFrame();
      await until(
        () =>
            pager() != null && pager()!.widget.mode == mode && !pager()!.isBusy,
      );
      cold.stop();
      require(
        cold.elapsedMilliseconds < 3000,
        '$mode cold layout exceeded 3 seconds',
      );
      await turn();
      await turn();
      // Drain the engine's batched warm-up timings before measuring steady turns.
      await Future<void>.delayed(const Duration(seconds: 1));
      final timings = <ui.FrameTiming>[];
      void listener(List<ui.FrameTiming> frames) => timings.addAll(frames);
      SchedulerBinding.instance.addTimingsCallback(listener);
      final rss = ProcessInfo.currentRss;
      final submitLatency = <int>[];
      final phase = Stopwatch()..start();
      try {
        for (var i = 0; i < 20; i++) {
          submitLatency.add(await turn());
        }
        phase.stop();
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(listener);
      }
      require(
        timings.length >= 20,
        '$mode did not report native frame timings',
      );
      if (mode != 'none') {
        require(
          phase.elapsedMilliseconds >=
              20 * (mode == 'simulation' ? 360 : 320) * .8,
          '$mode did not finish the requested animation workload',
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
      require(build95 <= 33.4, '$mode build P95 exceeded 33.4ms: $build95');
      require(raster95 <= 33.4, '$mode raster P95 exceeded 33.4ms: $raster95');
      require(
        ProcessInfo.currentRss - rss < 128 * 1024 * 1024,
        '$mode unbounded RSS growth',
      );
      await ReaderSystemService.flushParticipants();
      final position = await ReaderPositionService().load('local_perf_$mode');
      require(
        position != null && position.paragraphIndex > 0,
        '$mode lost reading progress',
      );
      final metric = <String, Object?>{
        'mode': mode,
        'effectiveMode': pager()!.widget.mode,
        'turnsMs': phase.elapsedMilliseconds,
        'coldMs': cold.elapsedMilliseconds,
        'frames': timings.length,
        'buildP95Ms': build95,
        'rasterP95Ms': raster95,
        // This measures Dart command -> submitted frame, not physical input
        // -> visible pixel latency. Occluded/headless results are not FPS proof.
        'commandToSubmittedFrameP95Ms': percentile(submitLatency, .95),
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
        'devicePixelRatio': WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .first
            .devicePixelRatio,
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
    }
    report['pagination'] = modes;
    DesktopCommands.dispatch('find');
    await WidgetsBinding.instance.endOfFrame;
    await until(() => queryField('reader-search-query') != null);
    final search = queryField('reader-search-query')!;
    final searching = Stopwatch()..start();
    search.controller!.text = '原文锚点';
    search.onChanged?.call(search.controller!.text);
    await until(searchReady);
    searching.stop();
    require(
      searching.elapsedMilliseconds < 3000,
      'Local search exceeded 3 seconds',
    );
    report['localSearchReadyMs'] = searching.elapsedMilliseconds;
    await ReaderSystemService.flushParticipants();
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
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
    await WidgetsBinding.instance.endOfFrame;
    await until(() => mountedNotes() > 0);
    notesReady.stop();
    require(
      notesReady.elapsedMilliseconds < 3000,
      '5000-note index exceeded 3 seconds',
    );
    require(mountedNotes() < 30, 'Notes workspace did not virtualize cards');
    report['notesReadyMs'] = notesReady.elapsedMilliseconds;
    report['mountedNoteCards'] = mountedNotes();
    require(errors.isEmpty, 'Profile framework errors: $errors');
    report['rssBytes'] = ProcessInfo.currentRss;
    stdout.writeln('FANQIE_WORKSPACE_PERF_OK ${jsonEncode(report)}');
    await stdout.flush();
    result = 0;
  } catch (error, stack) {
    stderr.writeln('FANQIE_WORKSPACE_PERF_FAILED $error\n$stack');
  } finally {
    runApp(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await BookmarkService().flush();
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    await DesktopReaderPreferences.flush();
    AppStorage.documentsOverride = null;
    if (root != null && await root.exists()) await root.delete(recursive: true);
  }
  exit(result);
}
