import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/desktop_shortcut_preferences.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final day in [5, 6, 7]) {
    test(
      'appended day $day and warm-dark palettes survive storage and switching',
      () async {
        final settings = const ReaderSettings().copyWith(
          themeIndex: day,
          dayThemeIndex: day,
          nightThemeIndex: 8,
          themeMode: ReaderThemeMode.system,
        );
        await ReaderSettingsRepository().save(settings);
        final loaded = (await ReaderSettingsRepository().load()).settings;
        expect(loaded.themeIndex, day);
        expect(loaded.dayThemeIndex, day);
        expect(loaded.nightThemeIndex, 8);
        expect(
          loaded.effectiveTheme(systemDark: false, now: DateTime(2026)),
          day,
        );
        expect(loaded.effectiveTheme(systemDark: true, now: DateTime(2026)), 8);
        final scheduled = loaded.copyWith(themeMode: ReaderThemeMode.scheduled);
        expect(
          scheduled.effectiveTheme(
            systemDark: false,
            now: DateTime(2026, 1, 1, 22),
          ),
          8,
        );
        expect(
          scheduled.effectiveTheme(
            systemDark: true,
            now: DateTime(2026, 1, 2, 7),
          ),
          day,
        );
      },
    );
  }
  test(
    'legacy v2 palettes and low-contrast custom colors remain unchanged on read',
    () async {
      for (var index = 0; index < 5; index++) {
        final original = ReaderSettings(
          themeIndex: index,
          dayThemeIndex: index < 3 ? index : 1,
          nightThemeIndex: index >= 3 ? index : 3,
          customBackground: 0xFF777777,
          customText: 0xFF888888,
        );
        final loaded = ReaderSettings.fromJson(original.toJson());
        expect(loaded.toJson(), original.toJson());
      }
      expect(ReaderSettings.fromJson({'version': 2}).themeIndex, 1);
      expect(ReaderSettings.fromJson({'version': 2}).dayThemeIndex, 1);
      expect(ReaderSettings.fromJson({'version': 2}).nightThemeIndex, 3);
    },
  );
  test('day and night selections reject palettes of the wrong brightness', () {
    final settings = ReaderSettings.fromJson({
      'themeIndex': 8,
      'dayThemeIndex': 8,
      'nightThemeIndex': 7,
    });
    expect(settings.themeIndex, 8);
    expect(settings.dayThemeIndex, 1);
    expect(settings.nightThemeIndex, 3);
  });
  test(
    'new settings validate limits without changing old schema or anchors',
    () async {
      final old = ReaderSettings.fromJson({'version': 2});
      expect(old.animationSpeed, 1);
      expect(old.tapToTurn, true);
      final next = old.copyWith(
        animationSpeed: 1.4,
        tapToTurn: false,
        columnGap: 40,
        lineCharacters: 28,
        displayScript: 'traditional',
        customBackground: 0xFFF8F2E0,
        customText: 0xFF242424,
      );
      await ReaderSettingsRepository().save(next);
      final loaded = (await ReaderSettingsRepository().load()).settings;
      expect(loaded.toJson(), next.toJson());
      expect(loaded.copyWith(clearCustomColors: true).customText, isNull);
      final clamped = ReaderSettings.fromJson({
        'animationSpeed': double.nan,
        'columnGap': 10000,
        'lineCharacters': -1,
        'displayScript': 'unknown',
      });
      expect(clamped.animationSpeed, 1);
      expect(clamped.columnGap, 80);
      expect(clamped.lineCharacters, 0);
      expect(clamped.displayScript, 'original');
    },
  );
  test(
    'shortcut collisions and unsafe editing/system bindings are rejected',
    () async {
      final service = DesktopShortcutPreferences();
      await service.load();
      await expectLater(
        service.set(
          'directory',
          ReaderShortcut(LogicalKeyboardKey.keyF.keyId, meta: true),
        ),
        throwsFormatException,
      );
      await expectLater(
        service.set(
          'directory',
          ReaderShortcut(LogicalKeyboardKey.keyC.keyId, meta: true),
        ),
        throwsFormatException,
      );
      await expectLater(
        service.set('directory', ReaderShortcut(LogicalKeyboardKey.keyB.keyId)),
        throwsFormatException,
      );
      await service.set(
        'directory',
        ReaderShortcut(LogicalKeyboardKey.keyB.keyId, meta: true, shift: true),
      );
      await service.load();
      expect(service.bindings['directory']!.key, LogicalKeyboardKey.keyB.keyId);
      expect(service.bindings['directory']!.shift, true);
      await service.set('directory', null);
      expect(service.bindings['directory']!.key, LogicalKeyboardKey.keyD.keyId);
    },
  );
}
