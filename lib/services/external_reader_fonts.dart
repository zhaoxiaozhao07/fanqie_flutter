import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_storage.dart';
import 'atomic_file.dart';

class ExternalReaderFont {
  final String id, name, format;
  final int bytes;
  final DateTime importedAt;
  const ExternalReaderFont(
    this.id,
    this.name,
    this.format,
    this.bytes,
    this.importedAt,
  );
  String get hash => id.substring('external_'.length);
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'format': format,
    'bytes': bytes,
    'imported_at': importedAt.toUtc().toIso8601String(),
  };
  factory ExternalReaderFont.fromJson(Map json) {
    if (!RegExp(
          r'^external_[a-f0-9]{64}$',
        ).hasMatch(json['id']?.toString() ?? '') ||
        !['ttf', 'otf'].contains(json['format']) ||
        json['name'] is! String ||
        (json['name'] as String).length > 256 ||
        json['bytes'] is! int ||
        json['bytes'] <= 0 ||
        json['bytes'] > ExternalReaderFonts.maxFileBytes) {
      throw const FormatException('字体索引损坏');
    }
    return ExternalReaderFont(
      json['id'],
      json['name'],
      json['format'],
      json['bytes'],
      DateTime.parse(json['imported_at']),
    );
  }
}

class ReaderFontInspection {
  final String name, format, hash;
  const ReaderFontInspection(this.name, this.format, this.hash);
}

/// Bounded SFNT validation before either native font decoder sees the bytes.
/// Collections/web fonts are deliberately unsupported; no font is installed OS-wide.
ReaderFontInspection inspectReaderFont(Uint8List bytes) {
  if (bytes.length < 28 || bytes.length > ExternalReaderFonts.maxFileBytes) {
    throw const FormatException('字体为空或超过 20 MB');
  }
  final data = ByteData.sublistView(bytes);
  final signature = data.getUint32(0);
  final format = switch (signature) {
    0x00010000 => 'ttf',
    0x4F54544F => 'otf', // OTTO
    _ => throw const FormatException('仅支持独立 TTF / OTF 字体，不支持 TTC / WOFF'),
  };
  final count = data.getUint16(4);
  if (count < 3 || count > 128 || 12 + count * 16 > bytes.length) {
    throw const FormatException('字体表目录损坏');
  }
  final tables = <String, (int, int)>{};
  final intervals = <(int, int)>[];
  for (var i = 0; i < count; i++) {
    final at = 12 + i * 16;
    final tag = ascii.decode(bytes.sublist(at, at + 4), allowInvalid: true);
    final offset = data.getUint32(at + 8), length = data.getUint32(at + 12);
    if (!RegExp(r'^[\x20-\x7e]{4}$').hasMatch(tag) ||
        tables.containsKey(tag) ||
        offset < 12 + count * 16 ||
        offset % 4 != 0 ||
        offset > bytes.length ||
        length > bytes.length - offset) {
      throw const FormatException('字体表越界、重复或未对齐');
    }
    tables[tag] = (offset, length);
    if (length > 0) intervals.add((offset, offset + length));
  }
  intervals.sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < intervals.length; i++) {
    if (intervals[i].$1 < intervals[i - 1].$2) {
      throw const FormatException('字体表重叠');
    }
  }
  if (!tables.keys.toSet().containsAll(['head', 'cmap', 'name', 'maxp']) ||
      (format == 'ttf' && !tables.keys.toSet().containsAll(['glyf', 'loca'])) ||
      (format == 'otf' &&
          !tables.containsKey('CFF ') &&
          !tables.containsKey('CFF2'))) {
    throw const FormatException('字体缺少必要表');
  }
  final head = tables['head']!;
  if (head.$2 < 54 || data.getUint32(head.$1 + 12) != 0x5F0F3CF5) {
    throw const FormatException('字体 head 表损坏');
  }
  final cmap = tables['cmap']!;
  if (cmap.$2 < 12 || data.getUint16(cmap.$1) != 0) {
    throw const FormatException('字体字符映射损坏');
  }
  final encodings = data.getUint16(cmap.$1 + 2);
  if (encodings == 0 || encodings > 128 || 4 + encodings * 8 > cmap.$2) {
    throw const FormatException('字体字符映射越界');
  }
  var unicode = false;
  for (var i = 0; i < encodings; i++) {
    final at = cmap.$1 + 4 + i * 8;
    final offset = data.getUint32(at + 4);
    if (offset > cmap.$2 - 2) throw const FormatException('字体子映射越界');
    final platform = data.getUint16(at), encoding = data.getUint16(at + 2);
    final subFormat = data.getUint16(cmap.$1 + offset);
    if ([0, 4, 6, 12, 13].contains(subFormat)) {
      final longHeader = subFormat == 12 || subFormat == 13;
      final minimum = longHeader ? 16 : 6;
      if (offset + minimum > cmap.$2) throw const FormatException('字体子映射截断');
      final length = longHeader
          ? data.getUint32(cmap.$1 + offset + 4)
          : data.getUint16(cmap.$1 + offset + 2);
      if (length < minimum || length > cmap.$2 - offset) {
        throw const FormatException('字体子映射长度越界');
      }
    }
    if ((platform == 0 || (platform == 3 && [1, 10].contains(encoding))) &&
        [0, 4, 6, 12, 13].contains(subFormat)) {
      unicode = true;
    }
  }
  if (!unicode) throw const FormatException('字体没有可用 Unicode 字符映射');
  final name = tables['name']!;
  if (name.$2 < 6) throw const FormatException('字体名称表损坏');
  final names = data.getUint16(name.$1 + 2),
      storage = data.getUint16(name.$1 + 4);
  if (names > 4096 || storage < 6 + names * 12 || storage > name.$2) {
    throw const FormatException('字体名称表越界');
  }
  String? family;
  for (var i = 0; i < names; i++) {
    final at = name.$1 + 6 + i * 12;
    final platform = data.getUint16(at), nameId = data.getUint16(at + 6);
    final length = data.getUint16(at + 8), offset = data.getUint16(at + 10);
    if (storage + offset > name.$2 || length > name.$2 - storage - offset) {
      throw const FormatException('字体名称记录越界');
    }
    if (![1, 16].contains(nameId) || ![0, 3].contains(platform) || length.isOdd) {
      continue;
    }
    final start = name.$1 + storage + offset;
    final clean = String.fromCharCodes([
      for (var j = 0; j < length; j += 2) data.getUint16(start + j),
    ]).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (clean.isNotEmpty && (family == null || nameId == 16)) {
      family = clean.characters.take(80).join();
    }
  }
  return ReaderFontInspection(
    family ?? '自定义字体',
    format,
    sha256.convert(bytes).toString(),
  );
}

