import 'dart:io';
import 'dart:typed_data';
import 'package:fanqie_flutter/services/external_reader_fonts.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ExternalReaderFonts fonts;
  late Uint8List bytes;
  setUpAll(() async {
    bytes = await File('assets/fonts/ZCOOLXiaoWei-Regular.ttf').readAsBytes();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('reader-font-tests-');
    fonts = ExternalReaderFonts.forTesting(
      documents: () async => root,
      loadBytes: (_, _) async {},
    );
  });
  tearDown(() async {
    fonts.dispose();
    await root.delete(recursive: true);
  });
  test(
    'bundled SFNT validates; truncated, overlapping and disguised fonts reject',
    () {
      final inspection = inspectReaderFont(bytes);
      expect(inspection.format, 'ttf');
      expect(inspection.hash.length, 64);
      expect(
        () => inspectReaderFont(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      final damaged = Uint8List.fromList(bytes)..[0] = 0x77;
      expect(() => inspectReaderFont(damaged), throwsFormatException);
      final truncated = Uint8List.sublistView(bytes, 0, 1000);
      expect(() => inspectReaderFont(truncated), throwsFormatException);
      final overlap = Uint8List.fromList(bytes);
      final view = ByteData.sublistView(overlap);
      view.setUint32(12 + 8, view.getUint32(28 + 8));
      expect(() => inspectReaderFont(overlap), throwsFormatException);
    },
  );
  test(
    'imports are deduplicated, owned, preview-ready and deletion leaves source',
    () async {
      final source = File('${root.path}/source.ttf');
      await source.writeAsBytes(bytes);
      final font = await fonts.importFile(source);
      expect(fonts.fonts.length, 1);
      expect(fonts.familyFor(font.id), 'ReaderExternal_${font.hash}');
      expect(await (await fonts.fileFor(font)).exists(), true);
      expect((await fonts.importFile(source)).id, font.id);
      expect(fonts.fonts.length, 1);
      await fonts.remove(font.id);
      expect(fonts.fonts, isEmpty);
      expect(fonts.familyFor(font.id), isNull);
      expect(await source.exists(), true);
      await expectLater(fonts.ensureLoaded(font.id), throwsFormatException);
    },
  );
  test('font files round-trip with backup independently of books', () async {
    final font = await fonts.importBytes(bytes);
    final backup = ReaderBackupService(
      documents: () async => root,
      notifyServices: false,
    );
    final file = await backup.create(includeBooks: false);
    final info = await backup.inspect(file);
    expect(info.fonts, 1);
    expect(info.files, 1);
    await fonts.remove(font.id);
    await backup.restore(file, mode: ReaderRestoreMode.replace);
    await fonts.reload();
    await fonts.ensureLoaded(font.id);
    expect(fonts.fonts.single.id, font.id);
    expect(await (await fonts.fileFor(font)).readAsBytes(), bytes);
  });
  test(
    'bounded streams and symlink input are rejected without metadata loss',
    () async {
      await expectLater(
        fonts.importStream(
          Stream.value(Uint8List(ExternalReaderFonts.maxFileBytes + 1)),
        ),
        throwsFormatException,
      );
      final file = File('${root.path}/source.ttf')..writeAsBytesSync(bytes);
      final link = Link('${root.path}/linked.ttf')..createSync(file.path);
      await expectLater(
        fonts.importFile(File(link.path)),
        throwsFormatException,
      );
      expect(fonts.fonts, isEmpty);
    },
  );
  test(
    'invalid metadata and file tampering never silently replace settings',
    () async {
      final font = await fonts.importBytes(bytes);
      final fresh = ExternalReaderFonts.forTesting(
        documents: () async => root,
        loadBytes: (_, _) async {},
      );
      await (await fonts.fileFor(font)).writeAsString('not a font');
      await expectLater(fresh.ensureLoaded(font.id), throwsFormatException);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(ExternalReaderFonts.preferencesKey);
      await fonts.reload();
      expect(prefs.getString(ExternalReaderFonts.preferencesKey), raw);
      fresh.dispose();
    },
  );
}
