import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:fanqie_flutter/services/compatible_tts_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/tts_audio.dart';

void main() {
  Future<TtsAudio> speak(CompatibleTtsClient service) => service.synthesize(
    baseUrl: 'https://compatible.example/v1',
    apiKey: 'synthetic-key',
    model: 'custom-model',
    voice: 'custom-voice',
    text: '隔离语音测试。',
    speed: 1.25,
  );
  test('endpoint resolution and authorization boundaries', () {
    for (final base in [
      'https://service.example',
      'https://service.example/v1/',
      'https://service.example/v1/audio/speech',
    ]) {
      expect(CompatibleTtsClient.endpoint(base).path, '/v1/audio/speech');
    }
    expect(CompatibleTtsClient.endpoint('http://127.0.0.1:9000').port, 9000);
    for (final base in [
      'http://remote.example',
      'https://user:password@service.example',
      'https://service.example?api_key=secret',
      'https://service.example#fragment',
    ]) {
      expect(() => CompatibleTtsClient.endpoint(base), throwsFormatException);
    }
  });
  test(
    'a real silent MP3 frame validates but a truncated header does not',
    () async {
      final mp3 = await File('test/fixtures/tts/silent.mp3').readAsBytes();
      expect(CompatibleTtsClient.audioFormat(mp3), 'mp3');
      expect(
        () => CompatibleTtsClient.audioFormat(
          Uint8List.fromList([0xff, 0xfb, 0x90, 0x44]),
        ),
        throwsA(isA<TtsRequestFailure>()),
      );
    },
  );
  test(
    'Android-compatible request sends binary response with exact custom fields',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/audio/speech');
        expect(request.headers['Authorization'], 'Bearer synthetic-key');
        expect(jsonDecode(request.body), {
          'model': 'custom-model',
          'input': '隔离语音测试。',
          'voice': 'custom-voice',
          'response_format': 'mp3',
          'speed': 1.25,
        });
        expect(request.followRedirects, false);
        return http.Response.bytes(
          silentTtsWav(),
          200,
          headers: {'content-type': 'audio/wav'},
        );
      });
      final audio = await speak(CompatibleTtsClient(client));
      expect(audio.format, 'wav');
      expect(audio.bytes, silentTtsWav());
      client.close();
    },
  );
  test('401/403 and redirects never retry or forward credentials', () async {
    for (final status in [401, 403, 302, 307]) {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          'private response must not be shown',
          status,
          headers: {'location': 'https://other.example'},
        );
      });
      await expectLater(
        speak(CompatibleTtsClient(client)),
        throwsA(isA<TtsRequestFailure>()),
      );
      expect(calls, 1);
      client.close();
    }
  });
  test('bounded 429/5xx backoff and invalid bodies', () async {
    var calls = 0;
    final client = MockClient((_) async {
      if (++calls == 1) {
        return http.Response('', 429, headers: {'retry-after': '0'});
      }
      return http.Response.bytes(silentTtsWav(), 200);
    });
    await speak(CompatibleTtsClient(client, retryDelay: Duration.zero));
    expect(calls, 2);
    client.close();
    for (final response in [
      http.Response(
        'not audio',
        200,
        headers: {'content-type': 'application/json'},
      ),
      http.Response.bytes(
        Uint8List(CompatibleTtsClient.maxAudioBytes + 1),
        200,
      ),
      http.Response.bytes([1, 2, 3], 200),
    ]) {
      final bad = MockClient((_) async => response);
      await expectLater(
        speak(CompatibleTtsClient(bad)),
        throwsA(isA<TtsRequestFailure>()),
      );
      bad.close();
    }
  });
  test('cancellation aborts even a mock that delivers response late', () async {
    final gate = Completer<http.Response>();
    final client = MockClient((_) => gate.future);
    final service = CompatibleTtsClient(client);
    final pending = speak(service);
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    await expectLater(pending, throwsA(isA<TtsRequestCancelled>()));
    gate.complete(http.Response.bytes(silentTtsWav(), 200));
    await Future<void>.delayed(Duration.zero);
    client.close();
  });
  test(
    'isolated loopback HTTP protocol uses no real service or user data',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<Map>();
      server.listen((request) async {
        final json = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(request.uri.path, '/v1/audio/speech');
        expect(request.headers.value('authorization'), 'Bearer synthetic-only');
        received.complete(json);
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(silentTtsWav());
        await request.response.close();
      });
      final client = http.Client();
      try {
        final result = await CompatibleTtsClient(client).synthesize(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'synthetic-only',
          model: 'local-compatible',
          voice: 'local-voice',
          text: '这是一段隔离测试。',
          speed: 1,
        );
        expect(result.format, 'wav');
        expect((await received.future)['model'], 'local-compatible');
      } finally {
        client.close();
        await server.close(force: true);
      }
    },
  );
}
