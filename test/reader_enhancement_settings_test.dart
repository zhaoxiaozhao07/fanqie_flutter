import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/services/desktop_shortcut_preferences.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
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
