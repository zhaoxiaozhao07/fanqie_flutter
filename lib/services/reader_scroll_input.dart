import 'dart:collection';

import 'package:flutter/gestures.dart';

import 'reader_platform.dart';

/// One-shot native Mac precision, keyed only by the source event timestamp.
/// Delivery delays cannot make a precise/unknown event into a discrete wheel.
abstract final class ReaderScrollInput {
  static const _maxPending = 64;
  static const _maxSourceAgeMicros = 1000000;
  static const _maxTimestampMicros = 0x7fffffffffffffff;
  static final _pending = SplayTreeMap<int, bool>();
  static int? _newestMicros;
  static int? _lastLookupMicros;

  static void record(Object? arguments) {
    if (!_onMac() || arguments is! Map) return;
    final micros = arguments['timestampMicros'];
    if (micros is! int || !_validTimestamp(micros)) return;
    _advanceSource(micros);
    if ((_lastLookupMicros != null && micros <= _lastLookupMicros!) ||
        _newestMicros! - micros >= _maxSourceAgeMicros) {
      return;
    }
    final precise = arguments['precise'];
    // Missing/invalid precision and duplicate timestamps are ambiguous. Never
    // let a later "false" overwrite either precision or that ambiguity.
    _pending[micros] =
        _pending.containsKey(micros) || precise is! bool || precise;
    while (_pending.length > _maxPending) {
      _pending.remove(_pending.keys.first);
    }
  }

  static bool takeDiscrete(PointerScrollEvent event) {
    if (!_onMac()) return false;
    final micros = event.timeStamp.inMicroseconds;
    if (!_validTimestamp(micros)) return false;
    _advanceSource(micros);
    if (_lastLookupMicros != null && micros <= _lastLookupMicros!) {
      return false;
    }
    // Even an unmatched pointer closes its timestamp to late metadata/replay.
    _lastLookupMicros = micros;
    final precise = _pending.remove(micros);
    return event.kind == PointerDeviceKind.mouse && precise == false;
  }

  static bool _validTimestamp(int micros) =>
      micros > 0 && micros <= _maxTimestampMicros;

  static void _advanceSource(int micros) {
    if (_newestMicros == null || micros > _newestMicros!) {
      _newestMicros = micros;
    }
    // Expiry is measured in the native source timeline, never DateTime.now().
    _pending.removeWhere(
      (timestamp, _) => _newestMicros! - timestamp >= _maxSourceAgeMicros,
    );
  }

  static bool _onMac() {
    if (ReaderPlatform.isMacOS) return true;
    _pending.clear();
    _newestMicros = null;
    _lastLookupMicros = null;
    return false;
  }
}
