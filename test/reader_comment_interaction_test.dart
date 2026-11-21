@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';

/// 只返回评论统计与本章评论数量，不发起任何网络请求。
class _FakeApiService extends ApiService {
  _FakeApiService();

  @override
  Future<ChapterCommentStats?> getChapterCommentStats(
    String itemId, {
    String? bookId,
    bool preferCache = true,
  }) async =>
      ChapterCommentStats(
        chapterId: itemId,
        counts: {for (var i = 0; i < 60; i++) i: 3},
        totalCount: 180,
      );

  @override
  Future<CommentPageData?> getChapterComments(
    String bookId,
    String itemId, {
    int offset = 0,
    int count = 20,
    String cursor = '',
    bool preferCache = true,
  }) async => const CommentPageData(comments: [], total: 9);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('comment-interaction-');
    AppStorage.documentsOverride = () async => directory;
  });

  tearDown(() async {
    await ReaderPositionService.flush();
    await ReaderSettingsRepository.flush();
    AppStorage.documentsOverride = null;
    ReaderPlatform.resetForTesting();
    await directory.delete(recursive: true);
  });

  Future<void> mountReader(
    WidgetTester tester, {
    required String id,
    bool pageMode = true,
    int paragraphCount = 24,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    ReaderPlatform.resetForTesting();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: Book(bookId: 'book_$id', bookName: '评论测试', author: '测试'),
          chapters: List.generate(
            1,
            (index) => Chapter(
              itemId: 'c$index',
              title: '第${index + 1}章 评论测试',
              content: List.generate(
                paragraphCount,
                (i) =>
                    '第${index + 1}章第$i段。这是用于验证评论入口点击不会触发翻页的正文内容，需要足够长才能撑满整行。',
              ).join('\n\n'),
            ),
          ),
          resumeSavedPosition: false,
          bookDocuments: () async => directory,
          apiService: _FakeApiService(),
          initialSettings: ReaderSettingsRecord(
            ReaderSettings(
              pageMode: pageMode,
              commentBubbles: true,
              pureMode: false,
              showStatus: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('段落评论气泡点击不会翻页', (tester) async {
    try {
      await mountReader(tester, id: 'bubble');
      // Move to a middle page so that any hot-zone interpretation of the
      // click (previous or next page) is observable.
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      final pageRect = tester.getRect(find.byType(ReaderPageView));
      Finder visibleBubble() {
        for (var i = 0; i < 60; i++) {
          final finder = find.byKey(ValueKey('paragraph-comment-c0-$i'));
          if (finder.evaluate().isEmpty) continue;
          final rect = tester.getRect(finder);
          if (rect.top >= pageRect.top &&
              rect.bottom <= pageRect.bottom &&
              rect.left >= pageRect.left &&
              rect.right <= pageRect.right) {
            return finder;
          }
        }
        throw StateError('当前页没有可见的段评气泡');
      }

      final bubble = visibleBubble();
      final pageState = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final before = pageState.currentPageId;
      await tester.tapAt(
        tester.getCenter(bubble),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(pageState.currentPageId, before);
      expect(find.byKey(const ValueKey('reader_controls')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('章节评论入口点击不会翻页', (tester) async {
    try {
      await mountReader(tester, id: 'chapter', paragraphCount: 6);
      await tester.pump(const Duration(milliseconds: 100));
      // The chapter comment card lives at the end of the chapter.
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      final card = find.textContaining('本章评论');
      expect(card, findsOneWidget);
      final pageState = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      final before = pageState.currentPageId;
      await tester.tapAt(
        tester.getCenter(card),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(pageState.currentPageId, before);
      expect(find.byKey(const ValueKey('reader_controls')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
