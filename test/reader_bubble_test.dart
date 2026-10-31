import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Reader Comment Bubble & Page Mode Tap Tests', () {
    testWidgets('Enlarged bubble visual styling and hit target expansion', (tester) async {
      bool bubbleClicked = false;
      DateTime lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);

      InlineSpan buildCommentBubbleSpan({
        required int commentCount,
        required VoidCallback onTap,
      }) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 6.0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) {
                lastBubbleTapTime = DateTime.now();
              },
              onTap: () {
                lastBubbleTapTime = DateTime.now();
                onTap();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 3.5),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7.0, vertical: 2.5),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                      width: 0.6,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.chat_bubble_outline,
                        size: 12,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 3.0),
                      Text(
                        commentCount > 999 ? '999+' : '$commentCount',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white70,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: '这是一个包含段评气泡的测试段落。'),
                    buildCommentBubbleSpan(
                      commentCount: 88,
                      onTap: () {
                        bubbleClicked = true;
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      // Verify visual elements
      final textFinder = find.text('88');
      expect(textFinder, findsOneWidget);
      final textWidget = tester.widget<Text>(textFinder);
      expect(textWidget.style?.fontSize, 11);
      expect(textWidget.style?.fontWeight, FontWeight.bold);

      final iconFinder = find.byIcon(Icons.chat_bubble_outline);
      expect(iconFinder, findsOneWidget);
      final iconWidget = tester.widget<Icon>(iconFinder);
      expect(iconWidget.size, 12);

      // Tap on the bubble
      await tester.tap(textFinder);
      await tester.pumpAndSettle();
      expect(bubbleClicked, isTrue);
      expect(DateTime.now().difference(lastBubbleTapTime).inMilliseconds < 1000, isTrue);
    });

    testWidgets('Horizontal page mode: clicking bubble does NOT flip page or toggle controls', (tester) async {
      bool bubbleClicked = false;
      bool controlsToggled = false;
      int pageIndex = 0;
      final pageController = PageController();
      DateTime lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);
      Offset? lastPagePointerDown;

      void toggleControls() {
        if (DateTime.now().difference(lastBubbleTapTime) < const Duration(milliseconds: 400)) {
          return;
        }
        controlsToggled = !controlsToggled;
      }

      void handleHorizontalPageTap(Offset localPosition, double screenWidth, int totalPages) {
        if (DateTime.now().difference(lastBubbleTapTime) < const Duration(milliseconds: 400)) {
          return;
        }
        final dx = localPosition.dx;
        if (dx < screenWidth * 0.28) {
          if (pageIndex > 0) {
            pageIndex--;
            pageController.jumpToPage(pageIndex);
          }
        } else if (dx > screenWidth * 0.72) {
          if (pageIndex < totalPages - 1) {
            pageIndex++;
            pageController.jumpToPage(pageIndex);
          }
        } else {
          toggleControls();
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                return Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    lastPagePointerDown = event.localPosition;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      final pos = lastPagePointerDown ?? Offset(constraints.maxWidth / 2, 0);
                      handleHorizontalPageTap(pos, constraints.maxWidth, 2);
                    },
                    child: Container(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      color: Colors.transparent,
                      child: PageView(
                        controller: pageController,
                        physics: const BouncingScrollPhysics(),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText.rich(
                                  TextSpan(
                                    children: [
                                      const TextSpan(text: '第一页正文内容，段落文字测试。'),
                                      WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 6.0),
                                          child: GestureDetector(
                                            key: const Key('bubble_key'),
                                            behavior: HitTestBehavior.opaque,
                                            onTapDown: (_) {
                                              lastBubbleTapTime = DateTime.now();
                                            },
                                            onTap: () {
                                              lastBubbleTapTime = DateTime.now();
                                              bubbleClicked = true;
                                            },
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 3.5),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 7.0, vertical: 2.5),
                                                child: const Text('10评'),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  onTap: () {
                                    final pos = lastPagePointerDown ?? Offset(constraints.maxWidth / 2, 0);
                                    handleHorizontalPageTap(pos, constraints.maxWidth, 2);
                                  },
                                ),
                              ],
                            ),
                          ),
                          Container(
                            key: const Key('page_2_container'),
                            child: const Text('第二页'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 1. Click paragraph bubble directly
      bubbleClicked = false;
      controlsToggled = false;
      final bubbleFinder = find.byKey(const Key('bubble_key'));
      expect(bubbleFinder, findsOneWidget);
      await tester.tap(bubbleFinder);
      await tester.pumpAndSettle();

      // Bubble should trigger, page should NOT flip, controls should NOT toggle
      expect(bubbleClicked, isTrue);
      expect(controlsToggled, isFalse);
      expect(pageIndex, 0);

      // Reset bubble tap time to simulate > 400ms passing
      lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);

      // 2. Click on the right 28% of the screen (e.g. x = 750 on 800-wide screen)
      bubbleClicked = false;
      controlsToggled = false;
      await tester.tapAt(const Offset(750, 300));
      await tester.pumpAndSettle();
      expect(pageIndex, 1);
      expect(controlsToggled, isFalse);
      expect(bubbleClicked, isFalse);

      // 3. Click on the left 28% of the screen to go back
      await tester.tapAt(const Offset(50, 300));
      await tester.pumpAndSettle();
      expect(pageIndex, 0);
      expect(controlsToggled, isFalse);

      // 4. Click in the center 44% (e.g. x = 400) to toggle controls
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(controlsToggled, isTrue);
      expect(pageIndex, 0);
    });

    testWidgets('Horizontal page mode: tapping paragraph text triggers page flip or controls based on horizontal position', (tester) async {
      bool controlsToggled = false;
      int pageIndex = 0;
      final pageController = PageController();
      DateTime lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);
      Offset? lastPagePointerDown;

      void toggleControls() {
        if (DateTime.now().difference(lastBubbleTapTime) < const Duration(milliseconds: 400)) {
          return;
        }
        controlsToggled = !controlsToggled;
      }

      void handleHorizontalPageTap(Offset localPosition, double screenWidth, int totalPages) {
        if (DateTime.now().difference(lastBubbleTapTime) < const Duration(milliseconds: 400)) {
          return;
        }
        final dx = localPosition.dx;
        if (dx < screenWidth * 0.28) {
          if (pageIndex > 0) {
            pageIndex--;
            pageController.jumpToPage(pageIndex);
          }
        } else if (dx > screenWidth * 0.72) {
          if (pageIndex < totalPages - 1) {
            pageIndex++;
            pageController.jumpToPage(pageIndex);
          }
        } else {
          toggleControls();
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                return Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    lastPagePointerDown = event.localPosition;
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      final pos = lastPagePointerDown ?? Offset(constraints.maxWidth / 2, 0);
                      handleHorizontalPageTap(pos, constraints.maxWidth, 2);
                    },
                    child: Container(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      color: Colors.transparent,
                      child: PageView(
                        controller: pageController,
                        physics: const BouncingScrollPhysics(),
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText.rich(
                                  const TextSpan(
                                    text: '这是一个整行饱满的段落文本，跨越了整屏的宽度，测试用户点击文字不同区域时是否能精确进行左右翻页与呼出控制栏。',
                                  ),
                                  onTap: () {
                                    final pos = lastPagePointerDown ?? Offset(constraints.maxWidth / 2, 0);
                                    handleHorizontalPageTap(pos, constraints.maxWidth, 2);
                                  },
                                ),
                              ],
                            ),
                          ),
                          Container(
                            key: const Key('page_2_container'),
                            child: const Text('第二页'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 1. Tap text on the right (e.g. x = 700 on 800-wide screen)
      controlsToggled = false;
      await tester.tapAt(const Offset(700, 30));
      await tester.pumpAndSettle();
      expect(pageIndex, 1);
      expect(controlsToggled, isFalse);

      // 2. Tap on the left (e.g. x = 50)
      controlsToggled = false;
      await tester.tapAt(const Offset(50, 30));
      await tester.pumpAndSettle();
      expect(pageIndex, 0);
      expect(controlsToggled, isFalse);

      // 3. Tap text in the middle (e.g. x = 400)
      controlsToggled = false;
      await tester.tapAt(const Offset(400, 30));
      await tester.pumpAndSettle();
      expect(controlsToggled, isTrue);
      expect(pageIndex, 0);
    });

    testWidgets('Vertical scroll mode: bubble click opens comments without triggering controls', (tester) async {
      bool bubbleClicked = false;
      bool controlsToggled = false;
      DateTime lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);

      void toggleControls() {
        if (DateTime.now().difference(lastBubbleTapTime) < const Duration(milliseconds: 400)) {
          return;
        }
        controlsToggled = !controlsToggled;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: toggleControls,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: '连续滚屏模式下的测试段落。'),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6.0),
                            child: GestureDetector(
                              key: const Key('vertical_bubble_key'),
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (_) {
                                lastBubbleTapTime = DateTime.now();
                              },
                              onTap: () {
                                lastBubbleTapTime = DateTime.now();
                                bubbleClicked = true;
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 3.5),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7.0, vertical: 2.5),
                                  child: const Text('25评'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    onTap: toggleControls,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 1. Tap on bubble
      final bubbleFinder = find.byKey(const Key('vertical_bubble_key'));
      expect(bubbleFinder, findsOneWidget);
      await tester.tap(bubbleFinder);
      await tester.pumpAndSettle();

      expect(bubbleClicked, isTrue);
      expect(controlsToggled, isFalse);

      // 2. Tap on text
      lastBubbleTapTime = DateTime.fromMillisecondsSinceEpoch(0);
      await tester.tapAt(const Offset(30, 25));
      await tester.pumpAndSettle();

      expect(controlsToggled, isTrue);
    });
    test('Comment bubble toggle preference persistence', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('reader_show_comment_bubbles', false);
      expect(prefs.getBool('reader_show_comment_bubbles'), isFalse);
      await prefs.setBool('reader_show_comment_bubbles', true);
      expect(prefs.getBool('reader_show_comment_bubbles'), isTrue);
    });
  });
}
