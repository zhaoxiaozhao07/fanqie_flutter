import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/online_chapter.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/widgets/reader_illustration.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'epub_image_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  onlineReaderTests();
}

void onlineReaderTests({bool platform = false}) {
  for (final mode
      in platform
          ? ['scroll', 'none']
          : ['scroll', 'none', 'cover', 'simulation', 'slide', 'fade']) {
    for (final scenario in [
      'download',
      'legacy',
      'pure',
      if (mode == 'scroll' || mode == 'none') 'missing',
    ]) {
      testWidgets('online $scenario pictures render in $mode', (tester) async {
        SharedPreferences.setMockInitialValues({});
        const native = MethodChannel('com.fanqie.fanqie_flutter/download');
        if (!platform) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(native, (_) async => null);
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(native, null),
          );
        }
        late Directory root;
        late ApiService api;
        var offline = false;
        Future<void> setup() async {
          root = await Directory.systemTemp.createTemp('online-reader-');
          final engine = FanqieBackendEngine(
            cache: ReaderCacheService(documents: () async => root),
            chapterDocumentLoader: (_) async {
              if (offline) throw const SocketException('offline');
              return OnlineChapter.parse(
                '<h1>插画章</h1><p>'
                '${scenario == 'pure' ? '' : '图片前文'}'
                '<img src="https://p3-novel.byteimg.com/a.png" alt="人物插画"/>'
                '${scenario == 'pure' ? '' : '图片后文'}</p>',
              );
            },
            client: MockClient((_) async {
              if (offline) throw const SocketException('offline');
              return http.Response.bytes(
                imagePng(width: 240, height: 120),
                200,
              );
            }),
          );
          api = ApiService(engine: engine);
          if (scenario == 'legacy') {
            await (await engine.getOfflineChapterFile(
              'book',
              'one',
            )).writeAsString('图片前文图片后文');
          } else {
            await engine.downloadChapters(
              bookId: 'book',
              chapters: [Chapter(itemId: 'one', title: '插画章')],
            );
            offline = scenario != 'missing';
            if (scenario == 'missing') {
              await Directory(
                '${root.path}/offline_books/book/images',
              ).delete(recursive: true);
            }
            await engine.readerCache.trim(0, includePinned: true);
          }
        }

        if (platform) {
          await setup();
        } else {
          await tester.runAsync(setup);
        }
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderScreen(
                book: Book(bookId: 'book', bookName: '首页插图书', author: '测试'),
                chapters: [Chapter(itemId: 'one', title: '插画章')],
                apiService: api,
                bookDocuments: () async => root,
                resumeSavedPosition: false,
                initialSettings: ReaderSettingsRecord(
                  ReaderSettings(
                    pageMode: mode != 'scroll',
                    pageAnimation: mode == 'scroll' ? 'none' : mode,
                    commentBubbles: false,
                    pureMode: true,
                  ),
                ),
              ),
            ),
          );
          final renderedPictures = find.descendant(
            of: find.byType(ReaderIllustrationView),
            matching: find.byType(RawImage),
          );
          var stableFrames = 0;
          for (var i = 0; i < 200; i++) {
            if (platform) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            } else {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
            }
            await tester.pump(const Duration(milliseconds: 30));
            if (tester
                    .widgetList<RawImage>(renderedPictures)
                    .any((w) => w.image != null) &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty) {
              // A temporary restoration screenshot is not the illustration.
              // Allow asynchronous repair/rebinding and the native codec to
              // settle, rather than stopping on one transient ready frame.
              if (++stableFrames >= 4) break;
            } else {
              stableFrames = 0;
            }
          }
          await tester.pumpAndSettle();
          expect(find.byType(ReaderIllustrationView), findsWidgets);
          expect(find.textContaining('插图下载失败'), findsNothing);
          expect(find.textContaining('本章内容为空'), findsNothing);
          expect(
            tester
                .widgetList<RawImage>(renderedPictures)
                .any((w) => w.image != null),
            true,
          );
          if (scenario != 'pure') {
            final before = find
                .textContaining('图片前文', findRichText: true)
                .first;
            final after = find.textContaining('图片后文', findRichText: true).first;
            expect(
              tester.getTopLeft(before).dy,
              lessThan(
                tester.getTopLeft(find.byType(ReaderIllustrationView).first).dy,
              ),
            );
            expect(
              tester.getTopLeft(after).dy,
              greaterThan(
                tester
                    .getBottomLeft(find.byType(ReaderIllustrationView).first)
                    .dy,
              ),
            );
          }
          if (platform) {
            debugPrint('ONLINE_CAPTURE_${scenario}_$mode');
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
          await tester.tap(find.byType(Image).first);
          await tester.pumpAndSettle();
          expect(find.byType(InteractiveViewer), findsOneWidget);
          await tester.tap(find.byTooltip('关闭图片'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          if (platform) {
            await root.delete(recursive: true);
          } else {
            await tester.runAsync(() => root.delete(recursive: true));
          }
        }
      });
    }
  }
}
