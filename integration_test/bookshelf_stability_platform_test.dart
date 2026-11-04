import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fanqie_flutter/main.dart';
import 'package:fanqie_flutter/models/bookshelf_book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reading_history_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test/epub_image_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final grid in [false, true]) {
    testWidgets(
      'Android 20-book ${grid ? 'grid' : 'list'} stays stable after slow updates, retabs and resume',
      (tester) async {
        final prefix = 'stability_${grid ? 'grid' : 'list'}_';
        final ids = List.generate(
          20,
          (i) => '$prefix${i.toString().padLeft(2, '0')}',
        );
        final text = List.generate(
          100,
          (i) => '正文第${i.toString().padLeft(3, '0')}段，稳定阅读，不应先显示章节开头再跳动。',
        ).join('\n\n');
        final chapters = List.generate(
          10,
          (i) => Chapter(itemId: 'c$i', title: '章节$i', order: i + 1),
        );
        final books = [
          for (var i = 0; i < ids.length; i++)
            BookshelfBook(
              bookId: ids[i],
              bookName: '稳定书籍 $i',
              author: '测试',
              thumbUrl: 'https://p3-novel.byteimg.com/stability-$i.png',
              addedTime: DateTime(2026, 1, 1).add(Duration(minutes: i)),
              totalChapters: 10,
            ),
        ];
        SharedPreferences.setMockInitialValues({
          'bookshelf_books_v1': jsonEncode(
            books.map((b) => b.toJson()).toList(),
          ),
          'bookshelf_view_mode': grid ? 'grid3' : 'list',
          'reader_settings_v2': jsonEncode(
            const ReaderSettings(
              pureMode: true,
              commentBubbles: false,
            ).toJson(),
          ),
        });
        final root = await getApplicationDocumentsDirectory();
        final backend = FanqieBackendEngine();
        final shelf = BookshelfService();
        await shelf.reload();
        await ReadingHistoryService().reload();
        final gate = Completer<List<Chapter>>();
        var checks = 0;
        shelf.directoryLoader = (id) async {
          checks++;
          if (id == ids.first) return gate.future;
          return chapters;
        };
        try {
          for (final id in ids) {
            final dir = Directory('${root.path}/offline_books/$id');
            await dir.create(recursive: true);
            await File(
              '${dir.path}/cover.jpg',
            ).writeAsBytes(imagePng(width: 128, height: 180));
            await File('${dir.path}/directory.json').writeAsString(
              jsonEncode(chapters.map((c) => c.toJson()).toList()),
            );
            for (final chapter in chapters) {
              await File(
                '${dir.path}/${chapter.itemId}.txt',
              ).writeAsString(text);
              await backend.onlineImages.saveSources(
                id,
                chapter.itemId,
                OnlineChapter(text),
              );
            }
          }
          await ReaderPositionService().save(
            ids.first,
            const ReadingPosition(chapterId: 'c0', paragraphIndex: 40),
          );
          await tester.pumpWidget(const FanqieApp());
          await tester.pumpAndSettle();
          await tester.tap(find.text('书架').last);
          await tester.pumpAndSettle();
          expect(checks, 1);
          await shelf.updateReadingProgress(ids.first, 0, '章节0');
          final time = shelf.getBook(ids.first)!.lastReadTime;
          await tester.pumpAndSettle();
          final key = ValueKey(ids.first);
          final before = tester.getTopLeft(find.byKey(key));
          gate.complete([
            ...chapters,
            Chapter(itemId: 'c10', title: '新章'),
            Chapter(itemId: 'c11', title: '新章'),
          ]);
          await tester.pumpAndSettle();
          expect(shelf.getBook(ids.first)!.lastReadTime, time);
          expect(shelf.books.map((b) => b.bookId).toSet().length, 20);
          expect(tester.getTopLeft(find.byKey(key)), before);
          expect(checks, 20);
          for (var i = 0; i < 8; i++) {
            await tester.tap(find.text('主页').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('书架').last);
            await tester.pump();
            expect(find.byType(CircularProgressIndicator), findsNothing);
            await tester.pumpAndSettle();
            expect(tester.getTopLeft(find.byKey(key)), before);
          }
          expect(checks, 20);
          debugPrint('STABILITY_CAPTURE_${grid ? 'grid' : 'list'}');
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          if (grid) {
            // Grid's cover opens the reader; list has an explicit continue button.
            await tester.tap(
              find
                  .descendant(
                    of: find.byKey(key),
                    matching: find.byType(AspectRatio),
                  )
                  .first,
            );
          } else {
            await tester.tap(
              find.descendant(of: find.byKey(key), matching: find.text('续读')),
            );
          }
          for (var i = 0; i < 60; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await tester.pump();
            if (find.byType(ReaderScreen).evaluate().isNotEmpty &&
                find
                    .byKey(const ValueKey('reader-initial-position'))
                    .evaluate()
                    .isEmpty &&
                find
                    .textContaining('正文第040段', findRichText: true)
                    .evaluate()
                    .isNotEmpty) {
              break;
            }
          }
          await tester.pumpAndSettle();
          expect(find.byType(ReaderScreen), findsOneWidget);
          expect(
            find.textContaining('正文第040段', findRichText: true),
            findsWidgets,
          );
          expect(
            find.byKey(const ValueKey('reader-initial-position')),
            findsNothing,
          );
          debugPrint('STABILITY_CAPTURE_reader_${grid ? 'grid' : 'list'}');
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await ReaderPositionService.flush();
          if (!gate.isCompleted) gate.complete(chapters);
          shelf.directoryLoader = null;
          backend.dispose();
          for (final id in ids) {
            for (final tree in ['offline_books', 'reader_cache_v2']) {
              final directory = Directory('${root.path}/$tree/$id');
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
            }
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }
}
