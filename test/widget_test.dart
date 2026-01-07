import 'package:flutter_test/flutter_test.dart';
import 'package:fanqie_flutter/main.dart';

void main() {
  testWidgets('App loads correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FanqieApp());

    // Verify that the app loads with the search screen.
    expect(find.text('番茄小说'), findsOneWidget);
  });
}
