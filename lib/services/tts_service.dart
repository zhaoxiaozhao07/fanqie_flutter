import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/chapter.dart';
import '../models/reading_position.dart';
import 'api_service.dart';
import 'bookshelf_service.dart';
import 'reader_position_service.dart';
import 'reader_system_service.dart';
import 'reader_platform.dart';
import 'reader_text.dart';
import 'reading_history_service.dart';

enum TtsEngineType { native, openAi }

enum TtsPlayState { stopped, playing, paused, buffering }

typedef TtsInvoker =
    Future<Object?> Function(String method, Map<String, Object?>? args);

class TtsChunk {
  final int index;
  final String text;
  final int startOffset;
  final int endOffset;
  String? audioFilePath;
  bool isPreloaded = false;
  bool isPreloading = false;

  TtsChunk({
    required this.index,
    required this.text,
    this.startOffset = 0,
    int? endOffset,
    this.audioFilePath,
  }) : endOffset = endOffset ?? startOffset + text.length;
}

/// One playback owner, independent of reader routes. Every asynchronous result
/// and native event is checked against a session and a playback token.
class TtsService extends ChangeNotifier with WidgetsBindingObserver {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  static const _channel = MethodChannel('com.fanqie.fanqie_flutter/download');

  TtsService._internal()
    : _testInvoker = false,
      _invoke = _nativeInvoke,
      _http = http.Client(),
      _now = DateTime.now {
    WidgetsBinding.instance.addObserver(this);
    _bindPlatformEvents();
    _ready = loadSettings();
  }

  @visibleForTesting
  TtsService.forTesting({
    required TtsInvoker invoke,
    http.Client? client,
    DateTime Function()? now,
    bool bindPlatformEvents = false,
  }) : _testInvoker = true,
       _invoke = invoke,
       _http = client ?? http.Client(),
       _now = now ?? DateTime.now {
    if (bindPlatformEvents) {
      WidgetsBinding.instance.addObserver(this);
      _bindPlatformEvents();
    }
    _ready = loadSettings();
  }

  static Future<Object?> _nativeInvoke(
    String method,
    Map<String, Object?>? args,
  ) async {
    if (ReaderPlatform.isMacOS && !ReaderPlatform.capabilities.tts) return null;
    return _channel.invokeMethod<Object?>(method, args);
  }

  final bool _testInvoker;
  bool get isAvailable =>
      _testInvoker ||
      !ReaderPlatform.isMacOS ||
      ReaderPlatform.capabilities.tts;
  final TtsInvoker _invoke;
  final http.Client _http;
  final DateTime Function() _now;
  final ApiService _api = ApiService();
  late final Future<void> _ready;
  bool _closed = false;
  bool _boundPlatformEvents = false;
  int _session = 0;
  int _startIntent = 0;
  bool _appForeground = true;
  int _playSerial = 0;
  int _audioSerial = 0;
  String? _playToken;
  final String _instanceId = DateTime.now().microsecondsSinceEpoch.toString();
  TtsEngineType _engineType = TtsEngineType.native;
  TtsEngineType? _actualEngine;
  String _openAiBaseUrl = 'https://api.openai.com';
  String _openAiApiKey = '';
  String _openAiModel = 'tts-1';
  String _openAiVoice = 'alloy';
  double _speechRate = 1;
  TtsPlayState _state = TtsPlayState.stopped;
  List<TtsChunk> _chunks = [];
  int _currentIndex = 0;
  String _currentChapterTitle = '';
  String _source = '';
  Book? _book;
  List<Chapter> _chapters = [];
  int _chapterIndex = 0;
  ReadingPosition? _pendingBookPosition;
  final Map<String, int> _attachedReaders = {};
  final Map<int, Future<String?>> _preloads = {};
  bool _audioStarted = false;
  Timer? _watchdog;
  Timer? _sleepTimer;
  DateTime? _sleepDeadline;
  bool _stopAfterCurrentChapter = false;
  String? _errorMessage;
  String? _notice;
  void Function(int chapterIndex)? onChapterComplete;