class ExternalReaderFonts extends ChangeNotifier {
  static const preferencesKey = 'reader_external_fonts_v1';
  static const maxFileBytes = 20 * 1024 * 1024;
  static final _instance = ExternalReaderFonts._(AppStorage.documents, null);
  factory ExternalReaderFonts() => _instance;
  ExternalReaderFonts._(this.documents, this.loadBytes);
  @visibleForTesting
  ExternalReaderFonts.forTesting({required this.documents, this.loadBytes});
  final Future<Directory> Function() documents;
  final Future<void> Function(String family, Uint8List bytes)? loadBytes;
  List<ExternalReaderFont> _fonts = [];
  final _loaded = <String>{};
  final _loading = <String, Future<void>>{};
  Future<void>? _write;
  List<ExternalReaderFont> get fonts => List.unmodifiable(_fonts);
  String? familyFor(String id) =>
      _loaded.contains(id) ? 'ReaderExternal_${id.substring(9)}' : null;

  Future<void> reload() async {
    await _write?.catchError((_) {});
    await _read();
  }

  Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonDecode(prefs.getString(preferencesKey) ?? '[]');
    if (json is! List || json.length > 20) {
      throw const FormatException('字体索引超限');
    }
    _fonts = json.map((e) => ExternalReaderFont.fromJson(e as Map)).toList();
    if (_fonts.map((e) => e.id).toSet().length != _fonts.length) {
      throw const FormatException('字体索引重复');
    }
    _loaded.removeWhere((id) => !_fonts.any((font) => font.id == id));
    notifyListeners();
  }

  Future<File> fileFor(ExternalReaderFont font) async => File(
    '${(await documents()).path}/reader_fonts/${font.hash}/font.${font.format}',
  );

  Future<ExternalReaderFont> importFile(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('请选择普通字体文件，不支持符号链接');
    }
    if (await file.length() > maxFileBytes) {
      throw const FormatException('字体超过 20 MB');
    }
    return importStream(file.openRead());
  }

  Future<ExternalReaderFont> importStream(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxFileBytes) {
        throw const FormatException('字体超过 20 MB');
      }
      builder.add(chunk);
    }
    return importBytes(builder.takeBytes());
  }

  Future<ExternalReaderFont> importBytes(Uint8List bytes) async {
    if (bytes.length > maxFileBytes) throw const FormatException('字体超过 20 MB');
    bytes = Uint8List.fromList(
      bytes,
    ); // Do not retain a caller's mutable buffer.
    final inspected = await compute(inspectReaderFont, bytes);
    return _serialize(() async {
      await _read();
      final id = 'external_${inspected.hash}';
      final existing = _fonts.where((e) => e.id == id).firstOrNull;
      if (existing == null &&
          (_fonts.length >= 20 ||
              _fonts.fold(0, (sum, e) => sum + e.bytes) + bytes.length >
                  200 * 1024 * 1024)) {
        throw const FormatException('最多 20 种字体、总计 200 MB，请先删除不用的字体');
      }
      final font =
          existing ??
          ExternalReaderFont(
            id,
            inspected.name,
            inspected.format,
            bytes.length,
            DateTime.now(),
          );
      final target = await fileFor(font);
      await _checkParents(target);
      await AtomicFile.writeBytes(target, bytes);
      try {
        await _register(font, bytes);
        await _save([..._fonts.where((e) => e.id != id), font]);
      } catch (_) {
        _loaded.remove(id);
        if (existing == null && await target.exists()) await target.delete();
        rethrow;
      }
      return font;
    });
  }

  Future<void> ensureLoaded(String id) {
    if (_loaded.contains(id)) return Future.value();
    return _loading.putIfAbsent(id, () async {
      try {
        // Only safe hashed preferences can become a path.
        if (!RegExp(r'^external_[a-f0-9]{64}$').hasMatch(id)) {
          throw const FormatException('字体标识不合法');
        }
        if (!_fonts.any((font) => font.id == id)) await reload();
        final font = _fonts.where((e) => e.id == id).firstOrNull;
        if (font == null) throw const FormatException('字体已删除，暂用系统字体');
        final file = await fileFor(font);
        await _checkParents(file);
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.length() > maxFileBytes) {
          throw const FormatException('字体丢失或损坏，暂用系统字体');
        }
        final bytes = await file.readAsBytes();
        final inspected = await compute(inspectReaderFont, bytes);
        if (inspected.hash != font.hash || inspected.format != font.format) {
          throw const FormatException('字体校验失败，暂用系统字体');
        }
        await _register(font, bytes);
      } finally {
        _loading.remove(id);
      }
    });
  }

  Future<void> _register(ExternalReaderFont font, Uint8List bytes) async {
    final family = 'ReaderExternal_${font.hash}';
    if (loadBytes != null) {
      await loadBytes!(family, bytes);
    } else {
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
    _loaded.add(font.id);
  }

  Future<void> remove(String id) => _serialize(() async {
    final font = _fonts.where((e) => e.id == id).firstOrNull;
    if (font == null) return;
    final file = await fileFor(font);
    await _checkParents(file);
    // Commit metadata before removing only this owned, hashed directory.
    await _save(_fonts.where((e) => e.id != id).toList());
    _loaded.remove(id);
    if (await FileSystemEntity.type(file.parent.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await file.parent.delete(recursive: true);
    }
    notifyListeners();
  });

  Future<void> _save(List<ExternalReaderFont> next) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      preferencesKey,
      jsonEncode(next.map((e) => e.toJson()).toList()),
    )) {
      throw StateError('字体索引未保存');
    }
    _fonts = next;
    notifyListeners();
  }

  Future<void> _checkParents(File file) async {
    for (final parent in [file.parent.parent, file.parent]) {
      final type = await FileSystemEntity.type(parent.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const FormatException('字体目录不是普通目录');
      }
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('字体文件不能是符号链接');
    }
  }

  Future<T> _serialize<T>(Future<T> Function() task) {
    // reload inside this operation must not await its own write.
    final previous = _write;
    final result = (previous ?? Future<void>.value())
        .catchError((_) {})
        .then((_) => task());
    late final Future<void> pending;
    pending = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_write, pending)) _write = null;
        });
    _write = pending;
    return result;
  }
}
