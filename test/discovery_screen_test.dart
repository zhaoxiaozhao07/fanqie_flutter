import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/discovery.dart';
import 'package:fanqie_flutter/screens/search_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';

Book book(String id) => Book(bookId: id, bookName: '书籍$id', author: '作者');
const category = LibraryCategory(id: 1317, name: '接口新增分类', group: '主题');

class FakeDiscoveryApi extends ApiService {
  final requests = <Map<String, int>>[];
  final categoryRequests = <int>[];
  Future<CategoryCatalog> Function(int)? categoryHandler;
  Future<LibraryPage> Function(Map<String, int>)? pageHandler;

  @override
  Future<CategoryCatalog> getCategories({int gender = 1}) {
    categoryRequests.add(gender);
    return categoryHandler?.call(gender) ??
        Future.value(const CategoryCatalog([category]));
  }

  @override
  Future<LibraryPage> discoverBooks({
    int categoryId = -1,
    int gender = 1,
    int creationStatus = -1,
    int wordCount = -1,
    int sort = 0,
    int page = 1,
  }) {
    final args = {
      'categoryId': categoryId,
      'gender': gender,
      'creationStatus': creationStatus,
      'wordCount': wordCount,
      'sort': sort,
      'page': page,
    };
    requests.add(args);
    return pageHandler?.call(args) ??
        Future.value(LibraryPage([book('1')], hasMore: false));
  }
}

