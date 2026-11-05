import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/screens/book_detail_screen.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/bookshelf_service.dart';
import 'package:fanqie_flutter/services/fanqie_backend_engine.dart';
import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:fanqie_flutter/services/reader_text.dart';
import 'package:fanqie_flutter/widgets/book_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fault injection affects only HTML; directory JSON and body/CDN traffic are
/// real device requests. This is intentionally not part of the release workflow.
class _WithoutDetailHtml extends http.BaseClient {
  final _inner = http.Client();
  int directoryRequests = 0, blockedPages = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.startsWith('/page/')) {
      blockedPages++;
      return http.StreamedResponse(
        Stream.value('<html>verification</html>'.codeUnits),
        200,
      );
    }
    if (request.url.path == '/api/reader/directory/detail') directoryRequests++;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  bookDirectoryPlatformTests();
}

void bookDirectoryPlatformTests({
  String platform = 'Android',
  bool skip = false,
}) {
  for (final source in ['home_new', 'old_book']) {
    testWidgets(
      '$platform real $source: card -> directory -> read/download -> delete/re-add',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'reader_settings_v2':
              '{"version":2,"pureMode":true,"commentBubbles":false}',
        });
        await BookshelfService().reload();
        final root = await Directory.systemTemp.createTemp('catalog-platform-');
        final previousDocuments = AppStorage.documentsOverride;
        if (ReaderPlatform.isMacOS) {
          AppStorage.documentsOverride = () async => root;
          await ReaderPlatform.initialize();
          AppLifecycleService.initialize();
        }
        final cache = ReaderCacheService(documents: () async => root);
        final client = _WithoutDetailHtml();
        final api = ApiService(
          engine: FanqieBackendEngine(cache: cache, client: client),
        );
        try {
          final Book book;
          if (source == 'home_new') {
            final page = await api.discoverBooks(categoryId: 7, gender: 1);
            book = page.books.first;
          } else {
            book = Book(
              bookId: '7069948840148732967',
              bookName: '部族荣光',
              author: '丧狐',
            );
          }
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: SafeArea(
                    child: BookCard(
                      book: book,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              BookDetailScreen(book: book, apiService: api),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(BookCard));
          for (
            var i = 0;
            i < 120 && find.text('开始阅读').evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(find.text('开始阅读'), findsOneWidget);
          expect(find.byKey(const ValueKey('directory-error')), findsNothing);
          expect(client.directoryRequests, 1);
          expect(client.blockedPages, 1);

          final chapters = await api.getBookChapters(book.bookId);
          expect(chapters.length, greaterThan(20));
          final text = await api.getChapterContent(
            chapters.first.itemId,
            bookId: book.bookId,
          );
          expect(text, isNotNull);
          expect(text!.length, greaterThan(100));
          await api.downloadChapters(
            bookId: book.bookId,
            chapters: chapters.take(1).toList(),
          );

          // Reconstruct both directory and content from disk, with zero network.
          var offlineRequests = 0;
          final offline = FanqieBackendEngine(
            cache: cache,
            client: MockClient((_) async {
              offlineRequests++;
              throw const SocketException('offline');
            }),
          );
          try {
            expect(
              (await offline.getBookDirectory(book.bookId)).length,
              chapters.length,
            );
            expect(
              await offline.getChapterContent(
                chapters.first.itemId,
                bookId: book.bookId,
              ),
              text,
            );
            expect(offlineRequests, 0);
          } finally {
            offline.dispose();
          }
          await tester.tap(find.text('开始阅读'));
          final firstParagraph = ReaderText.paragraphs(
            text,
            chapterTitle: chapters.first.title,
          ).first;
          final excerpt = firstParagraph.substring(
            0,
            firstParagraph.length.clamp(1, 10),
          );
          for (var i = 0; i < 200; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await tester.pump();
            if (find
                .textContaining(excerpt, findRichText: true)
                .evaluate()
                .isNotEmpty) {
              break;
            }
          }
          expect(find.byType(ReaderScreen), findsOneWidget);
          expect(
            find.textContaining(excerpt, findRichText: true),
            findsWidgets,
          );
          debugPrint('CATALOG_CAPTURE_$source');
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();

          await BookshelfService().addToBookshelf(book);
          await BookshelfService().removeFromBookshelf(book.bookId);
          for (final tree in ['offline_books', 'reader_cache_v2']) {
            final dir = Directory('${root.path}/$tree/${book.bookId}');
            if (await dir.exists()) await dir.delete(recursive: true);
          }
          await BookshelfService().addToBookshelf(book);
          final freshClient = _WithoutDetailHtml();
          final fresh = FanqieBackendEngine(cache: cache, client: freshClient);
          try {
            final restored = await fresh.getBookDirectory(book.bookId);
            expect(
              restored.map((c) => c.itemId),
              chapters.map((c) => c.itemId),
            );
            expect(freshClient.directoryRequests, 1);
            expect(freshClient.blockedPages, 0);
            await fresh.downloadChapters(
              bookId: book.bookId,
              chapters: restored.take(1).toList(),
            );
            expect(
              await fresh.getOfflineChapterContent(
                book.bookId,
                restored.first.itemId,
              ),
              text,
            );
          } finally {
            fresh.dispose();
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await ReaderPositionService.flush();
          await ReaderSettingsRepository.flush();
          api.dispose();
          await root.delete(recursive: true);
          AppStorage.documentsOverride = previousDocuments;
        }
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: skip,
    );
  }
}
