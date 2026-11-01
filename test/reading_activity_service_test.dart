import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/services/reading_activity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DateTime now;
  late ReadingActivityService activity;
  final book = Book(bookId: 'activity-book', bookName: '统计测试', author: '测试');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 2, 10);
    activity = ReadingActivityService.forTesting(now: () => now);
    await activity.reload();
  });
  tearDown(() => activity.dispose());

  test('tracking is opt-in and disabled sessions store no activity', () async {
    final owner = Object();
    activity.attach(
      owner,
      book,
      active: () => true,
      automatic: () => false,
      position: () => const ReadingActivityPosition('c', 0, 1000),
    );
    now = now.add(const Duration(seconds: 1));
    activity.tick();
    expect(activity.books, isEmpty);
    expect(activity.remainingMinutes(book.bookId, 1000), isNull);
    await activity.flush();
    expect(
      (await SharedPreferences.getInstance()).containsKey('reader_activity_v1'),
      false,
    );
  });

  test(
    'foreground interaction counts; idle and background reading do not',
    () async {
      await activity.setEnabled(true);
      final owner = Object();
      var active = true;
      var offset = 0;
      activity.attach(
        owner,
        book,
        active: () => active,
        automatic: () => false,
        position: () => ReadingActivityPosition('c', offset, 5000),
      );
      for (var i = 0; i < 100; i++) {
        now = now.add(const Duration(seconds: 1));
        offset += 10;
        activity.tick();
      }
      expect((activity.books[book.bookId] as Map)['reading_ms'], 90000);
      active = false;
      activity.interact(owner);
      now = now.add(const Duration(seconds: 1));
      activity.tick();
      expect((activity.books[book.bookId] as Map)['reading_ms'], 90000);
      expect(activity.remainingMinutes(book.bookId, 1000), greaterThan(0));
    },
  );

  test(
    'listening has a separate counter and is not double-counted as reading',
    () async {
      await activity.setEnabled(true);
      activity.attach(
        Object(),
        book,
        active: () => true,
        automatic: () => true,
        position: () => const ReadingActivityPosition('c', 0, 1000),
      );
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 1));
        activity.tick(
          listeningBookId: book.bookId,
          listeningTitle: book.bookName,
        );
      }
      final stats = activity.books[book.bookId] as Map;
      expect(stats['listening_ms'], 10000);
      expect(stats['reading_ms'] ?? 0, 0);
    },
  );

  test(
    'explicit jumps do not count skipped characters and clearing preserves progress',
    () async {
      await activity.setEnabled(true);
      var offset = 10;
      activity.attach(
        Object(),
        book,
        active: () => true,
        automatic: () => true,
        position: () => ReadingActivityPosition('c', offset, 5000),
      );
      now = now.add(const Duration(seconds: 1));
      activity.tick();
      activity.breakSequence();
      offset = 3000;
      now = now.add(const Duration(seconds: 1));
      activity.tick();
      expect((activity.books[book.bookId] as Map)['characters'], 0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reader_position_activity-book', 'keep');
      await activity.setEnabled(false, clear: true);
      expect(activity.books, isEmpty);
      expect(prefs.containsKey('reader_activity_v1'), false);
      expect(prefs.getString('reader_position_activity-book'), 'keep');
    },
  );
}
