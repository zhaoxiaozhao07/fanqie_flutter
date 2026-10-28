import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/services/tts_service.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('TtsService Tests', () {
    test('Smart text chunking splits naturally without breaking mid-sentence', () {
      final tts = TtsService();
      const chapter = '''
这是第一句话，讲述了主角的背景故事。突然间，一道惊雷划破了夜空！
主角抬头望去，心中惊骇莫名：“难道这就是传说中的九天雷劫？”
没有人能够回答他的问题。四周万籁俱寂，只有狂风呼啸的声音。
狂风越来越大，几乎要将山顶的大树连根拔起；然而主角的脚步却依然坚定不移。
''';

      final chunks = tts.splitIntoChunks(chapter);
      expect(chunks, isNotEmpty);
      for (final chunk in chunks) {
        expect(chunk.text.length, lessThanOrEqualTo(250));
        expect(chunk.text.isNotEmpty, isTrue);
      }
    });

    test('TtsService settings persistence', () async {
      final tts = TtsService();
      await tts.loadSettings();
      expect(tts.engineType, equals(TtsEngineType.native));

      await tts.saveSettings(
        engineType: TtsEngineType.openAi,
        openAiBaseUrl: 'https://custom-api.example.com',
        openAiApiKey: 'sk-test-123456',
        openAiModel: 'tts-1-hd',
        openAiVoice: 'nova',
        speechRate: 1.2,
      );

      expect(tts.engineType, equals(TtsEngineType.openAi));
      expect(tts.openAiBaseUrl, equals('https://custom-api.example.com'));
      expect(tts.openAiApiKey, equals('sk-test-123456'));
      expect(tts.openAiModel, equals('tts-1-hd'));
      expect(tts.openAiVoice, equals('nova'));
      expect(tts.speechRate, equals(1.2));
    });
  });
}
