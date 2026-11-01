import 'dart:io';

import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/services/reader_position_service.dart';
import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_platform_test.dart' as fixture;

const soakSeconds = int.fromEnvironment('SOAK_SECONDS', defaultValue: 1800);

Future<void> until(Future<bool> Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(end)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Media action was not acknowledged within five seconds');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('screen-off speech pipeline soak ($soakSeconds seconds)', (
    tester,
  ) async {
    final root = await (await getTemporaryDirectory()).createTemp(
      'speech-soak-',
    );
    final wav = await fixture.wave(root);
    final audio = await wav.readAsBytes();
    final prefs = await SharedPreferences.getInstance();
    final oldEngine = prefs.getString('tts_engine_type');
    final oldBase = prefs.getString('tts_openai_base_url');
    final tts = TtsService.forTesting(
      invoke: (method, args) =>
          fixture.native.invokeMethod<Object?>(method, args),
      client: MockClient((_) async => http.Response.bytes(audio, 200)),
      bindPlatformEvents: true,
    );
    const bookId = 'local_platform_soak';
    try {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('关屏稳定性验证'))),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiBaseUrl: 'https://audio-test.invalid',
      );
      await tts.startBook(
        Book(bookId: bookId, bookName: '后台稳定性测试', author: '本地测试'),
        [Chapter(itemId: 'soak-chapter', title: '长章', content: '文' * 200000)],
        0,
      );
      expect(tts.isPlaying, true);
      debugPrint('FANQIE_SOAK_DURATION=$soakSeconds');
      debugPrint('FANQIE_BACKGROUND_READY');
      await tester.runAsync(() async {
        final start = DateTime.now();
        var samples = 0;
        var playingSamples = 0;
        while (DateTime.now().difference(start).inSeconds < soakSeconds) {
          final remaining =
              soakSeconds - DateTime.now().difference(start).inSeconds;
          final interval = [5, 7, 6][samples % 3];
          await Future<void>.delayed(
            Duration(seconds: remaining < interval ? remaining : interval),
          );
          final caps = await fixture.native.invokeMapMethod(
            'getReaderCapabilities',
          );
          expect(caps!['foreground'], false);
          expect(caps['interactive'], false);
          expect(tts.isActive, true);
          expect(tts.isPaused, false, reason: tts.errorMessage);
          expect(tts.actualEngine, anyOf(isNull, TtsEngineType.openAi));
          expect(
            tts.chunks.where((chunk) => chunk.audioFilePath != null).length,
            lessThanOrEqualTo(4),
          );
          if ((await fixture.playback())['playing'] == true) playingSamples++;
          samples++;
          if (samples % 50 == 0) {
            debugPrint(
              'FANQIE_SOAK_PROGRESS chunk=${tts.currentIndex} samples=$samples',
            );
          }
        }
        expect(playingSamples, greaterThan(0));
        expect(playingSamples, greaterThanOrEqualTo((samples * .7).floor()));
        final minimumOffset = (soakSeconds ~/ 6) * 100;
        expect(
          tts.currentPosition!.characterOffset,
          greaterThanOrEqualTo(minimumOffset),
        );
        final saved = await ReaderPositionService().load(bookId);
        expect(saved, isNotNull);
        expect(saved!.characterOffset, greaterThanOrEqualTo(minimumOffset));
        debugPrint('FANQIE_MEDIA_PAUSE_READY');
        await until(
          () async =>
              tts.isPaused && (await fixture.playback())['playing'] == false,
        );
        debugPrint('FANQIE_MEDIA_PLAY_READY');
        await until(
          () async =>
              tts.isPlaying && (await fixture.playback())['playing'] == true,
        );
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
      if (await Directory(root.path).exists()) {
        await root.delete(recursive: true);
      }
    }
  }, timeout: Timeout(Duration(seconds: soakSeconds + 180)));
}
