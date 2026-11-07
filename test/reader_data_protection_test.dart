import 'dart:convert';
import 'dart:io';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/reader_auto_backup_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_library_service.dart';
import 'package:fanqie_flutter/services/reader_trash_coordinator.dart';
import 'package:fanqie_flutter/services/reader_trash_service.dart';
import 'package:fanqie_flutter/services/safe_zip_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferences prefs;
  late ReaderAutoBackupService auto;
  var now = DateTime.utc(2026, 11, 6);
  final service = BookmarkService();
  setUp(() async {
    await service.flush();
    await ReaderTrashService().flush();
    SharedPreferences.setMockInitialValues({});
    service.invalidate();
    root = await Directory.systemTemp.createTemp('reader-data-protection-');
    AppStorage.documentsOverride = () async => root;
    prefs = await SharedPreferences.getInstance();
    now = DateTime.utc(2026, 11, 6);
    auto = ReaderAutoBackupService.forTesting(
      documents: () async => root,
      clock: () => now,
    );
    await auto.initialize(observe: false);
    await BookshelfService().reload();
  });
  tearDown(() async {
    await service.flush();
    await ReaderTrashService().flush();
    await auto.flush();
    auto.dispose();
    AppStorage.documentsOverride = null;
    await root.delete(recursive: true);
  });
  test(
    'note/bookmark deletion commits undo copy and restores exact anchors',
    () async {
      final note = await service.addNote(
        bookId: 'b',
        chapterIndex: 2,
        chapterId: 'c',
        chapterTitle: '章',
        paragraphIndex: 7,
        text: '原文',
        startOffset: 4,
        endOffset: 6,
      );
      final deleted = await service.deleteNotes('b', {note.id});
      expect(await service.getNotes('b'), isEmpty);
      expect(
        (await ReaderTrashService().entries())
            .single
            .items
            .single['start_offset'],
        4,
      );
      await ReaderTrashCoordinator.restore(deleted!);
      expect((await service.getNotes('b')).single.toJson(), note.toJson());
      expect(await ReaderTrashService().entries(), isEmpty);
      final bookmark = await service.addBookmark(
        bookId: 'b',
        chapterIndex: 2,
        chapterId: 'c',
        chapterTitle: '章',
        paragraphIndex: 7,
        characterOffset: 4,
        contentPreview: '原文',
      );
      final entry = await service.deleteBookmarks('b', {bookmark.id});
      await ReaderTrashCoordinator.restore(entry!);
      expect(
        (await service.getBookmarks('b')).single.toJson(),
        bookmark.toJson(),
      );
    },
  );
  test(
    'undo modifications refuses later edits and never changes source',
    () async {
      final note = await service.addNote(
        bookId: 'b',
        chapterIndex: 0,
        chapterTitle: '章',
        text: '原文',
      );
      final one = await service.updateNoteWithUndo(
        note.edited(note: '第一版', colorIndex: 1, tags: ['一']),
      );
      final current = (await service.getNotes('b')).single;
      final two = await service.updateNoteWithUndo(
        current.edited(note: '第二版', colorIndex: 2, tags: ['二']),
      );
      await expectLater(ReaderTrashCoordinator.restore(one!), throwsStateError);
      expect((await service.getNotes('b')).single.note, '第二版');
      await ReaderTrashCoordinator.restore(two!);
      await ReaderTrashCoordinator.restore(one);
      expect((await service.getNotes('b')).single.toJson(), note.toJson());
    },
  );
  test(
    'concurrent books preserve all undo records and additive tags',
    () async {
      final a = await service.addNote(
        bookId: 'a',
        chapterIndex: 0,
        chapterTitle: 'A',
        text: '甲',
        tags: ['原标签'],
      );
      final b = await service.addNote(
        bookId: 'b',
        chapterIndex: 0,
        chapterTitle: 'B',
        text: '乙',
      );
      await Future.wait([
        service.addTags('a', {a.id}, ['新标签']),
        service.addTags('b', {b.id}, ['新标签']),
      ]);
      expect((await service.getNotes('a')).single.tags, ['原标签', '新标签']);
      expect((await ReaderTrashService().entries()).length, 2);
      for (final entry in await ReaderTrashService().entries()) {
        await ReaderTrashCoordinator.restore(entry);
      }
      expect((await service.getNotes('a')).single.tags, ['原标签']);
    },
  );
  test('malformed live or trash metadata refuses destructive writes', () async {
    await prefs.setString('notes_b', '{broken');
    await expectLater(
      service.addNote(
        bookId: 'b',
        chapterIndex: 0,
        chapterTitle: '章',
        text: '原文',
      ),
      throwsStateError,
    );
    expect(prefs.getString('notes_b'), '{broken');
    await prefs.remove('notes_b');
    service.invalidate();
    final note = await service.addNote(
      bookId: 'b',
      chapterIndex: 0,
      chapterTitle: '章',
      text: '原文',
    );
    await prefs.setString(ReaderTrashService.preferencesKey, '{broken');
    await expectLater(service.removeNote(note.id, 'b'), throwsFormatException);
    expect((await service.getNotes('b')).single.id, note.id);
    expect(prefs.getString(ReaderTrashService.preferencesKey), '{broken');
    await prefs.remove(ReaderTrashService.preferencesKey);
  });
  test(
    'shelf removal restores membership without deleting files or replacing new progress',
    () async {
      final shelf = BookshelfService();
      await shelf.addToBookshelf(
        Book(bookId: 'b', bookName: '书', author: '作者'),
      );
      final file = File('${root.path}/offline_books/b/c.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('完整正文');
      final entry = await shelf.removeMultipleWithUndo(['b']);
      expect(shelf.isInBookshelf('b'), false);
      expect(await file.readAsString(), '完整正文');
      await ReaderTrashCoordinator.restore(entry!);
      expect(shelf.isInBookshelf('b'), true);
    },
  );
  test(
    'automatic backup opt-in, change detection, retention and secret exclusion',
    () async {
      expect(await auto.runDue(), isNull);
      await prefs.setString('tts_openai_api_key', 'synthetic-do-not-backup');
      await service.addNote(
        bookId: 'b',
        chapterIndex: 0,
        chapterTitle: '章',
        text: '原文',
      );
      await auto.configure(enabled: true, retain: 3);
      await auto.flush();
      expect((await auto.snapshots()).length, 1);
      now = now.add(const Duration(days: 1));
      expect(await auto.runDue(), isNull);
      final foreign = File('${root.path}/reader_auto_backups/manual.zip')
        ..writeAsStringSync('not owned');
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(days: 1));
        await service.addNote(
          bookId: 'b',
          chapterIndex: i + 1,
          chapterTitle: '章$i',
          text: '原文$i',
        );
        await auto.runDue();
      }
      final snapshots = await auto.snapshots();
      expect(snapshots.length, 3);
      expect(await foreign.exists(), true);
      final zip = await SafeZipReader.open(snapshots.first);
      expect(
        utf8.decode(await zip.read('manifest.json')),
        isNot(contains('synthetic-do-not-backup')),
      );
      await prefs.setString('notes_b', '{broken');
      now = now.add(const Duration(days: 1));
      await expectLater(auto.runDue(), throwsFormatException);
      expect((await auto.snapshots()).length, 3);
      expect(auto.lastError, isNotNull);
      await prefs.remove('notes_b');
      service.invalidate();
    },
  );
  test(
    'group/status and trash round-trip through a metadata-only backup',
    () async {
      final library = ReaderLibraryService();
      final group = await library.createGroup('稍后阅读');
      await library.setBooks(
        {'b'},
        groupId: group,
        status: ReaderBookStatus.read,
      );
      final note = await service.addNote(
        bookId: 'b',
        chapterIndex: 0,
        chapterTitle: '章',
        text: '原文',
      );
      await service.deleteNotes('b', {note.id});
      final backup = ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      );
      final file = await backup.create(includeFonts: false);
      await prefs.remove(ReaderLibraryService.preferencesKey);
      await prefs.remove(ReaderTrashService.preferencesKey);
      await backup.restore(file, mode: ReaderRestoreMode.replace);
      await library.load();
      expect(library.statusFor('b'), ReaderBookStatus.read);
      expect(library.groupFor('b'), group);
      expect((await ReaderTrashService().entries()).length, 1);
      expect(
        jsonDecode(
          prefs.getString(ReaderTrashService.preferencesKey)!,
        )['version'],
        1,
      );
    },
  );
}
