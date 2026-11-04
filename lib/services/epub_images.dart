import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../models/reader_illustration.dart';
import 'safe_zip_reader.dart';

class ExtractedIllustration {
  final int offset;
  final ReaderIllustration image;
  const ExtractedIllustration(this.offset, this.image);
}

/// Extract only referenced resources, using generated names and bounded reads.
/// SVG is rendered natively, never in a WebView; all external references are
/// rejected and internal bitmap references are embedded before saving it.
class EpubImages {
  final SafeZipReader zip;
  final String staging;
  final Set<String> encrypted;
  final String Function(String, String) resolve;
  final void Function() check;
  final _assets = <String>{};
  int _count = 0, _totalBytes = 0;
  static const maxImageBytes = 8 * 1024 * 1024;

  EpubImages({
    required this.zip,
    required this.staging,
    required this.encrypted,
    required this.resolve,
    required this.check,
  });

  Future<ReaderIllustration> extract(
    String base,
    String source,
    String alt, {
    String? inlineSvg,
  }) async {
    check();
    if (++_count > 2000) throw const FormatException('插图数量超过安全限制');
    final id = 'illustration_$_count';
    alt = String.fromCharCodes(
      alt.replaceAll(RegExp(r'\s+'), ' ').runes.take(200),
    );
    try {
      final bytes = inlineSvg == null
          ? await _read(base, source)
          : Uint8List.fromList(utf8.encode(inlineSvg));
      if (bytes.length > maxImageBytes) {
        throw const FormatException('插图超过 8 MB');
      }
      var saved = bytes;
      var info = _rasterInfo(bytes);
      String extension;
      int width, height;
      if (info != null) {
        (extension, width, height) = info;
      } else {
        final (svg, w, h) = await _svg(
          bytes,
          inlineSvg == null && !source.startsWith('data:')
              ? resolve(base, source)
              : base,
        );
        saved = Uint8List.fromList(utf8.encode(svg));
        extension = 'svg';
        width = w;
        height = h;
      }
      if (width <= 0 ||
          height <= 0 ||
          width > 16000 ||
          height > 16000 ||
          width * height > 40000000) {
        throw const FormatException('插图尺寸超过安全限制');
      }
      final asset = 'images/${sha256.convert(saved)}.$extension';
      if (_assets.add(asset)) {
        _totalBytes += saved.length;
        if (_totalBytes > 128 * 1024 * 1024) {
          throw const LocalImageLimit('插图资源总量超过 128 MB');
        }
        await Directory('$staging/images').create(recursive: true);
        await File(path.join(staging, asset)).writeAsBytes(saved);
      }
      return ReaderIllustration(
        id: id,
        asset: asset,
        alt: alt,
        width: width,
        height: height,
      );
    } on LocalImageLimit {
      rethrow;
    } on FormatException catch (error) {
      // Preserve an explicit block even if this image is unavailable. Do not
      // expose remote URLs or archive paths in the rendered message.
      return ReaderIllustration(
        id: id,
        alt: alt,
        error: error.message.toString().contains('尺寸')
            ? '插图尺寸过大，未加载'
            : error.message.toString().contains('加密')
            ? '插图已加密，无法显示'
            : '插图缺失、损坏或格式不受支持',
      );
    } on FileSystemException {
      rethrow; // Disk errors/cancellation must not commit a false success.
    } catch (_) {
      check();
      return ReaderIllustration(id: id, alt: alt, error: '插图无法解析');
    }
  }

  Future<Uint8List> _read(String base, String source) async {
    check();
    if (source.startsWith('data:')) {
      final match = RegExp(
        r'^data:image/(png|jpeg|gif|webp|bmp|svg\+xml);base64,',
        caseSensitive: false,
      ).firstMatch(source);
      if (match == null || source.length > maxImageBytes * 4 ~/ 3 + 256) {
        throw const FormatException('不支持的内嵌插图');
      }
      final bytes = base64Decode(
        source.substring(match.end).replaceAll(RegExp(r'\s'), ''),
      );
      if (bytes.length > maxImageBytes) {
        throw const FormatException('插图超过 8 MB');
      }
      return bytes;
    }
    if (source.trim().isEmpty) throw const FormatException('插图缺少资源路径');
    final target = resolve(base, source);
    if (encrypted.contains(target)) throw const FormatException('插图已加密');
    if (!zip.entries.containsKey(target)) throw const FormatException('插图资源缺失');
    return zip.read(target, maxBytes: maxImageBytes, checkCancelled: check);
  }

