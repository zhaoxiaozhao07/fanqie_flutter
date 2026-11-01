import 'dart:convert';

import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final repository = ReaderSettingsRepository();

  test('legacy preferences migrate without changing typography', () async {
    SharedPreferences.setMockInitialValues({
      'reader_font_size': 23.0,
      'reader_font_family': 'serif',
      'reader_is_page_mode': true,
      'reader_theme_index': 4,
    });
    final record = await repository.load('book');
    expect(record.settings.fontSize, 23);
    expect(record.settings.fontFamily, 'serif');
    expect(record.settings.pageMode, true);
    expect(record.settings.themeIndex, 4);
    expect(record.bookOverride, false);
  });
  test(
    'book override does not pollute global or other book settings',
    () async {
      await repository.save(const ReaderSettings(fontSize: 20));
      await repository.save(
        const ReaderSettings(fontSize: 28),
        bookId: 'large',
      );
      expect((await repository.load('large')).settings.fontSize, 28);
      expect((await repository.load('another')).settings.fontSize, 20);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('reader_font_size'), 20);
      await repository.clearBookOverride('large');
      expect((await repository.load('large')).settings.fontSize, 20);
      expect((await repository.load('large')).bookOverride, false);
    },
  );
  test('scheduled night crosses midnight with exact boundary behavior', () {
    const settings = ReaderSettings(themeMode: ReaderThemeMode.scheduled);
    int theme(int hour, int minute) => settings.effectiveTheme(
      systemDark: false,
      now: DateTime(2026, 11, 2, hour, minute),
    );
    expect(theme(21, 59), 1);
    expect(theme(22, 0), 3);
    expect(theme(0, 0), 3);
    expect(theme(6, 59), 3);
    expect(theme(7, 0), 1);
    final manual = settings.copyWith(
      themeMode: ReaderThemeMode.manual,
      themeIndex: 2,
    );
    expect(manual.effectiveTheme(systemDark: true, now: DateTime(2026)), 2);
  });
  test('invalid numbers and enum values fall back to safe settings', () {
    final settings = ReaderSettings.fromJson({
      'fontSize': double.nan,
      'lineHeight': 100,
      'fontFamily': '../../bad.ttf',
      'brightness': -1,
      'themeMode': 'unknown',
      'dayStartMinutes': 60,
      'nightStartMinutes': 60,
    });
    expect(settings.fontSize, 18);
    expect(settings.lineHeight, 2.6);
    expect(settings.fontFamily, 'system');
    expect(settings.brightness, .05);
    expect(settings.dayStartMinutes, 420);
    expect(settings.nightStartMinutes, 1320);
    expect(
      () => ReaderSettings.fromJson({'version': 999}),
      throwsFormatException,
    );
  });
  test('typography presets preserve theme, brightness and reading mode', () {
    const original = ReaderSettings(
      pageMode: true,
      brightness: .2,
      themeMode: ReaderThemeMode.system,
      volumeKeys: true,
    );
    final settings = original.typographyFrom(ReaderSettings.presets['纸书']!);
    expect(settings.fontFamily, 'serif');
    expect(settings.pageMode, true);
    expect(settings.themeMode, ReaderThemeMode.system);
    expect(settings.brightness, .2);
    expect(settings.volumeKeys, true);
  });
  test(
    'concurrent personal preset saves are serialized without losing entries',
    () async {
      await Future.wait(
        List.generate(
          8,
          (i) =>
              repository.savePreset('预设$i', ReaderSettings(fontSize: 18.0 + i)),
        ),
      );
      expect((await repository.loadPresets()).length, 8);
      await expectLater(
        repository.savePreset('第九个', const ReaderSettings()),
        throwsStateError,
      );
      expect((await repository.loadPresets()).length, 8);
      await repository.removePreset('预设0');
      await repository.savePreset('第九个', const ReaderSettings(fontSize: 30));
      expect((await repository.loadPresets())['第九个']!.fontSize, 30);
    },
  );
  test(
    'future settings and malformed presets are not destructively read',
    () async {
      final future = jsonEncode({'version': 999, 'fontSize': 22});
      SharedPreferences.setMockInitialValues({
        ReaderSettingsRepository.globalKey: future,
        ReaderSettingsRepository.presetsKey: jsonEncode({
          '损坏': 'bad',
          '有效': const ReaderSettings(fontSize: 21).toJson(),
        }),
      });
      expect((await repository.load()).settings.fontSize, 18);
      expect((await repository.loadPresets())['有效']!.fontSize, 21);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ReaderSettingsRepository.globalKey), future);
    },
  );
}