  TtsEngineType get engineType => _engineType;
  TtsEngineType? get actualEngine => _actualEngine;
  String get openAiBaseUrl => _openAiBaseUrl;
  String get openAiApiKey => _openAiApiKey;
  String get openAiModel => _openAiModel;
  String get openAiVoice => _openAiVoice;
  double get speechRate => _speechRate;
  TtsPlayState get state => _state;
  bool get isPlaying => _state == TtsPlayState.playing;
  bool get isPaused => _state == TtsPlayState.paused;
  bool get isActive => _state != TtsPlayState.stopped;
  List<TtsChunk> get chunks => List.unmodifiable(_chunks);
  int get currentIndex => _currentIndex;
  String get currentChapterTitle => _currentChapterTitle;
  String? get currentBookId => _book?.bookId;
  String get currentBookTitle => _book?.bookName ?? _currentChapterTitle;
  String? get errorMessage => _errorMessage;
  String? get notice => _notice;
  String? get currentPlaybackToken => _playToken;
  String get currentText =>
      _currentIndex < _chunks.length ? _chunks[_currentIndex].text : '';
  double get progress =>
      _chunks.isEmpty ? 0 : ((_currentIndex + 1) / _chunks.length).clamp(0, 1);
  bool get stopAfterCurrentChapter => _stopAfterCurrentChapter;
  int get timerRemainingMinutes => _sleepDeadline == null
      ? 0
      : (_sleepDeadline!.difference(_now()).inMilliseconds / 60000)
            .ceil()
            .clamp(0, 1440);

  ReadingPosition? get currentPosition {
    if (_book == null || _chapters.isEmpty || _currentIndex >= _chunks.length) {
      return null;
    }
    return ReaderText.positionForOffset(
      _chapters[_chapterIndex].itemId,
      _source,
      _chunks[_currentIndex].startOffset,
    );
  }

  ({int start, int end})? spokenRange(
    String bookId,
    String chapterId,
    int paragraphIndex,
  ) {
    if (!isActive ||
        bookId != currentBookId ||
        _chapters.isEmpty ||
        _chapters[_chapterIndex].itemId != chapterId ||
        _currentIndex >= _chunks.length) {
      return null;
    }
    final paragraphs = _source.split('\n\n');
    if (paragraphIndex < 0 || paragraphIndex >= paragraphs.length) return null;
    final base = ReaderText.offsetForPosition(
      _source,
      ReadingPosition(chapterId: chapterId, paragraphIndex: paragraphIndex),
    );
    final chunk = _chunks[_currentIndex];
    final start = (chunk.startOffset - base).clamp(
      0,
      paragraphs[paragraphIndex].length,
    );
    final end = (chunk.endOffset - base).clamp(
      0,
      paragraphs[paragraphIndex].length,
    );
    return start < end ? (start: start, end: end) : null;
  }

