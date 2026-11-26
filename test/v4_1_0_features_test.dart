import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fanqie_flutter/app_theme.dart';
import 'package:fanqie_flutter/immersive/models/immersive_config.dart';
import 'package:fanqie_flutter/immersive/services/immersive_config_service.dart';
import 'package:fanqie_flutter/immersive/services/immersive_database.dart';
import 'package:fanqie_flutter/immersive/services/immersive_job_scheduler.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/services/text_model_adapter.dart';
import 'package:fanqie_flutter/immersive/services/tts_provider_adapter.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/bookshelf_book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/notes_workspace_screen.dart';
import 'package:fanqie_flutter/services/ai_reading_assistant_service.dart';
import 'package:fanqie_flutter/services/app_theme_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/bookshelf_update_cache_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reading_activity_service.dart';
import 'package:fanqie_flutter/services/search_history_service.dart';
import 'package:fanqie_flutter/services/text_replace_rule_service.dart';
import 'package:fanqie_flutter/widgets/reading_activity_dialog.dart';

/// 构造带精确有效音频时长的最小 PCM WAV 字节流
Uint8List _buildMinimalWav({int durationMs = 1500, int sampleRate = 8000}) {
  final numSamples = (sampleRate * durationMs) ~/ 1000;
  final dataSize = numSamples * 2;
  final totalSize = 44 + dataSize;
  final bytes = Uint8List(totalSize);
  final bd = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  bd.setUint32(4, totalSize - 8, Endian.little);
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  bytes.setRange(12, 16, ascii.encode('fmt '));
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  bd.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < numSamples; i++) {
    bd.setInt16(44 + i * 2, ((i * 7) % 400) - 200, Endian.little);
  }
  return bytes;
}

class _NoopTextAdapter implements TextModelAdapter {
  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async => const StructuredModelResponse(
    data: {},
    latencyMs: 1,
    schemaVersion: ImmersiveNativeSchemas.chunkAnalysisVersion,
  );

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async => const StructuredModelResponse(
    data: {},
    latencyMs: 1,
    schemaVersion: ImmersiveNativeSchemas.identityRecheckVersion,
  );

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async => const StructuredModelResponse(
    data: {},
    latencyMs: 1,
    schemaVersion: ImmersiveNativeSchemas.summaryUpdateVersion,
  );

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async => const AnalysisProviderTestResult(
    success: true,
    message: 'ok',
    latencyMs: 1,
    modeUsed: 'mock',
  );

