import 'dart:convert';

import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/models/reading_snapshot.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'migrates v1 anchors without losing UTF-16 offset or viewport',
    () async {
      const anchor = ReadingPosition(
        chapterId: 'b',
        paragraphIndex: 3,
        characterOffset: 24,
        viewportFraction: .25,
      );
      SharedPreferences.setMockInitialValues({
        'reader_position_book': jsonEncode(anchor.toJson()),
      });
      final snapshot = await ReaderPositionService().loadSnapshot('book');
      expect(snapshot!.position.toJson(), anchor.toJson());
      final target = snapshot.resolve([
        Chapter(itemId: 'inserted', title: '新增'),
        Chapter(itemId: 'a', title: '第一章'),
        Chapter(itemId: 'b', title: '第二章'),
      ])!;
      expect(target.chapterIndex, 2);
      expect(target.position.toJson(), anchor.toJson());
      expect(target.notice, isNull);
    },
  );

  test('deleted chapter falls back with a notice and discards old offset', () {
    final snapshot = ReadingSnapshot(
      position: const ReadingPosition(
        chapterId: 'deleted',
        characterOffset: 80,
      ),
      chapterIndex: 1,
      chapterTitle: '重复标题',
      nextChapterId: 'next',
      updatedAt: DateTime.utc(2026),
    );
    final target = snapshot.resolve([
      Chapter(itemId: 'a', title: '重复标题'),
      Chapter(itemId: 'b', title: '重复标题'),
      Chapter(itemId: 'next', title: '下一章'),
    ])!;
    expect(target.chapterIndex, 2);
    expect(target.position.characterOffset, 0);
    expect(target.notice, isNotEmpty);
    expect(snapshot.resolve([]), isNull);
  });

  test(
    'serializes 100 writes across instances and commits matching summaries',
    () async {
      final writes = <Future<void>>[];
      final observed = <int>[];
      for (var i = 0; i < 100; i++) {
        writes.add(
          ReaderPositionService().save(
            'book',
            ReadingPosition(chapterId: 'chapter-$i', characterOffset: i),
            chapterIndex: i,
            chapterTitle: '第$i章',
            onCommitted: () async => observed.add(i),
          ),
        );
      }
      await Future.wait(writes);
      final saved = await ReaderPositionService().loadSnapshot('book');
      expect(saved!.chapterIndex, 99);
      expect(saved.position.chapterId, 'chapter-99');
      expect(saved.position.characterOffset, 99);
      expect(observed, List.generate(100, (i) => i));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('read_progress_index_book'), 99);
      expect(prefs.getString('read_progress_title_book'), '第99章');
      expect(saved.updatedAt.isUtc, isTrue);
    },
  );

  test(
    'corrupt and future snapshots are preserved but not interpreted',
    () async {
      final future = jsonEncode({
        'chapter_id': 'future',
        'schema_version': 999,
      });
      SharedPreferences.setMockInitialValues({
        'reader_position_corrupt': 'not json',
        'reader_position_future': future,
      });
      final service = ReaderPositionService();
      expect(await service.load('corrupt'), isNull);
      expect(await service.load('future'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('reader_position_future'), future);
    },
  );
}