  void attachReader(String bookId) =>
      _attachedReaders[bookId] = (_attachedReaders[bookId] ?? 0) + 1;
  void detachReader(String bookId) {
    final count = (_attachedReaders[bookId] ?? 1) - 1;
    if (count <= 0) {
      _attachedReaders.remove(bookId);
    } else {
      _attachedReaders[bookId] = count;
    }
    if (isActive && currentBookId == bookId) _persistPosition();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _bindPlatformEvents() {
    _boundPlatformEvents = true;
    ReaderSystemService.registerTtsListener(handlePlatformEvent);
    ReaderSystemService.registerMediaListener((method) {
      switch (method) {
        case 'onMediaPlay':
          unawaited(resume());
          break;
        case 'onMediaPause':
          unawaited(pause());
          break;
        case 'onMediaNext':
          unawaited(nextChunk());
          break;
        case 'onMediaPrev':
          unawaited(previousChunk());
          break;
        case 'onMediaStop':
          unawaited(stop());
          break;
      }
    });
  }

  Future<Object?> _safe(String method, [Map<String, Object?>? args]) async {
    try {
      return await _invoke(method, args);
    } catch (_) {
      return null;
    }
  }

  bool _current(int session, String token) =>
      !_closed &&
      session == _session &&
      token == _playToken &&
      _state != TtsPlayState.stopped &&
      _state != TtsPlayState.paused;

  Future<void> loadSettings() async {
    if (!isAvailable) return;
    final prefs = await SharedPreferences.getInstance();
    _engineType = prefs.getString('tts_engine_type') == 'openAi'
        ? TtsEngineType.openAi
        : TtsEngineType.native;
    _openAiBaseUrl =
        prefs.getString('tts_openai_base_url') ?? 'https://api.openai.com';
    _openAiModel = prefs.getString('tts_openai_model') ?? 'tts-1';
    _openAiVoice = prefs.getString('tts_openai_voice') ?? 'alloy';
    _speechRate = (prefs.getDouble('tts_speech_rate') ?? 1).clamp(.5, 2);
    final legacy = prefs.getString('tts_openai_api_key');
    try {
      _openAiApiKey = (await _invoke('readTtsSecret', null)) as String? ?? '';
      if (_openAiApiKey.isEmpty && legacy?.isNotEmpty == true) {
        if (await _invoke('writeTtsSecret', {'value': legacy}) != true) {
          throw StateError('安全存储不可用');
        }
        _openAiApiKey = legacy!;
      }
      if (legacy != null) await prefs.remove('tts_openai_api_key');
    } catch (_) {
      if (legacy?.isNotEmpty == true) _notice = '语音密钥迁移未完成，请在设置中重新保存';
    }
    _notify();
  }

  Future<void> saveSettings({
    TtsEngineType? engineType,
    String? openAiBaseUrl,
    String? openAiApiKey,
    String? openAiModel,
    String? openAiVoice,
    double? speechRate,
  }) async {
    if (!isAvailable) throw UnsupportedError('macOS 听书将在后续版本提供');
    await _ready;
    final previousVoice = (
      _engineType,
      _openAiBaseUrl,
      _openAiApiKey,
      _openAiModel,
      _openAiVoice,
      _speechRate,
    );
    if (openAiBaseUrl != null) {
      final uri = Uri.tryParse(openAiBaseUrl.trim());
      final local =
          uri != null &&
          ['localhost', '127.0.0.1', '::1', '10.0.2.2'].contains(uri.host);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
        throw const FormatException('语音接口须使用 HTTPS（本机调试地址除外）');
      }
    }
    // A failed secure write must not silently drop the old key or persist plaintext.
    if (openAiApiKey != null) {
      if (await _invoke('writeTtsSecret', {'value': openAiApiKey.trim()}) !=
          true) {
        throw StateError('语音密钥未能写入系统安全存储');
      }
      _openAiApiKey = openAiApiKey.trim();
    }
    final prefs = await SharedPreferences.getInstance();
    if (engineType != null) _engineType = engineType;
    if (openAiBaseUrl != null) {
      _openAiBaseUrl = openAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    }
    if (openAiModel != null) _openAiModel = openAiModel.trim();
    if (openAiVoice != null) _openAiVoice = openAiVoice.trim();
    if (speechRate != null) _speechRate = speechRate.clamp(.5, 2);
    await prefs.setString('tts_engine_type', _engineType.name);
    await prefs.setString('tts_openai_base_url', _openAiBaseUrl);
    await prefs.setString('tts_openai_model', _openAiModel);
    await prefs.setString('tts_openai_voice', _openAiVoice);
    await prefs.setDouble('tts_speech_rate', _speechRate);
    await prefs.remove('tts_openai_api_key');
    final nextVoice = (
      _engineType,
      _openAiBaseUrl,
      _openAiApiKey,
      _openAiModel,
      _openAiVoice,
      _speechRate,
    );
    if (isActive && previousVoice != nextVoice) {
      await pause();
      ++_session;
      _playToken = null;
      _preloads.clear();
      _actualEngine = null;
      _audioStarted = false;
      final stale = <String>[];
      for (final chunk in _chunks) {
        if (chunk.audioFilePath != null) stale.add(chunk.audioFilePath!);
        chunk.audioFilePath = null;
        chunk.isPreloaded = false;
      }
      await _deletePaths(stale);
      _errorMessage = null;
      _notice = '语音设置已保存，点击继续应用新设置';
    }
    _notify();
  }

  List<TtsChunk> splitIntoChunks(String content, {int startOffset = 0}) {
    final chunks = <TtsChunk>[];
    var start = ReaderText.safeOffset(content, startOffset);
    var end = start;
    var count = 0;
    void flush() {
      final raw = content.substring(start, end);
      final text = raw.trim();
      if (text.isNotEmpty) {
        final offset = start + raw.length - raw.trimLeft().length;
        chunks.add(
          TtsChunk(
            index: chunks.length,
            text: text,
            startOffset: offset,
            endOffset: offset + text.length,
          ),
        );
      }
      start = end;
      count = 0;
    }

    // Grapheme iteration never splits surrogate pairs or combining characters.
    for (final character in content.substring(start).characters) {
      end += character.length;
      count++;
      if (count >= 200 ||
          (count >= 80 && RegExp(r'[。！？!?；;\n]').hasMatch(character))) {
        flush();
      }
    }
    flush();
    return chunks;
  }

