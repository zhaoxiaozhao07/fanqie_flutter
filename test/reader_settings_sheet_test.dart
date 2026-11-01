import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> settleSettings(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'book-specific presets are isolated and can restore global settings',
    (tester) async {
      final repository = ReaderSettingsRepository();
      await repository.save(const ReaderSettings(fontSize: 18));
      final values = <(ReaderSettings, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSettingsSheet(
              bookId: 'book',
              settings: const ReaderSettings(),
              bookOverride: false,
              onChanged: (settings, scope) async =>
                  values.add((settings, scope)),
            ),
          ),
        ),
      );
      await settleSettings(tester);
      await tester.tap(find.text('仅此书使用这些设置'));
      await settleSettings(tester);
      await tester.tap(find.text('大字'));
      await settleSettings(tester);
      expect(values.last.$1.fontSize, 28);
      expect(values.last.$2, true);
      expect((await repository.load('book')).settings.fontSize, 28);
      expect((await repository.load()).settings.fontSize, 18);
      await tester.ensureVisible(find.text('仅此书使用这些设置'));
      await tester.tap(find.text('仅此书使用这些设置'));
      await settleSettings(tester);
      expect(values.last.$1.fontSize, 18);
      expect(values.last.$2, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dark preset dialog inherits night theme and saves personal typography',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSettingsSheet(
              bookId: 'night',
              settings: const ReaderSettings(themeIndex: 3),
              bookOverride: false,
              onChanged: (_, _) async {},
            ),
          ),
        ),
      );
      await settleSettings(tester);
      await tester.tap(find.text('保存为个人预设'));
      await settleSettings(tester);
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        Brightness.dark,
      );
      await tester.enterText(find.byType(TextField), '晚读');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await settleSettings(tester);
      expect(
        (await ReaderSettingsRepository().loadPresets()).containsKey('晚读'),
        true,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
