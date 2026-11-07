import 'dart:convert';
import 'dart:io';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/models/reading_selection.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import 'package:fanqie_flutter/services/reader_backup_service.dart';
import 'package:fanqie_flutter/services/reader_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paragraphs = ['前缀👨‍👩‍👧‍👦开始叙事，', '中间正文é。', '尾段引用之后'];
  ReadingSelection selection() => ReadingSelection.capture([
    ReaderSelectionPart(0, 0, 2, paragraphs[0].length, paragraphs[0]),
    ReaderSelectionPart(0, 1, 0, paragraphs[1].length, paragraphs[1]),
    ReaderSelectionPart(0, 2, 0, 4, paragraphs[2]),
  ], paragraphs);
  ReadingNote note() {
    final s = selection();
    return ReadingNote(
      id: 'n',
      bookId: 'b',
      chapterId: 'c',
      chapterIndex: 0,
      chapterTitle: '章',
      paragraphIndex: s.firstParagraph,
      endParagraphIndex: s.lastParagraph,
      startOffset: s.start,
      endOffset: s.end,
      text: s.text,
      prefix: s.prefix,
      suffix: s.suffix,
      chapterHash: s.chapterHash,
      createdAt: DateTime.utc(2026),
    );
  }

  test(
    'same-chapter contiguous selection keeps UTF-16 ranges across paragraphs',
    () {
      final selected = selection();
      expect(selected.text, startsWith('👨‍👩‍👧‍👦'));
      expect(selected.text, contains('\n\n中间正文é。\n\n'));
      expect(selected.text, endsWith('尾段引用'));
      final n = note();
      final ranges = NoteAnchorResolver.resolveAll(n, paragraphs)!;
      expect(ranges.map((e) => e.paragraphIndex), [0, 1, 2]);
      expect(ranges.first.start, 2);
      expect(ranges.last.end, 4);
      expect(ranges.every((e) => !e.relocated), true);
      expect(n.toJson()['version'], 3);
      final edited = ReadingNote.fromJson(
        n.toJson(),
      ).edited(note: '批注', colorIndex: 2, tags: ['主题']);
      expect(edited.endParagraphIndex, 2);
      expect(edited.text, n.text);
      expect(edited.validAnchor, true);
    },
  );
  test(
    'incomplete, cross-chapter and grapheme-splitting selections reject',
    () {
      expect(
        () => ReadingSelection.capture([
          ReaderSelectionPart(0, 0, 2, paragraphs[0].length, paragraphs[0]),
          ReaderSelectionPart(0, 2, 0, 4, paragraphs[2]),
        ], paragraphs),
        throwsFormatException,
      );
      expect(
        () => ReadingSelection.capture([
          ReaderSelectionPart(0, 0, 2, paragraphs[0].length, paragraphs[0]),
          ReaderSelectionPart(1, 1, 0, paragraphs[1].length, paragraphs[1]),
        ], paragraphs),
        throwsFormatException,
      );
      expect(
        () => ReadingSelection.capture([
          ReaderSelectionPart(0, 0, 3, paragraphs[0].length, paragraphs[0]),
        ], paragraphs),
        throwsFormatException,
      );
    },
  );
  test(
    'contextual relocation is exact; changed or ambiguous ranges never guess',
    () {
      final n = note();
      final moved = NoteAnchorResolver.resolveAll(n, ['新增前言', ...paragraphs])!;
      expect(moved.first.paragraphIndex, 1);
      expect(moved.first.start, 2);
      expect(moved.every((e) => e.relocated), true);
      expect(
        NoteAnchorResolver.resolveAll(n, [...paragraphs, '分隔', ...paragraphs]),
        isNull,
      );
      expect(
        NoteAnchorResolver.resolveAll(n, [
          paragraphs.first,
          '修改后的正文',
          paragraphs.last,
        ]),
        isNull,
      );
    },
  );
  test(
    'legacy notes remain version 2 and multi-paragraph notes export/backup round-trip',
    () async {
      SharedPreferences.setMockInitialValues({});
      BookmarkService().invalidate();
      final root = await Directory.systemTemp.createTemp('spanning-note-');
      try {
        final legacy = ReadingNote(
          id: 'old',
          bookId: 'b',
          chapterIndex: 0,
          chapterTitle: '章',
          text: '原文',
          createdAt: DateTime.utc(2026),
        );
        expect(legacy.toJson()['version'], 2);
        expect(legacy.toJson().containsKey('end_paragraph_index'), false);
        final n = note();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('notes_b', jsonEncode([n.toJson()]));
        final exporter = ReaderExportService(temporary: () async => root);
        final jsonFile = await exporter.exportNotes(
          Book(bookId: 'b', bookName: '书', author: '作者'),
          markdown: false,
        );
        expect(
          jsonDecode(
            await jsonFile.readAsString(),
          )['notes'][0]['end_paragraph_index'],
          2,
        );
        final markdown = await exporter.exportNotes(
          Book(bookId: 'b', bookName: '书', author: '作者'),
        );
        expect(await markdown.readAsString(), contains('> 中间正文é。'));
        final backup = ReaderBackupService(
          documents: () async => root,
          notifyServices: false,
        );
        final file = await backup.create(includeFonts: false);
        await prefs.remove('notes_b');
        await backup.restore(file, mode: ReaderRestoreMode.replace);
        expect(
          ReadingNote.fromJson(
            (jsonDecode(prefs.getString('notes_b')!) as List).single,
          ).toJson(),
          n.toJson(),
        );
      } finally {
        BookmarkService().invalidate();
        await root.delete(recursive: true);
      }
    },
  );
}