  Future<void> startBook(
    Book book,
    List<Chapter> chapters,
    int chapterIndex, {
    ReadingPosition? position,
  }) async {
    if (!isAvailable) {
      _notice = 'macOS 听书将在后续版本提供';
      _notify();
      return;
    }
    final intent = ++_startIntent;
    await _ready;
    if (intent != _startIntent) return;
    await stop(supersedeStart: false);
    if (intent != _startIntent) return;
    if (chapters.isEmpty || _closed) return;
    _book = book;
    _chapters = List.unmodifiable(chapters);
    _chapterIndex = chapterIndex.clamp(0, chapters.length - 1);
    await _openBookChapter(_chapterIndex, position: position);
  }

  Future<void> _openBookChapter(int index, {ReadingPosition? position}) async {
    final session = ++_session;
    _playToken = null;
    _state = TtsPlayState.buffering;
    _errorMessage = null;
    if (_chapterIndex != index) _pendingBookPosition = null;
    if (position != null) _pendingBookPosition = position;
    final startPosition = _pendingBookPosition;
    _chapterIndex = index;
    _notify();
    final book = _book;
    if (book == null) return;
    final chapter = _chapters[index];
    _currentChapterTitle = chapter.title;
    final previousChunks = _chunks;
    _chunks = [];
    _currentIndex = 0;
    _preloads.clear();
    unawaited(_deleteAudio(previousChunks));
    try {
      final raw =
          chapter.content ??
          await _api
              .getChapterContent(chapter.itemId, bookId: book.bookId)
              .timeout(const Duration(seconds: 30));
      if (session != _session || !isActive || isPaused) return;
      if (raw == null || raw.trim().isEmpty || raw.contains('APP端专享/锁章章节')) {
        throw const FormatException('章节正文不可用');
      }
      final source = ReaderText.paragraphs(
        raw,
        chapterTitle: chapter.title,
      ).join('\n\n');
      final offset = startPosition?.chapterId == chapter.itemId
          ? ReaderText.offsetForPosition(source, startPosition!)
          : 0;
      await _prepareChapter(
        chapter.title,
        source,
        offset: offset,
        session: session,
      );
    } catch (_) {
      if (session == _session) _fail('下一章加载失败，已暂停；点击继续重试，不会跳过正文');
    }
  }

  Future<void> startChapter(
    String chapterTitle,
    String chapterContent, {
    int startChunk = 0,
  }) async {
    final intent = ++_startIntent;
    await _ready;
    if (intent != _startIntent) return;
    await stop(supersedeStart: false);
    if (intent != _startIntent) return;
    final session = ++_session;
    await _prepareChapter(
      chapterTitle,
      chapterContent,
      session: session,
      startChunk: startChunk,
    );
  }

  Future<void> _prepareChapter(
    String title,
    String source, {
    required int session,
    int offset = 0,
    int startChunk = 0,
  }) async {
    final oldChunks = _chunks;
    _chunks = [];
    _preloads.clear();
    await _stopPlayers();
    unawaited(_deleteAudio(oldChunks));
    if (session != _session || _closed || isPaused) return;
    _source = source;
    _currentChapterTitle = title;
    _chunks = splitIntoChunks(source, startOffset: offset);
    _currentIndex = startChunk.clamp(
      0,
      _chunks.isEmpty ? 0 : _chunks.length - 1,
    );
    if (_chunks.isEmpty) {
      _fail('章节没有可朗读的正文');
      return;
    }
    _state = TtsPlayState.buffering;
    _notify();
    await _playCurrentChunk();
  }

