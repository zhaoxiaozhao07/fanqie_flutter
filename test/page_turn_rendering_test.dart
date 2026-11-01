import 'dart:ui' as ui;

import 'package:fanqie_flutter/widgets/reader_page_transition.dart';
import 'package:fanqie_flutter/widgets/simulation_page_turn.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pageSize = Size(400, 600);

class _PaintCounter extends CustomPainter {
  final VoidCallback onPaint;

  _PaintCounter(this.onPaint);

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(covariant _PaintCounter oldDelegate) => false;
}

class _PageProbe extends StatelessWidget {
  final String label;
  final VoidCallback onBuild;
  final VoidCallback onPaint;
  final Key? contentKey;

  const _PageProbe({
    required this.label,
    required this.onBuild,
    required this.onPaint,
    this.contentKey,
  });

  @override
  Widget build(BuildContext context) {
    onBuild();
    return CustomPaint(
      painter: _PaintCounter(onPaint),
      child: ColoredBox(
        color: const Color(0xFFF5EEDC),
        child: Center(child: Text(label, key: contentKey)),
      ),
    );
  }
}

class _SimulationHarness extends StatefulWidget {
  final int initialPage;
  final GlobalKey<SimulationPageTurnState> simulationKey;
  final GlobalKey? selectionKey;

  const _SimulationHarness({
    super.key,
    this.initialPage = 0,
    required this.simulationKey,
    this.selectionKey,
  });

  @override
  State<_SimulationHarness> createState() => _SimulationHarnessState();
}

class _SimulationHarnessState extends State<_SimulationHarness> {
  late int page = widget.initialPage;
  String chapter = 'chapter-a';
  final builds = [0, 0, 0];
  final paints = [0, 0, 0];
  final changes = <int>[];
  int centerTaps = 0;
  DateTime bubbleTap = DateTime.fromMillisecondsSinceEpoch(0);

  void changeChapter() {
    setState(() {
      chapter = 'chapter-b';
      page = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: _pageSize,
            child: SimulationPageTurn(
              key: widget.simulationKey,
              totalPages: 3,
              currentPageIndex: page,
              pageSetKey: chapter,
              backgroundColor: const Color(0xFFF5EEDC),
              pageBuilder: (context, index) => _PageProbe(
                label: '$chapter-page-$index',
                onBuild: () => builds[index]++,
                onPaint: () => paints[index]++,
                contentKey: index == page ? widget.selectionKey : null,
              ),
              onPageChanged: (index) {
                changes.add(index);
                setState(() => page = index);
              },
              onCenterTap: () => centerTaps++,
              lastBubbleTapTimeGetter: () => bubbleTap,
            ),
          ),
        ),
      ),
    );
  }
}

Path _frontClip(WidgetTester tester) {
  final clipper = tester.widget<ClipPath>(find.byType(ClipPath).first).clipper!;
  return clipper.getClip(_pageSize);
}

Path _backClip(WidgetTester tester) {
  final clipper = tester.widget<ClipPath>(find.byType(ClipPath).last).clipper!;
  return clipper.getClip(_pageSize);
}

Offset _paperCorner(WidgetTester tester, Offset corner) {
  final transform = tester
      .widget<Transform>(
        find.ancestor(
          of: find.byType(RawImage),
          matching: find.byType(Transform),
        ),
      )
      .transform;
  return Offset(
    transform.entry(0, 0) * corner.dx +
        transform.entry(0, 1) * corner.dy +
        transform.entry(0, 3),
    transform.entry(1, 0) * corner.dx +
        transform.entry(1, 1) * corner.dy +
        transform.entry(1, 3),
  );
}

