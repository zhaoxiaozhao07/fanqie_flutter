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
import 'compatible_tts_client.dart';
import 'reader_library_service.dart';

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
      _temporary = getTemporaryDirectory,
      _nativeOverride = null,
      _now = DateTime.now {
    WidgetsBinding.instance.addObserver(this);
    _bindPlatformEvents();
    _ready = loadSettings().whenComplete(() => _initialSettingsFinished = true);
  }

  @visibleForTesting
  TtsService.forTesting({
    required TtsInvoker invoke,
    http.Client? client,
    DateTime Function()? now,
    bool bindPlatformEvents = false,
    Future<Directory> Function()? temporary,
    bool nativeSpeechAvailable = true,
  }) : _testInvoker = true,
       _invoke = invoke,
       _http = client ?? http.Client(),
       _temporary = temporary ?? getTemporaryDirectory,
       _nativeOverride = nativeSpeechAvailable,
       _now = now ?? DateTime.now {
    if (bindPlatformEvents) {
      WidgetsBinding.instance.addObserver(this);
      _bindPlatformEvents();
    }
    _ready = loadSettings().whenComplete(() => _initialSettingsFinished = true);
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
  late final _speechClient = CompatibleTtsClient(_http);
  final Future<Directory> Function() _temporary;
  final bool? _nativeOverride;
  bool get nativeSpeechAvailable =>
      _nativeOverride ?? ReaderPlatform.capabilities.nativeSpeech;
  bool _settingsLoaded = false, _initialSettingsFinished = false;
  Future<void>? _settingsWrites;
  final _ownedAudio = <String>{};
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
  String _nativeVoice = '';
  String get nativeVoice => _nativeVoice;
  static const settingsKey = 'tts_settings_v2';
  String? _lastNetworkError;
  double _speechRate = 1;
  TtsPlayState _state = TtsPlayState.stopped;
  List<TtsChunk> _chunks = [];
  int _currentIndex = 0;
  String _currentChapterTitle = '';
  String _source = '';
  Book? _book;
  List<Chapter> _chapters = [];
  Future<String?> Function(Chapter)? _contentLoader;
  bool _offlineOnly = false;
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

  Future<void> _ensureReady() async {
    if (_settingsLoaded) return;
    if (!_initialSettingsFinished) await _ready;
    if (!_settingsLoaded && isAvailable) await loadSettings();
  }

  Future<List<Map<String, dynamic>>> nativeVoices() async {
    if (!ReaderPlatform.isMacOS || !nativeSpeechAvailable) return [];
    final raw = await _safe('getNativeTtsVoices');
    return raw is List
        ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : [];
  }

  Future<void> loadSettings() async {
    if (!isAvailable) return;
    final prefs = await SharedPreferences.getInstance();
    Map data = {};
    final raw = prefs.getString(settingsKey);
    if (raw != null) {
      try {
        data = jsonDecode(raw) as Map;
        if (data['version'] != 2) throw const FormatException('语音配置版本不支持');
      } catch (_) {
        _notice = '语音配置不可读，原记录已保留，暂用兼容配置';
        data = {};
      }
    }
    _engineType =
        (data['engine'] ?? prefs.getString('tts_engine_type')) == 'openAi'
        ? TtsEngineType.openAi
        : TtsEngineType.native;
    _openAiBaseUrl =
        (data['base_url'] ??
                prefs.getString('tts_openai_base_url') ??
                'https://api.openai.com')
            .toString();
    _openAiModel =
        (data['model'] ?? prefs.getString('tts_openai_model') ?? 'tts-1')
            .toString();
    _openAiVoice =
        (data['voice'] ?? prefs.getString('tts_openai_voice') ?? 'alloy')
            .toString();
    _nativeVoice =
        (data['native_voice'] ?? prefs.getString('tts_native_voice') ?? '')
            .toString();
    final rate = data['rate'] ?? prefs.get('tts_speech_rate');
    _speechRate = rate is num && rate.isFinite
        ? rate.toDouble().clamp(.5, 2)
        : 1;
    final legacy = prefs.getString('tts_openai_api_key');
    if (raw == null &&
        legacy == null &&
        _engineType == TtsEngineType.native &&
        !prefs.containsKey('tts_openai_base_url')) {
      _settingsLoaded = true;
      _notify();
      return; // Native-only fresh profiles need not read a user's Keychain.
    }
    try {
      _openAiApiKey = (await _invoke('readTtsSecret', null)) as String? ?? '';
      if (_openAiApiKey.isEmpty && legacy?.isNotEmpty == true) {
        if (await _invoke('writeTtsSecret', {'value': legacy}) != true) {
          throw StateError('安全存储不可用');
        }
        _openAiApiKey = legacy!;
      }
      if (legacy != null && !await prefs.remove('tts_openai_api_key')) {
        _notice = '密钥已迁移，旧配置尚未清除，请检查存储空间';
      }
    } catch (_) {
      _notice = '系统安全存储暂不可用；未删除原密钥，请在设置中重新保存';
    }
    _settingsLoaded = true;
    _notify();
  }

  Future<void> saveSettings({
    TtsEngineType? engineType,
    String? openAiBaseUrl,
    String? openAiApiKey,
    String? openAiModel,
    String? openAiVoice,
    double? speechRate,
    String? nativeVoice,
  }) {
    late final Future<void> pending;
    pending = (_settingsWrites ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          if (!isAvailable) throw UnsupportedError('当前平台没有可用音频能力');
          await _ensureReady();
          final engine = engineType ?? _engineType;
          final base = (openAiBaseUrl ?? _openAiBaseUrl).trim().replaceAll(
            RegExp(r'/+$'),
            '',
          );
          final model = (openAiModel ?? _openAiModel).trim();
          final voice = (openAiVoice ?? _openAiVoice).trim();
          final native = (nativeVoice ?? _nativeVoice).trim();
          final key = (openAiApiKey ?? _openAiApiKey).trim();
          final rate = speechRate ?? _speechRate;
          CompatibleTtsClient.endpoint(base);
          if (model.isEmpty ||
              model.length > 256 ||
              voice.isEmpty ||
              voice.length > 256 ||
              native.length > 512 ||
              utf8.encode(key).length > 8192 ||
              key.contains(RegExp(r'[\r\n\x00]')) ||
              !rate.isFinite) {
            throw const FormatException('语音参数不能为空、包含非法字符或超过长度限制');
          }
          final before = (
            _engineType,
            _openAiBaseUrl,
            _openAiApiKey,
            _openAiModel,
            _openAiVoice,
            _speechRate,
            _nativeVoice,
          );
          if (isActive) await pause();
          final prefs = await SharedPreferences.getInstance();
          if (openAiApiKey != null &&
              await _invoke('writeTtsSecret', {'value': key}) != true) {
            throw StateError('语音密钥未写入系统安全存储；原配置保留');
          }
          final json = jsonEncode({
            'version': 2,
            'engine': engine.name,
            'base_url': base,
            'model': model,
            'voice': voice,
            'rate': rate.clamp(.5, 2),
            'native_voice': native,
          });
          if (!await prefs.setString(settingsKey, json)) {
            if (openAiApiKey != null) {
              await _safe('writeTtsSecret', {'value': _openAiApiKey});
            }
            throw StateError('语音配置未保存，已尝试恢复原密钥');
          }
          _engineType = engine;
          _openAiBaseUrl = base;
          _openAiApiKey = key;
          _openAiModel = model;
          _openAiVoice = voice;
          _speechRate = rate.clamp(.5, 2);
          _nativeVoice = native;
          // Compatibility mirrors contain no secret; v2 is the atomic authority.
          await prefs.setString('tts_engine_type', engine.name);
          await prefs.setString('tts_openai_base_url', base);
          await prefs.setString('tts_openai_model', model);
          await prefs.setString('tts_openai_voice', voice);
          await prefs.setString('tts_native_voice', native);
          await prefs.setDouble('tts_speech_rate', _speechRate);
          await prefs.remove('tts_openai_api_key');
          final after = (
            _engineType,
            _openAiBaseUrl,
            _openAiApiKey,
            _openAiModel,
            _openAiVoice,
            _speechRate,
            _nativeVoice,
          );
          if (isActive && before != after) {
            ++_session;
            _playToken = null;
            _speechClient.cancel();
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
          _settingsLoaded = true;
          _notify();
        })
        .whenComplete(() {
          if (identical(_settingsWrites, pending)) _settingsWrites = null;
        });
    _settingsWrites = pending;
    return pending;
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
      if (end > start && end - start + character.length > 4096) flush();
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
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
  }) async {
    if (!isAvailable) {
      _notice = '当前平台没有可用的音频播放能力';
      _notify();
      return;
    }
    final intent = ++_startIntent;
    await _ensureReady();
    if (intent != _startIntent) return;
    await stop(supersedeStart: false);
    if (intent != _startIntent) return;
    if (chapters.isEmpty || _closed) return;
    _book = book;
    _contentLoader = contentLoader;
    _offlineOnly = offlineOnly;
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
          (_contentLoader != null
              ? await _contentLoader!(chapter)
              : _offlineOnly
              ? await _api.engine.readerCache.read(book.bookId, chapter.itemId)
              : await _api
                    .getChapterContent(chapter.itemId, bookId: book.bookId)
                    .timeout(const Duration(seconds: 30)));
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
    await _ensureReady();
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
    _speechClient.cancel();
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
    if (_chunks.any((chunk) => chunk.text.length > 4096)) {
      _fail('正文含超长字素，不能在不破坏原文的情况下分段朗读');
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
        _lastNetworkError = null;
        audio = await _fetchAudio(chunk.index, session);
        if (!_current(session, token)) return;
        if (audio == null) {
          if (!nativeSpeechAvailable) {
            _fail('${_lastNetworkError ?? '网络语音不可用'}；系统语音也不可用，请检查兼容接口配置');
            return;
          }
          _notice = '${_lastNetworkError ?? '网络语音不可用'}；已切换系统语音，未跳过本段';
        }
      }
      if (audio == null && !nativeSpeechAvailable) {
        _fail('系统语音不可用，请下载系统声音或配置 OpenAI 兼容 TTS');
        return;
      }
      _actualEngine = audio == null
          ? TtsEngineType.native
          : TtsEngineType.openAi;
      final accepted =
          await _invoke(audio == null ? 'speakNativeTts' : 'playAudioFile', {
            'id': token,
            'text': chunk.text,
            'filePath': audio,
            'rate': audio == null ? _speechRate : 1.0,
            if (ReaderPlatform.isMacOS) 'voice': _nativeVoice,
          }).timeout(const Duration(seconds: 30));
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
    bool cancelled() =>
        session != _session ||
        _closed ||
        isPaused ||
        chunk.index < _currentIndex - 1 ||
        chunk.index > _currentIndex + 2;
    try {
      if (Uri.tryParse(_openAiBaseUrl)?.host == 'api.openai.com' &&
          _openAiApiKey.isEmpty) {
        throw const TtsRequestFailure('请先保存接口密钥');
      }
      final audio = await _speechClient.synthesize(
        baseUrl: _openAiBaseUrl,
        apiKey: _openAiApiKey,
        model: _openAiModel,
        voice: _openAiVoice,
        text: chunk.text,
        speed: _speechRate,
        isCancelled: cancelled,
      );
      if (cancelled()) return null;
      Directory root;
      try {
        root = await _temporary();
      } catch (_) {
        if (ReaderPlatform.isMacOS && !_testInvoker) rethrow;
        root = Directory.systemTemp;
      }
      final file = File(
        '${root.path}/tts_$_instanceId-$session-${chunk.index}-${++_audioSerial}.${audio.format}',
      );
      await file.writeAsBytes(audio.bytes, flush: true);
      _ownedAudio.add(file.path);
      if (cancelled()) {
        await _deletePaths([file.path]);
        return null;
      }
      chunk.audioFilePath = file.path;
      chunk.isPreloaded = true;
      return file.path;
    } on TtsRequestCancelled {
      return null;
    } catch (e) {
      if (!cancelled() && chunk.index == _currentIndex) {
        _lastNetworkError = e is TtsRequestFailure
            ? e.message
            : e is FormatException
            ? '接口地址或参数无效'
            : '语音音频未缓存，请检查存储空间';
      }
      return null;
    }
  }

  void handlePlatformEvent(String method, dynamic args) {
    if (_closed) return;
    final id = args is Map ? args['id']?.toString() : args?.toString();
    if (method == 'onAudioFocusLost' || method == 'onAudioBecomingNoisy') {
      if (id != null && id != _playToken) {
        return;
      }
      _notice = method == 'onAudioFocusLost' ? '音频焦点变化，已暂停' : '音频输出设备变化，已暂停';
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
      if (method == 'onAudioError' && _currentIndex < _chunks.length) {
        final chunk = _chunks[_currentIndex];
        if (chunk.audioFilePath != null) {
          unawaited(_deletePaths([chunk.audioFilePath!]));
        }
        chunk.audioFilePath = null;
        chunk.isPreloaded = false;
      }
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
    _speechClient.cancel();
    _preloads.clear();
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
      _notice = null;
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
      if (!_ownedAudio.remove(path)) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> stop({bool supersedeStart = true}) async {
    _speechClient.cancel();
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
    _contentLoader = null;
    _offlineOnly = false;
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
              await ReaderLibraryService().markReading(book.bookId);
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