  Future<void> _playCurrentChunk() async {
    if (_currentIndex >= _chunks.length || _closed) return;
    final session = _session;
    final token = '$_instanceId:$session:$_currentIndex:${++_playSerial}';
    _playToken = token;
    _audioStarted = false;
    _actualEngine = null;
    _errorMessage = null;
    _notice = null;
    _watchdog?.cancel();
    _state = TtsPlayState.buffering;
    _notify();
    await _stopPlayers();
    if (!_current(session, token)) return;
    final chunk = _chunks[_currentIndex];
    try {
      String? audio;
      if (_engineType == TtsEngineType.openAi) {
        audio = await _fetchAudio(chunk.index, session);
        if (!_current(session, token)) return;
        if (audio == null) _notice = '网络语音不可用，已切换系统语音；可在设置中检查接口';
      }
      _actualEngine = audio == null
          ? TtsEngineType.native
          : TtsEngineType.openAi;
      final accepted = await _invoke(
        audio == null ? 'speakNativeTts' : 'playAudioFile',
        {
          'id': token,
          'text': chunk.text,
          'filePath': audio,
          'rate': _speechRate,
        },
      ).timeout(const Duration(seconds: 30));
      if (!_current(session, token)) return;
      if (accepted != true) {
        _fail('语音播放未启动，请检查系统语音引擎或音频输出');
        return;
      }
      _audioStarted = audio != null;
      _state = TtsPlayState.playing;
      _armWatchdog(chunk, token);
      _syncMediaState();
      _persistPosition();
      _prunePlayedAudio();
      _notify();
      if (_engineType == TtsEngineType.openAi) {
        for (final next in [chunk.index + 1, chunk.index + 2]) {
          if (next < _chunks.length) unawaited(_fetchAudio(next, session));
        }
      }
    } catch (_) {
      if (_current(session, token)) _fail('语音播放异常，已暂停；点击继续重试');
    }
  }

  void _armWatchdog(TtsChunk chunk, String token) {
    _watchdog?.cancel();
    final seconds = (chunk.text.characters.length / (2.5 * _speechRate) + 30)
        .ceil()
        .clamp(30, 240);
    _watchdog = Timer(Duration(seconds: seconds), () {
      if (token == _playToken && isPlaying) _fail('播放回调超时，已暂停在本段，请重试');
    });
  }

  Future<String?> _fetchAudio(int index, int session) {
    if (session != _session || index >= _chunks.length) {
      return Future.value(null);
    }
    final existing = _preloads[index];
    if (existing != null) return existing;
    final chunk = _chunks[index];
    late final Future<String?> request;
    chunk.isPreloading = true;
    request = _downloadAudio(chunk, session).whenComplete(() {
      chunk.isPreloading = false;
      if (identical(_preloads[index], request)) _preloads.remove(index);
    });
    _preloads[index] = request;
    return request;
  }

