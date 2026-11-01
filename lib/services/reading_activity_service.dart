import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import 'tts_service.dart';

class ReadingActivityPosition {
  final String chapterId;
  final int offset, total;
  const ReadingActivityPosition(this.chapterId, this.offset, this.total);
}

class ReadingActivityService extends ChangeNotifier {
  static final ReadingActivityService _instance = ReadingActivityService._();
  factory ReadingActivityService() => _instance;
  ReadingActivityService._() : _now = DateTime.now, _automatic = true {
    _ready = reload();
  }
  @visibleForTesting
  ReadingActivityService.forTesting({required DateTime Function() now})
    : _now = now,
      _automatic = false {
    _ready = reload();
  }
  final DateTime Function() _now;
  final bool _automatic;
  late Future<void> _ready;
  bool _enabled = false;
  bool _closed = false;
  String? errorMessage;
  bool _listening = false;
  Object? _owner;
  Book? _book;
  bool Function()? _active;
  bool Function()? _autoReading;
  ReadingActivityPosition? Function()? _position;
  ReadingActivityPosition? _lastPosition;
  DateTime? _lastTick;
  DateTime? _lastInput;
  Timer? _timer, _saveTimer;
  Future<void> _writes = Future.value();
  Map<String, dynamic> _books = {}, _days = {};
  bool get enabled => _enabled;
  Map<String, dynamic> get books => Map.unmodifiable(_books);
  Map<String, dynamic> get days => Map.unmodifiable(_days);

  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('reader_activity_enabled') ?? false;
    try {
      final data =
          jsonDecode(prefs.getString('reader_activity_v1') ?? '{}') as Map;
      _books = Map<String, dynamic>.from(data['books'] as Map? ?? {});
      _days = Map<String, dynamic>.from(data['days'] as Map? ?? {});
      _books.removeWhere((key, value) => value is! Map);
      _days.removeWhere((key, value) => value is! Map);
      for (final entries in [_books, _days]) {
        for (final key in entries.keys.toList()) {
          final item = Map<String, dynamic>.from(entries[key] as Map);
          for (final field in ['reading_ms', 'listening_ms', 'characters']) {
            final value = item[field];
            item[field] = value is num && value.isFinite && value >= 0
                ? value.toInt()
                : 0;
          }
          item['title'] = item['title']?.toString() ?? '未知书籍';
          entries[key] = item;
        }
      }
    } catch (_) {
      _books = {};
      _days = {};
    }
    _lastTick = _now();
    _lastPosition = null;
    _syncTimer();
    if (!_closed) notifyListeners();
  }

  Future<void> setEnabled(bool value, {bool clear = false}) async {
    await _ready;
    _enabled = value;
    _lastTick = _now();
    _lastPosition = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('reader_activity_enabled', value);
    if (clear) {
      _books.clear();
      _days.clear();
    }
    await flush();
    _syncTimer();
    notifyListeners();
  }

  void attach(
    Object owner,
    Book book, {
    required bool Function() active,
    required bool Function() automatic,
    required ReadingActivityPosition? Function() position,
  }) {
    _owner = owner;
    _book = book;
    _active = active;
    _autoReading = automatic;
    _position = position;
    _lastPosition = null;
    _lastInput = _now();
    _lastTick = _now();
    _syncTimer();
  }

  void detach(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _book = null;
    _active = null;
    _position = null;
    _autoReading = null;
    _lastPosition = null;
    unawaited(flush().catchError((_) {}));
    _syncTimer();
  }

  void interact(Object owner) {
    if (identical(owner, _owner)) _lastInput = _now();
  }

  void breakSequence() => _lastPosition = null;

  void _syncTimer() {
    if (!_automatic || _closed) return;
    if (_enabled && !_listening) {
      TtsService().addListener(_syncTimer);
      _listening = true;
    }
    if (!_enabled && _listening) {
      TtsService().removeListener(_syncTimer);
      _listening = false;
    }
    final needs = _enabled && (_owner != null || TtsService().isPlaying);
    if (!needs) {
      _timer?.cancel();
      _timer = null;
      _lastTick = _now();
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final tts = TtsService();
      tick(
        listeningBookId: tts.isPlaying ? tts.currentBookId : null,
        listeningTitle: tts.currentBookTitle,
      );
    });
  }

  @visibleForTesting
  void tick({String? listeningBookId, String listeningTitle = ''}) {
    final now = _now();
    final elapsed = now
        .difference(_lastTick ?? now)
        .inMilliseconds
        .clamp(0, 2000);
    _lastTick = now;
    if (!_enabled || _closed) return;
    var changed = false;
    if (listeningBookId != null) {
      _record(listeningBookId, listeningTitle, 'listening_ms', elapsed, 0, now);
      changed = true;
    }
    final active =
        _book != null &&
        (_active?.call() ?? false) &&
        listeningBookId != _book!.bookId &&
        ((_autoReading?.call() ?? false) ||
            now.difference(_lastInput ?? now).inSeconds <= 90);
    if (active) {
      final position = _position?.call();
      var characters = 0;
      if (position != null && _lastPosition?.chapterId == position.chapterId) {
        final delta = position.offset - _lastPosition!.offset;
        if (delta > 0 && delta <= 2000) characters = delta;
      }
      _lastPosition = position;
      _record(
        _book!.bookId,
        _book!.bookName,
        'reading_ms',
        elapsed,
        characters,
        now,
      );
      changed = true;
    } else {
      _lastPosition = null;
    }
    if (changed) {
      _saveTimer ??= Timer(const Duration(seconds: 5), () {
        _saveTimer = null;
        unawaited(flush().catchError((_) {}));
      });
      notifyListeners();
    }
  }

  void _record(
    String id,
    String title,
    String field,
    int elapsed,
    int characters,
    DateTime now,
  ) {
    final book = Map<String, dynamic>.from(_books[id] as Map? ?? {});
    book['title'] = title;
    book[field] = ((book[field] as num?)?.toInt() ?? 0) + elapsed;
    book['characters'] =
        ((book['characters'] as num?)?.toInt() ?? 0) + characters;
    book['last_active'] = now.toUtc().toIso8601String();
    _books[id] = book;
    final key =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final day = Map<String, dynamic>.from(_days[key] as Map? ?? {});
    day[field] = ((day[field] as num?)?.toInt() ?? 0) + elapsed;
    _days[key] = day;
  }

  int? remainingMinutes(String bookId, int remainingCharacters) {
    if (!_enabled) return null;
    final stats = _books[bookId] as Map? ?? {};
    final millis = (stats['reading_ms'] as num?)?.toDouble() ?? 0;
    final chars = (stats['characters'] as num?)?.toDouble() ?? 0;
    final speed = millis >= 60000 && chars >= 200
        ? (chars * 60000 / millis).clamp(100, 1500)
        : 500.0;
    return (remainingCharacters.clamp(0, 1 << 30) / speed).ceil();
  }

  Future<void> flush() async {
    await _ready;
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_enabled && _books.isEmpty && _days.isEmpty) {
      _writes = _writes.catchError((_) {}).then((_) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('reader_activity_v1');
      });
      return _writes;
    }
    final data = jsonEncode({'version': 1, 'books': _books, 'days': _days});
    _writes = _writes
        .catchError((_) {})
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (!await prefs.setString('reader_activity_v1', data)) {
            throw StateError('统计写入失败');
          }
          errorMessage = null;
        })
        .catchError((_) {
          errorMessage = '统计暂未保存，请检查存储空间';
          if (!_closed) notifyListeners();
        });
    return _writes;
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _saveTimer?.cancel();
    if (_listening) TtsService().removeListener(_syncTimer);
    super.dispose();
  }
}
