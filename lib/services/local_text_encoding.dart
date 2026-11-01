import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'local_book_parser.dart' show LocalImportCancelled;

class LocalImportToken {
  static int _sequence = 0;
  final String id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  bool cancelled = false;
  SendPort? worker;
  void check() {
    if (cancelled) throw const LocalImportCancelled();
  }

  void cancel() {
    cancelled = true;
    worker?.send('cancel');
    unawaited(
      const MethodChannel(
        'com.fanqie.fanqie_flutter/download',
      ).invokeMethod('cancelTextDecode', {'id': id}).catchError((_) {}),
    );
  }
}

class NormalizedLocalText {
  final File file;
  final String encoding;
  final bool temporary;
  const NormalizedLocalText(this.file, this.encoding, {this.temporary = false});
}

Future<NormalizedLocalText> normalizeLocalText(
  File file,
  String requested,
  Directory temporary,
  LocalImportToken token,
) async {
  token.check();
  if (Platform.isAndroid) {
    final result =
        await const MethodChannel(
          'com.fanqie.fanqie_flutter/download',
        ).invokeMapMethod<String, dynamic>('normalizeTextFile', {
          'path': file.path,
          'encoding': requested,
          'id': token.id,
        });
    if (result == null) throw const FormatException('文本解码失败');
    return NormalizedLocalText(
      File(result['path'] as String),
      result['encoding'] as String,
      temporary: true,
    );
  }
  final header = await file
      .openRead(0, (await file.length()).clamp(0, 4))
      .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
  var encoding = requested;
  if (encoding == 'auto') {
    encoding = header.length >= 2 && header[0] == 0xff && header[1] == 0xfe
        ? 'UTF-16LE'
        : header.length >= 2 && header[0] == 0xfe && header[1] == 0xff
        ? 'UTF-16BE'
        : 'UTF-8';
  }
  if (encoding == 'UTF-8') {
    await for (final _ in file.openRead().transform(utf8.decoder)) {
      token.check();
    }
    return NormalizedLocalText(file, encoding);
  }
  if (encoding != 'UTF-16LE' && encoding != 'UTF-16BE') {
    throw const FormatException('当前平台请先转为 UTF-8；Android 支持 GB18030/GBK 与 Big5');
  }
  final target = File('${temporary.path}/normalized.txt');
  final output = target.openWrite(encoding: utf8);
  try {
    await for (final text in _utf16(
      file.openRead(),
      encoding == 'UTF-16LE',
      token,
    )) {
      output.write(text);
    }
    await output.flush();
  } finally {
    await output.close();
  }
  return NormalizedLocalText(target, encoding, temporary: true);
}

Stream<String> _utf16(
  Stream<List<int>> input,
  bool little,
  LocalImportToken token,
) async* {
  int? odd;
  int? high;
  var first = true;
  await for (final bytes in input) {
    token.check();
    final units = <int>[];
    for (final byte in bytes) {
      if (odd == null) {
        odd = byte;
        continue;
      }
      final unit = little ? odd | (byte << 8) : (odd << 8) | byte;
      odd = null;
      if (first) {
        first = false;
        if (unit == 0xfeff) continue;
      }
      if (high != null) {
        if (unit < 0xdc00 || unit > 0xdfff) {
          throw const FormatException('UTF-16 字符损坏');
        }
        units
          ..add(high)
          ..add(unit);
        high = null;
      } else if (unit >= 0xd800 && unit <= 0xdbff) {
        high = unit;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('UTF-16 字符损坏');
      } else {
        units.add(unit);
      }
    }
    if (units.isNotEmpty) yield String.fromCharCodes(units);
  }
  if (odd != null || high != null) throw const FormatException('UTF-16 数据截断');
}