Future<void> mount(
  WidgetTester tester,
  FakeDiscoveryApi api, {
  double scale = 1,
}) async {
  addTearDown(api.dispose);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: SearchScreen(apiService: api),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'category search reaches the full server taxonomy, not a shortlist',
    (tester) async {
      final api = FakeDiscoveryApi()
        ..categoryHandler = (_) async => CategoryCatalog(
          List.generate(
            260,
            (i) => LibraryCategory(
              id: 1000 + i,
              name: '接口类别$i',
              group: i.isEven ? '角色' : '情节',
            ),
          ),
        );
      await mount(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '接口类别259');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-1259')));
      await tester.pumpAndSettle();
      expect(api.requests.last['categoryId'], 1259);
    },
  );

  testWidgets(
    'metadata failure keeps all-category browsing without guessed IDs',
    (tester) async {
      final api = FakeDiscoveryApi()
        ..categoryHandler = (_) async =>
            throw const FanqieApiException('offline');
      await mount(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('分类加载失败，可浏览全部分类或重试'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-1')), findsOneWidget);
      expect(api.requests.single['categoryId'], -1);
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
    },
  );

  testWidgets(
    'dynamic grouped category is selectable; all categories is the default',
    (tester) async {
      final api = FakeDiscoveryApi();
      await mount(tester, api);
      await tester.pumpAndSettle();
      expect(api.requests.single['categoryId'], -1);
      expect(find.text('巅峰榜'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      expect(find.text('主题'), findsOneWidget);
      expect(find.text('接口新增分类'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-1317')));
      await tester.pumpAndSettle();
      expect(api.requests.last['categoryId'], 1317);
      expect(find.text('接口新增分类'), findsOneWidget);
      await tester.tap(find.text('女频'));
      await tester.pumpAndSettle();
      expect(api.categoryRequests.last, 2);
      expect(api.requests.last['gender'], 2);
      expect(api.requests.last['categoryId'], -1);
    },
  );

  testWidgets('advanced filter maps the first and last word bands to 0 and 4', (
    tester,
  ) async {
    final api = FakeDiscoveryApi();
    await mount(tester, api);
    await tester.pumpAndSettle();
    for (final band in {'30万以下': 0, '200万以上': 4}.entries) {
      await tester.tap(find.text('高级筛选'));
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(ChoiceChip, band.key);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      final apply = find.text('确定筛选');
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(api.requests.last['wordCount'], band.value);
    }
  });

  testWidgets('late book response cannot overwrite a new audience', (
    tester,
  ) async {
    final old = Completer<LibraryPage>();
    final api = FakeDiscoveryApi()
      ..pageHandler = (args) => args['gender'] == 0
          ? old.future
          : Future.value(LibraryPage([book('new')], hasMore: false));
    await mount(tester, api);
    await tester.tap(find.text('女频'));
    await tester.pumpAndSettle();
    old.complete(LibraryPage([book('old')], hasMore: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-old')), findsNothing);
  });

  testWidgets('late category metadata cannot overwrite a new audience', (
    tester,
  ) async {
    final old = Completer<CategoryCatalog>();
    final api = FakeDiscoveryApi()
      ..categoryHandler = (gender) => gender == 0
          ? old.future
          : Future.value(
              const CategoryCatalog([
                LibraryCategory(id: 8888, name: '女频新分类', group: '主分类'),
              ]),
            );
    await mount(tester, api);
    await tester.tap(find.text('女频'));
    await tester.pumpAndSettle();
    old.complete(const CategoryCatalog([category]));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-picker')));
    await tester.pumpAndSettle();
    expect(find.text('女频新分类'), findsOneWidget);
    expect(find.text('接口新增分类'), findsNothing);
  });

  testWidgets('has_more stops pagination and duplicate IDs are not appended', (
    tester,
  ) async {
    final api = FakeDiscoveryApi()
      ..pageHandler = (args) async => args['page'] == 1
          ? LibraryPage([book('1')], hasMore: true)
          : LibraryPage([book('1'), book('2')], hasMore: false);
    await mount(tester, api);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-2')), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(api.requests.map((r) => r['page']), [1, 2]);
  });

  testWidgets(
    'load-more error preserves books and retry requests the same page',
    (tester) async {
      var failed = false;
      final api = FakeDiscoveryApi()
        ..pageHandler = (args) async {
          if (args['page'] == 1) return LibraryPage([book('1')], hasMore: true);
          if (!failed) {
            failed = true;
            throw const FanqieApiException('offline');
          }
          return LibraryPage([book('2')], hasMore: false);
        };
      await mount(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-1')), findsOneWidget);
      expect(api.requests.length, 2);
      await tester.tap(find.text('加载更多失败，点击重试'));
      await tester.pumpAndSettle();
      expect(api.requests.map((r) => r['page']), [1, 2, 2]);
      expect(find.byKey(const ValueKey('book-2')), findsOneWidget);
    },
  );

  testWidgets(
    'late pagination response cannot append books to a new audience',
    (tester) async {
      final gate = Completer<LibraryPage>();
      final api = FakeDiscoveryApi()
        ..pageHandler = (args) {
          if (args['gender'] == 2) {
            return Future.value(LibraryPage([book('new')], hasMore: false));
          }
          return args['page'] == 1
              ? Future.value(LibraryPage([book('1')], hasMore: true))
              : gate.future;
        };
      await mount(tester, api);
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.tap(find.text('女频'));
      await tester.pumpAndSettle();
      gate.complete(LibraryPage([book('late')], hasMore: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('book-late')), findsNothing);
      expect(find.text('加载更多'), findsNothing);
    },
  );

  testWidgets('failure is not shown as an empty successful library', (
    tester,
  ) async {
    final api = FakeDiscoveryApi()
      ..pageHandler = (_) async => throw const FanqieApiException('offline');
    await mount(tester, api);
    await tester.pumpAndSettle();
    expect(find.text('书库加载失败，请稍后重试'), findsOneWidget);
    expect(find.text('暂无符合条件的内容'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets(
    'cached metadata is labelled and removed selections reset on refresh',
    (tester) async {
      var removed = false;
      final api = FakeDiscoveryApi()
        ..categoryHandler = (_) async => CategoryCatalog(
          removed
              ? const [LibraryCategory(id: 9999, name: '更新分类', group: '主题')]
              : const [category],
          isCached: true,
        );
      await mount(tester, api);
      await tester.pumpAndSettle();
      expect(find.text('分类使用上次缓存'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-1317')));
      await tester.pumpAndSettle();
      removed = true;
      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      await refresh.onRefresh();
      await tester.pumpAndSettle();
      expect(api.requests.last['categoryId'], -1);
      expect(find.text('接口新增分类'), findsNothing);
    },
  );

  testWidgets('disposed screen ignores pending requests', (tester) async {
    final gate = Completer<LibraryPage>();
    final api = FakeDiscoveryApi()..pageHandler = (_) => gate.future;
    await mount(tester, api);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete(LibraryPage([book('late')], hasMore: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow phone and landscape large text do not overflow', (
    tester,
  ) async {
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final api = FakeDiscoveryApi();
      await mount(tester, api, scale: 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });
}
