// Build this dedicated entry point in Release to validate the actual sandbox
// and AOT runtime. It uses the production app/initializer but isolated data.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fanqie_flutter/main.dart' as application;
import 'package:fanqie_flutter/services/app_lifecycle_service.dart';
import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/local_book_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:fanqie_flutter/services/reader_route_observer.dart';
import 'package:fanqie_flutter/services/reader_settings_repository.dart';
import 'package:fanqie_flutter/models/reader_settings.dart';
import 'package:fanqie_flutter/screens/reader_screen.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const manualSave = bool.fromEnvironment('MACOS_SAVE_PANEL_TEST');

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

CustomScrollView? readerScroll(Element element) {
  if (element.widget is CustomScrollView) {
    return element.widget as CustomScrollView;
  }
  CustomScrollView? result;
  element.visitChildren((child) {
    result ??= readerScroll(child);
  });
  return result;
}

IconButton? readerFullScreenButton(Element element) {
  final widget = element.widget;
  if (widget is IconButton && widget.tooltip == '阅读全屏') return widget;
  IconButton? result;
  element.visitChildren((child) {
    result ??= readerFullScreenButton(child);
  });
  return result;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    errors.add(error.toString());
    return true;
  };
  Directory? root;
  const result =
      1; // Success exits through AppKit, never through this fallback.
  try {
    SharedPreferences.setMockInitialValues({});
    root = await (await AppStorage.documents()).createTemp(
      'isolated-release-smoke-',
    );
    AppStorage.documentsOverride = () async => root!;
    await application.initializeReaderApplication();
    runApp(const application.FanqieApp());
    await ReaderPlatform.invoke('showMainWindow');
    await Future<void>.delayed(const Duration(seconds: 5));
    await WidgetsBinding.instance.endOfFrame;
    final caps = await ReaderPlatform.invoke<Map>('getReaderCapabilities');
    require(caps?['architecture'] == 'arm64', 'Incorrect native architecture');
    require(caps?['windowVisible'] == true, 'Release window is not visible');
    require(
      caps?['tts'] == true &&
          caps?['secureStorage'] == true &&
          caps?['mediaPlayback'] == true,
      'Speech/audio/secure native bridge is missing',
    );
    final size = WidgetsBinding.instance.renderViews.first.size;
    require(size.width >= 720 && size.height >= 540, 'Invalid native viewport');
    final source = await File('${root.path}/release-import.txt').writeAsString(
      '第一章 开篇\n${List.generate(100, (i) => '第$i段 Release 沙盒中文正文。退出之前必须保存当前原文锚点，而不是返回章节开头。').join('\n\n')}\n第二章 结尾\n中文结尾。',
    );
    final book = await LocalBookService().importLocalTxt(source);
    require(book.chapters.isNotEmpty, 'Release native import has no chapters');
    final imported = await File(
      '${root.path}/offline_books/${book.book.bookId}/${book.chapters.first.itemId}.txt',
    ).readAsString();
    require(imported.contains('中文'), 'Release native decoder lost text');
    if (manualSave) {
      stdout.writeln('FANQIE_RELEASE_SAVE_PANEL_READY');
    }
    final save = FileExportService().save(
      source,
      name: 'fanqie-release-smoke.txt',
      mimeType: 'text/plain',
      requestId: 'release-smoke-panel',
    );
    if (manualSave) {
      final exported = await save;
      require(exported.status == FileExportStatus.saved, 'Manual save failed');
      require(
        await File(exported.path!).readAsString() ==
            await source.readAsString(),
        'Manual export changed its content',
      );
      stdout.writeln('FANQIE_RELEASE_SAVE_OK ${exported.path}');
      // Leave the chosen output for inspection; never delete an arbitrary
      // user-selected external file as part of test cleanup.
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await ReaderPlatform.invoke('cancelExport', {
        'id': 'release-smoke-panel',
      });
      require(
        (await save).status == FileExportStatus.cancelled,
        'Panel cancellation failed',
      );
    }
    require(await source.exists(), 'Cancelled export deleted its source');
    // Exercise the actual native termination handshake with a dirty reading
    // position, rather than passing by calling exit() on an empty home screen.
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    runApp(
      MaterialApp(
        navigatorObservers: [readerRouteObserver],
        home: ReaderScreen(
          book: book.book,
          chapters: book.chapters,
          resumeSavedPosition: false,
          initialSettings: const ReaderSettingsRecord(
            ReaderSettings(
              pureMode: true,
              commentBubbles: false,
              pageMode: false,
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    await WidgetsBinding.instance.endOfFrame;
    final scroll = readerScroll(
      WidgetsBinding.instance.rootElement!,
    )?.controller;
    require(scroll?.hasClients == true, 'Release reader did not lay out');
    require(
      scroll!.position.maxScrollExtent > 1800,
      'Insufficient reading fixture',
    );
    scroll.jumpTo(1800);
    await WidgetsBinding.instance.endOfFrame;
    await ReaderSystemService.flushParticipants();
    final before = await ReaderPositionService().load(book.book.bookId);
    final windowSize = WidgetsBinding.instance.renderViews.first.size;
    final windowedHeight = scroll.position.viewportDimension;
    final fullScreen = readerFullScreenButton(
      WidgetsBinding.instance.rootElement!,
    );
    require(
      fullScreen?.onPressed != null,
      'Release reader full-screen entry missing',
    );
    fullScreen!.onPressed!();
    await Future<void>.delayed(const Duration(seconds: 1));
    await WidgetsBinding.instance.endOfFrame;
    require(
      scroll.position.viewportDimension >= windowedHeight + 40,
      'Reading immersion did not reclaim the toolbar area',
    );
    require(
      WidgetsBinding.instance.renderViews.first.size == windowSize,
      'Reading immersion changed the application viewport',
    );
    await ReaderSystemService.flushParticipants();
    final immersed = await ReaderPositionService().load(book.book.bookId);
    require(
      before != null &&
          immersed?.paragraphIndex == before.paragraphIndex &&
          immersed?.characterOffset == before.characterOffset,
      'Reading immersion lost the source anchor',
    );
    require(errors.isEmpty, 'Release framework/runtime errors: $errors');
    stdout.writeln(
      'FANQIE_RELEASE_SMOKE_OK ${jsonEncode({'width': size.width, 'height': size.height, 'native': caps, 'readerImmersive': true, 'rss': ProcessInfo.currentRss})}',
    );
    ReaderSystemService.registerQuitHandler(() async {
      stdout.writeln('FANQIE_RELEASE_QUIT_CALLBACK');
      final allowed = await AppLifecycleService.prepareToQuit();
      final position = await ReaderPositionService().load(book.book.bookId);
      require(
        allowed && position != null && position.paragraphIndex > 0,
        'Native quit did not flush the visible reading anchor',
      );
      stdout.writeln(
        'FANQIE_RELEASE_QUIT_ALLOWED paragraph=${position!.paragraphIndex}',
      );
      final directory = root;
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      await stdout.flush();
      return true;
    });
    await ReaderPlatform.invoke('requestQuit');
    await Future<void>.delayed(const Duration(seconds: 30));
    throw StateError('AppKit did not terminate after the native quit callback');
  } catch (error, stack) {
    stderr.writeln('FANQIE_RELEASE_SMOKE_FAILED $error\n$stack');
  } finally {
    runApp(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final directory = root;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
  exit(result);
}