  Future<(String, int, int)> _svg(Uint8List bytes, String base) async {
    if (bytes.length > 2 * 1024 * 1024) throw const FormatException('SVG 插图过大');
    final source = utf8.decode(bytes);
    if (RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(source)) {
      throw const FormatException('SVG 包含不安全声明');
    }
    final doc = XmlDocument.parse(source);
    final root = doc.rootElement;
    if (root.name.local != 'svg') throw const FormatException('未知图片格式');
    final elements = [root, ...root.descendants.whereType<XmlElement>()];
    if (elements.length > 5000) throw const FormatException('SVG 结构过大');
    bool unsafeCss(String value) {
      if (value.contains('\\') || value.toLowerCase().contains('@import')) {
        return true;
      }
      return RegExp(r'url\(([^)]*)\)', caseSensitive: false)
          .allMatches(value)
          .any(
            (m) => !m[1]!.replaceAll(RegExp("[\\s'\"]"), '').startsWith('#'),
          );
    }

    var embeddedBytes = bytes.length;
    for (final element in elements) {
      check();
      if (const {
        'script',
        'foreignObject',
        'iframe',
        'object',
        'audio',
        'video',
      }.contains(element.name.local)) {
        throw const FormatException('SVG 包含不安全内容');
      }
      if (element.name.local == 'style' && unsafeCss(element.innerText)) {
        throw const FormatException('SVG 外部样式不受支持');
      }
      for (final attribute in element.attributes.toList()) {
        if (attribute.name.local.toLowerCase().startsWith('on') ||
            unsafeCss(attribute.value)) {
          throw const FormatException('SVG 属性不安全');
        }
        if (attribute.name.local != 'href') continue;
        if (attribute.value.startsWith('#')) continue;
        if (element.name.local != 'image') {
          throw const FormatException('SVG 外部引用不受支持');
        }
        final raster = await _read(base, attribute.value);
        final info = _rasterInfo(raster);
        if (info == null ||
            info.$2 <= 0 ||
            info.$3 <= 0 ||
            info.$2 > 16000 ||
            info.$3 > 16000 ||
            info.$2 * info.$3 > 40000000) {
          throw const FormatException('SVG 引用插图尺寸异常');
        }
        final mime = info.$1 == 'jpg' ? 'jpeg' : info.$1;
        embeddedBytes += (raster.length + 2) ~/ 3 * 4 + 64;
        if (embeddedBytes > maxImageBytes) {
          throw const FormatException('SVG 内嵌资源过大');
        }
        attribute.value = 'data:image/$mime;base64,${base64Encode(raster)}';
      }
    }
    final box = (root.getAttribute('viewBox') ?? '')
        .split(RegExp(r'[\s,]+'))
        .map(double.tryParse)
        .toList();
    double? dimension(String? value) => value == null || value.contains('%')
        ? null
        : double.tryParse(RegExp(r'^[0-9.]+').stringMatch(value) ?? '');
    final width =
        dimension(root.getAttribute('width')) ??
        (box.length == 4 ? box[2] : null) ??
        512;
    final height =
        dimension(root.getAttribute('height')) ??
        (box.length == 4 ? box[3] : null) ??
        384;
    if (!width.isFinite || !height.isFinite) {
      throw const FormatException('SVG 尺寸异常');
    }
    final result = doc.toXmlString();
    if (utf8.encode(result).length > maxImageBytes) {
      throw const FormatException('SVG 资源过大');
    }
    return (result, width.ceil(), height.ceil());
  }

  static (String, int, int)? _rasterInfo(Uint8List bytes) {
    if (bytes.length < 10) return null;
    final d = ByteData.sublistView(bytes);
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        ascii.decode(bytes.sublist(1, 4), allowInvalid: true) == 'PNG') {
      return ('png', d.getUint32(16), d.getUint32(20));
    }
    final magic = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
    if (magic == 'GIF87a' || magic == 'GIF89a') {
      return (
        'gif',
        d.getUint16(6, Endian.little),
        d.getUint16(8, Endian.little),
      );
    }
    if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
      return (
        'bmp',
        d.getInt32(18, Endian.little).abs(),
        d.getInt32(22, Endian.little).abs(),
      );
    }
    if (bytes[0] == 0xff && bytes[1] == 0xd8) {
      var i = 2;
      while (i + 4 < bytes.length) {
        if (bytes[i++] != 0xff) break;
        while (i < bytes.length && bytes[i] == 0xff) {
          i++;
        }
        if (i >= bytes.length) break;
        final marker = bytes[i++];
        if (marker == 0xd9 || marker == 0xda) break;
        if (marker == 1 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (i + 2 > bytes.length) break;
        final length = d.getUint16(i);
        if (length < 2 || i + length > bytes.length) break;
        if (const {
              0xc0,
              0xc1,
              0xc2,
              0xc3,
              0xc5,
              0xc6,
              0xc7,
              0xc9,
              0xca,
              0xcb,
              0xcd,
              0xce,
              0xcf,
            }.contains(marker) &&
            length >= 7) {
          return ('jpg', d.getUint16(i + 5), d.getUint16(i + 3));
        }
        i += length;
      }
      throw const FormatException('JPEG 图片头损坏');
    }
    if (bytes.length >= 30 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      final type = ascii.decode(bytes.sublist(12, 16), allowInvalid: true);
      if (type == 'VP8X') {
        int u24(int i) => bytes[i] | bytes[i + 1] << 8 | bytes[i + 2] << 16;
        return ('webp', u24(24) + 1, u24(27) + 1);
      }
      if (type == 'VP8L' && bytes[20] == 0x2f) {
        final value = d.getUint32(21, Endian.little);
        return ('webp', (value & 0x3fff) + 1, ((value >> 14) & 0x3fff) + 1);
      }
      if (type == 'VP8 ') {
        return (
          'webp',
          d.getUint16(26, Endian.little) & 0x3fff,
          d.getUint16(28, Endian.little) & 0x3fff,
        );
      }
    }
    return null;
  }
}

class LocalImageLimit extends FormatException {
  const LocalImageLimit(super.message);
}
