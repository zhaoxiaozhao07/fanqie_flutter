import 'dart:io';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reader_illustration.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:fanqie_flutter/services/reader_content.dart';
import 'package:fanqie_flutter/services/bookmark_service.dart';
import 'package:fanqie_flutter/services/note_anchor_resolver.dart';
import 'package:fanqie_flutter/services/reader_pagination.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/services/reader_text.dart';
import 'package:fanqie_flutter/widgets/reader_illustration.dart';
import 'package:fanqie_flutter/widgets/reader_page_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'epub_image_fixture.dart';

const _native = MethodChannel('com.fanqie.fanqie_flutter/download');
final _asset = 'images/${'a' * 64}.png';
final _svgAsset = 'images/${'b' * 64}.svg';
ReaderIllustration picture({int offset = 2, int height = 180}) =>
    ReaderIllustration(
      id: 'figure',
      asset: _asset,
      alt: '书中插图',
      width: 240,
      height: height,
      characterOffset: offset,
    );

ReaderLayout layout(double scale, double width) => ReaderLayout(
  size: Size(width, 560),
  bodyStyle: const TextStyle(fontSize: 18, height: 1.8, letterSpacing: .5),
  titleStyle: const TextStyle(fontSize: 22, height: 1.4),
  textScaler: TextScaler.linear(scale),
  horizontalPadding: 20,
  paragraphSpacing: 14,
);

