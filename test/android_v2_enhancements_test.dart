import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fanqie_flutter/immersive/models/immersive_entities.dart';
import 'package:fanqie_flutter/immersive/services/immersive_playback_coordinator.dart';
import 'package:fanqie_flutter/immersive/services/immersive_preset_config.dart';
import 'package:fanqie_flutter/immersive/widgets/immersive_pipeline_tab.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/book_detail_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/services/reading_history_service.dart';
import 'package:fanqie_flutter/widgets/quote_share_card_sheet.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';

class _FakeDetailApiService extends ApiService {
  @override
  Future<Book?> getBookDetail(String bookId) async {
    return Book(
      bookId: bookId,
      bookName: '雪中测试传',
      author: '测试作者',
      abstract: '一段测试简介文本，用来校验详情页不误写阅读历史以及听书入口展示。',
    );
  }

  @override
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) async {
    return [
      Chapter(itemId: 'c1', title: '第一章 初入江湖'),
      Chapter(itemId: 'c2', title: '第二章 剑气长虹'),
    ];
  }

  @override
  Future<List<Book>> searchBooks(String keyword, {int offset = 0}) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ReadingHistoryService().reload();
    await ReaderSystemService.setMediaButtonBehavior(
      MediaButtonBehavior.segment,
    );
  });

  group('Android 二三期增强功能回归验证', () {
    test('蓝牙/车载媒体上下曲键映射支持解析与持久化', () async {
      expect(MediaButtonBehaviorX.parse(null), MediaButtonBehavior.segment);
      expect(MediaButtonBehaviorX.parse('seek15s'), MediaButtonBehavior.seek15s);
      expect(MediaButtonBehaviorX.parse('chapter'), MediaButtonBehavior.chapter);

      await ReaderSystemService.setMediaButtonBehavior(
        MediaButtonBehavior.seek15s,
      );
      expect(
        ReaderSystemService.mediaButtonBehavior,
        MediaButtonBehavior.seek15s,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('android_media_button_behavior_v1'),
        'seek15s',
      );
    });

    testWidgets('金句书摘分享卡片支持 4 种风格切换、开关与文案复制', (tester) async {
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copiedText = (call.arguments as Map)['text']?.toString();
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => QuoteShareCardSheet.show(
                  context,
                  quote: '天地不仁，以万物为刍狗。',
                  bookName: '诛仙',
                  author: '萧鼎',
                  chapterTitle: '第一章 青云',
                  noteText: '经典开篇名句',
                ),
                child: const Text('打开金句卡'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开金句卡'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('quote-share-card-preview')), findsOneWidget);
      expect(find.text('天地不仁，以万物为刍狗。'), findsOneWidget);
      expect(find.text('经典开篇名句'), findsOneWidget);
      expect(find.text('《诛仙》'), findsOneWidget);

      // 切换配色风格
      await tester.tap(find.text('墨夜星空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('竹韵墨绿'));
      await tester.pumpAndSettle();

      // 隐藏想法
      await tester.tap(find.text('显示我的想法'));
      await tester.pumpAndSettle();
      expect(find.text('经典开篇名句'), findsNothing);

      // 复制文案
      await tester.tap(find.text('复制文案'));
      await tester.pumpAndSettle();
      expect(copiedText, contains('天地不仁，以万物为刍狗。'));
      expect(copiedText, contains('《诛仙》'));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '打开书籍详情页不会自动污染阅读历史，且移动端显示听书快捷按钮',
      (tester) async {
        ReaderPlatform.resetForTesting();
        addTearDown(ReaderPlatform.resetForTesting);

        final fakeApi = _FakeDetailApiService();
        await tester.pumpWidget(
          MaterialApp(
            home: BookDetailScreen(
              book: Book(
                bookId: 'detail-no-history-1',
                bookName: '雪中测试传',
                author: '测试作者',
              ),
              apiService: fakeApi,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final histories = await ReadingHistoryService().getHistoryList();
        expect(histories, isEmpty);
        expect(
          find.byKey(const ValueKey('book-detail-listen-btn')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      '安卓平板/折叠屏宽屏视口下排版设置开放双栏选项',
      (tester) async {
        ReaderPlatform.resetForTesting();
        addTearDown(ReaderPlatform.resetForTesting);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(840, 900);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderSettingsSheet(
                bookId: 'wide-test',
                settings: const ReaderSettings(),
                bookOverride: false,
                onChanged: (_, _) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('排版字体'));
        await tester.pumpAndSettle();

        expect(find.text('宽屏 / 平板双栏'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('沉浸式管线面板支持通勤预合成触发与蓝牙按键行为切换', (tester) async {
      final cfg = ImmersivePresetConfig.createConfiguredDefault(
        textApiKey: 'sk-test',
        ttsApiKey: 'sk-tts',
      );
      int? requestedChapters;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImmersivePipelineTab(
              config: cfg,
              pipelineStatus: const PipelineStatus(),
              coordinator: ImmersivePlaybackCoordinator(),
              hasBookContext: true,
              rebuilding: false,
              onDraftChanged: (_) {},
              onApplyAndSaveConfig: (_, _) async => true,
              onResetFailover: () {},
              onRebuildPressed: (_) async {},
              onPreSynthesizePressed: (count) async {
                requestedChapters = count;
              },
              onRetryBlocked: () async {},
              onClearUnpinnedCache: () async {},
              onReload: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 滚动并点击预合成后 5 章
      final presynthBtn = find.byKey(const ValueKey('presynth-5-btn'));
      await tester.scrollUntilVisible(presynthBtn, 200);
      await tester.tap(presynthBtn);
      await tester.pumpAndSettle();
      expect(requestedChapters, 5);

      // 切换蓝牙按键映射至快进/快退 15 秒
      final seekChip = find.byKey(const ValueKey('media-btn-seek15s'));
      await tester.scrollUntilVisible(seekChip, 200);
      await tester.tap(seekChip);
      await tester.pumpAndSettle();
      expect(
        ReaderSystemService.mediaButtonBehavior,
        MediaButtonBehavior.seek15s,
      );
      expect(tester.takeException(), isNull);
    });

    for (final pageMode in [true, false]) {
      testWidgets(
        'Android ${pageMode ? "左右翻页" : "上下滚动"}模式支持长按拖拽跨多段选择文本、复制与跨段划线',
        (tester) async {
          ReaderPlatform.resetForTesting();
          addTearDown(ReaderPlatform.resetForTesting);
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(420, 840);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          String? copiedText;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method == 'Clipboard.setData') {
                  copiedText = (call.arguments as Map)['text']?.toString();
                }
                return null;
              });
          addTearDown(() {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null);
          });

          const para1 = '第一段风起青萍之末，少年提剑出门远行。';
          const para2 = '第二段星河垂落山野，长夜将明万物复苏。';
          const para3 = '第三段沧海桑田变幻，初心如磐终不移。';
          final extraParas = List.generate(
            18,
            (i) => '续段${i + 4}：远山含黛烟波浩渺，行舟破浪向前，书页翻动间岁月流转不停歇，故人旧梦犹在眼前。',
          );
          final bookId = 'multi-para-select-${pageMode ? "page" : "scroll"}';

          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('reader_is_page_mode', pageMode);
          await prefs.setString('reader_page_turn_animation', 'slide');

          await tester.pumpWidget(
            MaterialApp(
              home: ReaderScreen(
                book: Book(
                  bookId: bookId,
                  bookName: '跨段选词测试书',
                  author: '测试作者',
                ),
                chapters: [
                  Chapter(
                    itemId: 'ch1',
                    title: '第一章 测试章节',
                    content: [para1, para2, para3, ...extraParas].join('\n\n'),
                  ),
                ],
                resumeSavedPosition: false,
              ),
            ),
          );
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }

          final p1Key = ValueKey(
            pageMode ? 'reader-paragraph-page_ch1_0_0' : 'reader-paragraph-ch1_0',
          );
          final p2Key = ValueKey(
            pageMode ? 'reader-paragraph-page_ch1_0_1' : 'reader-paragraph-ch1_1',
          );
          expect(find.byKey(p1Key), findsOneWidget);
          expect(find.byKey(p2Key), findsOneWidget);

          final rect1 = tester.getRect(find.byKey(p1Key));
          final rect2 = tester.getRect(find.byKey(p2Key));

          // 模拟真实手机触屏：在第一段首行长按触发选词后直接向下拖至第二段末尾松手
          final startPoint = Offset(rect1.left + 48, rect1.top + 10);
          final endPoint = Offset(rect2.right - 24, rect2.bottom - 6);
          final gesture = await tester.startGesture(startPoint);
          await tester.pump(const Duration(milliseconds: 600));
          await gesture.moveTo(endPoint);
          await tester.pump(const Duration(milliseconds: 120));
          await gesture.up();
          await tester.pumpAndSettle();

          // 应同时出现跨段气泡菜单（复制、跨段划线、跨段笔记、分享卡片）
          expect(
            find.byKey(const ValueKey('desktop-copy-paragraphs')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('desktop-highlight-range')),
            findsOneWidget,
          );
          expect(find.text('分享卡片'), findsOneWidget);

          // 点击复制验证多段文本完整进入剪贴板且带段落分隔
          await tester.tap(
            find.byKey(const ValueKey('desktop-copy-paragraphs')),
          );
          await tester.pumpAndSettle();
          expect(copiedText, isNotNull);
          expect(copiedText, contains('少年提剑出门远行'));
          expect(copiedText, contains('第二段'));
          expect(copiedText, contains('\n\n'));

          // 再次长按跨段并点击「跨段划线」，验证跨段笔记持久化
          final gesture2 = await tester.startGesture(startPoint);
          await tester.pump(const Duration(milliseconds: 600));
          await gesture2.moveTo(endPoint);
          await tester.pump(const Duration(milliseconds: 120));
          await gesture2.up();
          await tester.pumpAndSettle();

          await tester.tap(
            find.byKey(const ValueKey('desktop-highlight-range')),
          );
          await tester.pumpAndSettle();
          final notes = await BookmarkService().getNotes(bookId);
          expect(notes, isNotEmpty);
          expect(notes.first.isSpanning, isTrue);

          if (pageMode) {
            // 验证翻页模式下左滑翻页不受 SelectionArea 干扰，且翻到下一页后依然支持长按跨多段选词
            await tester.drag(find.byType(ReaderPageView), const Offset(-300, 0));
            await tester.pumpAndSettle();
            final page2Texts = find.byWidgetPredicate(
              (w) =>
                  w is Text &&
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith(
                    'reader-paragraph-page_ch1_1_',
                  ),
            );
            expect(page2Texts.evaluate().length, greaterThanOrEqualTo(2));
            final page2FirstRect = tester.getRect(page2Texts.at(0));
            final page2SecondRect = tester.getRect(page2Texts.at(1));
            copiedText = null;
            final gPage2 = await tester.startGesture(
              Offset(page2FirstRect.left + 48, page2FirstRect.top + 10),
            );
            await tester.pump(const Duration(milliseconds: 600));
            await gPage2.moveTo(
              Offset(page2SecondRect.right - 24, page2SecondRect.bottom - 6),
            );
            await tester.pump(const Duration(milliseconds: 120));
            await gPage2.up();
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('desktop-copy-paragraphs')),
              findsOneWidget,
            );
            await tester.tap(
              find.byKey(const ValueKey('desktop-copy-paragraphs')),
            );
            await tester.pumpAndSettle();
            expect(copiedText, contains('\n\n'));
          }

          // 取消选区后轻点正文中央仍可正常呼出工具栏
          await tester.tapAt(const Offset(210, 420));
          await tester.pumpAndSettle();
          expect(find.text('排版设置'), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }

    testWidgets(
      'Android 窄屏阅读长按单段与跨段选词时全部菜单项自适应展示且分享卡片可点击',
      (tester) async {
        ReaderPlatform.resetForTesting();
        addTearDown(ReaderPlatform.resetForTesting);
        tester.view.devicePixelRatio = 1.0;
        // 模拟经典小屏安卓手机（360x780），验证菜单自动折行不被 44dp 裁切
        tester.view.physicalSize = const Size(360, 780);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        const para1 = '第一段清风拂面，长夜将尽晨光微露。';
        const para2 = '第二段江河奔涌，少年仗剑行万里路。';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('reader_is_page_mode', false);

        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(
              book: Book(
                bookId: 'narrow-selection-menu-test',
                bookName: '窄屏选词测试书',
                author: '测试作者',
              ),
              chapters: [
                Chapter(
                  itemId: 'ch1',
                  title: '第一章 窄屏测试',
                  content: '$para1\n\n$para2',
                ),
              ],
              resumeSavedPosition: false,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        final p1Rect = tester.getRect(
          find.byKey(const ValueKey('reader-paragraph-ch1_0')),
        );
        final p2Rect = tester.getRect(
          find.byKey(const ValueKey('reader-paragraph-ch1_1')),
        );

        // 1. 单段长按选词：校验全部 5 个按钮完整落在气泡与屏幕内，且未撑满整屏
        await tester.longPressAt(Offset(p1Rect.left + 64, p1Rect.top + 10));
        await tester.pumpAndSettle();

        final toolbarFinder = find.byKey(
          const ValueKey('adaptive-selection-bubble-toolbar'),
        );
        expect(toolbarFinder, findsOneWidget);
        final toolbarRect = tester.getRect(toolbarFinder);
        expect(toolbarRect.left, greaterThanOrEqualTo(0));
        expect(toolbarRect.right, lessThanOrEqualTo(360));
        expect(toolbarRect.top, greaterThanOrEqualTo(0));
        expect(toolbarRect.bottom, lessThanOrEqualTo(780));
        // 气泡应按内容自适应包裹，不撑满视口高度
        expect(toolbarRect.height, lessThan(180));

        for (final label in ['笔记', '复制', '划线', 'AI 速查', '分享卡片']) {
          final itemFinder = find.text(label);
          expect(itemFinder, findsOneWidget);
          final itemRect = tester.getRect(itemFinder);
          expect(itemRect.left, greaterThanOrEqualTo(toolbarRect.left));
          expect(itemRect.right, lessThanOrEqualTo(toolbarRect.right));
          expect(itemRect.top, greaterThanOrEqualTo(toolbarRect.top));
          expect(itemRect.bottom, lessThanOrEqualTo(toolbarRect.bottom));
        }

        // 实际点击末尾的「分享卡片」，确保无裁剪遮挡并成功打开金句分享卡片
        await tester.tap(find.text('分享卡片'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('quote-share-card-preview')),
          findsOneWidget,
        );
        Navigator.of(
          tester.element(find.byKey(const ValueKey('quote-share-card-preview'))),
        ).pop();
        await tester.pumpAndSettle();

        // 2. 跨段长按拖拽选词：校验全部 5 个跨段按钮同样完整展示且「分享卡片」可点击
        final gesture = await tester.startGesture(
          Offset(p1Rect.left + 48, p1Rect.top + 10),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(Offset(p2Rect.right - 24, p2Rect.bottom - 6));
        await tester.pump(const Duration(milliseconds: 120));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(toolbarFinder, findsOneWidget);
        final multiRect = tester.getRect(toolbarFinder);
        expect(multiRect.left, greaterThanOrEqualTo(0));
        expect(multiRect.right, lessThanOrEqualTo(360));
        expect(multiRect.bottom, lessThanOrEqualTo(780));
        for (final label in ['复制', '跨段划线', '跨段笔记', 'AI 速查', '分享卡片']) {
          final itemFinder = find.text(label);
          expect(itemFinder, findsOneWidget);
          final itemRect = tester.getRect(itemFinder);
          expect(itemRect.top, greaterThanOrEqualTo(multiRect.top));
          expect(itemRect.bottom, lessThanOrEqualTo(multiRect.bottom));
          expect(itemRect.left, greaterThanOrEqualTo(multiRect.left));
          expect(itemRect.right, lessThanOrEqualTo(multiRect.right));
        }

        await tester.tap(find.text('分享卡片'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('quote-share-card-preview')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Android 阅读器更多阅读工具中沉浸式听书不换行且同行卡片严格等高对齐',
      (tester) async {
        ReaderPlatform.resetForTesting();
        addTearDown(ReaderPlatform.resetForTesting);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(360, 780);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(
              book: Book(
                bookId: 'more-actions-grid-test',
                bookName: '网格布局测试书',
                author: '测试作者',
              ),
              chapters: [
                Chapter(
                  itemId: 'ch1',
                  title: '第一章',
                  content: '正文测试内容段落，用于唤起阅读器顶部与底部工具栏。',
                ),
              ],
              resumeSavedPosition: false,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // 点击屏幕中央唤起阅读器控制栏，再打开右上角「更多选项」底部工具网格
        await tester.tapAt(const Offset(180, 390));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多选项'));
        await tester.pumpAndSettle();

        expect(find.text('更多阅读工具'), findsOneWidget);
        expect(find.text('沉浸式多角色听书'), findsNothing);
        expect(find.text('沉浸式听书'), findsOneWidget);

        // 校验第二行三个卡片（「纯净阅读」「沉浸式听书」「沉浸式听书设置」）均单行且等高齐平
        final rowLabels = ['纯净阅读', '沉浸式听书', '沉浸式听书设置'];
        final cardRects = <Rect>[];
        for (final label in rowLabels) {
          final textFinder = find.text(label);
          expect(textFinder, findsOneWidget);
          // 12px 单行文字高度远小于 24px（两行会达到 ~32px 以上）
          expect(tester.getSize(textFinder).height, lessThan(24));
          final cardFinder = find.ancestor(
            of: textFinder,
            matching: find.byType(InkWell),
          );
          cardRects.add(tester.getRect(cardFinder.first));
        }
        for (var i = 1; i < cardRects.length; i++) {
          expect(cardRects[i].top, closeTo(cardRects[0].top, 0.5));
          expect(cardRects[i].bottom, closeTo(cardRects[0].bottom, 0.5));
          expect(cardRects[i].height, closeTo(cardRects[0].height, 0.5));
        }
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Android 320dp 超窄屏与 1.5x 系统字号下选词气泡与更多工具网格无溢出且等高对齐',
      (tester) async {
        ReaderPlatform.resetForTesting();
        addTearDown(ReaderPlatform.resetForTesting);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(320, 640);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: ReaderScreen(
              book: Book(
                bookId: 'small-large-font-test',
                bookName: '超窄大字测试书',
                author: '测试作者',
              ),
              chapters: [
                Chapter(
                  itemId: 'ch1',
                  title: '第一章',
                  content: '超窄屏大字号选词测试段落内容，验证气泡与分享卡片不溢出且可点击。',
                ),
              ],
              resumeSavedPosition: false,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        // 呼出控制栏并打开「更多选项」，大字号下自动切为 2 列且每行严格等高
        await tester.tapAt(const Offset(160, 320));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多选项'));
        await tester.pumpAndSettle();

        expect(find.text('沉浸式听书'), findsOneWidget);
        final cardA = tester.getRect(
          find
              .ancestor(
                of: find.text('沉浸式听书'),
                matching: find.byType(InkWell),
              )
              .first,
        );
        final cardB = tester.getRect(
          find
              .ancestor(
                of: find.text('沉浸式听书设置'),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(cardA.top, closeTo(cardB.top, 0.5));
        expect(cardA.bottom, closeTo(cardB.bottom, 0.5));
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  });
}