  Future<String?> _downloadAudio(TtsChunk chunk, int session) async {
    if (chunk.audioFilePath != null &&
        await File(chunk.audioFilePath!).exists()) {
      return chunk.audioFilePath;
    }
    final base = _openAiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      base.endsWith('/v1') ? '$base/audio/speech' : '$base/v1/audio/speech',
    );
    final local = [
      'localhost',
      '127.0.0.1',
      '::1',
      '10.0.2.2',
    ].contains(uri.host);
    if (uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      return null;
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (session != _session || _closed) return null;
      try {
        final response = await _http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                if (_openAiApiKey.isNotEmpty)
                  'Authorization': 'Bearer $_openAiApiKey',
              },
              body: jsonEncode({
                'model': _openAiModel,
                'input': chunk.text,
                'voice': _openAiVoice,
                'response_format': 'mp3',
                'speed': _speechRate,
              }),
            )
            .timeout(const Duration(seconds: 15));
        if (session != _session || _closed) return null;
        if (response.statusCode == 401 || response.statusCode == 403) {
          return null;
        }
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          Directory root;
          try {
            root = await getTemporaryDirectory();
          } catch (_) {
            root = Directory.systemTemp;
          }
          if (session != _session || _closed) return null;
          if (chunk.index < _currentIndex - 1 ||
              chunk.index > _currentIndex + 2) {
            return null;
          }
          final file = File(
            '${root.path}/tts_$_instanceId-$session-${chunk.index}-${++_audioSerial}.mp3',
          );
          await file.writeAsBytes(response.bodyBytes, flush: true);
          if (session != _session ||
              _closed ||
              chunk.index < _currentIndex - 1 ||
              chunk.index > _currentIndex + 2) {
            await file.delete();
            return null;
          }
          chunk.audioFilePath = file.path;
          chunk.isPreloaded = true;
          return file.path;
        }
      } catch (_) {
        /* bounded retry, never log credentials or source text */
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return null;
  }

  void handlePlatformEvent(String method, dynamic args) {
    if (_closed) return;
    final id = args is Map ? args['id']?.toString() : args?.toString();
    if (method == 'onAudioFocusLost' || method == 'onAudioBecomingNoisy') {
      if (method == 'onAudioFocusLost' && id != null && id != _playToken) {
        return;
      }
      unawaited(pause());
      return;
    }
    if (method == 'onAudioSleepTimer') {
      final expired = args is Map ? (args['deadline'] as num?)?.toInt() : null;
      if (expired != null &&
          expired == _sleepDeadline?.millisecondsSinceEpoch) {
        unawaited(stop());
      }
      return;
    }
    if (id == null ||
        id != _playToken ||
        (!isPlaying &&
            !(state == TtsPlayState.buffering && _actualEngine != null))) {
      return;
    }
    if (method == 'onTtsError' || method == 'onAudioError') {
      _fail('当前语音播放失败，已保留本段，点击继续重试');
    } else if (method == 'onTtsComplete' || method == 'onAudioComplete') {
      _playToken =
          null; // consume before any await: duplicate completion is harmless
      _watchdog?.cancel();
      _currentIndex++;
      if (_currentIndex < _chunks.length) {
        unawaited(_playCurrentChunk());
      } else {
        unawaited(_chapterFinished());
      }
    }
  }

  Future<void> _chapterFinished() async {
    if (_stopAfterCurrentChapter || _sleepDeadline?.isBefore(_now()) == true) {
      await stop();
      return;
    }
    if (_book != null && _chapterIndex + 1 < _chapters.length) {
      await _openBookChapter(_chapterIndex + 1);
    } else {
      final last = _chapterIndex;
      await stop();
      onChapterComplete?.call(last);
    }
  }

  void _fail(String message) {
    final failedToken = _playToken;
    _playToken = null;
    _watchdog?.cancel();
    _state = TtsPlayState.paused;
    _audioStarted = false;
    _errorMessage = message;
    unawaited(_safe('stopPlayback', {'id': failedToken}));
    _syncMediaState();
    _notify();
  }

  Future<void> pause() async {
    if (!isActive || isPaused) return;
    _watchdog?.cancel();
    _state = TtsPlayState.paused;
    _notify();
    _syncMediaState();
    if (_actualEngine == TtsEngineType.openAi && _audioStarted) {
      await _safe('pauseAudio', {'id': _playToken});
    } else {
      await _safe('stopNativeTts');
    }
  }

  Future<void> resume() async {
    if (!isPaused) return;
    if (_chunks.isEmpty || _currentIndex >= _chunks.length) {
      if (_book != null) await _openBookChapter(_chapterIndex);
      return;
    }
    if (_actualEngine == TtsEngineType.openAi &&
        _audioStarted &&
        _playToken != null) {
      final token = _playToken!;
      _state = TtsPlayState.playing;
      final accepted = await _safe('resumeAudio', {'id': token});
      if (token != _playToken || !isPlaying) return;
      if (accepted != true) {
        _fail('恢复播放失败，请重试');
        return;
      }
      _armWatchdog(_chunks[_currentIndex], token);
      _syncMediaState();
      _notify();
    } else {
      await _playCurrentChunk();
      if (isPlaying && _actualEngine == TtsEngineType.native) {
        _notice = '${_notice == null ? '' : '$_notice；'}系统语音从当前段重新开始';
        _notify();
      }
    }
  }

  Future<void> nextChunk() async {
    if (_currentIndex + 1 >= _chunks.length) return;
    _currentIndex++;
    await _playCurrentChunk();
  }

  Future<void> previousChunk() async {
    if (_currentIndex <= 0 || _chunks.isEmpty) return;
    _currentIndex--;
    await _playCurrentChunk();
  }

  Future<void> _stopPlayers() async {
    await _safe('stopPlayback');
  }

  Future<void> _deleteAudio(List<TtsChunk> chunks) async {
    await _deletePaths([
      for (final chunk in chunks)
        if (chunk.audioFilePath != null) chunk.audioFilePath!,
    ]);
  }

  void _prunePlayedAudio() {
    final stale = <String>[];
    for (var index = 0; index < _currentIndex - 1; index++) {
      final chunk = _chunks[index];
      if (chunk.audioFilePath == null) continue;
      stale.add(chunk.audioFilePath!);
      chunk.audioFilePath = null;
      chunk.isPreloaded = false;
    }
    unawaited(_deletePaths(stale));
  }

  Future<void> _deletePaths(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> stop({bool supersedeStart = true}) async {
    if (supersedeStart) ++_startIntent;
    final stoppedSession = ++_session;
    _playToken = null;
    _watchdog?.cancel();
    _sleepTimer?.cancel();
    _sleepDeadline = null;
    _stopAfterCurrentChapter = false;
    _state = TtsPlayState.stopped;
    _actualEngine = null;
    _audioStarted = false;
    _errorMessage = null;
    final oldChunks = _chunks;
    _chunks = [];
    _preloads.clear();
    _book = null;
    _chapters = [];
    _pendingBookPosition = null;
    _notify();
    await _stopPlayers();
    if (stoppedSession == _session) {
      await Future.wait([
        _safe('setAudioVolume', {'volume': 1.0}),
        _safe('setSleepDeadline', {'milliseconds': 0}),
        if (supersedeStart) _safe('releasePlaybackService'),
      ]);
    }
    await _deleteAudio(oldChunks);
  }

  void setStopAfterCurrentChapter(bool value) {
    _stopAfterCurrentChapter = value;
    _notify();
  }

  void toggleStopAfterCurrentChapter() =>
      setStopAfterCurrentChapter(!_stopAfterCurrentChapter);
  void setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepDeadline = minutes <= 0
        ? null
        : _now().add(Duration(minutes: minutes.clamp(1, 1440)));
    unawaited(
      _safe('setSleepDeadline', {
        'milliseconds': _sleepDeadline?.millisecondsSinceEpoch ?? 0,
      }),
    );
    unawaited(_safe('setAudioVolume', {'volume': 1.0}));
    if (_sleepDeadline != null) {
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining =
            _sleepDeadline?.difference(_now()).inMilliseconds ?? 0;
        if (remaining <= 0) {
          unawaited(stop());
          return;
        }
        if (remaining <= 10000) {
          unawaited(
            _safe('setAudioVolume', {
              'volume': (remaining / 10000).clamp(0.0, 1.0),
            }),
          );
        }
        _notify();
      });
    }
    _notify();
  }

  void _syncMediaState() {
    unawaited(
      _safe('updateMediaPlaybackState', {
        'title': currentBookTitle,
        'subtitle': _currentChapterTitle,
        'isPlaying': isPlaying,
        'isActive': isActive,
      }),
    );
  }

  void _persistPosition() {
    final position = currentPosition;
    final book = _book;
    if (position == null ||
        book == null ||
        (_appForeground && _attachedReaders.containsKey(book.bookId))) {
      return;
    }
    final index = _chapterIndex;
    final title = _chapters[index].title;
    final text = currentText;
    final preview = text.substring(
      0,
      ReaderText.safeOffset(text, text.length.clamp(0, 120)),
    );
    unawaited(
      ReaderPositionService()
          .save(
            book.bookId,
            position,
            chapterIndex: index,
            chapterTitle: title,
            previousChapterId: index > 0 ? _chapters[index - 1].itemId : null,
            nextChapterId: index + 1 < _chapters.length
                ? _chapters[index + 1].itemId
                : null,
            onCommitted: () async {
              await ReadingHistoryService().recordReading(
                book: book,
                chapterIndex: index,
                chapterTitle: title,
                preview: preview,
              );
              final shelf = BookshelfService();
              await shelf.initialize();
              if (shelf.isInBookshelf(book.bookId)) {
                await shelf.updateReadingProgress(book.bookId, index, title);
              }
            },
          )
          .catchError((_) {
            _notice = '听书进度未保存，请检查存储空间';
          }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (!_appForeground && isActive) _persistPosition();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_boundPlatformEvents) {
      ReaderSystemService.registerTtsListener(null);
      ReaderSystemService.registerMediaListener(null);
    }
    _closed = true;
    unawaited(stop());
    _http.close();
    _api.dispose();
    super.dispose();
  }
}
