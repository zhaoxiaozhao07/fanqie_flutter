import 'dart:async';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/download_history.dart';
import 'package:fanqie_flutter/screens/bookshelf_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/history_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/widgets/book_cover_widget.dart';
import 'package:fanqie_flutter/widgets/book_page_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiService {
  Completer<List<Chapter>>? directory;
  int searches = 0;
  @override
  Future<List<Book>> searchBooks(String keyword, {int offset = 0}) async {
    searches++;
    return [];
  }

  @override
  Future<Book?> getBookDetail(String id) async => null;
  @override
  Future<List<Chapter>> getBookChapters(String id, {bool refresh = false}) =>
      directory?.future ??
      Future.value([Chapter(itemId: 'c', title: '章', content: '可以稳定阅读的正文。')]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.fanqie.fanqie_flutter/download');
  late BookshelfService shelf;
  late HistoryService history;
  late _Api api;
  var checks = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    checks = 0;
    shelf = BookshelfService.forTesting(
      directoryLoader: (_) async {
        checks++;
        return List.generate(10, (i) => Chapter(itemId: 'c$i', title: '章'));
      },
    );
    history = HistoryService.forTesting();
    api = _Api();
    for (var i = 0; i < 15; i++) {
      await shelf.addToBookshelf(
        Book(bookId: 'local_b$i', bookName: '书籍$i', author: '作者'),
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (_) async => null);
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null),
  );

  Future<void> mount(
    WidgetTester tester,
    GlobalKey<BookshelfScreenState> key,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: StatefulBuilder(
          builder: (context, setState) =>
              _Tabs(shelfKey: key, shelf: shelf, history: history, api: api),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'local notifications and retabbing retain rows, scroll and never blank the shelf',
    (tester) async {
      final key = GlobalKey<BookshelfScreenState>();
      await mount(tester, key);
      final list = find.byKey(const PageStorageKey('favorites-list'));
      final state = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      );
      await tester.drag(list, const Offset(0, -380));
      await tester.pumpAndSettle();
      final offset = state.position.pixels;
      final rows = tester.elementList(find.byType(BookCoverWidget)).toList();
      for (var i = 0; i < 5; i++) {
        await key.currentState!.refresh();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(state.position.pixels, offset);
        await tester.tap(find.text('切换页面'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('切换页面'));
        await tester.pumpAndSettle();
        expect(state.position.pixels, offset);
      }
      expect(tester.elementList(find.byType(BookCoverWidget)).toList(), rows);
      expect(checks, 0);
      expect(api.searches, 0); // Local books never perform name searches.
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('reordering retains the cover state for each book ID', (
    tester,
  ) async {
    final key = GlobalKey<BookshelfScreenState>();
    await mount(tester, key);
    final row = find.byKey(const ValueKey('local_b13'));
    final image = find.descendant(
      of: row,
      matching: find.byType(BookCoverWidget),
    );
    final element = tester.element(image);
    await tester.runAsync(
      () => shelf.updateReadingProgress('local_b13', 2, '新进度'),
    );
    await tester.pumpAndSettle();
    expect(tester.element(image), same(element));
    expect(
      tester.getTopLeft(row).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('local_b14'))).dy),
    );
    for (var i = 0; i < 4; i++) {
      await key.currentState!.refresh();
      await tester.pumpAndSettle();
      expect(tester.element(image), same(element));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a new download updates retained shelf via notification without tab reload',
    (tester) async {
      await mount(tester, GlobalKey<BookshelfScreenState>());
      await tester.runAsync(
        () => history.addHistory(
          DownloadHistory(
            bookId: 'local_download',
            bookName: '下载书',
            author: '作者',
            creationStatus: '完结',
            wordNumber: 100,
            format: 'TXT',
            filePath: '/tmp/download.txt',
            fileSize: 1,
            downloadTime: DateTime.now(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已下载 (1)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'opening uses inline progress, one route, and no fading dialog/snapshot',
    (tester) async {
      await mount(tester, GlobalKey<BookshelfScreenState>());
      api.directory = Completer<List<Chapter>>();
      final barriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(find.text('开读').first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ModalBarrier).evaluate().length, barriers);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('shelf-opening')), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey('favorites-list')),
        findsOneWidget,
      );
      api.directory!.complete([
        Chapter(itemId: 'c', title: '稳定章节', content: '可以稳定阅读的正文。'),
      ]);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(ReaderScreen)))!;
      expect(route, isA<BookPageRoute>());
      expect(route.allowSnapshotting, false);
      expect(find.textContaining('可以稳定阅读', findRichText: true), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    '20-count tabs and three-column cards fit a narrow screen at large text',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 15; i < 20; i++) {
          await shelf.addToBookshelf(
            Book(bookId: 'local_b$i', bookName: '书籍$i', author: '作者'),
          );
        }
      });
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: BookshelfScreen(
              bookshelfService: shelf,
              historyService: history,
              apiService: api,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('切换为三列视图'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const PageStorageKey('favorites-grid')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        // The next mounted shelf starts in list mode before exercising the toggle.
        await tester.runAsync(() async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('bookshelf_view_mode', 'list');
        });
      }
    },
  );
}

class _Tabs extends StatefulWidget {
  final GlobalKey<BookshelfScreenState> shelfKey;
  final BookshelfService shelf;
  final HistoryService history;
  final ApiService api;
  const _Tabs({
    required this.shelfKey,
    required this.shelf,
    required this.history,
    required this.api,
  });
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  bool active = true;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: active ? 0 : 1,
      children: [
        BookshelfScreen(
          key: widget.shelfKey,
          isActive: active,
          bookshelfService: widget.shelf,
          historyService: widget.history,
          apiService: widget.api,
        ),
        const SizedBox.expand(),
      ],
    ),
    bottomNavigationBar: TextButton(
      onPressed: () => setState(() => active = !active),
      child: const Text('切换页面'),
    ),
  );
}
