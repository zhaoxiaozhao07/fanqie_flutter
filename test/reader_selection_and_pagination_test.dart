import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Reader Selection & Bubble Toolbar Tests', () {
    testWidgets('SelectableText with custom bubble toolbar toggles 划线 and 取消划线', (tester) async {
      final bookmarkService = BookmarkService();
      await bookmarkService.initialize();

      const bookId = 'book_bubble_test';
      const chapterIndex = 0;
      const chapterTitle = '第一章 测试章节';
      final notes = <String>[];

      Widget buildBubbleToolbar({
        required BuildContext context,
        required TextSelectionToolbarAnchors anchors,
        required String selectedText,
        required VoidCallback onDismiss,
      }) {
        final clean = selectedText.trim();
        final isUnderlined = notes.contains(clean);

        return TextSelectionToolbar(
          anchorAbove: anchors.primaryAnchor,
          anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
          children: [
            TextButton(
              onPressed: () {
                onDismiss();
              },
              child: const Text('复制'),
            ),
            if (isUnderlined)
              TextButton(
                onPressed: () async {
                  onDismiss();
                  notes.remove(clean);
                  await bookmarkService.removeNoteByParagraph(
                    bookId: bookId,
                    chapterIndex: chapterIndex,
                    paragraphIndex: 0,
                    text: clean,
                  );
                },
                child: const Text('取消划线'),
              )
            else
              TextButton(
                onPressed: () async {
                  onDismiss();
                  notes.add(clean);
                  await bookmarkService.addNote(
                    bookId: bookId,
                    chapterIndex: chapterIndex,
                    chapterTitle: chapterTitle,
                    paragraphIndex: 0,
                    text: clean,
                  );
                },
                child: const Text('划线'),
              ),
          ],
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '白日依山尽',
                          style: TextStyle(
                            decoration: notes.contains('白日依山尽') ? TextDecoration.underline : null,
                            decorationStyle: TextDecorationStyle.dashed,
                          ),
                        ),
                        const TextSpan(text: '，黄河入海流。欲穷千里目，更上一层楼。'),
                      ],
                    ),
                    contextMenuBuilder: (context, state) {
                      final textVal = state.textEditingValue;
                      final selected = textVal.selection.textInside(textVal.text);
                      if (selected.trim().isEmpty) return const SizedBox.shrink();
                      return buildBubbleToolbar(
                        context: context,
                        anchors: state.contextMenuAnchors,
                        selectedText: selected,
                        onDismiss: () {
                          state.hideToolbar();
                          setState(() {});
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );

      // 1. Long press on text to trigger selection and bubble
      final gesture1 = await tester.startGesture(tester.getCenter(find.byType(SelectableText)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture1.up();
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('划线'), findsOneWidget);
      expect(find.text('取消划线'), findsNothing);

      // 2. Tap 划线
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();

      expect(notes.isNotEmpty, isTrue);
      final savedNotes = await bookmarkService.getNotes(bookId);
      expect(savedNotes.length, 1);

      // 3. Long press on the underlined text again
      final gesture2 = await tester.startGesture(tester.getCenter(find.byType(SelectableText)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture2.up();
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      expect(find.text('取消划线'), findsOneWidget);
      expect(find.text('划线'), findsNothing);

      // 4. Tap 取消划线
      await tester.tap(find.text('取消划线'));
      await tester.pumpAndSettle();

      expect(notes.isEmpty, isTrue);
      final updatedNotes = await bookmarkService.getNotes(bookId);
      expect(updatedNotes.isEmpty, isTrue);
    });
  });

  group('Horizontal Page Mode Filling Tests', () {
    test('TextPainter pagination fills screen height efficiently', () {
      const fontSize = 18.0;
      const lineHeight = 1.8;
      const letterSpacing = 0.5;
      const horizontalPadding = 18.0;
      const paraSpacing = 8.0;
      const pageSize = Size(390.0, 750.0);

      final content = List.generate(15, (i) =>
        '第${i + 1}段：夜幕降临，繁星点缀在浩瀚的天际。在这个属于修行者的神秘世界里，每一次风云激荡，都伴随着无数少年天才的崛起与陨落。岁月悠悠，唯有不屈的道心能够穿透无尽风霜。'
      ).join('\n\n');

      final availWidth = (pageSize.width - horizontalPadding * 2);
      const reservedVertical = 36.0;
      final normalAvailHeight = pageSize.height - reservedVertical;

      final textStyle = const TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: letterSpacing,
      );
      final painter = TextPainter(textDirection: TextDirection.ltr);

      double measureHeight(String text) {
        if (text.isEmpty) return 0.0;
        painter.text = TextSpan(text: text, style: textStyle);
        painter.layout(maxWidth: availWidth);
        return painter.height;
      }

      final singleLineHeight = measureHeight('测');
      expect(singleLineHeight > 25.0, isTrue);

      final paragraphs = content.split('\n\n');
      final pages = <String>[];
      final currentParas = <String>[];
      double currentHeight = 0.0;

      for (var para in paragraphs) {
        var text = para.trim();
        if (text.isEmpty) continue;

        while (text.isNotEmpty) {
          final fullParaHeight = measureHeight(text);

          if (currentHeight == 0.0) {
            if (fullParaHeight <= normalAvailHeight) {
              currentParas.add(text);
              currentHeight += fullParaHeight + paraSpacing;
              break;
            } else {
              int low = 1, high = text.length, best = 1;
              while (low <= high) {
                final mid = (low + high) ~/ 2;
                final h = measureHeight(text.substring(0, mid));
                if (h <= normalAvailHeight) {
                  best = mid;
                  low = mid + 1;
                } else {
                  high = mid - 1;
                }
              }
              currentParas.add(text.substring(0, best));
              text = text.substring(best);
              pages.add(currentParas.join('\n\n'));
              currentParas.clear();
              currentHeight = 0.0;
            }
          } else {
            final neededHeight = fullParaHeight + paraSpacing;
            if (currentHeight + neededHeight <= normalAvailHeight) {
              currentParas.add(text);
              currentHeight += neededHeight;
              break;
            } else {
              final spaceLeft = normalAvailHeight - currentHeight - paraSpacing;
              if (spaceLeft >= singleLineHeight) {
                int low = 1, high = text.length, best = 0;
                while (low <= high) {
                  final mid = (low + high) ~/ 2;
                  final h = measureHeight(text.substring(0, mid));
                  if (h <= spaceLeft) {
                    best = mid;
                    low = mid + 1;
                  } else {
                    high = mid - 1;
                  }
                }
                if (best > 0) {
                  currentParas.add(text.substring(0, best));
                  text = text.substring(best);
                }
              }
              pages.add(currentParas.join('\n\n'));
              currentParas.clear();
              currentHeight = 0.0;
            }
          }
        }
      }

      if (currentParas.isNotEmpty) {
        pages.add(currentParas.join('\n\n'));
      }

      expect(pages.length >= 3, isTrue);

      for (int p = 0; p < pages.length - 1; p++) {
        expect(pages[p].contains(r'$trimmed'), isFalse);
        expect(pages[p].contains('夜幕降临'), isTrue);
        final paras = pages[p].split('\n\n');
        double h = 0.0;
        for (int i = 0; i < paras.length; i++) {
          h += measureHeight(paras[i]);
          if (i < paras.length - 1) h += paraSpacing;
        }
        final fillRatio = h / normalAvailHeight;
        expect(fillRatio >= 0.88, isTrue, reason: 'Page $p filled less than 88%');
      }
    });
  });

  group('Virtualized Vertical Scroll & On-Demand Selection Optimization Tests', () {
    testWidgets('CustomScrollView + SliverList virtualizes paragraphs and activates SelectableText only on long press', (tester) async {
      final paragraphs = List.generate(
        120,
        (i) => '　　第${i + 1}段：天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。寒来暑往，秋收冬藏。闰余成岁，律吕调阳。',
      );
      final activeParaNotifier = ValueNotifier<String?>(null);
      final activeSelectableKey = GlobalKey();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: scrollController,
              // ignore: deprecated_member_use
              cacheExtent: 650.0,
              slivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final paraKeyStr = 'ch1_$index';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: ValueListenableBuilder<String?>(
                          valueListenable: activeParaNotifier,
                          builder: (context, activeKey, _) {
                            if (activeKey == paraKeyStr) {
                              return SelectableText.rich(
                                key: activeSelectableKey,
                                TextSpan(text: paragraphs[index]),
                                contextMenuBuilder: (context, editableState) {
                                  return TextSelectionToolbar(
                                    anchorAbove: editableState.contextMenuAnchors.primaryAnchor,
                                    anchorBelow: editableState.contextMenuAnchors.secondaryAnchor ??
                                        editableState.contextMenuAnchors.primaryAnchor,
                                    children: [
                                      TextButton(
                                        onPressed: () {
                                          editableState.hideToolbar();
                                          activeParaNotifier.value = null;
                                        },
                                        child: const Text('复制'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          editableState.hideToolbar();
                                          activeParaNotifier.value = null;
                                        },
                                        child: const Text('划线'),
                                      ),
                                    ],
                                  );
                                },
                              );
                            }
                            return GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onLongPressStart: (details) {
                                activeParaNotifier.value = paraKeyStr;
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  final Object? st = activeSelectableKey.currentState;
                                  if (st is TextSelectionGestureDetectorBuilderDelegate) {
                                    final editable = st.editableTextKey.currentState;
                                    if (editable != null && editable.mounted) {
                                      editable.renderEditable.selectWordsInRange(
                                        from: details.globalPosition,
                                        cause: SelectionChangedCause.longPress,
                                      );
                                      editable.showToolbar();
                                    }
                                  }
                                });
                              },
                              child: Text.rich(TextSpan(text: paragraphs[index])),
                            );
                          },
                        ),
                      );
                    },
                    childCount: paragraphs.length,
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                    addSemanticIndexes: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 1. During normal reading/scrolling, ZERO SelectableText widgets are mounted,
      //    and only viewport + cacheExtent paragraphs (< 35 out of 120) are built!
      expect(find.byType(SelectableText), findsNothing);
      final mountedTexts = tester.widgetList<Text>(find.byType(Text)).length;
      expect(mountedTexts < 35, isTrue, reason: 'Should virtualize 120 paragraphs to < 35 mounted');

      // 2. Single long press on paragraph 0 activates SelectableText and shows bubble menu
      final firstParaFinder = find.textContaining('第1段：天地玄黄');
      expect(firstParaFinder, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(firstParaFinder));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('划线'), findsOneWidget);

      // 3. Dismissing bubble menu reverts back to zero SelectableText instances
      await tester.tap(find.text('划线'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  group('Horizontal Page Turn Animation Tests', () {
    testWidgets('Page turn animations (cover, simulation, slide, fade) animate smoothly and persist preference', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reader_page_turn_animation', 'simulation');
      expect(prefs.getString('reader_page_turn_animation'), 'simulation');

      final controller = PageController();
      String currentAnimMode = 'cover';
      final pages = ['第一页正文内容', '第二页正文内容', '第三页正文内容'];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'cover', label: Text('覆盖')),
                        ButtonSegment(value: 'simulation', label: Text('仿真')),
                        ButtonSegment(value: 'slide', label: Text('滑动')),
                        ButtonSegment(value: 'fade', label: Text('渐变')),
                      ],
                      selected: {currentAnimMode},
                      onSelectionChanged: (val) {
                        setState(() => currentAnimMode = val.first);
                      },
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return PageView.builder(
                            controller: controller,
                            itemCount: pages.length,
                            itemBuilder: (context, pageIdx) {
                              final card = Container(
                                color: const Color(0xFFF5EEDC),
                                alignment: Alignment.center,
                                child: Text(pages[pageIdx]),
                              );
                              return AnimatedBuilder(
                                animation: controller,
                                child: card,
                                builder: (context, staticChild) {
                                  double page = 0.0;
                                  if (controller.hasClients &&
                                      controller.position.haveDimensions) {
                                    page = controller.page ?? 0.0;
                                  }
                                  final delta = pageIdx - page;
                                  if (delta.abs() < 0.0005 || delta.abs() >= 1.0) {
                                    return staticChild!;
                                  }
                                  if (currentAnimMode == 'simulation' && delta < 0) {
                                    final t = (-delta).clamp(0.0, 1.0);
                                    final curlWidth = (math.sin(t * math.pi) * 44.0).clamp(6.0, 44.0);
                                    return ClipRect(
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Transform.translate(
                                            offset: Offset(t * constraints.maxWidth, 0),
                                            child: staticChild,
                                          ),
                                          Positioned(
                                            right: 0,
                                            top: 0,
                                            bottom: 0,
                                            width: curlWidth,
                                            child: const ColoredBox(color: Color(0xFFE5DAC4)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  return ClipRect(
                                    child: Transform.translate(
                                      offset: Offset(delta > 0 ? -delta * constraints.maxWidth : 0, 0),
                                      child: staticChild,
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('第一页正文内容'), findsOneWidget);

      // Switch animation mode to 仿真
      await tester.tap(find.text('仿真'));
      await tester.pumpAndSettle();
      expect(currentAnimMode, 'simulation');

      // Animate to next page and verify mid-animation frame renders curl transform without error
      controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(ClipRect), findsWidgets);

      await tester.pumpAndSettle();
      expect(find.text('第二页正文内容'), findsOneWidget);
    });
  });
}
