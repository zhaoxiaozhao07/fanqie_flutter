import 'package:fanqie_flutter/models/bookmark.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  ReadingNote note({
    String hash = '',
    int start = -1,
    int end = -1,
    String prefix = '',
    String suffix = '',
  }) => ReadingNote(
    id: 'n',
    bookId: 'b',
    chapterIndex: 0,
    chapterId: 'c',
    chapterTitle: '章节',
    paragraphIndex: 0,
    text: '目标',
    startOffset: start,
    endOffset: end,
    chapterHash: hash,
    prefix: prefix,
    suffix: suffix,
    createdAt: DateTime.utc(2026),
  );

  test('exact content hash locates the selected second occurrence', () {
    final paragraphs = ['目标和目标。'];
    final resolved = NoteAnchorResolver.resolve(
      note(hash: NoteAnchorResolver.digest(paragraphs), start: 3, end: 5),
      paragraphs,
    )!;
    expect(resolved.start, 3);
    expect(resolved.end, 5);
    expect(resolved.relocated, false);
  });
  test('changed text relocates only when quotation and context are unique', () {
    final saved = note(hash: 'old', start: 3, end: 5, prefix: '乙', suffix: '丙');
    final resolved = NoteAnchorResolver.resolve(saved, ['甲目标。', '新增：乙目标丙。'])!;
    expect(resolved.paragraphIndex, 1);
    expect(resolved.start, 4);
    expect(resolved.relocated, true);
    expect(NoteAnchorResolver.resolve(note(), ['目标。', '目标。']), isNull);
  });
  test(
    'same chapter supports multiple bookmarks and exact-range notes',
    () async {
      final service = BookmarkService();
      await Future.wait([
        service.addBookmark(
          bookId: 'b',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '章节',
          paragraphIndex: 0,
          characterOffset: 0,
          contentPreview: '第一处',
        ),
        service.addBookmark(
          bookId: 'b',
          chapterIndex: 0,
          chapterId: 'c',
          chapterTitle: '章节',
          paragraphIndex: 2,
          characterOffset: 5,
          contentPreview: '第二处',
        ),
      ]);
      expect((await service.getBookmarks('b')).length, 2);
      await Future.wait([
        service.addNote(
          bookId: 'b',
          chapterIndex: 0,
          chapterTitle: '章节',
          text: '目标',
          startOffset: 0,
          endOffset: 2,
        ),
        service.addNote(
          bookId: 'b',
          chapterIndex: 0,
          chapterTitle: '章节',
          text: '目标',
          startOffset: 3,
          endOffset: 5,
        ),
      ]);
      final notes = await service.getNotes('b');
      expect(notes.length, 2);
      await service.removeNote(notes.first.id, 'b');
      expect((await service.getNotes('b')).length, 1);
    },
  );
}
