import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _WheelReader extends StatefulWidget {
  final String mode;
  final int initialPage;
  final bool scrollableContent;

  const _WheelReader({
    super.key,
    required this.mode,
    this.initialPage = 1,
    this.scrollableContent = false,
  });

  @override
  State<_WheelReader> createState() => _WheelReaderState();
}

class _WheelReaderState extends State<_WheelReader> {
  final pager = GlobalKey<ReaderPageViewState>();
  final selection = ValueNotifier<String?>(null);
  final contentScroll = ScrollController();
  final settled = <int>[];
  late int page = widget.initialPage;
  int userTurns = 0;
  int boundaries = 0;

  @override
  void dispose() {
    selection.dispose();
    contentScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ReaderPageView(
        key: pager,
        pages: [
          for (var index = 0; index < 8; index++)
            ReaderPageItem(
              id: index,
              builder: (_) => widget.scrollableContent && index == page
                  ? ListView(
                      controller: contentScroll,
                      itemExtent: 50,
                      children: [
                        for (var item = 0; item < 60; item++)
                          Text('Page $index, line $item'),
                      ],
                    )
                  : Center(child: Text('Page $index')),
            ),
        ],
        currentPageId: page,
        contentVersion: 1,
        mode: widget.mode,
        backgroundColor: Colors.white,
        isDark: false,
        selection: selection,
        onPageSettled: (item) => setState(() {
          page = item.id as int;
          settled.add(page);
        }),
        onPreviousBoundary: () => boundaries++,
        onNextBoundary: () => boundaries++,
        onCenterTap: () {},
        onDismissSelection: () => selection.value = null,
        onUserPageTurn: () => userTurns++,
        lastBubbleTap: () => DateTime.fromMillisecondsSinceEpoch(0),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void desktopTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<_WheelReaderState> open(
    WidgetTester tester,
    String mode, {
    int initialPage = 1,
    bool scrollableContent = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(tester.view.reset);
    final key = GlobalKey<_WheelReaderState>();
    await tester.pumpWidget(
      _WheelReader(
        key: key,
        mode: mode,
        initialPage: initialPage,
        scrollableContent: scrollableContent,
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  Future<void> wheel(
    WidgetTester tester,
    Offset delta, {
    Duration timeStamp = Duration.zero,
  }) => tester.sendEventToBinding(
    PointerScrollEvent(
      timeStamp: timeStamp,
      kind: PointerDeviceKind.mouse,
      position: tester.getCenter(find.byType(ReaderPageView)),
      scrollDelta: delta,
    ),
  );

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
    desktopTest(
      '$mode delayed native wheel dispatch keeps the source gesture',
      (tester) async {
        final reader = await open(tester, mode);
        await wheel(
          tester,
          const Offset(0, 120),
          timeStamp: const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        // A costly frame can delay delivery; only 70ms elapsed at the source.
        await tester.pump(const Duration(milliseconds: 260));
        await wheel(
          tester,
          const Offset(0, 12),
          timeStamp: const Duration(milliseconds: 1070),
        );
        await tester.pumpAndSettle();
        expect(reader.settled, [2]);
        expect(reader.userTurns, 1);
        // A genuinely separate gesture still works, even if events arrive in
        // the same delivery burst after the main thread was occupied.
        await wheel(
          tester,
          const Offset(0, -120),
          timeStamp: const Duration(milliseconds: 1450),
        );
        await tester.pumpAndSettle();
        expect(reader.settled, [2, 1]);
        expect(reader.userTurns, 2);
        await close(tester);
      },
    );

    desktopTest(
      '$mode a wheel burst turns once and never queues an extra page',
      (tester) async {
        final reader = await open(tester, mode);
        for (var event = 0; event < 3; event++) {
          await wheel(tester, const Offset(0, 120));
          await tester.pump(const Duration(milliseconds: 35));
        }
        await tester.pumpAndSettle();
        expect(reader.settled, [2]);
        expect(reader.userTurns, 1);
        expect(reader.pager.currentState!.isBusy, false);

        await tester.pump(const Duration(milliseconds: 220));
        await wheel(tester, const Offset(0, -120));
        await tester.pumpAndSettle();
        expect(reader.settled, [2, 1]);
        expect(reader.userTurns, 2);
        await close(tester);
      },
    );

    desktopTest('$mode trailing wheel momentum after animation does not skip', (
      tester,
    ) async {
      final reader = await open(tester, mode);
      for (var event = 0; event < 12; event++) {
        await wheel(
          tester,
          Offset(0, event == 0 ? 120 : 12 - event.toDouble()),
        );
        await tester.pump(const Duration(milliseconds: 70));
      }
      await tester.pumpAndSettle();
      expect(reader.settled, [2]);
      expect(reader.userTurns, 1);
      await tester.pump(const Duration(milliseconds: 220));
      reader.pager.currentState!.turnToNextPage();
      await tester.pumpAndSettle();
      expect(reader.settled, [2, 3]);
      await close(tester);
    });

    if (mode != 'none') {
      desktopTest(
        '$mode page animation is slightly slower, not an input delay',
        (tester) async {
          final reader = await open(tester, mode);
          reader.pager.currentState!.turnToNextPage();
          await tester.pump();
          expect(reader.pager.currentState!.isBusy, true);
          await tester.pump(
            Duration(milliseconds: mode == 'simulation' ? 320 : 280),
          );
          expect(reader.pager.currentState!.isBusy, true);
          await tester.pumpAndSettle();
          expect(reader.settled, [2]);
          expect(reader.pager.currentState!.isBusy, false);
          await close(tester);
        },
      );
    }
  }

  desktopTest('one wheel gesture requests an unavailable chapter only once', (
    tester,
  ) async {
    final reader = await open(tester, 'none', initialPage: 0);
    for (var event = 0; event < 4; event++) {
      await wheel(tester, const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(reader.boundaries, 1);
    expect(reader.settled, isEmpty);
    await tester.pump(const Duration(milliseconds: 220));
    await wheel(tester, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(reader.settled, [1]);
    await close(tester);
  });

  desktopTest(
    'wheel input during a keyboard turn does not queue a second turn',
    (tester) async {
      final reader = await open(tester, 'cover');
      reader.pager.currentState!.turnToNextPage();
      await tester.pump(const Duration(milliseconds: 40));
      await wheel(tester, const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(reader.settled, [2]);
      await close(tester);
    },
  );

  desktopTest('deliberate repeat page commands still keep their queued turn', (
    tester,
  ) async {
    final reader = await open(tester, 'cover');
    reader.pager.currentState!.turnToNextPage();
    await tester.pump(const Duration(milliseconds: 40));
    reader.pager.currentState!.turnToNextPage();
    await tester.pumpAndSettle();
    expect(reader.settled, [2, 3]);
    await close(tester);
  });

  desktopTest('no-animation turns begin without waiting for wheel quiet time', (
    tester,
  ) async {
    final reader = await open(tester, 'none');
    await wheel(tester, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 16));
    expect(reader.settled, [2]);
    await close(tester);
  });

  desktopTest('nested vertical scrolling consumes the wheel before paging', (
    tester,
  ) async {
    final reader = await open(tester, 'cover', scrollableContent: true);
    await wheel(tester, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(reader.contentScroll.offset, greaterThan(0));
    expect(reader.settled, isEmpty);
    expect(reader.userTurns, 0);
    await close(tester);
  });

  desktopTest('selection and horizontal scroll remain higher priority', (
    tester,
  ) async {
    final reader = await open(tester, 'simulation');
    reader.selection.value = 'selected-paragraph';
    await tester.pump();
    await wheel(tester, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(reader.selection.value, 'selected-paragraph');
    expect(reader.settled, isEmpty);
    reader.selection.value = null;
    await tester.pump();
    await wheel(tester, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(reader.settled, isEmpty);
    await close(tester);
  });
}
