// Standalone native smoke: no test-framework teardown or mocked export channel.
// A blocking platform-thread dialog must fail by exit code, not hang cleanup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fanqie_flutter/services/app_storage.dart';
import 'package:fanqie_flutter/services/file_export_service.dart';
import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bound = Duration(seconds: 4);
late Directory root;

void evidence(String message) {
  final line = 'NATIVE_CANCEL_SMOKE $message';
  // This standalone entry point must emit captured native console evidence.
  // ignore: avoid_print
  print(line);
  File(
    '${root.path}/evidence.log',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> cancel(String id) async {
  final clock = Stopwatch()..start();
  final ack = await ReaderPlatform.invoke<bool>('cancelExport', {'id': id})
      .timeout(
        bound,
        onTimeout: () {
          throw TimeoutException(
            'cancelExport($id) channel ACK blocked',
            bound,
          );
        },
      );
  check(ack == true, 'cancelExport($id) did not acknowledge');
  evidence('ACK id=$id elapsedMs=${clock.elapsedMilliseconds}');
}

Future<FileExportResult> save(File source, String id) => FileExportService()
    .save(
      source,
      name: 'fanqie-native-cancel-$id.txt',
      mimeType: 'text/plain',
      requestId: id,
    )
    .timeout(
      bound + const Duration(seconds: 2),
      onTimeout: () {
        throw TimeoutException('saveExportFile($id) result blocked');
      },
    );

Future<void> preserved(File source, List<int> bytes) async {
  final actual = await source.readAsBytes();
  check(
    actual.isNotEmpty &&
        actual.length == bytes.length &&
        List.generate(
          bytes.length,
          (i) => actual[i] == bytes[i],
        ).every((same) => same),
    'nonempty source bytes changed',
  );
  evidence('SOURCE_UNCHANGED bytes=${actual.length}');
}

Future<void> ordinary(File source, List<int> bytes, String id) async {
  evidence('START ordinary id=$id real-save-channel');
  final result = save(source, id);
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await cancel(id);
  check(
    (await result).status == FileExportStatus.cancelled,
    'ordinary cancellation returned success/failure',
  );
  await preserved(source, bytes);
  evidence('PASS ordinary id=$id cancelled-not-saved');
}

Future<void> copyRegressions(File source, List<int> bytes) async {
  final target = await Directory('${root.path}/copies').create();
  final guard = await File(
    '${target.path}/guard.txt',
  ).writeAsString('previous-file-preserved');
  Future<Map?> commit(File input, Directory directory, String id) =>
      ReaderPlatform.invoke<Map>('commitDownloadFile', {
        'id': id,
        'sourcePath': input.path,
        'directory': directory.path,
        'fileName': 'guard.txt',
      }).timeout(bound);
  String name(Map value) =>
      (value['path'] as String).split(RegExp(r'[/\\]')).last;
  final first = (await commit(source, target, 'commit-first'))!;
  final second = (await commit(source, target, 'commit-second'))!;
  check(
    first['status'] == 'saved' && name(first) == 'guard (2).txt',
    'first atomic numbered commit failed',
  );
  check(
    second['status'] == 'saved' && name(second) == 'guard (3).txt',
    'second atomic numbered commit failed',
  );
  await preserved(File(first['path'] as String), bytes);
  await preserved(File(second['path'] as String), bytes);
  check(
    await guard.readAsString() == 'previous-file-preserved',
    'existing destination was overwritten',
  );
  await cancel('commit-second');
  check(second['status'] == 'saved', 'late cancellation changed saved result');
  await preserved(File(second['path'] as String), bytes);
  evidence(
    'PASS atomic numbered commits previous-file preserved '
    'late-cancel saved-authoritative',
  );

  final cancelTarget = await Directory('${root.path}/copy-cancel').create();
  final cancelGuard = await File(
    '${cancelTarget.path}/guard.txt',
  ).writeAsString('previous-file-preserved');
  final bigSource = File('${root.path}/copy-source.bin');
  final output = await bigSource.open(mode: FileMode.write);
  final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 90);
  try {
    for (var i = 0; i < 1024; i++) {
      await output.writeFrom(chunk);
    }
    await output.flush();
  } finally {
    await output.close();
  }
  var finished = false;
  final result = commit(bigSource, cancelTarget, 'copy-cancel').then((value) {
    finished = true;
    return value;
  });
  var stagingSeen = false;
  final clock = Stopwatch()..start();
  while (!finished && clock.elapsed < const Duration(seconds: 2)) {
    stagingSeen = await cancelTarget.list().any(
      (entry) => entry.path.endsWith('.tmp'),
    );
    if (stagingSeen) break;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  check(stagingSeen, 'copy cancellation requires observed native staging');
  evidence('COPY_STARTED staging-observed bytes=67108864');
  await cancel('copy-cancel');
  final copied = await result;
  final cancelled = copied?['status'] == 'cancelled';
  final saved = copied?['status'] == 'saved';
  check(
    cancelled || saved,
    'copy cancellation returned a failure instead of a terminal outcome',
  );
  check(
    await cancelGuard.readAsString() == 'previous-file-preserved',
    'copy cancellation changed previous destination',
  );
  final remaining = await cancelTarget.list().toList();
  check(
    remaining.length == (cancelled ? 1 : 2) &&
        remaining.every((entry) => !entry.path.endsWith('.tmp')),
    'copy left a staging/unexpected destination file',
  );
  var sourceLength = 0;
  await for (final data in bigSource.openRead()) {
    check(data.every((byte) => byte == 90), 'large source bytes changed');
    sourceLength += data.length;
  }
  check(sourceLength == 64 * 1024 * 1024, 'large source length changed');
  if (saved) {
    // A committed copy wins a cancellation race. Never demand "cancelled"
    // solely because the request arrived after observing a staging file.
    var committedLength = 0;
    await for (final data in File(copied!['path'] as String).openRead()) {
      check(data.every((byte) => byte == 90), 'committed bytes changed');
      committedLength += data.length;
    }
    check(committedLength == sourceLength, 'partial copy reported saved');
  }
  await preserved(source, bytes);
  evidence(
    'PASS copy ${cancelled ? 'cancelled-after-staging no-staging-or-commit' : 'commit-won-race saved-authoritative'} '
    'source-unchanged bytes=$sourceLength previous-file-preserved',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  // No production preference/storage initialization or application main().
  root = Directory(Platform.environment['FANQIE_NATIVE_CANCEL_ROOT']!);
  check(
    root.isAbsolute && root.path.contains('fanqie-native-cancel-smoke-'),
    'an explicitly isolated absolute temp root is required',
  );
  AppStorage.documentsOverride = () async => root;
  final watchdog = Timer(const Duration(seconds: 30), () {
    evidence('FAIL inner-watchdog exit=1');
    exit(1);
  });
  try {
    await ReaderPlatform.initialize().timeout(bound);
    check(
      ReaderPlatform.isWindows && ReaderPlatform.capabilities.fileExport,
      'real Windows export bridge required',
    );
    final bytes = utf8.encode('保留正文 native cancellation source\n');
    final source = await File('${root.path}/source.txt').writeAsBytes(bytes);
    await ordinary(source, bytes, 'ordinary');

    // A real native cancellation latch before native SaveAs exists.
    await cancel('early');
    check(
      (await save(source, 'early')).status == FileExportStatus.cancelled,
      'early cancellation was lost',
    );
    await preserved(source, bytes);
    evidence('PASS early cancelled-not-saved');

    // Send both native messages without FileExportService's async preflight:
    // cancellation may dispatch inside Show before a visible HWND exists.
    for (var i = 0; i < 8; i++) {
      final id = 'creating-$i';
      evidence('START creating id=$id real-save-channel');
      final result =
          ReaderPlatform.invoke<Map>('saveExportFile', {
            'id': id,
            'filePath': source.path,
            'fileName': 'fanqie-native-cancel-$id.txt',
            'mimeType': 'text/plain',
          }).timeout(
            bound + const Duration(seconds: 2),
            onTimeout: () {
              throw TimeoutException(
                'creating saveExportFile($id) result blocked',
              );
            },
          );
      await cancel(id);
      check(
        (await result)?['status'] == 'cancelled',
        'dialog-creation cancellation was lost',
      );
      await preserved(source, bytes);
      evidence('PASS creating id=$id cancelled-not-saved');
    }

    final active = save(source, 'queue-active');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final queued = save(source, 'queued');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cancel('queued');
    await cancel('queue-active');
    check(
      (await active).status == FileExportStatus.cancelled,
      'queue-active was not cancelled',
    );
    check(
      (await queued).status == FileExportStatus.cancelled,
      'queued request opened/saved instead of cancelling',
    );
    await preserved(source, bytes);
    evidence('PASS queued and active cancelled-not-saved');

    // A new real dialog after prior workers/timers have been torn down.
    await ordinary(source, bytes, 'subsequent');
    await copyRegressions(source, bytes);
    evidence('PASS all real-channel cancellation cases exit=0');
    watchdog.cancel();
    exit(0);
  } catch (error, stack) {
    evidence('FAIL $error\n$stack\nexit=1');
    watchdog.cancel();
    exit(1);
  }
}
