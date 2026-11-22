import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/models/reading_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../integration_test/macos_client_platform_test.dart' as platform;

class _WindowFixture {
  final Directory root;
  final ReadingSnapshot expected = ReadingSnapshot(
    position: const ReadingPosition(
      chapterId: 'resized-chapter',
      paragraphIndex: 73,
      characterOffset: 11,
    ),
    updatedAt: DateTime.utc(2026, 11, 23),
  );
  final calls = <String>[];
  final phases = <String>[];
  var visible = true;
  var displayAssertion = true;
  var keepVisibleOnHide = false;
  var keepPowerOnHide = false;
  var saveOnHide = true;
  var keepOldGeneration = false;
  var readFailure = false;
  var showFailure = false;
  var showRemainsHidden = false;
  var hideReplyBlocked = false;
  var hiddenPumps = 0;
  var visiblePumps = 0;
  Completer<void>? blockedFrame;
  final hideReply = Completer<Object?>();
  Future<void>? publishing;
  Future<void>? operation;

  _WindowFixture(this.root);

  File get record => File('${root.path}/anchor.json');

  Future<void> initialize() async {
    await record.writeAsString(
      jsonEncode(
        ReadingSnapshot(
          position: const ReadingPosition(
            chapterId: 'resized-chapter',
            paragraphIndex: 73,
            characterOffset: 7,
          ),
          updatedAt: DateTime.utc(2026, 11, 23),
        ).toJson(),
      ),
    );
  }

  Future<Object?> native(String method) async {
    calls.add(method);
    switch (method) {
      case 'hideTestWindow':
        visible = keepVisibleOnHide;
        displayAssertion = keepPowerOnHide;
        if (saveOnHide) publishing = publish();
        return hideReplyBlocked ? hideReply.future : true;
      case 'getTestWindowState':
        return {'visible': visible, 'displayAssertion': displayAssertion};
      case 'showMainWindow':
        if (showFailure) throw StateError('Controlled show failure');
        visible = !showRemainsHidden;
        if (visible) releaseFrames();
        return true;
      default:
        throw StateError('Unexpected native call: $method');
    }
  }

  Future<void> publish() async {
    // A pending intent is not saved before hide. The hidden native/IO path
    // publishes it while frames remain unavailable.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await record.writeAsString(
      jsonEncode(
        ReadingSnapshot(
          position: expected.position,
          updatedAt: keepOldGeneration
              ? expected.updatedAt
              : expected.updatedAt.add(const Duration(seconds: 1)),
        ).toJson(),
      ),
    );
  }

  Future<ReadingSnapshot?> readSaved() async {
    calls.add('readSaved');
    if (readFailure)
      throw FileSystemException('Controlled anchor read failure');
    return ReadingSnapshot.fromJson(
      jsonDecode(await record.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> pump() async {
    if (!visible) {
      hiddenPumps++;
      blockedFrame ??= Completer<void>();
      await blockedFrame!.future;
    } else {
      visiblePumps++;
    }
  }

  void releaseFrames() {
    final pending = blockedFrame;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> verify() {
    operation = platform.verifyMacHiddenWindowLifecycle(
      native: native,
      readSaved: readSaved,
      expected: expected,
      runNativeIo: (action) => action(),
      pumpVisible: pump,
      diagnostic: phases.add,
      phaseTimeout: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 2),
    );
    // Independent of the helper's phase deadline, including a forbidden pump
    // that would wait forever for hidden VSync.
    return operation!.timeout(const Duration(milliseconds: 500));
  }

  Future<void> close() async {
    visible = true;
    releaseFrames();
    if (!hideReply.isCompleted) hideReply.complete(true);
    await publishing;
    await operation
        ?.catchError((Object _) {})
        .timeout(const Duration(milliseconds: 500));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _WindowFixture fixture;
  late String ownedRoot;
  late String temporaryParent;

  setUp(() async {
    temporaryParent = await Directory.systemTemp.resolveSymbolicLinks();
    final root = await Directory(
      temporaryParent,
    ).createTemp('macos-hidden-helper-');
    ownedRoot = await root.resolveSymbolicLinks();
    fixture = _WindowFixture(root);
    await fixture.initialize();
  });

  tearDown(() async {
    try {
      await fixture.close();
    } finally {
      expect(await fixture.root.resolveSymbolicLinks(), ownedRoot);
      expect(path.dirname(ownedRoot), temporaryParent);
      expect(
        path.basename(ownedRoot).startsWith('macos-hidden-helper-'),
        isTrue,
      );
      expect(
        await FileSystemEntity.type(fixture.root.path, followLinks: false),
        FileSystemEntityType.directory,
      );
      await fixture.root.delete(recursive: true);
    }
  });

  test(
    'suppressed hidden frames do not block native IO and recovery',
    () async {
      await fixture.verify();
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 1);
      expect(fixture.visible, isTrue);
      final saved = await fixture.readSaved();
      expect(saved!.position.chapterId, 'resized-chapter');
      expect(saved.position.paragraphIndex, 73);
      expect(saved.position.characterOffset, 11);
      expect(saved.updatedAt.isAfter(fixture.expected.updatedAt), isTrue);
      expect(
        fixture.calls.indexOf('hideTestWindow'),
        lessThan(fixture.calls.indexOf('readSaved')),
      );
      expect(
        fixture.calls.indexOf('readSaved'),
        lessThan(fixture.calls.indexOf('showMainWindow')),
      );
    },
  );

  for (final failure in ['visibility', 'power', 'anchor', 'generation']) {
    test('$failure failure is bounded and restores before pumping', () async {
      switch (failure) {
        case 'visibility':
          fixture.keepVisibleOnHide = true;
        case 'power':
          fixture.keepPowerOnHide = true;
        case 'anchor':
          fixture.saveOnHide = false;
        case 'generation':
          fixture.keepOldGeneration = true;
      }
      await expectLater(fixture.verify(), throwsA(isA<StateError>()));
      expect(fixture.visible, isTrue);
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 1);
      expect(fixture.phases.any((phase) => phase.contains('failed')), isTrue);
    });
  }

  test(
    'hide reply timeout still restores the actual window before pumping',
    () async {
      fixture.hideReplyBlocked = true;
      await expectLater(fixture.verify(), throwsA(isA<StateError>()));
      expect(fixture.calls, contains('showMainWindow'));
      expect(fixture.visible, isTrue);
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 1);
    },
  );

  test('stored anchor IO failure preserves error and recovers', () async {
    fixture.readFailure = true;
    await expectLater(fixture.verify(), throwsA(isA<FileSystemException>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  for (final failure in ['show reply', 'visible recovery']) {
    test('$failure failure never pumps a still-hidden window', () async {
      fixture.showFailure = failure == 'show reply';
      fixture.showRemainsHidden = failure == 'visible recovery';
      await expectLater(fixture.verify(), throwsA(isA<StateError>()));
      expect(fixture.visible, isFalse);
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 0);
    });
  }
}
