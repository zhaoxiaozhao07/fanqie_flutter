import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_system_service.dart';

/// TTS 发音引擎类型
enum TtsEngineType {
  native, // 系统原生 TTS
  openAi, // OpenAI 兼容 TTS 接口
}

/// TTS 播放状态
enum TtsPlayState {
  stopped,
  playing,
  paused,
  buffering,
}

/// 单个文本切片模型
class TtsChunk {
  final int index;
  final String text;
  String? audioFilePath;
  bool isPreloaded = false;
  bool isPreloading = false;

  TtsChunk({
    required this.index,
    required this.text,
    this.audioFilePath,
  });
}

/// TTS 语音听书服务（支持原生 TTS 与 OpenAI 兼容 TTS 双缓冲预拉取流水线）
class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal() {
    _initPlatformListener();
    loadSettings();
  }

  static const MethodChannel _channel = MethodChannel('com.fanqie.fanqie_flutter/download');

  // 配置
  TtsEngineType _engineType = TtsEngineType.native;
  String _openAiBaseUrl = 'https://api.openai.com';
  String _openAiApiKey = '';
  String _openAiModel = 'tts-1';
  String _openAiVoice = 'alloy';
  double _speechRate = 1.0;

  TtsEngineType get engineType => _engineType;
  String get openAiBaseUrl => _openAiBaseUrl;
  String get openAiApiKey => _openAiApiKey;
  String get openAiModel => _openAiModel;
  String get openAiVoice => _openAiVoice;
  double get speechRate => _speechRate;

  // 运行状态
  TtsPlayState _state = TtsPlayState.stopped;
  TtsPlayState get state => _state;
  bool get isPlaying => _state == TtsPlayState.playing;
  bool get isPaused => _state == TtsPlayState.paused;
  bool get isActive => _state == TtsPlayState.playing || _state == TtsPlayState.paused || _state == TtsPlayState.buffering;

  // 播放队列与切片管理
  List<TtsChunk> _chunks = [];
  int _currentIndex = 0;
  String _currentChapterTitle = '';
  void Function(int chapterIndex)? onChapterComplete;

  List<TtsChunk> get chunks => List.unmodifiable(_chunks);
  int get currentIndex => _currentIndex;
  String get currentChapterTitle => _currentChapterTitle;
  String get currentText => _chunks.isNotEmpty && _currentIndex < _chunks.length ? _chunks[_currentIndex].text : '';
  double get progress => _chunks.isNotEmpty ? ((_currentIndex + 1) / _chunks.length).clamp(0.0, 1.0) : 0.0;

  // 定时停止
  Timer? _stopTimer;
  int _timerRemainingMinutes = 0;
  int get timerRemainingMinutes => _timerRemainingMinutes;

  // 播放看门狗超时定时器（防止极端异常下漏掉回调导致播放停滞）
  Timer? _watchdogTimer;

  // 预取 Future 映射
  final Map<int, Future<String?>> _preloadFutures = {};
  final http.Client _httpClient = http.Client();

  void _initPlatformListener() {
    // 统一通过 ReaderSystemService 消息路由总线监听播放事件，彻底消除 Handler 互相覆盖 Bug
    ReaderSystemService.registerTtsListener((method, args) {
      if (method == 'onTtsComplete' || method == 'onAudioComplete') {
        _onChunkFinished();
      } else if (method == 'onTtsError' || method == 'onAudioError') {
        _onChunkFinished();
      }
    });

    // 初始化原生 TTS
    if (Platform.isAndroid) {
      _channel.invokeMethod('initNativeTts');
    }
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _engineType = (prefs.getString('tts_engine_type') == 'openAi') ? TtsEngineType.openAi : TtsEngineType.native;
    _openAiBaseUrl = prefs.getString('tts_openai_base_url') ?? 'https://api.openai.com';
    _openAiApiKey = prefs.getString('tts_openai_api_key') ?? '';
    _openAiModel = prefs.getString('tts_openai_model') ?? 'tts-1';
    _openAiVoice = prefs.getString('tts_openai_voice') ?? 'alloy';
    _speechRate = prefs.getDouble('tts_speech_rate') ?? 1.0;
    notifyListeners();
  }

  Future<void> saveSettings({
    TtsEngineType? engineType,
    String? openAiBaseUrl,
    String? openAiApiKey,
    String? openAiModel,
    String? openAiVoice,
    double? speechRate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (engineType != null) {
      _engineType = engineType;
      await prefs.setString('tts_engine_type', engineType == TtsEngineType.openAi ? 'openAi' : 'native');
    }
    if (openAiBaseUrl != null) {
      _openAiBaseUrl = openAiBaseUrl.trim();
      await prefs.setString('tts_openai_base_url', _openAiBaseUrl);
    }
    if (openAiApiKey != null) {
      _openAiApiKey = openAiApiKey.trim();
      await prefs.setString('tts_openai_api_key', _openAiApiKey);
    }
    if (openAiModel != null) {
      _openAiModel = openAiModel.trim();
      await prefs.setString('tts_openai_model', _openAiModel);
    }
    if (openAiVoice != null) {
      _openAiVoice = openAiVoice.trim();
      await prefs.setString('tts_openai_voice', _openAiVoice);
    }
    if (speechRate != null) {
      _speechRate = speechRate;
      await prefs.setDouble('tts_speech_rate', _speechRate);
    }
    notifyListeners();
  }

  /// 智能文本分块算法：按句末自然停顿切分，并归并为 80~200 字的高效切片
  List<TtsChunk> splitIntoChunks(String content) {
    final clean = content.replaceAll(RegExp(r'\r'), '').trim();
    if (clean.isEmpty) return [];

    final sentenceEndings = RegExp(r'[。！？；!?;]+|\n+');
    final rawSentences = <String>[];
    int lastEnd = 0;

    for (final match in sentenceEndings.allMatches(clean)) {
      final s = clean.substring(lastEnd, match.end).trim();
      if (s.isNotEmpty) {
        rawSentences.add(s);
      }
      lastEnd = match.end;
    }
    if (lastEnd < clean.length) {
      final s = clean.substring(lastEnd).trim();
      if (s.isNotEmpty) rawSentences.add(s);
    }

    // 合并短句为合适长度的 Chunk (目标 80~200 字)
    final chunks = <TtsChunk>[];
    final sb = StringBuffer();
    int chunkIdx = 0;

    for (final sent in rawSentences) {
      if (sb.length + sent.length > 200 && sb.isNotEmpty) {
        chunks.add(TtsChunk(index: chunkIdx++, text: sb.toString().trim()));
        sb.clear();
      }
      sb.write(sent);
    }
    if (sb.isNotEmpty) {
      chunks.add(TtsChunk(index: chunkIdx++, text: sb.toString().trim()));
    }

    return chunks;
  }

  /// 开始播放章节内容
  Future<void> startChapter(String chapterTitle, String chapterContent, {int startChunk = 0}) async {
    await stop();
    _currentChapterTitle = chapterTitle;
    _chunks = splitIntoChunks(chapterContent);
    _currentIndex = startChunk.clamp(0, _chunks.isEmpty ? 0 : _chunks.length - 1);

    if (_chunks.isEmpty) {
      _state = TtsPlayState.stopped;
      notifyListeners();
      return;
    }

    _state = TtsPlayState.playing;
    notifyListeners();

    _playCurrentChunk();
  }

  /// 播放当前分块，并触发后续分块的双缓冲滑动预取
  Future<void> _playCurrentChunk() async {
    if (_currentIndex >= _chunks.length) {
      _state = TtsPlayState.stopped;
      _watchdogTimer?.cancel();
      notifyListeners();
      onChapterComplete?.call(_currentIndex);
      return;
    }

    final chunk = _chunks[_currentIndex];
    
    // 启动当前切片播放看门狗（预估发音秒数 + 容错裕量），确保无论原生还是网络发音绝不卡顿挂起
    _watchdogTimer?.cancel();
    final estSeconds = ((chunk.text.length / 3.8) / _speechRate + 6.0).clamp(6.0, 40.0).toInt();
    _watchdogTimer = Timer(Duration(seconds: estSeconds), () {
      if (isActive && _currentIndex == chunk.index) {
        _onChunkFinished();
      }
    });

    // 1. 若使用 OpenAI TTS，启动滑动窗口预取流水线（预拉取后面 2 个切片）
    if (_engineType == TtsEngineType.openAi) {
      _triggerPreload(_currentIndex + 1);
      _triggerPreload(_currentIndex + 2);

      String? audioPath = chunk.audioFilePath;
      if (audioPath == null || !File(audioPath).existsSync()) {
        _state = TtsPlayState.buffering;
        notifyListeners();

        // 等待当前切片音频就绪
        audioPath = await _fetchChunkAudio(_currentIndex);
      }

      if (_state == TtsPlayState.stopped) return;

      if (audioPath != null && File(audioPath).existsSync()) {
        _state = TtsPlayState.playing;
        notifyListeners();
        await _channel.invokeMethod('playAudioFile', {'filePath': audioPath});
      } else {
        // OpenAI TTS 获取失败，自动容错降级使用原生发音
        _state = TtsPlayState.playing;
        notifyListeners();
        await _channel.invokeMethod('speakNativeTts', {
          'text': chunk.text,
          'rate': _speechRate,
          'id': 'chunk_${chunk.index}',
        });
      }
    } else {
      // 2. 原生系统 TTS 播放
      _state = TtsPlayState.playing;
      notifyListeners();
      await _channel.invokeMethod('speakNativeTts', {
        'text': chunk.text,
        'rate': _speechRate,
        'id': 'chunk_${chunk.index}',
      });
    }
  }

  /// 双缓冲预拉取流水线触发器
  void _triggerPreload(int index) {
    if (index >= _chunks.length || _engineType != TtsEngineType.openAi) return;
    final chunk = _chunks[index];
    if (chunk.isPreloaded || chunk.isPreloading) return;

    chunk.isPreloading = true;
    _preloadFutures[index] = _fetchChunkAudio(index).then((path) {
      chunk.isPreloaded = path != null;
      chunk.isPreloading = false;
      return path;
    }).catchError((_) {
      chunk.isPreloading = false;
      return null;
    });
  }

  /// 请求 OpenAI 兼容 TTS 接口并将二进制 MP3 存入临时切片文件
  Future<String?> _fetchChunkAudio(int index) async {
    if (index >= _chunks.length) return null;
    final chunk = _chunks[index];
    if (chunk.audioFilePath != null && File(chunk.audioFilePath!).existsSync()) {
      return chunk.audioFilePath;
    }

    try {
      final cleanBase = _openAiBaseUrl.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$cleanBase/v1/audio/speech');

      final body = jsonEncode({
        'model': _openAiModel.isNotEmpty ? _openAiModel : 'tts-1',
        'input': chunk.text,
        'voice': _openAiVoice.isNotEmpty ? _openAiVoice : 'alloy',
        'response_format': 'mp3',
        'speed': _speechRate,
      });

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (_openAiApiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $_openAiApiKey';
      }

      final res = await _httpClient.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        Directory tempDir;
        try {
          tempDir = await getTemporaryDirectory();
        } catch (_) {
          tempDir = Directory.systemTemp;
        }
        final audioFile = File('${tempDir.path}/tts_chunk_${DateTime.now().millisecondsSinceEpoch}_$index.mp3');
        await audioFile.writeAsBytes(res.bodyBytes);
        chunk.audioFilePath = audioFile.path;
        chunk.isPreloaded = true;
        return audioFile.path;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('OpenAI TTS fetch error ($index): $e');
    }
    return null;
  }

  /// 切片播放完毕回调，立即切入下一个切片
  void _onChunkFinished() {
    _watchdogTimer?.cancel();
    if (_state != TtsPlayState.playing && _state != TtsPlayState.buffering) return;

    _currentIndex++;
    if (_currentIndex < _chunks.length) {
      _playCurrentChunk();
    } else {
      _state = TtsPlayState.stopped;
      notifyListeners();
      onChapterComplete?.call(_currentIndex);
    }
  }

  /// 暂停播放
  Future<void> pause() async {
    _watchdogTimer?.cancel();
    if (_state != TtsPlayState.playing) return;
    _state = TtsPlayState.paused;
    notifyListeners();

    if (_engineType == TtsEngineType.openAi) {
      await _channel.invokeMethod('pauseAudio');
    } else {
      await _channel.invokeMethod('stopNativeTts');
    }
  }

  /// 继续播放
  Future<void> resume() async {
    if (_state != TtsPlayState.paused) return;
    _state = TtsPlayState.playing;
    notifyListeners();

    if (_engineType == TtsEngineType.openAi) {
      await _channel.invokeMethod('resumeAudio');
    } else {
      _playCurrentChunk();
    }
  }

  /// 停止播放并清理队列
  Future<void> stop() async {
    _watchdogTimer?.cancel();
    _state = TtsPlayState.stopped;
    _stopTimer?.cancel();
    _timerRemainingMinutes = 0;
    notifyListeners();

    await _channel.invokeMethod('stopNativeTts');
    await _channel.invokeMethod('stopAudio');

    // 清理临时音频缓存切片
    for (final c in _chunks) {
      if (c.audioFilePath != null) {
        try {
          final f = File(c.audioFilePath!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
    _chunks.clear();
    _preloadFutures.clear();
  }

  /// 下一句/下一切片
  void nextChunk() {
    if (_currentIndex < _chunks.length - 1) {
      _currentIndex++;
      _channel.invokeMethod('stopAudio');
      _channel.invokeMethod('stopNativeTts');
      _playCurrentChunk();
    }
  }

  /// 上一句/上一切片
  void previousChunk() {
    if (_currentIndex > 0) {
      _currentIndex--;
      _channel.invokeMethod('stopAudio');
      _channel.invokeMethod('stopNativeTts');
      _playCurrentChunk();
    }
  }

  /// 设置睡眠定时器（分钟）
  void setSleepTimer(int minutes) {
    _stopTimer?.cancel();
    _timerRemainingMinutes = minutes;
    notifyListeners();

    if (minutes > 0) {
      _stopTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        _timerRemainingMinutes--;
        if (_timerRemainingMinutes <= 0) {
          timer.cancel();
          stop();
        }
        notifyListeners();
      });
    }
  }
}
