import 'dart:convert';

import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/desktop_reader_preferences.dart';
import 'package:fanqie_flutter/services/reader_navigation_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(DesktopReaderPreferences.flush);

  test(
    'workspace reads are non-destructive and width is finite and bounded',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(DesktopReaderPreferences.key, 'invalid');
      expect((await DesktopReaderPreferences.load()).sidebarWidth, 304);
      expect(prefs.getString(DesktopReaderPreferences.key), 'invalid');
      for (final width in [-50, 300, 900]) {
        await prefs.setString(
          DesktopReaderPreferences.key,
          jsonEncode({'directoryOpen': true, 'sidebarWidth': width}),
        );
        final workspace = await DesktopReaderPreferences.load();
        expect(workspace.directoryOpen, true);
        expect(workspace.sidebarWidth, width.clamp(240, 480));
      }
      expect(DesktopReaderPreferences.boundedWidth(double.nan), 304);
      expect(DesktopReaderPreferences.boundedWidth(double.infinity), 304);
    },
  );

  test(
    'rapid workspace writes are serialized and the final state wins',
    () async {
      final writes = [
        for (var i = 0; i < 20; i++)
          DesktopReaderPreferences(
            directoryOpen: i.isOdd,
            sidebarWidth: 260 + i * 4,
          ).save(),
      ];
      await Future.wait(writes);
      await DesktopReaderPreferences.flush();
      final workspace = await DesktopReaderPreferences.load();
      expect(workspace.sidebarWidth, 336);
      expect(workspace.directoryOpen, true);
      expect((await SharedPreferences.getInstance()).getKeys(), {
        DesktopReaderPreferences.key,
      });
    },
  );

  ReadingPosition p(int n, {double fraction = 0}) => ReadingPosition(
    chapterId: 'c$n',
    paragraphIndex: n,
    characterOffset: n * 10,
    viewportFraction: fraction,
  );

  test('history supports exact back/forward and clears only a new branch', () {
    final history = ReaderNavigationHistory(capacity: 3);
    history.record(p(0), p(1));
    history.record(p(1), p(2));
    history.returnedTo(p(1), origin: p(2, fraction: .4));
    history.returnedTo(p(0), origin: p(1));
    expect(history.canGoBack, false);
    expect(history.next!.chapterId, 'c1');
    history.advancedTo(p(1), origin: p(0));
    expect(history.previous!.chapterId, 'c0');
    expect(history.next!.viewportFraction, .4);
    // A no-op jump must not destroy the forward branch.
    history.record(p(1), p(1));
    expect(history.canGoForward, true);
    history.record(p(1), p(3));
    expect(history.canGoForward, false);
    expect(history.length, 2);
  });

  test('failed traversals preserve both stacks and image identity matters', () {
    final history = ReaderNavigationHistory();
    history.record(p(0), p(1));
    history.returnedTo(p(2), origin: p(1));
    expect(history.previous!.chapterId, 'c0');
    history.returnedTo(p(0), origin: p(1));
    history.advancedTo(p(2), origin: p(0));
    expect(history.next!.chapterId, 'c1');
    expect(
      ReaderNavigationHistory.sameAnchor(
        const ReadingPosition(chapterId: 'c', imageId: 'a'),
        const ReadingPosition(chapterId: 'c', imageId: 'b'),
      ),
      false,
    );
    history.clear();
    expect(history.canGoBack || history.canGoForward, false);
  });
}