void main() {
  group('Simulation rendering regressions', () {
    testWidgets(
      'a missing chapter boundary keeps the page for a cancelled short drag',
      (tester) async {
        var requests = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: SimulationPageTurn(
                  totalPages: 1,
                  currentPageIndex: 0,
                  backgroundColor: Colors.white,
                  pageBuilder: (context, index) =>
                      const ColoredBox(color: Colors.white),
                  onPageChanged: (_) {},
                  onNextChapter: () => requests++,
                ),
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(const Offset(350, 300));
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(requests, 0);
        await tester.fling(
          find.byType(SimulationPageTurn),
          const Offset(-50, 0),
          2000,
        );
        await tester.pumpAndSettle();
        expect(requests, 1);
      },
    );
    testWidgets('animation reuses page content and paints it only once', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );

      final preparedBuilds = List<int>.of(key.currentState!.builds);
      expect(
        preparedBuilds[1],
        1,
        reason: 'Next page is laid out ahead of time.',
      );
      expect(key.currentState!.paints[1], 0);
      simulationKey.currentState!.turnToNextPage();
      await tester.pump();
      expect(key.currentState!.builds, preparedBuilds);
      final builds = List<int>.of(key.currentState!.builds);
      final paints = List<int>.of(key.currentState!.paints);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(find.text('chapter-a-page-0'), findsOneWidget);
      expect(find.text('chapter-a-page-1'), findsOneWidget);

      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(key.currentState!.builds, builds);
      expect(key.currentState!.paints, paints);
      expect(key.currentState!.changes, isEmpty);

      await tester.pumpAndSettle();
      expect(key.currentState!.changes, [1]);
      expect(find.text('chapter-a-page-1'), findsOneWidget);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNull);
      expect(tester.takeException(), isNull);
    });

    for (final isDark in [false, true]) {
      testWidgets(
        '${isDark ? 'dark' : 'light'} fold shadow is narrow and fades perpendicular to crease',
        (tester) async {
          var page = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox.fromSize(
                  size: _pageSize,
                  child: StatefulBuilder(
                    builder: (context, setState) => SimulationPageTurn(
                      totalPages: 2,
                      currentPageIndex: page,
                      backgroundColor: isDark ? Colors.black : Colors.white,
                      isDark: isDark,
                      pageBuilder: (context, index) => ColoredBox(
                        color: isDark ? Colors.black : Colors.white,
                      ),
                      onPageChanged: (index) => setState(() => page = index),
                    ),
                  ),
                ),
              ),
            ),
          );
          final gesture = await tester.startGesture(const Offset(390, 580));
          await gesture.moveBy(const Offset(-180, 0));
          await tester.pump();
          final foldLayers = tester
              .widgetList<Stack>(
                find.descendant(
                  of: find.byType(SimulationPageTurn),
                  matching: find.byType(Stack),
                ),
              )
              .firstWhere((stack) => stack.children.first is CustomPaint);
          final shadow = (foldLayers.children.first as CustomPaint).painter!;
          final recorder = ui.PictureRecorder();
          shadow.paint(Canvas(recorder), _pageSize);
          final picture = recorder.endRecording();
          final image = picture.toImageSync(400, 600);
          final bytes = await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          expect(bytes, isNotNull);

          int alpha(int x, int y) => bytes!.getUint8((y * 400 + x) * 4 + 3);
          final shadowColumns = [
            for (var x = 0; x < 400; x++)
              if (alpha(x, 300) > 0) x,
          ];
          expect(shadowColumns, isNotEmpty);
          expect(
            shadowColumns.last - shadowColumns.first + 1,
            lessThanOrEqualTo(10),
          );
          final x = shadowColumns.first;
          expect(alpha(x, 50), closeTo(alpha(x, 550), 1));
          expect(alpha(x, 300), greaterThan(alpha(shadowColumns.last, 300)));

          image.dispose();
          picture.dispose();
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final forward in [true, false]) {
      testWidgets(
        '${forward ? 'forward' : 'backward'} turn never flashes source after crease leaves viewport',
        (tester) async {
          final key = GlobalKey<_SimulationHarnessState>();
          final simulationKey = GlobalKey<SimulationPageTurnState>();
          await tester.pumpWidget(
            _SimulationHarness(
              key: key,
              initialPage: 1,
              simulationKey: simulationKey,
            ),
          );

          if (forward) {
            simulationKey.currentState!.turnToNextPage();
          } else {
            simulationKey.currentState!.turnToPreviousPage();
          }
          await tester.pump();
          expect(_frontClip(tester).contains(const Offset(200, 300)), isTrue);
          final front = find.byType(ClipPath).first;
          expect(
            find.descendant(of: front, matching: find.text('chapter-a-page-1')),
            findsOneWidget,
            reason: 'Both directions must start with the current page.',
          );

          await tester.pump(const Duration(milliseconds: 240));
          for (var frame = 0; frame < 7; frame++) {
            expect(key.currentState!.page, 1);
            expect(_frontClip(tester).getBounds().isEmpty, isTrue);
            expect(
              _backClip(tester).getBounds().overlaps(Offset.zero & _pageSize),
              isFalse,
            );
            await tester.pump(const Duration(milliseconds: 8));
          }

          await tester.pumpAndSettle();
          expect(key.currentState!.changes, [forward ? 2 : 0]);
          expect(_frontClip(tester).contains(const Offset(200, 300)), isTrue);
          expect(_backClip(tester).getBounds().isEmpty, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final forward in [true, false]) {
      for (final top in [true, false]) {
        testWidgets(
          '${top ? 'top' : 'bottom'} ${forward ? 'right' : 'left'} drag stays cached',
          (tester) async {
            final key = GlobalKey<_SimulationHarnessState>();
            final simulationKey = GlobalKey<SimulationPageTurnState>();
            await tester.pumpWidget(
              _SimulationHarness(
                key: key,
                initialPage: 1,
                simulationKey: simulationKey,
              ),
            );
            final start = Offset(forward ? 390 : 10, top ? 30 : 580);
            final gesture = await tester.startGesture(start);
            await gesture.moveBy(Offset(forward ? -90 : 90, top ? 70 : -70));
            await tester.pump();
            final builds = List<int>.of(key.currentState!.builds);
            final paints = List<int>.of(key.currentState!.paints);

            for (var move = 0; move < 5; move++) {
              await gesture.moveBy(Offset(forward ? -15 : 15, 0));
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(key.currentState!.builds, builds);
            expect(key.currentState!.paints, paints);
            expect(find.text('chapter-a-page-1'), findsOneWidget);
            expect(_backClip(tester).getBounds().isEmpty, isFalse);

            await gesture.up();
            await tester.pumpAndSettle();
            expect(key.currentState!.changes, [forward ? 2 : 0]);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('small and cancelled drags restore a full page', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );

      final smallDrag = await tester.startGesture(const Offset(390, 580));
      await smallDrag.moveBy(const Offset(-30, 0));
      await tester.pump();
      await smallDrag.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isEmpty);
      expect(_frontClip(tester).getBounds(), Offset.zero & _pageSize);
      expect(_backClip(tester).getBounds().isEmpty, isTrue);

      final cancelled = await tester.startGesture(const Offset(390, 30));
      await cancelled.moveBy(const Offset(-160, 80));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isEmpty);
      expect(_frontClip(tester).getBounds(), Offset.zero & _pageSize);
      expect(tester.takeException(), isNull);
    });

    testWidgets('center swipe starts from a small fold, not half a page', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(_frontClip(tester).contains(const Offset(380, 300)), isTrue);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isEmpty);
      expect(key.currentState!.centerTaps, 0);
    });

    for (final forward in [true, false]) {
      for (final top in [true, false]) {
        testWidgets(
          '${top ? 'top' : 'bottom'} ${forward ? 'forward' : 'backward'} crease tracks horizontal finger travel 1:1',
          (tester) async {
            final simulationKey = GlobalKey<SimulationPageTurnState>();
            await tester.pumpWidget(
              _SimulationHarness(initialPage: 1, simulationKey: simulationKey),
            );
            final corner = Offset(forward ? 400 : 0, top ? 0 : 600);
            final start = Offset(forward ? 390 : 10, top ? 30 : 580);
            final gesture = await tester.startGesture(start);
            var travel = 0.0;
            for (final delta in [20.0, 35.0, 55.0, -25.0]) {
              travel += delta * (forward ? -1 : 1);
              await gesture.moveBy(Offset(delta * (forward ? -1 : 1), 0));
              await tester.pump(const Duration(milliseconds: 16));
              final paper = _paperCorner(tester, corner);
              expect(paper.dx, closeTo(corner.dx + travel * 2, 0.01));
              expect(
                (paper.dx + corner.dx) / 2,
                closeTo(corner.dx + travel, 0.01),
              );
            }
            await gesture.cancel();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('vertical bending never clamps horizontal finger travel', (
      tester,
    ) async {
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(_SimulationHarness(simulationKey: simulationKey));
      final gesture = await tester.startGesture(const Offset(390, 580));
      await gesture.moveBy(const Offset(-80, -260));
      await tester.pump();
      expect(
        _paperCorner(tester, const Offset(400, 600)).dx,
        closeTo(240, 0.01),
      );
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(
        _paperCorner(tester, const Offset(400, 600)).dx,
        closeTo(240, 0.01),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('a new horizontal drag takes over a settling turn', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );
      simulationKey.currentState!.turnToNextPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = _paperCorner(tester, const Offset(400, 600));
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      final grabbed = _paperCorner(tester, const Offset(400, 600));
      expect(grabbed.dx, closeTo(before.dx + 100, 0.01));
      await tester.pump(const Duration(milliseconds: 500));
      expect(key.currentState!.changes, isEmpty);
      expect(
        _paperCorner(tester, const Offset(400, 600)).dx,
        closeTo(grabbed.dx, 0.01),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isEmpty);
      expect(_frontClip(tester).getBounds(), Offset.zero & _pageSize);
      simulationKey.currentState!.turnToNextPage();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, [1]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a held pointer remains usable when a turn commits', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );
      simulationKey.currentState!.turnToNextPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final gesture = await tester.startGesture(const Offset(350, 300));
      await tester.pump(const Duration(milliseconds: 250));
      expect(key.currentState!.changes, [1]);
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, [1, 2]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stationary release does not kick the paper forward', (
      tester,
    ) async {
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(_SimulationHarness(simulationKey: simulationKey));
      final gesture = await tester.startGesture(const Offset(390, 580));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump(const Duration(milliseconds: 300));
      final before = _paperCorner(tester, const Offset(400, 600));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      final after = _paperCorner(tester, const Offset(400, 600));
      expect((after - before).distance, lessThan(1));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a page window update does not drop a pending drag', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );
      final gesture = await tester.startGesture(const Offset(350, 300));
      key.currentState!.changeChapter();
      await tester.pump();
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(simulationKey.currentState!.isTurning, isTrue);
      expect(
        _paperCorner(tester, const Offset(400, 600)).dx,
        closeTo(200, 0.01),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, [1]);
      expect(find.text('chapter-b-page-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('paper snapshot is prewarmed and reused after cancellation', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1200, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(_SimulationHarness(simulationKey: simulationKey));
      final gesture = await tester.startGesture(const Offset(390, 580));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
      final first = tester.widget<RawImage>(find.byType(RawImage)).image!;
      expect(
        first.width,
        600,
        reason: 'Ghost text uses at most 1.5x resolution.',
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      final next = await tester.startGesture(const Offset(390, 580));
      await next.moveBy(const Offset(-50, 0));
      await tester.pump();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(first));
      await next.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'rapid taps keep one latest request without interrupting a turn',
      (tester) async {
        final key = GlobalKey<_SimulationHarnessState>();
        final simulationKey = GlobalKey<SimulationPageTurnState>();
        await tester.pumpWidget(
          _SimulationHarness(key: key, simulationKey: simulationKey),
        );
        simulationKey.currentState!.turnToNextPage();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(const Offset(380, 400));
        simulationKey.currentState!.turnToPreviousPage();
        await tester.pumpAndSettle();
        expect(key.currentState!.changes, [1, 0]);

        await tester.tapAt(const Offset(380, 400));
        await tester.pumpAndSettle();
        expect(key.currentState!.changes, [1, 0, 1]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'fast short flick uses velocity, and long-press owns selection drag',
      (tester) async {
        final key = GlobalKey<_SimulationHarnessState>();
        final simulationKey = GlobalKey<SimulationPageTurnState>();
        await tester.pumpWidget(
          _SimulationHarness(key: key, simulationKey: simulationKey),
        );
        await tester.fling(
          find.byType(SimulationPageTurn),
          const Offset(-50, 0),
          2000,
        );
        await tester.pumpAndSettle();
        expect(key.currentState!.changes, [1]);

        var selected = false;
        var page = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: StatefulBuilder(
                  builder: (context, setState) => SimulationPageTurn(
                    totalPages: 2,
                    currentPageIndex: page,
                    backgroundColor: Colors.white,
                    pageBuilder: (context, index) => GestureDetector(
                      onLongPressStart: (_) => selected = true,
                      onLongPressMoveUpdate: (_) {},
                      child: Center(child: Text('selection-$index')),
                    ),
                    onPageChanged: (index) => setState(() => page = index),
                  ),
                ),
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(const Offset(200, 300));
        await tester.pump(const Duration(milliseconds: 700));
        expect(selected, isTrue);
        await gesture.moveBy(const Offset(-120, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(page, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'chapter update cancels an old turn even with same page index',
      (tester) async {
        final key = GlobalKey<_SimulationHarnessState>();
        final simulationKey = GlobalKey<SimulationPageTurnState>();
        await tester.pumpWidget(
          _SimulationHarness(key: key, simulationKey: simulationKey),
        );
        simulationKey.currentState!.turnToNextPage();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        key.currentState!.changeChapter();
        await tester.pumpAndSettle();
        expect(key.currentState!.changes, isEmpty);
        expect(find.text('chapter-b-page-0'), findsOneWidget);
        expect(_frontClip(tester).getBounds(), Offset.zero & _pageSize);

        simulationKey.currentState!.turnToNextPage();
        await tester.pumpAndSettle();
        expect(key.currentState!.changes, [1]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('paper back does not duplicate keyed selectable content', (
      tester,
    ) async {
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      final selectionKey = GlobalKey();
      await tester.pumpWidget(
        _SimulationHarness(
          simulationKey: simulationKey,
          selectionKey: selectionKey,
        ),
      );
      simulationKey.currentState!.turnToNextPage();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(selectionKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('bubble taps do not turn pages or open controls', (
      tester,
    ) async {
      final key = GlobalKey<_SimulationHarnessState>();
      final simulationKey = GlobalKey<SimulationPageTurnState>();
      await tester.pumpWidget(
        _SimulationHarness(key: key, simulationKey: simulationKey),
      );
      key.currentState!.bubbleTap = DateTime.now();
      await tester.tapAt(const Offset(380, 300));
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(key.currentState!.changes, isEmpty);
      expect(key.currentState!.centerTaps, 0);
    });
  });

  group('PageView render isolation', () {
    for (final mode in ['cover', 'slide', 'fade']) {
      testWidgets(
        '$mode keeps page content mounted and cached through all frames',
        (tester) async {
          final controller = PageController(keepPage: false);
          final builds = [0, 0];
          final paints = [0, 0];
          final contentKey = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox.fromSize(
                  size: _pageSize,
                  child: PageView.builder(
                    controller: controller,
                    itemCount: 2,
                    allowImplicitScrolling: true,
                    itemBuilder: (context, index) => ReaderPageTransition(
                      controller: controller,
                      pageIndex: index,
                      width: _pageSize.width,
                      mode: mode,
                      child: _PageProbe(
                        label: 'page-$index',
                        contentKey: index == 0 ? contentKey : null,
                        onBuild: () => builds[index]++,
                        onPaint: () => paints[index]++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final originalElement = contentKey.currentContext;
          final animation = controller.animateToPage(
            1,
            duration: const Duration(milliseconds: 300),
            curve: Curves.linear,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          final initialBuilds = List<int>.of(builds);
          final initialPaints = List<int>.of(paints);
          for (var frame = 0; frame < 15; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              identical(contentKey.currentContext, originalElement),
              isTrue,
            );
          }
          expect(builds, initialBuilds);
          expect(paints, initialPaints);
          expect(tester.takeException(), isNull);
          await tester.pumpAndSettle();
          await animation;
          expect(controller.page, 1);
          expect(find.text('page-1'), findsOneWidget);

          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        },
      );
    }
  });
}
