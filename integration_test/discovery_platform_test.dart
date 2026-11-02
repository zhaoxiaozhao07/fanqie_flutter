import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/screens/search_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/app_theme.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android discovery uses server IDs, channel taxonomy and word bands',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final requests = <Uri>[];
      final api = ApiService(
        client: MockClient((request) async {
          requests.add(request.url);
          final p = request.url.queryParameters;
          final data = request.url.path.contains('category_list')
              ? [
                  {
                    'category_id': p['gender'] == '0' ? 8888 : 7777,
                    'name': p['gender'] == '0' ? '女频接口分类' : '接口新增分类',
                    'label': '主分类',
                  },
                ]
              : {
                  'book_list': [
                    {
                      'book_id': 'platform-discovery',
                      'book_name': '平台验证书籍',
                      'author': '测试',
                      'word_count': '20.0万字',
                    },
                  ],
                  'has_more': false,
                  'total_count': 1,
                };
          return http.Response(
            jsonEncode({'code': 0, 'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(api.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: SearchScreen(apiService: api),
        ),
      );
      await tester.pumpAndSettle();
      final screenWidth = MediaQuery.sizeOf(
        tester.element(find.byType(SearchScreen)),
      ).width;
      expect(
        tester.getCenter(find.text('番茄Reader')).dx,
        closeTo(screenWidth / 2, 1),
      );
      expect(
        tester.getCenter(find.text('全部')).dy,
        closeTo(tester.getCenter(find.text('高级筛选')).dy, 1),
      );
      final header = tester.widget<Container>(
        find.byKey(const ValueKey('home-red-header')),
      );
      expect(
        ((header.decoration! as BoxDecoration).gradient! as LinearGradient)
            .colors,
        [const Color(0xFFFFE8E8), Colors.white],
      );
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('category-7777')));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['category_id'], '7777');
      expect(find.text('接口新增分类'), findsOneWidget);

      await tester.tap(find.text('女频'));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['gender'], '0');
      expect(requests.last.queryParameters['category_id'], '-1');
      await tester.tap(find.byKey(const ValueKey('category-picker')));
      await tester.pumpAndSettle();
      expect(find.text('女频接口分类'), findsOneWidget);
      expect(find.text('接口新增分类'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('category-8888')));
      await tester.pumpAndSettle();

      for (final band in {'30万以下': '0', '200万以上': '4'}.entries) {
        await tester.tap(find.text('高级筛选'));
        await tester.pumpAndSettle();
        final chip = find.widgetWithText(ChoiceChip, band.key);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.ensureVisible(find.text('确定筛选'));
        await tester.tap(find.text('确定筛选'));
        await tester.pumpAndSettle();
        expect(requests.last.queryParameters['word_count'], band.value);
        expect(requests.last.queryParameters['category_id'], '8888');
      }
      expect(find.text('巅峰榜'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
