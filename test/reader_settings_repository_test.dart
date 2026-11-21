import 'dart:async';
import 'dart:convert';

import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only injection at the plugin boundary; no repository methods are mocked.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class ReaderPreferencesDisk extends InMemorySharedPreferencesStore {
  final Set<String> rejectedKeys = {};

  ReaderPreferencesDisk(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });

  void install() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = this;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      rejectedKeys.contains(key)
      ? Future.value(false)
      : super.setValue(valueType, key, value);

  @override
  Future<bool> remove(String key) =>
      rejectedKeys.contains(key) ? Future.value(false) : super.remove(key);
}

/// Models Windows' optimistic store cache and whole-map file writes separately
/// from SharedPreferences' public cache. False writes do not undo the mutation.
class OptimisticReaderPreferencesDisk extends InMemorySharedPreferencesStore {
  Map<String, Object> durableValues;
  final Set<String> rejectedKeys = {};
  final bool durableReads;
  bool delayNextRead = false;
  final readCaptured = Completer<void>();
  final releaseRead = Completer<void>();
  String? delayedWriteKey;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  OptimisticReaderPreferencesDisk(
    Map<String, Object> values, {
    this.durableReads = false,
  }) : durableValues = {
         for (final entry in values.entries)
           'flutter.${entry.key}': entry.value,
       },
       super.withData({
         for (final entry in values.entries)
           'flutter.${entry.key}': entry.value,
       });

