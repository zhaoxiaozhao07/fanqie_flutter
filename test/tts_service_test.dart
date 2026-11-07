import 'dart:async';

import 'package:characters/characters.dart';
import 'package:fanqie_flutter/models/book.dart';
import 'package:fanqie_flutter/models/chapter.dart';
import 'package:fanqie_flutter/models/reading_position.dart';
import 'package:fanqie_flutter/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/tts_audio.dart';

class FakeSpeechPlatform {
  String? secret;
  final calls = <(String, Map<String, Object?>?)>[];
  Future<Object?> invoke(String method, Map<String, Object?>? args) async {
    calls.add((method, args));
    if (method == 'readTtsSecret') return secret;
    if (method == 'writeTtsSecret') secret = args!['value'] as String;
    return true;
  }

  int count(String method) => calls.where((call) => call.$1 == method).length;
}

Future<void> drain() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSpeechPlatform platform;
  late TtsService tts;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = FakeSpeechPlatform();
    tts = TtsService.forTesting(invoke: platform.invoke);
  });
  tearDown(() async {
    await tts.stop();
    tts.dispose();
    await drain();
  });

  test('natural chunks retain source ranges and never split graphemes', () {
    final text = '${'这是句子。' * 30}\n\n${'👩🏽‍💻e\u0301' * 250}';
    final chunks = tts.splitIntoChunks(text);
    expect(chunks, isNotEmpty);
    final boundaries = <int>{0};
    var end = 0;
    for (final character in text.characters) {
      end += character.length;
      boundaries.add(end);
    }
    for (final chunk in chunks) {
      expect(chunk.text.characters.length, lessThanOrEqualTo(200));
      expect(boundaries, contains(chunk.startOffset));
      expect(boundaries, contains(chunk.endOffset));
      expect(text.substring(chunk.startOffset, chunk.endOffset), chunk.text);
    }
  });
  test(
    'compatible failure without system voices pauses instead of inventing playback',
    () async {
      await tts.stop();
      tts.dispose();
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        nativeSpeechAvailable: false,
        client: MockClient((_) async => http.Response('', 401)),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-key',
      );
      await tts.startChapter('测试', '隔离测试原文。');
      expect(tts.isPaused, true);
      expect(tts.errorMessage, contains('系统语音也不可用'));
      expect(platform.count('speakNativeTts'), 0);
      expect(platform.count('playAudioFile'), 0);
    },
  );
  test(
    'server speed is not applied twice at the native audio player',
    () async {
      await tts.stop();
      tts.dispose();
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        client: MockClient(
          (_) async => http.Response.bytes(silentTtsWav(), 200),
        ),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-key',
        speechRate: 1.5,
      );
      await tts.startChapter('测试', '隔离测试原文。');
      expect(
        platform.calls
            .lastWhere((call) => call.$1 == 'playAudioFile')
            .$2!['rate'],
        1.0,
      );
      expect(tts.actualEngine, TtsEngineType.openAi);
    },
  );

  test('settings persist without ever writing a plaintext key', () async {
    await tts.saveSettings(
      engineType: TtsEngineType.openAi,
      openAiBaseUrl: 'https://custom-api.example.com/v1',
      openAiApiKey: 'test-secret',
      openAiModel: 'model',
      openAiVoice: 'voice',
      speechRate: 1.2,
    );
    await tts.loadSettings();
    expect(tts.engineType, TtsEngineType.openAi);
    expect(tts.openAiApiKey, 'test-secret');
    expect(tts.openAiVoice, 'voice');
    expect(tts.speechRate, 1.2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('tts_openai_api_key'), isFalse);
    await expectLater(
      tts.saveSettings(openAiBaseUrl: 'http://remote.example.com'),
      throwsFormatException,
    );
  });

  test('legacy key is removed only after secure migration succeeds', () async {
    await tts.loadSettings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tts_openai_api_key', 'old-key');
    await tts.loadSettings();
    expect(platform.secret, 'old-key');
    expect(prefs.containsKey('tts_openai_api_key'), isFalse);
  });

  test('stop-after-chapter flags reset on explicit stop', () async {
    tts.setStopAfterCurrentChapter(true);
    expect(tts.stopAfterCurrentChapter, isTrue);
    tts.toggleStopAfterCurrentChapter();
    expect(tts.stopAfterCurrentChapter, isFalse);
    tts.setStopAfterCurrentChapter(true);
    await tts.stop();
    expect(tts.stopAfterCurrentChapter, isFalse);
  });

  test(
    'late and duplicate completion cannot skip chunks; errors pause in place',
    () async {
      await tts.startChapter('第一章', '一' * 600);
      final old = tts.currentPlaybackToken;
      tts.handlePlatformEvent('onTtsComplete', {'id': old});
      tts.handlePlatformEvent('onTtsComplete', {'id': old});
      await drain();
      expect(tts.currentIndex, 1);
      final current = tts.currentPlaybackToken;
      tts.handlePlatformEvent('onAudioError', {'id': old});
      expect(tts.isPlaying, isTrue);
      tts.handlePlatformEvent('onTtsError', {'id': current});
      expect(tts.isPaused, isTrue);
      expect(tts.currentIndex, 1);
      expect(tts.errorMessage, isNotEmpty);
      await tts.resume();
      expect(tts.currentIndex, 1);
      expect(tts.isPlaying, isTrue);
      expect(tts.currentPlaybackToken, isNot(current));
    },
  );

  test(
    'new start supersedes an earlier start waiting for native stop',
    () async {
      await tts.stop();
      tts.dispose();
      final gate = Completer<Object?>();
      var stops = 0;
      tts = TtsService.forTesting(
        invoke: (method, args) {
          if (method == 'stopPlayback' && stops++ == 0) return gate.future;
          return platform.invoke(method, args);
        },
      );
      final old = tts.startChapter('旧书', '旧正文' * 50);
      await drain();
      await tts.startChapter('新书', '新正文' * 50);
      gate.complete(true);
      await old;
      expect(tts.currentChapterTitle, '新书');
      expect(platform.count('speakNativeTts'), 1);
    },
  );

  test(
    'pause during network buffering never autoplays a late response',
    () async {
      await tts.stop();
      tts.dispose();
      final gate = Completer<http.Response>();
      var requests = 0;
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        client: MockClient((_) {
          requests++;
          return gate.future;
        }),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-test-key',
      );
      final start = tts.startChapter('缓冲测试', '等待朗读的正文。' * 10);
      await drain();
      expect(requests, 1);
      expect(tts.state, TtsPlayState.buffering);
      await tts.pause();
      gate.complete(http.Response.bytes(silentTtsWav(), 200));
      await start;
      expect(tts.isPaused, isTrue);
      expect(platform.count('playAudioFile'), 0);
      await tts.resume();
      expect(tts.isPlaying, isTrue);
      expect(platform.count('playAudioFile'), 1);
    },
  );

  test(
    'network fallback resumes actual native engine, not a missing audio player',
    () async {
      await tts.stop();
      tts.dispose();
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        client: MockClient((_) async => http.Response('', 401)),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-test-key',
      );
      await tts.startChapter('降级', '原生语音测试。' * 10);
      expect(tts.actualEngine, TtsEngineType.native);
      expect(tts.notice, isNotEmpty);
      await tts.pause();
      await tts.resume();
      expect(platform.count('resumeAudio'), 0);
      expect(platform.count('speakNativeTts'), 2);
    },
  );

  test(
    'long chapters retain only a bounded audio window and can seek back',
    () async {
      await tts.stop();
      tts.dispose();
      var requests = 0;
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        client: MockClient((_) async {
          requests++;
          return http.Response.bytes(silentTtsWav(), 200);
        }),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-test-key',
      );
      await tts.startChapter('长章', '文' * 2000);
      for (var i = 0; i < 8; i++) {
        await tts.nextChunk();
        expect(
          tts.chunks.where((chunk) => chunk.audioFilePath != null).length,
          lessThanOrEqualTo(4),
        );
      }
      expect(tts.chunks.first.audioFilePath, isNull);
      final before = requests;
      await tts.previousChunk();
      await tts.previousChunk();
      expect(tts.actualEngine, TtsEngineType.openAi);
      expect(requests, greaterThan(before));
    },
  );

  test(
    'changing voice while buffering invalidates pending audio until resume',
    () async {
      await tts.stop();
      tts.dispose();
      final gate = Completer<http.Response>();
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        client: MockClient((_) => gate.future),
      );
      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiApiKey: 'synthetic-test-key',
      );
      final starting = tts.startChapter('调整音色', '正文' * 50);
      await drain();
      await tts.saveSettings(engineType: TtsEngineType.native);
      gate.complete(http.Response.bytes(silentTtsWav(), 200));
      await starting;
      expect(tts.isPaused, true);
      expect(platform.count('playAudioFile'), 0);
      await tts.resume();
      expect(tts.actualEngine, TtsEngineType.native);
      expect(platform.count('speakNativeTts'), 1);
    },
  );

  test(
    'playlist advances without a reader route and retains sleep deadline',
    () async {
      await tts.startBook(
        Book(bookId: 'tts-playlist', bookName: '听书测试', author: '测试'),
        [
          Chapter(itemId: 'a', title: '第一章', content: '开篇正文。' * 15),
          Chapter(itemId: 'b', title: '第二章', content: '后续正文。' * 15),
        ],
        0,
      );
      tts.setSleepTimer(15);
      final token = tts.currentPlaybackToken;
      tts.handlePlatformEvent('onTtsComplete', {'id': token});
      await drain();
      expect(tts.currentChapterTitle, '第二章');
      expect(tts.currentBookId, 'tts-playlist');
      expect(tts.timerRemainingMinutes, 15);
      expect(tts.currentPosition!.chapterId, 'b');
      tts.setStopAfterCurrentChapter(true);
      tts.handlePlatformEvent('onTtsComplete', {
        'id': tts.currentPlaybackToken,
      });
      await drain();
      expect(tts.state, TtsPlayState.stopped);
    },
  );

  test(
    'pause during book opening preserves the requested source position',
    () async {
      void pauseOpening() {
        if (tts.state == TtsPlayState.buffering && tts.chunks.isEmpty) {
          unawaited(tts.pause());
        }
      }

      tts.addListener(pauseOpening);
      await tts.startBook(
        Book(bookId: 'resume-book', bookName: '原位续听', author: '测试'),
        [
          Chapter(
            itemId: 'resume-chapter',
            title: '章节',
            content: '${'开场内容。' * 20}\n\n${'继续阅读位置。' * 30}',
          ),
        ],
        0,
        position: const ReadingPosition(
          chapterId: 'resume-chapter',
          paragraphIndex: 1,
          characterOffset: 3,
        ),
      );
      tts.removeListener(pauseOpening);
      expect(tts.isPaused, true);
      await tts.resume();
      expect(tts.currentPosition!.paragraphIndex, 1);
      expect(tts.currentPosition!.characterOffset, 3);
    },
  );

  test(
    'stale native sleep and audio-focus events do not affect a new session',
    () async {
      await tts.startChapter('当前书', '正文' * 80);
      tts.handlePlatformEvent('onAudioSleepTimer', {'deadline': 1});
      tts.handlePlatformEvent('onAudioFocusLost', {'id': 'previous-session'});
      expect(tts.isPlaying, true);
      tts.handlePlatformEvent('onAudioFocusLost', {
        'id': tts.currentPlaybackToken,
      });
      expect(tts.isPaused, true);
      await tts.resume();
      tts.handlePlatformEvent('onAudioBecomingNoisy', null);
      expect(tts.isPaused, true);
    },
  );

  test(
    'repeated paragraphs use source ranges instead of first text match',
    () async {
      final paragraph = '重复文字' * 40;
      await tts.startBook(
        Book(bookId: 'range-book', bookName: '原文范围', author: '测试'),
        [
          Chapter(
            itemId: 'range-chapter',
            title: '章节',
            content: '$paragraph\n\n$paragraph',
          ),
        ],
        0,
      );
      expect(tts.spokenRange('range-book', 'range-chapter', 0), isNotNull);
      expect(tts.spokenRange('other-book', 'range-chapter', 0), isNull);
      tts.handlePlatformEvent('onTtsComplete', {
        'id': tts.currentPlaybackToken,
      });
      await drain();
      expect(tts.spokenRange('range-book', 'range-chapter', 0), isNull);
      expect(tts.spokenRange('range-book', 'range-chapter', 1), isNotNull);
      expect(tts.currentPosition!.paragraphIndex, 1);
    },
  );

  testWidgets(
    'sleep timer progressively fades and stops at wall-clock deadline',
    (tester) async {
      await tts.stop();
      tts.dispose();
      tts = TtsService.forTesting(
        invoke: platform.invoke,
        now: tester.binding.clock.now,
      );
      await tts.startChapter('睡眠测试', '一' * 200);
      tts.setSleepTimer(1);
      await tester.pump(const Duration(seconds: 51));
      final volumes = platform.calls
          .where((call) => call.$1 == 'setAudioVolume')
          .map((call) => call.$2!['volume'] as double)
          .toList();
      expect(volumes.any((volume) => volume > 0 && volume < 1), isTrue);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump();
      expect(tts.state, TtsPlayState.stopped);
      expect(tts.timerRemainingMinutes, 0);
    },
  );
}
