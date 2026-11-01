import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;

class SafeZipEntry {
  final String name;
  final int offset, compressedSize, size, method, crc;
  const SafeZipEntry(
    this.name,
    this.offset,
    this.compressedSize,
    this.size,
    this.method,
    this.crc,
  );
}

/// Bounded ZIP indexing and streaming inflation. Never extracts archive paths
/// to disk and never eagerly decompresses symlink/encrypted entries.
class SafeZipReader {
  final File file;
  final Map<String, SafeZipEntry> entries;
  SafeZipReader._(this.file, this.entries);
  static const maxFileBytes = 128 * 1024 * 1024;
  static const maxEntries = 10000;
  static const maxInflatedBytes = 512 * 1024 * 1024;

  static String safeName(String name) {
    final normalized = name.replaceAll('\\', '/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(normalized) ||
        normalized.contains('\x00') ||
        normalized.split('/').any((part) => part == '..')) {
      throw const FormatException('压缩包包含不安全路径');
    }
    return normalized;
  }

  static Future<SafeZipReader> open(
    File file, {
    void Function()? checkCancelled,
  }) async {
    final length = await file.length();
    if (length < 22 || length > maxFileBytes) {
      throw const FormatException('压缩包为空或超过 128 MB');
    }
    final input = await file.open();
    try {
      final start = math.max(0, length - 65557);
      await input.setPosition(start);
      final tail = ByteData.sublistView(await input.read(length - start));
      var end = -1;
      for (var i = tail.lengthInBytes - 22; i >= 0; i--) {
        if (tail.getUint32(i, Endian.little) == 0x06054b50 &&
            i + 22 + tail.getUint16(i + 20, Endian.little) ==
                tail.lengthInBytes) {
          end = i;
          break;
        }
      }
      if (end < 0) throw const FormatException('压缩包目录损坏');
      final count = tail.getUint16(end + 10, Endian.little);
      final size = tail.getUint32(end + 12, Endian.little);
      final offset = tail.getUint32(end + 16, Endian.little);
      if (count == 0 ||
          count > maxEntries ||
          size > 16 * 1024 * 1024 ||
          offset + size > start + end ||
          tail.getUint16(end + 4, Endian.little) != 0 ||
          tail.getUint16(end + 6, Endian.little) != 0 ||
          tail.getUint16(end + 8, Endian.little) != count) {
        throw const FormatException('压缩包目录超限或格式不受支持');
      }
      await input.setPosition(offset);
      final directoryBytes = await input.read(size);
      if (directoryBytes.length != size) throw const FormatException('压缩包目录截断');
      final directory = ByteData.sublistView(directoryBytes);
      final entries = <String, SafeZipEntry>{};
      var cursor = 0;
      var inflated = 0;
      for (var index = 0; index < count; index++) {
        checkCancelled?.call();
        if (cursor + 46 > size ||
            directory.getUint32(cursor, Endian.little) != 0x02014b50) {
          throw const FormatException('压缩包目录条目损坏');
        }
        final flags = directory.getUint16(cursor + 8, Endian.little);
        final method = directory.getUint16(cursor + 10, Endian.little);
        final crc = directory.getUint32(cursor + 16, Endian.little);
        final compressed = directory.getUint32(cursor + 20, Endian.little);
        final uncompressed = directory.getUint32(cursor + 24, Endian.little);
        final nameLength = directory.getUint16(cursor + 28, Endian.little);
        final extraLength = directory.getUint16(cursor + 30, Endian.little);
        final commentLength = directory.getUint16(cursor + 32, Endian.little);
        final attrs = directory.getUint32(cursor + 38, Endian.little);
        final localOffset = directory.getUint32(cursor + 42, Endian.little);
        final next = cursor + 46 + nameLength + extraLength + commentLength;
        if (nameLength > 1024 ||
            extraLength > 4096 ||
            commentLength > 4096 ||
            next > size ||
            localOffset + 30 > offset ||
            uncompressed > 32 * 1024 * 1024 ||
            ((attrs >> 16) & 0xf000) == 0xa000 ||
            (flags & 1) != 0 ||
            (method != 0 && method != 8)) {
          throw const FormatException('压缩包含加密、链接、超限或不支持的条目');
        }
        final rawName = directoryBytes.sublist(
          cursor + 46,
          cursor + 46 + nameLength,
        );
        String name;
        try {
          name = utf8.decode(rawName);
        } on FormatException {
          name = latin1.decode(rawName);
        }
        name = safeName(name);
        inflated += uncompressed;
        if (inflated > maxInflatedBytes || entries.containsKey(name)) {
          throw const FormatException('压缩包解压总量超限或存在重复路径');
        }
        await input.setPosition(localOffset);
        final headerBytes = await input.read(30);
        if (headerBytes.length != 30) throw const FormatException('压缩包文件头截断');
        final header = ByteData.sublistView(headerBytes);
        final localName = header.getUint16(26, Endian.little);
        final localExtra = header.getUint16(28, Endian.little);
        final dataStart = localOffset + 30 + localName + localExtra;
        if (header.getUint32(0, Endian.little) != 0x04034b50 ||
            (header.getUint16(6, Endian.little) & 1) != 0 ||
            header.getUint16(8, Endian.little) != method ||
            localName > 1024 ||
            localExtra > 4096 ||
            dataStart + compressed > offset ||
            (method == 0 && compressed != uncompressed)) {
          throw const FormatException('压缩包文件范围不合法');
        }
        entries[name] = SafeZipEntry(
          name,
          dataStart,
          compressed,
          uncompressed,
          method,
          crc,
        );
        cursor = next;
      }
      return SafeZipReader._(file, entries);
    } finally {
      await input.close();
    }
  }

  Future<Uint8List> read(
    String name, {
    int maxBytes = 8 * 1024 * 1024,
    void Function()? checkCancelled,
  }) async {
    final entry = entries[name];
    if (entry == null) throw FormatException('缺少压缩包资源：$name');
    if (entry.size > maxBytes) throw const FormatException('资源大小超过安全限制');
    Stream<List<int>> compressed() async* {
      await for (final chunk in file.openRead(
        entry.offset,
        entry.offset + entry.compressedSize,
      )) {
        for (var offset = 0; offset < chunk.length; offset += 512) {
          checkCancelled?.call();
          yield chunk.sublist(offset, math.min(chunk.length, offset + 512));
        }
      }
    }

    final data = entry.method == 8
        ? compressed().transform(ZLibDecoder(raw: true))
        : compressed();
    final output = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in data) {
      checkCancelled?.call();
      total += chunk.length;
      if (total > maxBytes || total > entry.size) {
        throw const FormatException('资源实际解压大小超过声明或安全限制');
      }
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    if (total != entry.size || archive.getCrc32(bytes) != entry.crc) {
      throw const FormatException('压缩包资源校验失败');
    }
    return bytes;
  }
}