  void install() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = this;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    final snapshot = durableReads
        ? Map<String, Object>.from(durableValues)
        : await super.getAll();
    if (delayNextRead) {
      delayNextRead = false;
      readCaptured.complete();
      await releaseRead.future;
    }
    return snapshot;
  }

  Future<bool> _write(String key) async {
    if (key == delayedWriteKey && !writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    if (rejectedKeys.contains(key)) return false;
    durableValues = await super.getAll();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    return _write(key);
  }

  @override
  Future<bool> remove(String key) async {
    await super.remove(key);
    return _write(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final repository = ReaderSettingsRepository();

  test(
    'Windows optimistic failed override removal cannot enter a later whole-map write',
    () async {
      final key = ReaderSettingsRepository.bookKey('windows');
      final original = jsonEncode(const ReaderSettings(fontSize: 28).toJson());
      final disk = OptimisticReaderPreferencesDisk({key: original})..install();
      disk.rejectedKeys.add('flutter.$key');
      await expectLater(
        repository.clearBookOverride('windows'),
        throwsStateError,
      );
      expect((await repository.load('windows')).bookOverride, true);
      // Reopening preferences must also see the restored platform cache.
      await (await SharedPreferences.getInstance()).reload();
      expect((await repository.load('windows')).settings.fontSize, 28);
      await repository.savePreset('later', const ReaderSettings(fontSize: 25));
      expect(disk.durableValues['flutter.$key'], original);
      expect((await repository.loadPresets())['later']!.fontSize, 25);
    },
  );

  test(
    'Windows optimistic failed new book save restores key absence',
    () async {
      final key = ReaderSettingsRepository.bookKey('new');
      final disk = OptimisticReaderPreferencesDisk({})..install();
      disk.rejectedKeys.add('flutter.$key');
      await expectLater(
        repository.save(const ReaderSettings(fontSize: 30), bookId: 'new'),
        throwsStateError,
      );
      expect((await repository.load('new')).bookOverride, false);
      await (await SharedPreferences.getInstance()).reload();
      expect((await repository.load('new')).bookOverride, false);
      await repository.savePreset('later', const ReaderSettings());
      expect(disk.durableValues.containsKey('flutter.$key'), false);
    },
  );

  test(
    'Windows optimistic failed global replacement retains confirmed settings',
    () async {
      final original = jsonEncode(const ReaderSettings(fontSize: 21).toJson());
      final disk = OptimisticReaderPreferencesDisk({
        ReaderSettingsRepository.globalKey: original,
      })..install();
      disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.globalKey}');
      await expectLater(
        repository.save(const ReaderSettings(fontSize: 30)),
        throwsStateError,
      );
      expect((await repository.load()).settings.fontSize, 21);
      await repository.savePreset('later', const ReaderSettings());
      expect(
        disk.durableValues['flutter.${ReaderSettingsRepository.globalKey}'],
        original,
      );
    },
  );

  for (final operation in ['save', 'remove']) {
    test(
      'Windows optimistic failed preset $operation retains confirmed collection',
      () async {
        final original = jsonEncode({
          'existing': const ReaderSettings(fontSize: 21).toJson(),
        });
        final disk = OptimisticReaderPreferencesDisk({
          ReaderSettingsRepository.presetsKey: original,
        })..install();
        disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.presetsKey}');
        await expectLater(
          operation == 'save'
              ? repository.savePreset(
                  'failed',
                  const ReaderSettings(fontSize: 30),
                )
              : repository.removePreset('existing'),
          throwsStateError,
        );
        expect((await repository.loadPresets()).keys, ['existing']);
        await (await SharedPreferences.getInstance()).reload();
        expect((await repository.loadPresets()).keys, ['existing']);
        await repository.save(
          const ReaderSettings(fontSize: 25),
          bookId: 'later',
        );
        expect(
          disk.durableValues['flutter.${ReaderSettingsRepository.presetsKey}'],
          original,
        );
      },
    );
  }

  for (final (key, previous) in <(String, Object)>[
    ('reader_font_size', 21.0),
    ('reader_font_family', 'serif'),
    ('reader_theme_index', 2),
    ('reader_is_page_mode', true),
  ]) {
    test(
      'Windows optimistic failed mirror $key restores its original type and value',
      () async {
        final disk = OptimisticReaderPreferencesDisk({key: previous})
          ..install();
        disk.rejectedKeys.add('flutter.$key');
        await expectLater(
          repository.save(const ReaderSettings()),
          throwsStateError,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.get(key), previous);
        expect(prefs.get(key).runtimeType, previous.runtimeType);
        await prefs.reload();
        expect(prefs.get(key), previous);
        expect(prefs.get(key).runtimeType, previous.runtimeType);
        await repository.savePreset('later', const ReaderSettings());
        expect(disk.durableValues['flutter.$key'], previous);
      },
    );
  }

  test(
    'Windows optimistic cross-key write waits for failed mutation compensation',
    () async {
      final key = ReaderSettingsRepository.bookKey('held');
      final original = jsonEncode(const ReaderSettings(fontSize: 28).toJson());
      final disk = OptimisticReaderPreferencesDisk({key: original})..install();
      disk.rejectedKeys.add('flutter.$key');
      disk.delayedWriteKey = 'flutter.$key';
      final failed = expectLater(
        repository.clearBookOverride('held'),
        throwsStateError,
      );
      await disk.writeStarted.future;
      final success = ReaderSettingsRepository().savePreset(
        'concurrent',
        const ReaderSettings(fontSize: 25),
      );
      // Drain runnable work while the first disk write is deliberately held.
      await pumpEventQueue();
      disk.releaseWrite.complete();
      await Future.wait([failed, success]);
      expect(disk.durableValues['flutter.$key'], original);
      expect((await repository.load('held')).bookOverride, true);
      expect((await repository.loadPresets()).keys, ['concurrent']);
    },
  );

  test(
    'delayed recovery snapshot cannot erase a successful different-key preset',
    () async {
      final key = ReaderSettingsRepository.bookKey('race');
      final disk = OptimisticReaderPreferencesDisk({
        key: jsonEncode(const ReaderSettings(fontSize: 28).toJson()),
      }, durableReads: true)..install();
      await SharedPreferences.getInstance();
      disk.rejectedKeys.add('flutter.$key');
      disk.delayNextRead = true;
      final failed = expectLater(
        repository.clearBookOverride('race'),
        throwsStateError,
      );
      // Old recovery captures a read here. Key-scoped recovery instead finishes
      // without reading. Neither path needs sleeps or a timeout to select it.
      await Future.any([disk.readCaptured.future, failed]);
      final successful = ReaderSettingsRepository().savePreset(
        'successful',
        const ReaderSettings(fontSize: 25),
      );
      await pumpEventQueue();
      disk.releaseRead.complete();
      await Future.wait([failed, successful]);
      expect((await repository.loadPresets()).keys, ['successful']);
      await repository.savePreset('next', const ReaderSettings(fontSize: 30));
      final stored =
          jsonDecode(
                disk.durableValues['flutter.${ReaderSettingsRepository.presetsKey}']!
                    as String,
              )
              as Map;
      expect(stored.keys, ['successful', 'next']);
      expect((await repository.loadPresets()).keys, ['successful', 'next']);
    },
  );

  test('failed override removal throws and retains persisted scope', () async {
    final disk = ReaderPreferencesDisk({
      ReaderSettingsRepository.bookKey('book'): jsonEncode(
        const ReaderSettings(fontSize: 28).toJson(),
      ),
    })..install();
    disk.rejectedKeys.add(
      'flutter.${ReaderSettingsRepository.bookKey('book')}',
    );
    await expectLater(repository.clearBookOverride('book'), throwsStateError);
    final record = await repository.load('book');
    expect(record.bookOverride, true);
    expect(record.settings.fontSize, 28);
  });

  for (final operation in ['save', 'remove']) {
    test(
      'failed preset $operation throws and does not cache an unpersisted change',
      () async {
        final disk = ReaderPreferencesDisk({
          ReaderSettingsRepository.presetsKey: jsonEncode({
            'existing': const ReaderSettings(fontSize: 21).toJson(),
          }),
        })..install();
        disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.presetsKey}');
        await expectLater(
          operation == 'save'
              ? repository.savePreset('new', const ReaderSettings(fontSize: 30))
              : repository.removePreset('existing'),
          throwsStateError,
        );
        final presets = await repository.loadPresets();
        expect(presets.keys, ['existing']);
        expect(presets['existing']!.fontSize, 21);
        // A failed serialized task must not poison the next write.
        disk.rejectedKeys.clear();
        await repository.savePreset(
          'retry',
          const ReaderSettings(fontSize: 25),
        );
        expect((await repository.loadPresets()).keys, ['existing', 'retry']);
      },
    );
  }

  test(
    'failed global write does not leave an unpersisted cached setting',
    () async {
      final disk = ReaderPreferencesDisk({
        ReaderSettingsRepository.globalKey: jsonEncode(
          const ReaderSettings(fontSize: 21).toJson(),
        ),
      })..install();
      disk.rejectedKeys.add('flutter.${ReaderSettingsRepository.globalKey}');
      await expectLater(
        repository.save(const ReaderSettings(fontSize: 30)),
        throwsStateError,
      );
      expect((await repository.load()).settings.fontSize, 21);
    },
  );

  test('failed compatibility mirror reports persistence failure', () async {
    final disk = ReaderPreferencesDisk({})..install();
    disk.rejectedKeys.add('flutter.reader_theme_index');
    await expectLater(
      repository.save(const ReaderSettings(themeIndex: 8)),
      throwsStateError,
    );
  });

  test(
    'preset mutations preserve malformed and future sibling entries',
    () async {
      final original = {
        'bad': 'not a settings object',
        'future': {
          'version': 999,
          'unknown': [1, 2, 3],
        },
        'existing': const ReaderSettings(fontSize: 21).toJson(),
      };
      SharedPreferences.setMockInitialValues({
        ReaderSettingsRepository.presetsKey: jsonEncode(original),
      });
      await repository.savePreset('new', const ReaderSettings(fontSize: 30));
      await repository.removePreset('existing');
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString(ReaderSettingsRepository.presetsKey)!)
              as Map;
      expect(stored['bad'], original['bad']);
      expect(stored['future'], original['future']);
      expect(stored.containsKey('existing'), false);
      expect((await repository.loadPresets())['new']!.fontSize, 30);
    },
  );

  for (final raw in ['not JSON', '[]', '{"future":{"version":999}}']) {
    test(
      'unreadable preset data is not destroyed by save or remove: $raw',
      () async {
        SharedPreferences.setMockInitialValues({
          ReaderSettingsRepository.presetsKey: raw,
        });
        if (raw.contains('future')) {
          await expectLater(
            repository.savePreset('future', const ReaderSettings()),
            throwsStateError,
          );
          await expectLater(
            repository.removePreset('future'),
            throwsStateError,
          );
        } else {
          await expectLater(
            repository.savePreset('new', const ReaderSettings()),
            throwsStateError,
          );
          await expectLater(repository.removePreset('new'), throwsStateError);
        }
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(ReaderSettingsRepository.presetsKey), raw);
      },
    );
  }

  test(
    'future or malformed settings cannot be silently overwritten or cleared',
    () async {
      const future = '{"version":999,"unknown":"preserve"}';
      const malformed = 'not JSON';
      SharedPreferences.setMockInitialValues({
        ReaderSettingsRepository.globalKey: future,
        ReaderSettingsRepository.bookKey('book'): malformed,
      });
      await expectLater(
        repository.save(const ReaderSettings()),
        throwsStateError,
      );
      await expectLater(
        repository.save(const ReaderSettings(), bookId: 'book'),
        throwsStateError,
      );
      await expectLater(repository.clearBookOverride('book'), throwsStateError);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ReaderSettingsRepository.globalKey), future);
      expect(
        prefs.getString(ReaderSettingsRepository.bookKey('book')),
        malformed,
      );
    },
  );

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
