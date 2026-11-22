import 'dart:async';

import 'package:fanqie_flutter/services/reader_platform.dart';
import 'package:fanqie_flutter/services/reader_scroll_input.dart';
import 'package:fanqie_flutter/services/reader_system_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();

  PointerScrollEvent scroll(
    int micros, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) => PointerScrollEvent(
    timeStamp: Duration(microseconds: micros),
    kind: kind,
    scrollDelta: const Offset(0, 120),
  );

  Future<Object?> notify(String method, Object? arguments) async {
    final reply = Completer<ByteData?>();
    binding.channelBuffers.push(
      ReaderPlatform.channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      reply.complete,
    );
    return codec.decodeEnvelope((await reply.future)!);
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ReaderScrollInput.record(null);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ReaderScrollInput.record(null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('literal source timestamps match exactly and only once', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(999999)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isTrue);
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
  });

  test('nearby or unmatched timestamps never borrow the latest metadata', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(999999)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(1000001)), isFalse);
  });

  test('metadata arriving after its pointer cannot authorize a replay', () {
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
  });

  test('recent metadata uses source age, not the time of Dart dispatch', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    ReaderScrollInput.record({'timestampMicros': 1999999, 'precise': true});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isTrue);
  });

  test('metadata at the one-second source-age boundary fails closed', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    ReaderScrollInput.record({'timestampMicros': 2000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(2000000)), isTrue);
  });

  test('late source-old metadata cannot reopen an expired classification', () {
    ReaderScrollInput.record({'timestampMicros': 2000000, 'precise': true});
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
  });

  test('an unmatched pointer also advances source-age eviction', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(2000000)), isFalse);
    ReaderScrollInput.record({'timestampMicros': 1000001, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000001)), isFalse);
  });

  test('the 65th outstanding input evicts the oldest of 64 entries', () {
    for (var index = 0; index < 65; index++) {
      ReaderScrollInput.record({
        'timestampMicros': 1000000 + index * 1000,
        'precise': false,
      });
    }
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(1001000)), isTrue);
    expect(ReaderScrollInput.takeDiscrete(scroll(1064000)), isTrue);
  });

  test('precise events never authorize discrete repeats', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': true});
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
  });

  for (final precisions in [
    [false, true],
    [true, false],
    [false, false],
  ]) {
    test('ambiguous duplicate precision $precisions fails closed', () {
      for (final precise in precisions) {
        ReaderScrollInput.record({
          'timestampMicros': 1000000,
          'precise': precise,
        });
      }
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    });
  }

  for (final value in <Object?>[null, 0, 1, 'false', [], {}]) {
    test('invalid precision ${value.runtimeType}/$value fails closed', () {
      ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
      ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': value});
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    });
  }

  // Each malformed precision has one fresh record. Duplicate-key ambiguity
  // above must not accidentally be the reason these exact lookups fail.
  for (final sample in const [
    (name: 'missing', micros: 3100000, payload: {'timestampMicros': 3100000}),
    (
      name: 'null',
      micros: 3200000,
      payload: {'timestampMicros': 3200000, 'precise': null},
    ),
    (
      name: 'zero',
      micros: 3300000,
      payload: {'timestampMicros': 3300000, 'precise': 0},
    ),
    (
      name: 'one',
      micros: 3400000,
      payload: {'timestampMicros': 3400000, 'precise': 1},
    ),
    (
      name: 'string',
      micros: 3500000,
      payload: {'timestampMicros': 3500000, 'precise': 'false'},
    ),
    (
      name: 'list',
      micros: 3600000,
      payload: {'timestampMicros': 3600000, 'precise': <Object?>[]},
    ),
    (
      name: 'map',
      micros: 3700000,
      payload: {'timestampMicros': 3700000, 'precise': <String, Object?>{}},
    ),
  ]) {
    test('single ${sample.name} precision fails closed on its exact key', () {
      ReaderScrollInput.record(sample.payload);
      expect(ReaderScrollInput.takeDiscrete(scroll(sample.micros)), isFalse);
    });
  }

  for (final value in <Object?>[
    null,
    true,
    0,
    -1,
    1000000.0,
    '1000000',
    double.nan,
    double.infinity,
    [],
    {},
  ]) {
    test('invalid timestamp ${value.runtimeType}/$value fails closed', () {
      ReaderScrollInput.record({'timestampMicros': value, 'precise': false});
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    });
  }

  test(
    'non-map or missing timestamp payloads are ignored without throwing',
    () {
      for (final value in <Object?>[
        null,
        [],
        true,
        1,
        'input',
        {},
        {'precise': false},
      ]) {
        ReaderScrollInput.record(value);
      }
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
    },
  );

  test('zero and negative pointer timestamps never match native input', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(ReaderScrollInput.takeDiscrete(scroll(0)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(-1)), isFalse);
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isTrue);
  });

  test('non-mouse lookup consumes metadata without authorizing reuse', () {
    ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
    expect(
      ReaderScrollInput.takeDiscrete(
        scroll(1000000, kind: PointerDeviceKind.trackpad),
      ),
      isFalse,
    );
    expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
  });

  for (final platform in TargetPlatform.values.where(
    (platform) => platform != TargetPlatform.macOS,
  )) {
    test('$platform never records or reuses a Mac classification', () {
      ReaderScrollInput.record({'timestampMicros': 1000000, 'precise': false});
      debugDefaultTargetPlatformOverride = platform;
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
      ReaderScrollInput.record({'timestampMicros': 1000001, 'precise': false});
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isFalse);
      expect(ReaderScrollInput.takeDiscrete(scroll(1000001)), isFalse);
    });
  }

  test(
    'scroll notifications coexist with every existing shared-bus route',
    () async {
      final received = <String>[];
      final owner = Object();
      ReaderSystemService.registerQuitHandler(() async => true);
      ReaderSystemService.registerDesktopCommandHandler((command) {
        received.add(command);
        return command == 'pageNext';
      });
      ReaderSystemService.registerSaveParticipant(owner, () async {
        received.add('saved');
      });
      ReaderSystemService.registerWindowHiddenHandler(() async {
        received.add('hidden');
      });
      ReaderSystemService.registerExternalImportsListener(owner, () async {
        received.add('imports');
      });
      ReaderSystemService.registerVolumeKeyListener(
        (direction) => received.add(direction),
        owner: owner,
      );
      ReaderSystemService.registerTtsListener((method, args) {
        received.add('$method:$args');
      });
      ReaderSystemService.registerMediaListener(received.add);
      addTearDown(() {
        ReaderSystemService.registerSaveParticipant(owner, null);
        ReaderSystemService.registerExternalImportsListener(owner, null);
        ReaderSystemService.registerVolumeKeyListener(null, owner: owner);
        ReaderSystemService.registerTtsListener(null);
        ReaderSystemService.registerMediaListener(null);
      });

      await notify('onReaderScrollInput', {
        'timestampMicros': 1000000,
        'precise': false,
      });
      await notify('onReaderScrollInput', null);
      expect(ReaderScrollInput.takeDiscrete(scroll(1000000)), isTrue);
      expect(await notify('onAppQuitRequested', null), isTrue);
      expect(await notify('onDesktopCommand', 'pageNext'), isTrue);
      expect(await notify('onExternalImportsAvailable', null), isTrue);
      await notify('onWindowHidden', null);
      await notify('onVolumeScroll', 'up');
      await notify('onTtsCompleted', 'tts-token');
      await notify('onAudioCompleted', 'audio-token');
      await notify('onMediaPause', null);
      expect(received, [
        'pageNext',
        'imports',
        'saved',
        'hidden',
        'up',
        'onTtsCompleted:tts-token',
        'onAudioCompleted:audio-token',
        'onMediaPause',
      ]);
    },
  );
}
