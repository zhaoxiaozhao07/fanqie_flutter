import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/screens/notes_workspace_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import 'package:fanqie_flutter/services/note_library_service.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_export_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/widgets/note_editor_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LibraryApi extends ApiService {
  List<Chapter> catalog = [];
  Completer<List<Chapter>>? pending;
  int directoryCalls = 0, contentCalls = 0;
  @override
  Future<List<Chapter>> getBookChapters(
    String bookId, {
    bool refresh = false,
  }) async {
    directoryCalls++;
    return pending?.future ?? catalog;
  }

  @override
  Future<String?> getChapterContent(String itemId, {String? bookId}) async {
    contentCalls++;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferences prefs;
  late _LibraryApi api;
  late NoteLibraryService library;
  setUp(() async {
    await BookmarkService().flush();
    SharedPreferences.setMockInitialValues({});
    BookmarkService().invalidate();
    prefs = await SharedPreferences.getInstance();
    root = await Directory.systemTemp.createTemp('note-library-');
    AppStorage.documentsOverride = () async => root;
    api = _LibraryApi();
    library = NoteLibraryService.forTesting(api: api);
  });
  tearDown(() async {
    if (api.pending != null && !api.pending!.isCompleted) {
      api.pending!.complete([]);
    }
    await BookmarkService().flush();
    api.dispose();
    AppStorage.documentsOverride = null;
    await root.delete(recursive: true);
  });

  Book book(String id) => Book(bookId: id, bookName: '书籍$id', author: '作者$id');
  ReadingNote note(
    String id,
    String bookId, {
    String text = '原文摘录',
    String body = '阅读想法',
    int color = 0,
    List<String> tags = const ['主题'],
    int day = 1,
    String prefix = '',
    String suffix = '',
    int start = 0,
    String hash = '',
  }) => ReadingNote(
    id: id,
    bookId: bookId,
    chapterIndex: 0,
    chapterId: 'chapter',
    chapterTitle: '第一章',
    paragraphIndex: 0,
    text: text,
    note: body,
    startOffset: start,
    endOffset: start + text.length,
    chapterHash: hash,
    prefix: prefix,
    suffix: suffix,
    colorIndex: color,
    tags: tags,
    createdAt: DateTime.utc(2026, 11, day),
  );

  Future<void> seed(String id, List<ReadingNote> notes) async {
    await BookmarkService().rememberBook(book(id));
    await prefs.setString(
      'notes_$id',
      jsonEncode(notes.map((note) => note.toJson()).toList()),
    );
    BookmarkService().invalidate();
  }

  test(
    'local cross-book index retains removed-book names without networking',
    () async {
      await seed('a', [note('one', 'a')]);
      await seed('b', [note('two', 'b', day: 2)]);
      await prefs.setString('bookshelf_books_v1', '[]');
      final snapshot = await library.load();
      expect(snapshot.entries.map((entry) => entry.note.id), ['two', 'one']);
      expect(snapshot.books['a']!.bookName, '书籍a');
      expect(snapshot.books['b']!.author, '作者b');
      expect(api.directoryCalls + api.contentCalls, 0);
      expect(prefs.getString('notes_a'), contains('原文摘录'));
    },
  );

  test(
    'book, tag, color, case-insensitive query and chronological filters compose',
    () async {
      await seed('a', [
        note('one', 'a', text: 'Flutter 原文', color: 1, tags: ['技术'], day: 1),
        note('two', 'a', body: '其他想法', tags: ['主题'], day: 3),
      ]);
      await seed('b', [
        note('three', 'b', color: 1, tags: ['技术'], day: 2),
      ]);
      final snapshot = await library.load();
      expect(
        NoteLibraryService.filter(
          snapshot,
          query: 'FLUTTER',
          tag: '技术',
          colorIndex: 1,
        ).single.note.id,
        'one',
      );
      expect(
        NoteLibraryService.filter(snapshot, bookId: 'b').single.note.id,
        'three',
      );
      expect(
        NoteLibraryService.filter(
          snapshot,
          sort: NoteLibrarySort.oldest,
        ).map((entry) => entry.note.id),
        ['one', 'three', 'two'],
      );
      expect(NoteLibraryService.filter(snapshot, query: '书籍a').length, 2);
    },
  );

  test(
    'editing uses the canonical source record, preserving quote and offsets',
    () async {
      final original = note(
        'one',
        'a',
        start: 20,
        hash: 'hash',
        prefix: '前文',
        suffix: '后文',
      );
      await seed('a', [original]);
      await library.load();
      await BookmarkService().updateNote(
        original.edited(note: '修改后的想法', colorIndex: 3, tags: ['新标签']),
      );
      final updated = (await library.load()).entries.single.note;
      expect(updated.note, '修改后的想法');
      expect(updated.tags, ['新标签']);
      expect(updated.text, original.text);
      expect(updated.startOffset, 20);
      expect(updated.endOffset, original.endOffset);
      expect(updated.chapterHash, 'hash');
      expect(updated.prefix, '前文');
    },
  );

  test(
    'corrupt and future note books remain untouched and do not hide valid books',
    () async {
      await seed('a', [note('one', 'a')]);
      await prefs.setString('notes_bad', 'unreadable original');
      final future = note('future', 'future').toJson()..['version'] = 99;
      await prefs.setString('notes_future', jsonEncode([future]));
      final snapshot = await library.load();
      expect(snapshot.entries.length, 1);
      expect(snapshot.warnings.length, 2);
      expect(prefs.getString('notes_bad'), 'unreadable original');
      expect(
        jsonDecode(prefs.getString('notes_future')!).single['version'],
        99,
      );
      await prefs.setString(BookmarkService.noteBooksKey, 'damaged metadata');
      await expectLater(
        BookmarkService().rememberBook(book('c')),
        throwsStateError,
      );
      expect(prefs.getString(BookmarkService.noteBooksKey), 'damaged metadata');
      expect((await library.load()).entries.length, 1);
    },
  );

  test(
    'locating checks chapter identity and the exact second occurrence before navigation',
    () async {
      const paragraph = '甲目标乙目标丙';
      final original = note(
        'one',
        'a',
        text: '目标',
        start: 4,
        prefix: '甲目标乙',
        suffix: '丙',
        hash: NoteAnchorResolver.digest([paragraph]),
      );
      await seed('a', [original]);
      api.catalog = [
        Chapter(itemId: 'other', title: '其他章', content: '其他正文'),
        Chapter(itemId: 'chapter', title: '第一章', content: '第一章\n\n$paragraph'),
      ];
      final entry = (await library.load()).entries.single;
      final location = await library.locate(entry);
      expect(location.chapterIndex, 1);
      expect(location.position.characterOffset, 4);
      expect(location.position.chapterId, 'chapter');
      expect(location.chapters[1].content, '第一章\n\n$paragraph');
      expect(api.contentCalls, 0);
      expect(
        (await BookmarkService().getNotes('a')).single.toJson(),
        original.toJson(),
      );
    },
  );

  test(
    'ambiguous, missing and cancelled source locations never alter notes or progress',
    () async {
      await seed('a', [
        note('one', 'a', text: '目标', hash: '', prefix: '', suffix: ''),
      ]);
      api.catalog = [
        Chapter(itemId: 'chapter', title: '第一章', content: '甲目标乙目标丙'),
      ];
      final entry = (await library.load()).entries.single;
      final before = prefs.getString('notes_a');
      await prefs.setString('reader_position_a', 'existing progress');
      await expectLater(library.locate(entry), throwsFormatException);
      api.catalog = [];
      await expectLater(library.locate(entry), throwsFormatException);
      final pending = api.pending = Completer<List<Chapter>>();
      var cancelled = false;
      final locate = library.locate(entry, isCancelled: () => cancelled);
      cancelled = true;
      pending.complete([Chapter(itemId: 'chapter', title: '第一章')]);
      await expectLater(locate, throwsA(isA<NoteLocateCancelled>()));
      expect(prefs.getString('notes_a'), before);
      expect(prefs.getString('reader_position_a'), 'existing progress');
      expect(api.contentCalls, 0);
    },
  );

  test(
    'aggregate export preserves all anchors and escapes Markdown content',
    () async {
      await seed('a', [
        note('one', 'a', text: '<script>😀</script>', start: 5, hash: 'digest'),
      ]);
      await seed('b', [note('two', 'b')]);
      final entries = (await library.load()).entries;
      final exporter = ReaderExportService(temporary: () async => root);
      final json =
          jsonDecode(
                await (await exporter.exportNoteLibrary(
                  entries,
                  markdown: false,
                )).readAsString(),
              )
              as Map;
      expect(json['format'], 'fanqie-note-library');
      expect((json['books'] as List).length, 2);
      final exported = (json['books'] as List)
          .expand((book) => book['notes'] as List)
          .toList();
      expect(exported.length, 2);
      expect(
        exported.singleWhere((item) => item['id'] == 'one')['start_offset'],
        5,
      );
      expect(
        exported.singleWhere((item) => item['id'] == 'one')['chapter_hash'],
        'digest',
      );
      final markdown = await (await exporter.exportNoteLibrary(
        entries,
      )).readAsString();
      expect(markdown, contains('&lt;script&gt;😀&lt;/script&gt;'));
      expect(markdown, contains('## 书籍a'));
      expect(prefs.getString('notes_a'), contains('<script>'));
    },
  );

  test(
    'book-name metadata participates in backups and merges both books',
    () async {
      await seed('a', [note('one', 'a')]);
      final backup = ReaderBackupService(
        documents: () async => root,
        notifyServices: false,
      );
      final file = await backup.create();
      expect((await backup.inspect(file)).notes, 1);
      final saved = prefs.getString(BookmarkService.noteBooksKey)!;
      await prefs.remove(BookmarkService.noteBooksKey);
      await backup.restore(file, mode: ReaderRestoreMode.merge);
      expect(prefs.getString(BookmarkService.noteBooksKey), saved);
      final merged = ReaderBackupService.merge(
        {BookmarkService.noteBooksKey: saved},
        {
          BookmarkService.noteBooksKey: jsonEncode({'b': book('b').toJson()}),
        },
      );
      expect(
        (jsonDecode(merged[BookmarkService.noteBooksKey] as String) as Map).keys
            .toSet(),
        {'a', 'b'},
      );
    },
  );

  testWidgets('workspace filters, edits and deletes the same per-book record', (
    tester,
  ) async {
    final original = note('one', 'a', start: 8);
    await seed('a', [original]);
    await library.load();
    await tester.pumpWidget(
      MaterialApp(home: NotesWorkspaceScreen(service: library)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('notes-workspace-query')),
      '不存在',
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('暂无匹配笔记'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('notes-workspace-query')),
      '',
    );
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(find.byTooltip('编辑笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(NoteEditorDialog),
            matching: find.byType(TextField),
          )
          .first,
      '新的想法',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('新的想法'), findsOneWidget);
    final updated = (await BookmarkService().getNotes('a')).single;
    expect(updated.startOffset, original.startOffset);
    expect(updated.text, original.text);
    await tester.tap(find.byTooltip('删除笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await BookmarkService().getNotes('a')).length, 1);
    await tester.tap(find.byTooltip('删除笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect((await BookmarkService().getNotes('a')), isEmpty);
    expect(find.text('暂无匹配笔记'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'workspace virtualizes 5000 notes and handles committed IME input',
    (tester) async {
      await seed(
        'a',
        List.generate(
          5000,
          (i) => note('n$i', 'a', text: '摘录 $i', body: '笔记内容 $i'),
        ),
      );
      await tester.runAsync(library.load);
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(home: NotesWorkspaceScreen(service: library)),
      );
      await tester.pumpAndSettle();
      final cards = find.byWidgetPredicate(
        (widget) =>
            widget is Card && widget.key.toString().contains('workspace-note-'),
      );
      expect(cards.evaluate().length, lessThan(15));
      final query = find.byKey(const ValueKey('notes-workspace-query'));
      await tester.showKeyboard(query);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'biji',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('显示 5000 条'), findsOneWidget);
      await tester.enterText(query, '笔记内容 4999');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('显示 1 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.reset();
    },
  );

  testWidgets('cancelled source lookup never opens a late reader route', (
    tester,
  ) async {
    await seed('a', [note('one', 'a')]);
    await library.load();
    final pending = api.pending = Completer<List<Chapter>>();
    await tester.pumpWidget(
      MaterialApp(home: NotesWorkspaceScreen(service: library)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('定位原文'));
    await tester.pump();
    expect(find.text('取消定位'), findsOneWidget);
    await tester.tap(find.text('取消定位'));
    pending.complete([
      Chapter(itemId: 'chapter', title: '第一章', content: '原文摘录'),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('取消定位'), findsNothing);
    expect((await BookmarkService().getNotes('a')).length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'validated workspace source opens at its exact character anchor',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        ReaderPlatform.channel,
        (_) async => null,
      );
      const text = '甲乙丙丁原文摘录后文';
      await seed('local_a', [
        note(
          'one',
          'local_a',
          start: 4,
          prefix: '甲乙丙丁',
          suffix: '后文',
          hash: NoteAnchorResolver.digest([text]),
        ),
      ]);
      api.catalog = [Chapter(itemId: 'chapter', title: '第一章', content: text)];
      await library.load();
      try {
        await tester.pumpWidget(
          MaterialApp(home: NotesWorkspaceScreen(service: library)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('定位原文'));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderScreen), findsOneWidget);
        await ReaderSystemService.flushParticipants();
        final position = await ReaderPositionService().load('local_a');
        expect(position!.chapterId, 'chapter');
        expect(position.characterOffset, 4);
        expect(
          (await BookmarkService().getNotes('local_a')).single.startOffset,
          4,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await ReaderPositionService.flush();
        messenger.setMockMethodCallHandler(ReaderPlatform.channel, null);
        ReaderPlatform.resetForTesting();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
