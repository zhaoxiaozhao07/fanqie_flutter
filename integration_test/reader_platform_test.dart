import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const native = MethodChannel('com.fanqie.fanqie_flutter/download');

Future<File> wave(Directory directory, {int seconds = 3}) async {
  const rate = 16000;
  final samples = rate * seconds;
  final bytes = ByteData(44 + samples * 2);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    bytes.setInt16(
      44 + i * 2,
      (math.sin(2 * math.pi * 220 * i / rate) * 1000).round(),
      Endian.little,
    );
  }
  return File(
    '${directory.path}/probe-$seconds.wav',
  ).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}

Future<Map<Object?, Object?>> playback() async =>
    (await native.invokeMapMethod<Object?, Object?>('getPlaybackState'))!;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await (await getTemporaryDirectory()).createTemp(
      'platform-probe-',
    );
  });
  tearDown(() async {
    await native.invokeMethod('stopPlayback');
    await native.invokeMethod('releasePlaybackService');
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('native capabilities and Keystore secret round-trip', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('平台验证'))),
      ),
    );
    final caps = await native.invokeMapMethod('getReaderCapabilities');
    expect(caps!['mediaPlayback'], true);
    expect(caps['secureStorage'], true);
    final old = await native.invokeMethod<String>('readTtsSecret');
    try {
      expect(
        await native.invokeMethod('writeTtsSecret', {
          'value': 'device-test-only-secret',
        }),
        true,
      );
      expect(
        await native.invokeMethod('readTtsSecret') == 'device-test-only-secret',
        true,
      );
    } finally {
      await native.invokeMethod('writeTtsSecret', {'value': old ?? ''});
    }
  });

  testWidgets(
    'real player supports pause, resume, volume and token isolation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('音频验证'))),
      );
      final file = await wave(directory, seconds: 20);
      expect(
        await native.invokeMethod('playAudioFile', {
          'id': 'device-audio',
          'filePath': file.path,
        }),
        true,
      );
      expect((await playback())['playing'], true);
      expect(
        await native.invokeMethod('stopPlayback', {'id': 'obsolete-token'}),
        false,
      );
      expect((await playback())['playing'], true);
      expect(
        await native.invokeMethod('pauseAudio', {'id': 'device-audio'}),
        true,
      );
      expect((await playback())['playing'], false);
      expect(
        await native.invokeMethod('resumeAudio', {'id': 'device-audio'}),
        true,
      );
      await native.invokeMethod('setAudioVolume', {'volume': .25});
      final state = await playback();
      expect(state['playing'], true);
      expect(state['volume'], closeTo(.25, .01));
      await native.invokeMethod('updateMediaPlaybackState', {
        'title': '测试书名',
        'subtitle': '测试章节',
        'isPlaying': true,
        'isActive': true,
      });
      await native.invokeMethod('setSleepDeadline', {
        'milliseconds': DateTime.now()
            .add(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
      });
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      expect((await playback())['playing'], false);
    },
  );

  testWidgets('missing native speech engine fails explicitly without hanging', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('语音引擎验证'))),
    );
    final caps = await native.invokeMapMethod('getReaderCapabilities');
    final started = await native
        .invokeMethod('speakNativeTts', {
          'id': 'native-engine-probe',
          'text': '这是一段系统语音测试。',
          'rate': 1.0,
        })
        .timeout(const Duration(seconds: 25));
    if ((caps!['ttsEngines'] as int) == 0) {
      expect(started, false);
      expect((await playback())['playing'], false);
    } else {
      expect(started, true);
    }
  });

  // Run via scripts/test_android_platform.sh, which backgrounds and locks the
  // test emulator after READY, and restores it only after VERIFIED.
  testWidgets('foreground service keeps actual audio playing with screen off', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('后台与锁屏验证'))),
    );
    final file = await wave(directory, seconds: 45);
    final bytes = await file.readAsBytes();
    final prefs = await SharedPreferences.getInstance();
    final oldEngine = prefs.getString('tts_engine_type');
    final oldBase = prefs.getString('tts_openai_base_url');
    final tts = TtsService.forTesting(
      invoke: (method, args) => native.invokeMethod<Object?>(method, args),
      client: MockClient((_) async => http.Response.bytes(bytes, 200)),
      bindPlatformEvents: true,
    );
    try {
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiBaseUrl: 'https://audio-test.invalid',
      );
      await tts.startChapter('后台播放验证', '屏幕关闭后仍然播放测试音频。' * 8);
      expect(tts.isPlaying, true);
      debugPrint('FANQIE_BACKGROUND_READY');
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 4));
        final caps = await native.invokeMapMethod('getReaderCapabilities');
        expect(caps!['foreground'], false);
        expect(caps['interactive'], false);
        expect((await playback())['playing'], true);
        debugPrint('FANQIE_MEDIA_PAUSE_READY');
        await Future<void>.delayed(const Duration(seconds: 3));
        debugPrint('FANQIE_PAUSE_STATE ${tts.state.name} ${await playback()}');
        expect(tts.isPaused, true);
        expect((await playback())['playing'], false);
        debugPrint('FANQIE_MEDIA_PLAY_READY');
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(tts.isPlaying, true);
        expect((await playback())['playing'], true);
        debugPrint('FANQIE_BACKGROUND_VERIFIED');
        await Future<void>.delayed(const Duration(seconds: 3));
      });
    } finally {
      await tts.stop();
      tts.dispose();
      if (oldEngine == null) {
        await prefs.remove('tts_engine_type');
      } else {
        await prefs.setString('tts_engine_type', oldEngine);
      }
      if (oldBase == null) {
        await prefs.remove('tts_openai_base_url');
      } else {
        await prefs.setString('tts_openai_base_url', oldBase);
      }
    }
  });
}
