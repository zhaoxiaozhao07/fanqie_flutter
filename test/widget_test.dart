import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fanqie_flutter/main.dart';
import 'package:fanqie_flutter/widgets/download_action_button.dart';
import 'package:fanqie_flutter/widgets/download_manager_sheet.dart';

void main() {
  testWidgets('App loads correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FanqieApp());

    // Verify that the app loads with the search screen.
    expect(find.text('番茄Reader'), findsOneWidget);
    expect(find.byType(DownloadActionButton), findsOneWidget);
  });

  testWidgets('DownloadManagerSheet can open and display empty state', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DownloadManagerSheet(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('下载任务管理'), findsOneWidget);
    expect(find.text('暂无进行中的下载任务'), findsOneWidget);
  });
}
