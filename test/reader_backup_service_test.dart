import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/models/reading_snapshot.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/safe_zip_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderBackupService backup;
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('backup_test_');
    backup = ReaderBackupService(
      documents: () async => root,
      notifyServices: false,
    );
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => root.delete(recursive: true));

  ReadingNote note(String id, DateTime date) => ReadingNote(
    id: id,
    bookId: 'b',
    chapterIndex: 0,
    chapterTitle: '章节',
    text: '摘录$id',
    note: '批注',
    createdAt: date,
    updatedAt: date,
  );

  test(
    'backup excludes credentials; merge keeps newer anchors and unions notes',
    () async {
      await prefs.setString('tts_openai_api_key', 'secret-never-export');
      await prefs.setString('unrelated_token', 'another-secret');
      await prefs.setString(
        'notes_b',
        jsonEncode([note('old', DateTime.utc(2026, 1)).toJson()]),
      );
      await prefs.setString(
        'reader_position_b',
        jsonEncode(
          ReadingSnapshot(
            position: const ReadingPosition(chapterId: 'one'),
            updatedAt: DateTime.utc(2026, 1),
          ).toJson(),
        ),
      );
      final file = await backup.create();
      final archive = await SafeZipReader.open(file);
      final manifest = utf8.decode(await archive.read('manifest.json'));
      expect(manifest, isNot(contains('secret-never-export')));
      expect(manifest, isNot(contains('unrelated_token')));
      await prefs.setString(
        'notes_b',
        jsonEncode([note('new', DateTime.utc(2026, 2)).toJson()]),
      );
      await prefs.setString(
        'reader_position_b',
        jsonEncode(
          ReadingSnapshot(
            position: const ReadingPosition(chapterId: 'two'),
            chapterIndex: 1,
            updatedAt: DateTime.utc(2026, 2),
          ).toJson(),
        ),
      );
      await backup.restore(file);
      expect((jsonDecode(prefs.getString('notes_b')!) as List).length, 2);
      expect(
        jsonDecode(prefs.getString('reader_position_b')!)['chapter_id'],
        'two',
      );
      expect(prefs.getInt('read_progress_index_b'), 1);
      expect(prefs.getString('tts_openai_api_key'), 'secret-never-export');
    },
  );

  test(
    'book files are preserved in merge and atomically replaced on request',
    () async {
      final chapter = File('${root.path}/offline_books/b/c.txt');
      await chapter.parent.create(recursive: true);
      await chapter.writeAsString('原正文');
      final file = await backup.create(includeBooks: true);
      expect((await backup.inspect(file)).files, 1);
      await chapter.writeAsString('新正文');
      await backup.restore(file);
      expect(await chapter.readAsString(), '新正文');
      await backup.restore(file, mode: ReaderRestoreMode.replace);
      expect(await chapter.readAsString(), '原正文');
      expect(
        await File('${root.path}/reader_restore_journal.json').exists(),
        false,
      );
    },
  );

  test('unsafe preference keys are rejected before any mutation', () async {
    await prefs.setDouble('reader_font_size', 23);
    final archive = Archive();
    final bytes = utf8.encode(
      jsonEncode({
        'format': 'fanqie-reading-backup',
        'version': 1,
        'created_at': DateTime.utc(2026).toIso8601String(),
        'preferences': {'tts_openai_api_key': 'injected'},
      }),
    );
    archive.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
    final file = await File(
      '${root.path}/bad.zip',
    ).writeAsBytes(ZipEncoder().encode(archive));
    await expectLater(backup.restore(file), throwsFormatException);
    expect(prefs.getDouble('reader_font_size'), 23);
    expect(prefs.containsKey('tts_openai_api_key'), false);
  });

  test(
    'corrupt book data cannot partially restore metadata or overwrite files',
    () async {
      await prefs.setDouble('reader_font_size', 18);
      final chapter = File('${root.path}/offline_books/b/c.txt');
      await chapter.parent.create(recursive: true);
      await chapter.writeAsString('源正文' * 100);
      final file = await backup.create(includeBooks: true);
      final archive = await SafeZipReader.open(file);
      final offset = archive.entries['books/b/c.txt']!.offset;
      final bytes = await file.readAsBytes();
      bytes[offset] ^= 0xff;
      await file.writeAsBytes(bytes);
      await prefs.setDouble('reader_font_size', 25);
      await chapter.writeAsString('当前正文');
      await expectLater(
        backup.restore(file, mode: ReaderRestoreMode.replace),
        throwsA(isA<Exception>()),
      );
      expect(prefs.getDouble('reader_font_size'), 25);
      expect(await chapter.readAsString(), '当前正文');
    },
  );

  test('interrupted restore is rolled back idempotently on startup', () async {
    const workName = 'restore-123';
    final previous = File('${root.path}/restore_work/$workName/old/b/c.txt');
    await previous.parent.create(recursive: true);
    await previous.writeAsString('旧文件');
    final current = File('${root.path}/offline_books/b/c.txt');
    await current.parent.create(recursive: true);
    await current.writeAsString('未完成的新文件');
    await prefs.setDouble('reader_font_size', 30);
    await prefs.setString('tts_openai_api_key', 'keep-private');
    await File('${root.path}/reader_restore_journal.json').writeAsString(
      jsonEncode({
        'version': 1,
        'work': workName,
        'preferences': {'reader_font_size': 18.0},
        'books': [
          {'id': 'b', 'had_old': true},
        ],
      }),
    );
    await backup.recover();
    await backup.recover();
    expect(await current.readAsString(), '旧文件');
    expect(prefs.getDouble('reader_font_size'), 18);
    expect(prefs.getString('tts_openai_api_key'), 'keep-private');
  });
}
