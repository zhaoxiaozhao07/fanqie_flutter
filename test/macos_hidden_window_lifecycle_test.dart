import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/models/reading_snapshot.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

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
  var swallowAsyncErrors = false;
  var acknowledgeHiddenSave = true;
  var usePositionService = false;
  var mismatchedAcknowledgement = false;
  var newerStoredGeneration = false;
  var hiddenProbeBlocked = false;
  var savedReadBlocked = false;
  var acknowledgementBlocked = false;
  var showReplyBlocked = false;
  var recoveryProbeBlocked = false;
  var showFailure = false;
  var showRemainsHidden = false;
  var hideReplyBlocked = false;
  var hiddenPumps = 0;
  var visiblePumps = 0;
  Completer<void>? blockedFrame;
  final hideReply = Completer<Object?>();
  final showReply = Completer<Object?>();
  final blockedProbe = Completer<Object?>();
  final blockedRead = Completer<ReadingSnapshot?>();
  final operationFinished = Completer<void>();
  Future<void>? publishing;
  Future<void>? operation;
  ReadingSnapshot? hiddenSave;
  ReadingPosition? publishedPosition;
  File? publishedRecord;
  final pendingReads = <Future<void>>{};

  _WindowFixture(this.root);

  File get record => publishedRecord ?? File('${root.path}/anchor.json');

  void initializePositionService() {
    usePositionService = true;
    SharedPreferences.setMockInitialValues({
      'reader_position_hidden-fixture': jsonEncode(expected.toJson()),
    });
  }

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
        if ((!visible && hiddenProbeBlocked) ||
            (visible && recoveryProbeBlocked)) {
          return blockedProbe.future;
        }
        return {'visible': visible, 'displayAssertion': displayAssertion};
      case 'showMainWindow':
        if (showFailure) throw StateError('Controlled show failure');
        visible = !showRemainsHidden;
        if (visible) releaseFrames();
        return showReplyBlocked ? showReply.future : true;
      default:
        throw StateError('Unexpected native call: $method');
    }
  }

  Future<void> publish({bool afterHide = true}) async {
    // A pending intent is not saved before hide. The hidden native/IO path
    // publishes it while frames remain unavailable.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (usePositionService) {
      await ReaderPositionService().save(
        'hidden-fixture',
        publishedPosition ?? expected.position,
      );
      if (afterHide && acknowledgeHiddenSave) {
        hiddenSave = await ReaderPositionService().loadSnapshot(
          'hidden-fixture',
        );
      }
      if (newerStoredGeneration) {
        await ReaderPositionService().save(
          'hidden-fixture',
          publishedPosition ?? expected.position,
        );
      }
      return;
    }
    final snapshot = ReadingSnapshot(
      position: publishedPosition ?? expected.position,
      updatedAt: keepOldGeneration
          ? expected.updatedAt
          : DateTime.now().toUtc(),
    );
    final staging = File('${root.path}/anchor.pending.json');
    final stored = newerStoredGeneration
        ? ReadingSnapshot(
            position: snapshot.position,
            updatedAt: snapshot.updatedAt.add(const Duration(microseconds: 1)),
          )
        : snapshot;
    await staging.writeAsString(jsonEncode(stored.toJson()), flush: true);
    // Publish an immutable file reference, like the preference record's atomic
    // value replacement. Windows cannot rename over a JSON file held by a
    // concurrent read; that is a fixture artifact, not a reader save failure.
    publishedRecord = staging;
    if (afterHide && acknowledgeHiddenSave) {
      hiddenSave = mismatchedAcknowledgement
          ? ReadingSnapshot(
              position: snapshot.position,
              updatedAt: snapshot.updatedAt.add(
                const Duration(microseconds: 1),
              ),
            )
          : snapshot;
    }
  }

  Future<ReadingSnapshot?> readSaved() {
    final reading = readSavedRecord();
    late final Future<void> finished;
    finished = reading
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => pendingReads.remove(finished));
    pendingReads.add(finished);
    return reading;
  }

  Future<ReadingSnapshot?> readSavedRecord() async {
    calls.add('readSaved');
    if (readFailure) {
      throw FileSystemException('Controlled anchor read failure');
    }
    if (savedReadBlocked) return blockedRead.future;
    if (usePositionService) {
      return ReaderPositionService().loadSnapshot('hidden-fixture');
    }
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

  Future<ReadingSnapshot?> readHiddenSave() async {
    if (acknowledgementBlocked) return blockedRead.future;
    return hiddenSave;
  }

  Future<void> verify({
    Future<void> Function(Future<void> Function() action)? runNativeIo,
  }) {
    operation = platform.verifyMacHiddenWindowLifecycle(
      native: native,
      readSaved: readSaved,
      readHiddenSave: readHiddenSave,
      expected: expected,
      runNativeIo:
          runNativeIo ??
          (action) async {
            try {
              await action();
            } catch (_) {
              // WidgetTester.runAsync reports callback errors and returns null.
              if (!swallowAsyncErrors) rethrow;
            }
          },
      pumpVisible: pump,
      diagnostic: phases.add,
      // Real flushed filesystem IO on a loaded Windows runner can exceed
      // 40ms. Keep the independent 500ms whole-operation bound below; this
      // fixture phase budget is not the production helper's five-second gate.
      phaseTimeout: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 2),
    );
    // Completion-only ownership signal: tearDown runs outside a widget test's
    // FakeAsync error zone and must not re-await its failed operation there.
    operation!.then<void>(
      (_) => operationFinished.complete(),
      onError: (Object _, StackTrace _) => operationFinished.complete(),
    );
    // Independent of the helper's phase deadline, including a forbidden pump
    // that would wait forever for hidden VSync.
    return operation!.timeout(const Duration(milliseconds: 500));
  }

  Future<void> close() async {
    visible = true;
    releaseFrames();
    if (!hideReply.isCompleted) hideReply.complete(true);
    if (!showReply.isCompleted) showReply.complete(true);
    if (!blockedProbe.isCompleted) blockedProbe.complete(null);
    if (!blockedRead.isCompleted) blockedRead.complete(null);
    await publishing;
    if (operation != null) {
      await operationFinished.future.timeout(const Duration(milliseconds: 500));
    }
    // Future.timeout does not cancel an owned File.readAsString. Wait for each
    // real read's completion before deleting the Windows fixture directory.
    await Future.wait(pendingReads.toList());
    if (usePositionService) await ReaderPositionService.flush();
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

  test('a live old-record handle does not block hidden publication', () async {
    final oldRecord = fixture.record;
    final original = await oldRecord.readAsString();
    final handle = await oldRecord.open();
    try {
      await fixture.verify();
      expect(fixture.record.path, isNot(oldRecord.path));
      expect(await oldRecord.readAsString(), original);
      expect((await fixture.readSaved())!.position.characterOffset, 11);
    } finally {
      await handle.close();
    }
  });

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

  test('runAsync cannot swallow a hidden verification failure', () async {
    fixture.readFailure = true;
    fixture.swallowAsyncErrors = true;
    await expectLater(fixture.verify(), throwsA(isA<FileSystemException>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  test('a fresh pre-hide snapshot is not evidence of a hidden save', () async {
    fixture.saveOnHide = false;
    await fixture.publish(afterHide: false);
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  test('a stored snapshot without hidden save acknowledgement fails', () async {
    fixture.acknowledgeHiddenSave = false;
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  test('stored generation cannot predate the hidden acknowledgement', () async {
    fixture.mismatchedAcknowledgement = true;
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  test('a newer hidden save retains the confirmed original anchor', () async {
    fixture.newerStoredGeneration = true;
    await fixture.verify();
    final stored = await fixture.readSaved();
    expect(stored!.updatedAt.isAfter(fixture.hiddenSave!.updatedAt), isTrue);
    expect(stored.position.toJson(), fixture.expected.position.toJson());
    expect(fixture.hiddenPumps, 0);
  });

  test(
    'ReaderPositionService accepts a same-anchor follow-up lifecycle save',
    () async {
      fixture.initializePositionService();
      fixture.newerStoredGeneration = true;
      await fixture.verify();
      final stored = await fixture.readSaved();
      expect(stored!.updatedAt.isAfter(fixture.hiddenSave!.updatedAt), isTrue);
      expect(stored.position.toJson(), fixture.expected.position.toJson());
      expect(fixture.hiddenPumps, 0);
    },
  );

  for (final field in ['chapter', 'paragraph', 'offset', 'image']) {
    test('fresh generation cannot hide a changed $field anchor', () async {
      final anchor = fixture.expected.position;
      fixture.publishedPosition = ReadingPosition(
        chapterId: field == 'chapter' ? 'different-chapter' : anchor.chapterId,
        paragraphIndex: field == 'paragraph' ? 74 : anchor.paragraphIndex,
        characterOffset: field == 'offset' ? 12 : anchor.characterOffset,
        imageId: field == 'image' ? 'different-image' : anchor.imageId,
      );
      await expectLater(fixture.verify(), throwsA(isA<StateError>()));
      expect(fixture.visible, isTrue);
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 1);
    });
  }

  test('ReaderPositionService saves a new hidden generation', () async {
    fixture.initializePositionService();
    final beforeHide = DateTime.now().toUtc();
    await fixture.verify();
    final saved = await ReaderPositionService().loadSnapshot('hidden-fixture');
    expect(saved!.position.toJson(), fixture.expected.position.toJson());
    expect(saved.updatedAt.isAfter(beforeHide), isTrue);
    expect(saved.updatedAt, fixture.hiddenSave!.updatedAt);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  test('ReaderPositionService cannot acknowledge a pre-hide save', () async {
    fixture.initializePositionService();
    await fixture.publish(afterHide: false);
    fixture.hiddenSave = await ReaderPositionService().loadSnapshot(
      'hidden-fixture',
    );
    fixture.saveOnHide = false;
    // Even a late observer handing back this same cached record is insufficient:
    // save() timestamps intent creation, not completion of its queued write.
    expect(
      fixture.hiddenSave!.updatedAt.isAfter(fixture.expected.updatedAt),
      isTrue,
    );
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
  });

  for (final phase in ['hidden probe', 'saved read', 'acknowledgement']) {
    test('blocked $phase is bounded and restores before pumping', () async {
      fixture.hiddenProbeBlocked = phase == 'hidden probe';
      fixture.savedReadBlocked = phase == 'saved read';
      fixture.acknowledgementBlocked = phase == 'acknowledgement';
      await expectLater(fixture.verify(), throwsA(isA<StateError>()));
      expect(fixture.calls, contains('showMainWindow'));
      expect(fixture.visible, isTrue);
      expect(fixture.hiddenPumps, 0);
      expect(fixture.visiblePumps, 1);
    });
  }

  test('show reply timeout still probes real visible recovery', () async {
    fixture.showReplyBlocked = true;
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
    expect(
      fixture.phases.any((phase) => phase.contains('visible_recovery done')),
      isTrue,
    );
  });

  test('blocked recovery probe cannot pump an unverified window', () async {
    fixture.recoveryProbeBlocked = true;
    await expectLater(fixture.verify(), throwsA(isA<StateError>()));
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 0);
  });

  testWidgets('real tester.runAsync preserves IO errors after recovery', (
    tester,
  ) async {
    fixture.readFailure = true;
    await expectLater(
      fixture.verify(
        runNativeIo: (action) async {
          await tester.runAsync(action);
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(fixture.visible, isTrue);
    expect(fixture.hiddenPumps, 0);
    expect(fixture.visiblePumps, 1);
    expect(tester.takeException(), isNull);
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
