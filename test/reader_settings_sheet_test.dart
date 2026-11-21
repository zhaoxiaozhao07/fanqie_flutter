import 'dart:convert';

import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reader_theme.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_colors_dialog.dart';
import 'package:fanqie_flutter/widgets/reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_settings_repository_test.dart' show ReaderPreferencesDisk;

Future<void> settleSettings(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('failed override removal shows save error and keeps book scope', (
    tester,
  ) async {
    final disk = ReaderPreferencesDisk({
      ReaderSettingsRepository.globalKey: jsonEncode(
        const ReaderSettings(fontSize: 18).toJson(),
      ),
      ReaderSettingsRepository.bookKey('book'): jsonEncode(
        const ReaderSettings(fontSize: 28).toJson(),
      ),
    })..install();
    disk.rejectedKeys.add(
      'flutter.${ReaderSettingsRepository.bookKey('book')}',
    );
    final values = <ReaderSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettingsSheet(
            bookId: 'book',
            settings: const ReaderSettings(fontSize: 28),
            bookOverride: true,
            onChanged: (value, _) async => values.add(value),
          ),
        ),
      ),
    );
    await settleSettings(tester);
    await tester.tap(find.text('仅此书使用这些设置'));
    await settleSettings(tester);
    expect(find.textContaining('设置未保存：'), findsOneWidget);
    expect(values, isEmpty);
    final scope = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '仅此书使用这些设置'),
    );
    expect(scope.value, true);
    expect((await ReaderSettingsRepository().load('book')).bookOverride, true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed personal preset save shows error without adding a chip', (
    tester,
  ) async {
    final disk = ReaderPreferencesDisk({})..install();
    disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.presetsKey}');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettingsSheet(
            bookId: 'book',
            settings: const ReaderSettings(),
            bookOverride: false,
            onChanged: (_, _) async {},
          ),
        ),
      ),
    );
    await settleSettings(tester);
    await tester.tap(find.text('保存为个人预设'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '未写入');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await settleSettings(tester);
    expect(find.textContaining('设置未保存：'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '未写入'), findsNothing);
    expect(await ReaderSettingsRepository().loadPresets(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed personal preset removal shows error and keeps its chip', (
    tester,
  ) async {
    final disk = ReaderPreferencesDisk({
      ReaderSettingsRepository.presetsKey: jsonEncode({
        '晚读': const ReaderSettings(fontSize: 21).toJson(),
      }),
    })..install();
    disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.presetsKey}');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettingsSheet(
            bookId: 'book',
            settings: const ReaderSettings(),
            bookOverride: false,
            onChanged: (_, _) async {},
          ),
        ),
      ),
    );
    await settleSettings(tester);
    final chip = find.widgetWithText(InputChip, '晚读');
    await tester.tap(
      find.descendant(of: chip, matching: find.byTooltip('Delete')),
    );
    await settleSettings(tester);
    expect(find.textContaining('设置未保存：'), findsOneWidget);
    expect(chip, findsOneWidget);
    expect(
      (await ReaderSettingsRepository().loadPresets()).containsKey('晚读'),
      true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'custom color apply rejects below 4.5 and returns the readable pair',
    (tester) async {
      (int, int)? applied;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    applied = await showDialog<(int, int)>(
                      context: context,
                      builder: (_) =>
                          ReaderColorsDialog(theme: ReaderTheme.presets[0]),
                    );
                  },
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'FFFFFF');
      await tester.enterText(find.byType(TextField).last, '777777');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).last, '767676');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await tester.enterText(find.byType(TextField).last, 'ZZZZZZ');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).last, '767676');
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(applied, (0xFFFFFFFF, 0xFF767676));
    },
  );

  testWidgets(
    'custom preview shows readable roles without overflow at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = ReaderTheme.presets[0].withColors(
        background: 0xFFFFFFFF,
        text: 0xFF000000,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(3)),
            child: child!,
          ),
          home: Scaffold(body: ReaderColorsDialog(theme: theme)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in ['正文：', '次要文字：', '高亮：']) {
        final finder = find.textContaining(label);
        expect(finder, findsOneWidget);
        final text = tester.widget<Text>(finder);
        final foreground = text.style!.color!;
        final background = tester
            .widget<Container>(
              find.ancestor(of: finder, matching: find.byType(Container)).first,
            )
            .color!;
        final x = foreground.computeLuminance();
        final y = background.computeLuminance();
        expect(
          ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05),
          greaterThanOrEqualTo(4.5),
        );
        if (label == '次要文字：') {
          expect(foreground, isNot(const Color(0xFF000000)));
        } else {
          expect(foreground.toARGB32(), 0xFF000000);
        }
        if (label == '高亮：') {
          expect(background, isNot(const Color(0xFFFFFFFF)));
        } else {
          expect(background.toARGB32(), 0xFFFFFFFF);
        }
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('appended palettes update day/night selection by brightness', (
    tester,
  ) async {
    final values = <ReaderSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderSettingsSheet(
            bookId: 'palette',
            settings: const ReaderSettings(),
            bookOverride: false,
            onChanged: (settings, _) async => values.add(settings),
          ),
        ),
      ),
    );
    await settleSettings(tester);
    // Catch both missing palettes and the legacy index < 3 classification.
    expect(find.text('雾蓝'), findsOneWidget);
    await tester.ensureVisible(find.text('雾蓝'));
    await tester.tap(find.text('雾蓝'));
    await settleSettings(tester);
    expect(values.last.dayThemeIndex, 6);
    expect(values.last.nightThemeIndex, 3);
    await tester.tap(find.text('暖暗'));
    await settleSettings(tester);
    expect(values.last.dayThemeIndex, 6);
    expect(values.last.nightThemeIndex, 8);
    await tester.ensureVisible(find.text('保存为个人预设'));
    await tester.tap(find.text('保存为个人预设'));
    await settleSettings(tester);
    expect(
      Theme.of(tester.element(find.byType(AlertDialog))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.text('取消'));
    await settleSettings(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