  @override
  void cancelAll() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v4.1.0 功能 #1：沉浸式听书睡眠定时与播完本章停止', () {
    test('定时设置、互斥切换、原生过期回调与预取收敛快照', () async {
      final tmp = await Directory.systemTemp.createTemp('v410_sleep_');
      addTearDown(() => tmp.delete(recursive: true));

      final cfgService = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final base = ImmersivePresetConfig.ensureNativeSystemTts(
        ImmersivePresetConfig.createConfiguredDefault(
          textApiKey: 'test-text-key',
          ttsApiKey: 'test-tts-key',
          featureEnabled: true,
        ),
      );
      await cfgService.saveConfig(base);

      final store = InMemoryImmersiveStateStore();
      await store.initialize();
      addTearDown(store.close);

      var now = DateTime(2026, 11, 26, 22, 0);
      final platformCalls = <String>[];
      final coord = ImmersivePlaybackCoordinator.forTesting(
        configService: cfgService,
        stateStore: store,
        textAdapter: _NoopTextAdapter(),
        ttsAdapter: OpenAiSpeechTtsAdapter(
          MockClient((_) async => http.Response('', 500)),
          nativeSynthesizerOverride: (_) async => _buildMinimalWav(),
        ),
        invoke: (method, args) async {
          platformCalls.add(method);
          return true;
        },
        audioCacheDir: p.join(tmp.path, 'audio'),
        tempDir: p.join(tmp.path, 'tmp'),
        now: () => now,
      );
      addTearDown(coord.dispose);

      coord.setSleepTimer(15);
      expect(coord.hasSleepSchedule, isTrue);
      expect(coord.stopAfterCurrentChapter, isFalse);
      expect(coord.timerRemainingMinutes, 15);
      expect(platformCalls, contains('setSleepDeadline'));

      // 切换为“播完本章停止”时自动取消按分钟倒计时
      coord.setStopAfterCurrentChapter(true);
      expect(coord.stopAfterCurrentChapter, isTrue);
      expect(coord.sleepDeadline, isNull);
      expect(coord.hasSleepSchedule, isTrue);

      // 再次设置分钟定时时自动清除“播完本章停止”
      coord.setSleepTimer(30);
      expect(coord.stopAfterCurrentChapter, isFalse);
      expect(coord.timerRemainingMinutes, 30);

      // 原生发出 onAudioSleepTimer 定时到期事件时应清空定时器
      final deadlineMs = coord.sleepDeadline!.millisecondsSinceEpoch;
      coord.handlePlatformEvent('onAudioSleepTimer', {'deadline': deadlineMs});
      expect(coord.sleepDeadline, isNull);
      expect(coord.hasSleepSchedule, isFalse);

      // 调度需求快照保留 limitPrefetchToCurrentChapter 标志
      final snapshot = SchedulerDemandSnapshot(
        bookId: 'b1',
        bookRevisionId: 'rev1',
        currentChapterIndex: 3,
        targetGlobalOrder: 0,
        playbackRate: 1.0,
        continuousReadySeconds: 10.0,
        paused: false,
        currentManifestSegments: const [],
        currentSegmentIndex: 0,
        limitPrefetchToCurrentChapter: true,
        resolveTtsApiKey: (_) => '',
        resolveTextApiKey: () => '',
      );
      expect(snapshot.limitPrefetchToCurrentChapter, isTrue);
    });
  });

  group('v4.1.0 功能 #2：阅读统计可视化与沉浸式听书打通', () {
    test('按日聚合趋势、连续活跃天数与平均阅读速度计算正确', () async {
      SharedPreferences.setMockInitialValues({});
      var now = DateTime(2026, 11, 24, 9, 0);
      final activity = ReadingActivityService.forTesting(now: () => now);
      addTearDown(activity.dispose);
      await activity.reload();
      await activity.setEnabled(true);

      final book = Book(bookId: 'stat_1', bookName: '统计测试书', author: '作者');
      var offset = 0;
      activity.attach(
        Object(),
        book,
        active: () => true,
        automatic: () => true,
        position: () => ReadingActivityPosition('c1', offset, 20000),
      );

      // 连续 3 天：11-24 看书 90 秒 + 11-25 听书 60 秒 + 11-26 听书 120 秒
      for (var i = 0; i < 90; i++) {
        now = now.add(const Duration(seconds: 1));
        offset += 10;
        activity.tick();
      }
      now = DateTime(2026, 11, 25, 10, 0);
      activity.tick(); // 更新基准时刻
      for (var i = 0; i < 60; i++) {
        now = now.add(const Duration(seconds: 1));
        activity.tick(listeningBookId: book.bookId, listeningTitle: book.bookName);
      }
      now = DateTime(2026, 11, 26, 11, 0);
      activity.tick();
      for (var i = 0; i < 120; i++) {
        now = now.add(const Duration(seconds: 1));
        activity.tick(listeningBookId: book.bookId, listeningTitle: book.bookName);
      }

      expect(activity.totalReadingMs, greaterThanOrEqualTo(89000));
      expect(activity.totalListeningMs, greaterThanOrEqualTo(178000));
      expect(activity.averageCharsPerMinute, isNotNull);
      expect(activity.currentStreakDays(anchor: now), 3);

      final daily7 = activity.recentDailyStats(7, anchor: now);
      expect(daily7.length, 7);
      expect(ReadingActivityService.dayKeyOf(daily7.last.date), '2026-11-26');
      expect(daily7.last.listeningMs, greaterThan(0));
    });

    testWidgets('ReadingActivityDialog 渲染报表并支持 7 天/30 天切换', (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_activity_enabled': true,
        'reader_activity_v1': jsonEncode({
          'books': {
            'b1': {
              'title': '测试小说一',
              'reading_ms': 1800000,
              'listening_ms': 900000,
              'characters': 15000,
            },
          },
          'days': {
            ReadingActivityService.dayKeyOf(DateTime.now()): {
              'reading_ms': 1800000,
              'listening_ms': 900000,
            },
          },
        }),
      });
      await ReadingActivityService().reload();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: const Scaffold(body: ReadingActivityDialog()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('阅读与听书统计'), findsOneWidget);
      expect(find.text('今日看书'), findsOneWidget);
      expect(find.text('今日听书'), findsOneWidget);
      expect(find.text('连续活跃'), findsOneWidget);
      expect(find.text('每日趋势'), findsOneWidget);
      expect(find.text('近 12 周活跃热力图'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reading-activity-bar-chart')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reading-activity-heatmap')),
        findsOneWidget,
      );

      await tester.tap(find.text('30 天'));
      await tester.pumpAndSettle();
      expect(find.text('测试小说一'), findsOneWidget);
    });
  });

  group('v4.1.0 功能 #3：全局外围深色模式', () {
    test('支持四种模式持久化及跟随阅读日夜模式动态解析', () async {
      SharedPreferences.setMockInitialValues({});
      final service = AppThemeService();
      await service.reload();
      expect(service.preference, AppThemePreference.system);
      expect(
        service.resolveThemeMode(platformBrightness: Brightness.light),
        ThemeMode.system,
      );

      await service.setPreference(AppThemePreference.dark);
      expect(
        service.resolveThemeMode(platformBrightness: Brightness.light),
        ThemeMode.dark,
      );

      await service.setPreference(AppThemePreference.light);
      expect(
        service.resolveThemeMode(platformBrightness: Brightness.dark),
        ThemeMode.light,
      );

      await service.setPreference(AppThemePreference.followReader);
      // 阅读器设为夜间主题（索引 3 为深色夜间主题）
      service.syncReaderSettings(
        const ReaderSettings(themeMode: ReaderThemeMode.manual, themeIndex: 3),
      );
      expect(
        service.resolveThemeMode(platformBrightness: Brightness.light),
        ThemeMode.dark,
      );

      // 阅读器切回日间主题（索引 0 为浅色主题）
      service.syncReaderSettings(
        const ReaderSettings(themeMode: ReaderThemeMode.manual, themeIndex: 0),
      );
      expect(
        service.resolveThemeMode(platformBrightness: Brightness.dark),
        ThemeMode.light,
      );
    });
  });

  group('v4.1.0 功能 #4：移动端跨书笔记工作台窄屏折叠适配', () {
    testWidgets('窄屏默认收起筛选区并支持点击展开', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: const Scaffold(body: NotesWorkspaceScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const ValueKey('notes-workspace-filter-toggle'));
      expect(toggle, findsOneWidget);
      expect(find.byKey(const ValueKey('notes-workspace-book')), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('notes-workspace-book')), findsOneWidget);
    });
  });

  group('v4.1.0 功能 #5：防剧透 AI 阅读助手', () {
    test('严格截断未读章节与当前章未读段落，并支持主备故障转移与思考标签剥离', () async {
      final tmp = await Directory.systemTemp.createTemp('v410_ai_');
      addTearDown(() => tmp.delete(recursive: true));

      final cfgService = ImmersiveConfigService(
        documents: () async => tmp,
        secretStore: MemoryImmersiveSecretStore(),
      );
      final cfg = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'secret-test-key',
        ttsApiKey: 'secret-tts-key',
        featureEnabled: true,
      );
      await cfgService.saveConfig(cfg);

      final capturedPrompts = <String>[];
      var callCount = 0;
      final mockHttp = MockClient((request) async {
        callCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final msgs = body['messages'] as List;
        capturedPrompts.add(msgs.last['content'].toString());
        // 第 1 次主模型返回 500，验证自动故障转移到兜底模型
        if (callCount == 1) {
          return http.Response('upstream error', 500);
        }
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': '<think>内部推理过程</think>1. 主角林渊初入青云宗。\n2. 师姐苏晚晴出场。',
                  },
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      final service = AiReadingAssistantService.forTesting(
        httpClient: mockHttp,
        configService: cfgService,
      );

      final chapters = [
        Chapter(itemId: 'c0', title: '第一章 初入山门', order: 1),
        Chapter(itemId: 'c1', title: '第二章 藏经阁', order: 2),
        Chapter(itemId: 'c2', title: '第三章 大结局剧透', order: 3),
      ];
      final loadedChapters = <int>[];
      final texts = <int, String>{
        0: '林渊背着行囊登上青云山。\n\n他在山门遇到师姐苏晚晴。',
        1: '藏经阁第一层摆满古籍。\n\n后文剧透秘密：其实掌门是反派！',
        2: '最终决战剧透：林渊飞升成仙！',
      };

      final recap = await service.generateRecap(
        bookId: 'book_ai_1',
        bookName: '青云录',
        chapters: chapters,
        currentChapterIndex: 1,
        currentParagraphIndex: 0, // 仅读到第 2 章第 1 段
        windowChapters: 5,
        chapterLoader: (idx) async {
          loadedChapters.add(idx);
          return texts[idx];
        },
      );

      expect(loadedChapters, [0, 1]);
      expect(loadedChapters, isNot(contains(2)));
      expect(callCount, 2); // 主模型失败后自动切换到兜底模型
      expect(capturedPrompts.last, contains('藏经阁第一层摆满古籍'));
      expect(capturedPrompts.last, isNot(contains('掌门是反派')));
      expect(capturedPrompts.last, isNot(contains('飞升成仙')));
      expect(recap.content, isNot(contains('<think>')));
      expect(recap.content, contains('林渊初入青云宗'));

      // 词条速查同样严格防剧透
      callCount = 1; // 让本次直接成功
      final lookup = await service.lookupTerm(
        bookId: 'book_ai_1',
        bookName: '青云录',
        term: '苏晚晴',
        chapters: chapters,
        currentChapterIndex: 1,
        currentParagraphIndex: 0,
        chapterLoader: (idx) async => texts[idx],
      );
      expect(lookup.matchedSnippets.length, 1);
      expect(lookup.matchedSnippets.first, contains('师姐苏晚晴'));
    });
  });

  group('v4.1.0 功能 #6：正文净化与替换规则引擎及偏移映射', () {
    test('正则/文本替换、单书作用域、偏移映射、TTS 清洗与备份合并', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = TextReplaceRuleService();
      await svc.reload();

      final added = await svc.installBuiltinTemplates();
      expect(added, greaterThanOrEqualTo(3));

      await svc.upsertRule(
        TextReplaceRule(
          id: 'rule_book_only',
          name: '单书改名',
          pattern: '张三',
          replacement: '李四四',
          scopeBookId: 'book_a',
          applyToReader: true,
          applyToTts: false,
        ),
      );

      // 验证广告净化 + 单书作用域 + 偏移映射保真
      const raw = '求月票求推荐！前面张三说道：你好世界。';
      final mappedA = svc.applyForDisplay(raw, bookId: 'book_a');
      expect(mappedA.modified, isTrue);
      expect(mappedA.text, '前面李四四说道：你好世界。');

      // 原文中「你好世界」位于 raw 的 [14, 18)，映射后应精准命中展示文本的「你好世界」
      final rawHelloStart = raw.indexOf('你好世界');
      final rawHelloEnd = rawHelloStart + 4;
      final projected = mappedA.mapRawRange(rawHelloStart, rawHelloEnd);
      expect(
        mappedA.text.substring(projected.start, projected.end),
        '你好世界',
      );

      // 其他书籍不应触发单书规则，但全局去广告规则生效
      final mappedB = svc.applyForDisplay(raw, bookId: 'book_b');
      expect(mappedB.text, '前面张三说道：你好世界。');

      // TTS 清洗跳过 applyToTts=false 的单书规则，保留去广告规则
      final ttsClean = svc.applyForTts(raw, bookId: 'book_a');
      expect(ttsClean, '前面张三说道：你好世界。');

      // JSON 导出与导入
      final exported = svc.exportRulesJson();
      await svc.deleteRule('rule_book_only');
      expect(svc.rules.any((r) => r.id == 'rule_book_only'), isFalse);
      final importedCount = await svc.importRulesJson(exported);
      expect(importedCount, greaterThanOrEqualTo(1));
      expect(svc.rules.any((r) => r.id == 'rule_book_only'), isTrue);

      // 备份合并白名单支持新键
      expect(ReaderBackupService.allowedKey(AppThemeService.preferencesKey), isTrue);
      expect(
        ReaderBackupService.allowedKey(TextReplaceRuleService.preferencesKey),
        isTrue,
      );
      expect(
        ReaderBackupService.allowedKey(SearchHistoryService.preferencesKey),
        isTrue,
      );
    });
  });

  group('v4.1.0 功能 #7：搜索历史服务', () {
    test('去重置顶、20 条上限、单删、清空与多端合并', () async {
      SharedPreferences.setMockInitialValues({});
      final history = SearchHistoryService();
      await history.reload();

      for (var i = 1; i <= 25; i++) {
        await history.addKeyword('关键词$i');
      }
      expect(history.items.length, SearchHistoryService.maxEntries);
      expect(history.items.first, '关键词25');

      await history.addKeyword('关键词10');
      expect(history.items.first, '关键词10');

      await history.removeKeyword('关键词10');
      expect(history.items, isNot(contains('关键词10')));

      final merged = SearchHistoryService.decodeHistory(
        SearchHistoryService.mergeEncoded(
          jsonEncode(['甲', '乙']),
          jsonEncode(['乙', '丙']),
        ),
      );
      expect(merged, ['甲', '乙', '丙']);

      await history.clearAll();
      expect(history.items, isEmpty);
    });
  });

  group('v4.1.0 功能 #8：书架置顶与一键增量离线缓存', () {
    test('书架置顶持久化排序优先于普通阅读时间', () async {
      SharedPreferences.setMockInitialValues({});
      final shelf = BookshelfService();
      await shelf.reload();

      await shelf.addToBookshelf(
        Book(bookId: 'b1', bookName: '第一本', author: '作者A'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await shelf.addToBookshelf(
        Book(bookId: 'b2', bookName: '第二本', author: '作者B'),
      );

      // 默认最新加入在前
      expect(shelf.books.first.bookId, 'b2');

      // 置顶第一本后应排在首位
      final pinned = await shelf.togglePin('b1');
      expect(pinned, isTrue);
      expect(shelf.books.first.bookId, 'b1');
      expect(shelf.books.first.isPinned, isTrue);

      // 重载后置顶状态保持
      await shelf.reload();
      expect(shelf.books.first.bookId, 'b1');
      expect(shelf.books.first.isPinned, isTrue);

      // 取消置顶后恢复顺序
      await shelf.togglePin('b1');
      expect(shelf.books.first.bookId, 'b2');
    });

    test('一键增量缓存仅拉取未离线新章节并跳过本地书', () async {
      final downloadedByBook = <String, List<String>>{};
      final clearedBadges = <String>[];

      final cacheService = BookshelfUpdateCacheService(
        loadDirectory: (bookId) async => [
          Chapter(itemId: '${bookId}_c1', title: '第1章', order: 1),
          Chapter(itemId: '${bookId}_c2', title: '第2章', order: 2),
          Chapter(itemId: '${bookId}_c3', title: '第3章', order: 3),
        ],
        isChapterOffline: (bookId, itemId) async => itemId.endsWith('_c1'),
        downloadChapters: ({
          required String bookId,
          required List<Chapter> chapters,
          void Function(int current, int total, String message)? onProgress,
          bool Function()? isCancelled,
        }) async {
          downloadedByBook[bookId] = chapters.map((c) => c.itemId).toList();
          onProgress?.call(chapters.length, chapters.length, '完成');
        },
        clearUpdateBadge: (bookId) async => clearedBadges.add(bookId),
      );

      final candidates = [
        BookshelfBook(
          bookId: 'online_1',
          bookName: '连载玄幻',
          author: '作者',
          hasUpdate: true,
        ),
        BookshelfBook(
          bookId: 'local_999',
          bookName: '本地导入书',
          author: '本地',
          hasUpdate: true,
        ),
      ];

      final summary = await cacheService.cacheUpdatedBooks(candidates);
      expect(summary.scannedBooks, 1);
      expect(summary.updatedBooks, 1);
      expect(summary.cachedChapters, 2);
      expect(downloadedByBook['online_1'], ['online_1_c2', 'online_1_c3']);
      expect(downloadedByBook.containsKey('local_999'), isFalse);
      expect(clearedBadges, ['online_1']);
    });
  });

  group('v4.1.0 功能 #9：沉浸式听书系统朗读与固定旁白音色', () {
    test('幂等注入 native_tts、免密钥校验放行、离线 WAV 合成与设为默认旁白', () async {
      final base = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'valid-text-key',
        ttsApiKey: 'valid-tts-key',
        featureEnabled: true,
      );

      final withNative = ImmersivePresetConfig.ensureNativeSystemTts(base);
      final withNativeAgain = ImmersivePresetConfig.ensureNativeSystemTts(
        withNative,
      );
      expect(withNative.tts.providers.length, base.tts.providers.length + 1);
      expect(withNativeAgain.tts.providers.length, withNative.tts.providers.length);

      // 将默认旁白设为系统朗读，且无需为系统朗读填写 API Key，整体验证应通过
      final narratorCfg = withNative.copyWith(
        bookDefaults: withNative.bookDefaults.copyWith(
          narratorVoiceProfileId:
              ImmersivePresetConfig.nativeSystemVoiceProfileId,
        ),
      );
      final issues = ImmersiveConfigValidator.validateConfig(narratorCfg);
      expect(issues, isEmpty);

      // 解析出系统朗读音色并构造 RenderSpec
      final resolution = narratorCfg.resolveVoiceProfile(
        ImmersivePresetConfig.nativeSystemVoiceProfileId,
      );
      expect(resolution, isNotNull);
      expect(resolution!.provider.adapter, 'native_tts');

      final spec = RenderSpec.fromResolution(
        resolution: resolution,
        inputText: '夜幕降临，青云山巅云雾缭绕。',
      );
      expect(spec.adapterVersion, startsWith('native_tts:'));
      expect(spec.audioFormat, 'wav');

      // 适配器命中 native_tts 路径：零网络请求，调用本地合成器并校验 WAV 音频与时长
      var httpCalled = false;
      var nativeCalled = false;
      final adapter = OpenAiSpeechTtsAdapter(
        MockClient((_) async {
          httpCalled = true;
          return http.Response('should not call network', 500);
        }),
        nativeSynthesizerOverride: (capturedSpec) async {
          nativeCalled = true;
          expect(capturedSpec.inputText, contains('青云山巅'));
          return _buildMinimalWav(durationMs: 1800);
        },
      );

      final payload = await adapter.synthesize(
        spec: spec,
        apiKey: '',
        timeoutMs: 15000,
      );
      expect(httpCalled, isFalse);
      expect(nativeCalled, isTrue);
      expect(payload.detectedFormat, 'wav');
      expect(payload.durationMs, greaterThanOrEqualTo(1500));
    });
  });
}
