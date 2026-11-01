import 'dart:async';
import 'dart:io';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached comments return immediately while one refresh is pending',
    () async {
      final id = 'cache_first_${DateTime.now().microsecondsSinceEpoch}';
      final refresh = Completer<ChapterCommentStats?>();
      var calls = 0;
      final api = ApiService(
        chapterStatsLoader: (_) {
          calls++;
          return calls == 1
              ? Future.value(
                  ChapterCommentStats(
                    chapterId: id,
                    counts: const {0: 2},
                    totalCount: 2,
                  ),
                )
              : refresh.future;
        },
      );
      try {
        expect(
          (await api.getChapterCommentStats(id, bookId: id))!.totalCount,
          2,
        );
        final cached = await api
            .getChapterCommentStats(id, bookId: id)
            .timeout(const Duration(seconds: 1));
        expect(cached!.totalCount, 2);
        expect(calls, 2);
        await api.getChapterCommentStats(id, bookId: id);
        expect(calls, 2);
        refresh.complete(
          ChapterCommentStats(
            chapterId: id,
            counts: const {0: 5},
            totalCount: 5,
          ),
        );
        // Wait for the atomic observable result rather than a timing assertion.
        ChapterCommentStats? updated;
        for (var attempt = 0; attempt < 100; attempt++) {
          updated = await api.getChapterCommentStats(id, bookId: id);
          if (updated?.totalCount == 5) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(updated!.totalCount, 5);
      } finally {
        api.dispose();
        if (!refresh.isCompleted) refresh.complete(null);
        for (final path in [
          '${Directory.systemTemp.path}/offline_books/$id/comments/stats_$id.json',
          '${Directory.systemTemp.path}/comment_cache/stats_$id.json',
        ]) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
    },
  );
}