Future<void> ioSettle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File png;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('reader-illustration-');
    png = File('${root.path}/offline_books/local_illustrated/$_asset');
    await png.parent.create(recursive: true);
    await png.writeAsBytes(imagePng());
    await File(
      '${root.path}/offline_books/local_illustrated/$_svgAsset',
    ).writeAsString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="48">'
      '<rect width="64" height="48" fill="blue"/></svg>',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, (_) async => null);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_native, null);
    await root.delete(recursive: true);
  });

  test('inline blocks retain source offsets and same-offset image order', () {
    final images = [
      picture(),
      ReaderIllustration(id: 'second', asset: _asset, characterOffset: 2),
    ];
    final blocks = readerContentBlocks(['前文后文'], images);
    expect(blocks.map((b) => (b.start, b.end)), [
      (0, 2),
      (2, 2),
      (2, 2),
      (2, 4),
    ]);
    expect(
      blocks.where((b) => b.image == null).map((b) => b.text).join(),
      '前文后文',
    );
    expect(blocks.where((b) => b.image != null).map((b) => b.image!.id), [
      'figure',
      'second',
    ]);
    final chapter = Chapter(itemId: 'c', title: '章', illustrations: images);
    final restored = Chapter.fromDirectoryJson(chapter.toJson(), 0);
    expect(
      restored.illustrations.map((e) => e.toJson()),
      images.map((e) => e.toJson()),
    );
  });

  for (final scale in [1.0, 2.0]) {
    for (final width in [320.0, 480.0]) {
      test('pictures fit pages without losing text at $width / $scale', () {
        final first = '前文${'山川与故事。' * 130}';
        final second = '后续章节正文' * 40;
        final content = '$first\n\n$second';
        final images = [picture(height: 3000), picture(offset: 50).at(1, 50)];
        final pages = ReaderPaginationCache().paginate(
          chapterId: 'c',
          title: '插图章',
          content: content,
          layout: layout(scale, width),
          indent: true,
          illustrations: images,
        );
        final fragments = pages.pages.expand((p) => p.fragments).toList();
        expect(fragments.where((f) => f.image != null).length, 2);
        for (final page in pages.pages) {
          final total =
              page.fragments.fold<double>(0, (h, f) => h + f.height) +
              (page.fragments.length - 1) * 14;
          expect(total, lessThanOrEqualTo(page.availableHeight + .01));
          expect(page.text, isNot(contains('images/')));
        }
        for (var p = 0; p < 2; p++) {
          final expected = p == 0 ? first : second;
          final text = fragments.where(
            (f) => f.paragraphIndex == p && f.image == null,
          );
          expect(
            text
                .map((f) => f.startOffset == 0 ? f.text.substring(2) : f.text)
                .join(),
            expected,
          );
          var offset = 0;
          for (final f in text) {
            expect(f.startOffset, offset);
            offset = f.endOffset;
          }
          expect(offset, expected.length);
        }
      });
    }
  }

  test('image position round trips and survives page reflow', () async {
    final content = '图前${'连续正文。' * 120}图后';
    final image = picture(offset: content.length - 2, height: 3000);
    final saved = ReadingPosition(
      chapterId: 'c',
      characterOffset: image.characterOffset,
      imageId: image.id,
    );
    await ReaderPositionService().save('image-anchor', saved);
    expect(
      (await ReaderPositionService().load('image-anchor'))!.imageId,
      image.id,
    );
    for (final scale in [1.0, 2.0]) {
      final pages = ReaderPaginationCache().paginate(
        chapterId: 'c',
        title: '章',
        content: content,
        layout: layout(scale, 320),
        indent: true,
        illustrations: [image],
      );
      final target = pages.pages[pages.pageFor(saved)];
      expect(target.fragments.any((f) => f.image?.id == image.id), true);
      expect(target.position('c').imageId, image.id);
    }
  });

  test('scroll geometry distinguishes image and text at the same anchor', () {
    final geometry = ReaderParagraphGeometry(
      source: '前文后文',
      images: [picture()],
      style: const TextStyle(fontSize: 18, height: 1.8),
      scaler: TextScaler.noScaling,
      width: 300,
      indent: true,
      spacing: 14,
      imageHeight: 600,
    );
    final imageY = geometry.yForOffset(2, imageId: 'figure');
    final textY = geometry.yForOffset(2);
    expect(imageY, greaterThan(0));
    expect(textY, greaterThan(imageY + 180));
    expect(geometry.atY(imageY + 70).$3, 'figure');
    expect(geometry.atY(textY).$1, 2);
    expect(geometry.atY(textY).$3, isNull);
  });

  Future<void> openImage(
    WidgetTester tester,
    ReaderIllustration image, {
    ValueChanged<bool>? viewer,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReaderIllustrationView(
                bookId: 'local_illustrated',
                image: image,
                height: 180,
                textColor: Colors.black,
                documents: () async => root,
                onViewerChanged: viewer,
              ),
            ),
          ),
        ),
      );
      // FileImage's native codec must start in a real async zone.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await ioSettle(tester);
  }

  for (final svg in [false, true]) {
    testWidgets(
      '${svg ? 'SVG' : 'raster'} renders and opens a zoomable viewer',
      (tester) async {
        final events = <bool>[];
        await openImage(
          tester,
          svg
              ? ReaderIllustration(id: 'figure', asset: _svgAsset, alt: '矢量插图')
              : picture(),
          viewer: events.add,
        );
        expect(find.text('插图缺失或无法显示'), findsNothing);
        expect(
          svg ? find.byType(SvgPicture) : find.byType(Image),
          findsOneWidget,
        );
        if (!svg) {
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            isNotNull,
          );
        }
        await tester.tap(find.byKey(const ValueKey('epub-image-figure')));
        await ioSettle(tester);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(events, [true]);
        await tester.tap(find.byTooltip('关闭图片'));
        await ioSettle(tester);
        expect(events, [true, false]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await ioSettle(tester);
      },
    );
  }

  testWidgets(
    'missing, corrupt and symlinked pictures are visible placeholders',
    (tester) async {
      for (final mode in ['missing', 'corrupt', 'symlink']) {
        await tester.runAsync(() async {
          if (await png.exists()) await png.delete();
          if (mode == 'corrupt') await png.writeAsString('not an image');
          if (mode == 'symlink') {
            final outside = File('${root.path}/outside.png');
            await outside.writeAsBytes(imagePng());
            await Link(png.path).create(outside.path);
          }
        });
        await openImage(tester, picture());
        expect(find.textContaining('插图缺失或无法显示'), findsOneWidget, reason: mode);
        expect(find.textContaining('书中插图'), findsOneWidget, reason: mode);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await ioSettle(tester);
        if (mode == 'symlink') {
          await tester.runAsync(() => Link(png.path).delete());
        }
        PaintingBinding.instance.imageCache.clear();
      }
    },
  );

  Future<void> openReader(
    WidgetTester tester,
    bool pageMode,
    String content, {
    String animation = 'none',
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          book: Book(
            bookId: 'local_illustrated',
            bookName: '插图阅读',
            author: '测试',
          ),
          chapters: [
            Chapter(
              itemId: 'c',
              title: '插图章',
              content: content,
              illustrations: [
                picture(offset: content == ReaderText.imageOnlyMarker ? 0 : 2),
              ],
            ),
          ],
          initialSettings: ReaderSettingsRecord(
            ReaderSettings(
              pageMode: pageMode,
              pageAnimation: animation,
              commentBubbles: false,
            ),
          ),
          resumeSavedPosition: false,
          bookDocuments: () async => root,
        ),
      ),
    );
    await ioSettle(tester);
    expect(tester.takeException(), isNull);
  }

  for (final mode in [
    'scroll',
    'none',
    'cover',
    'simulation',
    'slide',
    'fade',
  ]) {
    testWidgets(
      '$mode reader renders text / image / text in order without turning on image tap',
      (tester) async {
        await openReader(
          tester,
          mode != 'scroll',
          '前文后文',
          animation: mode == 'scroll' ? 'none' : mode,
        );
        final before = find.textContaining('前文', findRichText: true);
        final after = find.textContaining('后文', findRichText: true);
        final image = find.byKey(const ValueKey('epub-image-figure'));
        expect(before, findsWidgets);
        expect(after, findsWidgets);
        expect(image, findsWidgets);
        expect(
          tester.getTopLeft(before.first).dy,
          lessThan(tester.getTopLeft(image.first).dy),
        );
        expect(
          tester.getTopLeft(after.first).dy,
          greaterThan(tester.getBottomLeft(image.first).dy),
        );
        await tester.tap(image.first);
        await ioSettle(tester);
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.text('排版设置'), findsNothing);
        await tester.tap(find.byTooltip('关闭图片'));
        await ioSettle(tester);
        if (mode != 'scroll') {
          final dynamic address = tester
              .widget<ReaderPageView>(find.byType(ReaderPageView))
              .currentPageId;
          expect(address.pageIndex, 0);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await ioSettle(tester);
      },
    );
  }

  for (final pageMode in [false, true]) {
    testWidgets(
      'notes after an inline image retain exact offsets in ${pageMode ? 'page' : 'scroll'} mode',
      (tester) async {
        await BookmarkService().addNote(
          bookId: 'local_illustrated',
          chapterId: 'c',
          chapterIndex: 0,
          chapterTitle: '插图章',
          text: '后文',
          startOffset: 2,
          endOffset: 4,
          chapterHash: NoteAnchorResolver.digest(['前文后文']),
        );
        await openReader(tester, pageMode, '前文后文');
        final marked = <String>[];
        void walk(InlineSpan span) {
          if (span is! TextSpan) return;
          if (span.style?.decoration == TextDecoration.underline &&
              span.text != null) {
            marked.add(span.text!);
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            walk(child);
          }
        }

        for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
          walk(text.text);
        }
        expect(marked, contains('后文'));
        expect(marked, isNot(contains('前文')));
        final notes = await BookmarkService().getNotes('local_illustrated');
        expect((notes.single.startOffset, notes.single.endOffset), (2, 4));
        await tester.pumpWidget(const SizedBox.shrink());
        await ioSettle(tester);
      },
    );

    testWidgets(
      'image-only chapter is visible in ${pageMode ? 'page' : 'scroll'} mode',
      (tester) async {
        await openReader(tester, pageMode, ReaderText.imageOnlyMarker);
        expect(find.byKey(const ValueKey('epub-image-figure')), findsWidgets);
        expect(find.text('本章内容为空'), findsNothing);
        expect(find.textContaining('插图缺失'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await ioSettle(tester);
      },
    );
  }
}
