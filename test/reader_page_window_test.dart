import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PageContent extends StatefulWidget {
  final int id;
  final Color color;

  const _PageContent({super.key, required this.id, required this.color});

  @override
  State<_PageContent> createState() => _PageContentState();
}

class _PageContentState extends State<_PageContent> {
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.color,
    child: Center(child: Text('page-${widget.id}')),
  );
}

class _WindowReader extends StatefulWidget {
  final String mode;

  const _WindowReader({super.key, required this.mode});

  @override
  State<_WindowReader> createState() => _WindowReaderState();
}

class _WindowReaderState extends State<_WindowReader> {
  final pager = GlobalKey<ReaderPageViewState>();
  final selection = ValueNotifier<String?>(null);
  List<int> ids = [1, 2, 3];
  var current = 2;
  var version = 0;
  var color = Colors.white;
  final settled = <int>[];

  void prepend() => setState(() => ids = [0, ...ids]);
  void trim() => setState(() => ids = [current - 1, current, current + 1]);
  void repaint() => setState(() {
    color = Colors.blueGrey;
    version++;
  });

  @override
  void dispose() {
    selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ReaderPageView(
        key: pager,
        pages: [
          for (final id in ids)
            ReaderPageItem(
              id: id,
              builder: (_) => _PageContent(
                key: ValueKey('content-$id'),
                id: id,
                color: color,
              ),
            ),
        ],
        currentPageId: current,
        contentVersion: version,
        mode: widget.mode,
        backgroundColor: color,
        isDark: false,
        selection: selection,
        onPageSettled: (page) => setState(() {
          current = page.id as int;
          settled.add(current);
        }),
        onPreviousBoundary: () {},
        onNextBoundary: () {},
        onCenterTap: () {},
        onDismissSelection: () => selection.value = null,
        lastBubbleTap: () => DateTime.fromMillisecondsSinceEpoch(0),
      ),
    ),
  );
}

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final mode in ['cover', 'slide', 'fade', 'none', 'simulation']) {
      testWidgets(
        '${platform == TargetPlatform.macOS ? "Mac" : "Windows"} $mode prepending a cached page retains the mounted current page',
        (tester) async {
          final previousPlatform = debugDefaultTargetPlatformOverride;
          debugDefaultTargetPlatformOverride = platform;
          final key = GlobalKey<_WindowReaderState>();
          try {
            await tester.pumpWidget(_WindowReader(key: key, mode: mode));
            await tester.pumpAndSettle();
            final content = tester.state(
              find.byKey(const ValueKey('content-2')),
            );
            final pageView = find.byType(PageView);
            final controller = pageView.evaluate().isEmpty
                ? null
                : tester.widget<PageView>(pageView).controller;
            key.currentState!.prepend();
            await tester.pumpAndSettle();
            expect(key.currentState!.pager.currentState!.currentPageId, 2);
            expect(
              tester.state(find.byKey(const ValueKey('content-2'))),
              same(content),
            );
            if (controller != null) {
              expect(
                tester.widget<PageView>(pageView).controller,
                same(controller),
              );
            }
            expect(key.currentState!.settled, isEmpty);
            key.currentState!.pager.currentState!.turnToNextPage();
            await tester.pumpAndSettle();
            expect(key.currentState!.settled, [3]);
            final next = tester.state(find.byKey(const ValueKey('content-3')));
            key.currentState!.trim();
            await tester.pumpAndSettle();
            expect(key.currentState!.pager.currentState!.currentPageId, 3);
            expect(
              tester.state(find.byKey(const ValueKey('content-3'))),
              same(next),
            );
            expect(key.currentState!.settled, [3]);
            expect(tester.takeException(), isNull);
          } finally {
            try {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpAndSettle();
            } finally {
              debugDefaultTargetPlatformOverride = previousPlatform;
            }
          }
        },
      );
    }
  }
}
