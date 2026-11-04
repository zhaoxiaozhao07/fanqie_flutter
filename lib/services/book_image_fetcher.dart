import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'epub_images.dart';

class BookImageData {
  final Uint8List bytes;
  final String extension;
  final int width, height;
  const BookImageData(this.bytes, this.extension, this.width, this.height);
}

/// Bounded native-codec validation; neither HTML error pages nor unsupported
/// HEIC payloads are allowed to poison a permanent image cache.
class BookImageFetcher {
  final http.Client client;
  BookImageFetcher(this.client);
  static const maxBytes = 8 * 1024 * 1024;

  static bool allowed(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      const [
        'byteimg.com',
        'fqnovelpic.com',
        'pstatp.com',
        'toutiaoimg.com',
        'novelpic.com',
        'bytecdn.cn',
      ].any((host) => uri.host == host || uri.host.endsWith('.$host'));

  static Future<BookImageData> validate(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('图片大小不受支持');
    }
    final info = EpubImages.rasterInfo(bytes);
    if (info == null ||
        info.$2 <= 0 ||
        info.$3 <= 0 ||
        info.$2 > 16000 ||
        info.$3 > 16000 ||
        info.$2 * info.$3 > 40000000) {
      throw const FormatException('图片格式或尺寸不受支持');
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 64,
      targetHeight: 64,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
    return BookImageData(bytes, info.$1, info.$2, info.$3);
  }

  static String normalize(String source) {
    var url = source.trim();
    if (url.startsWith('//')) url = 'https:$url';
    if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
    return url;
  }

  Future<BookImageData> fetch(String source) async {
    final original = Uri.parse(normalize(source));
    // Preserve signed URLs and query parameters on the first request.
    final candidates = [original];
    final template = original.path.indexOf('~tplv');
    if (allowed(original) && template > 0) {
      candidates.add(
        Uri.https(
          'p3-novel.byteimg.com',
          '${original.path.substring(0, template)}~tplv-1yzifmftcy-expand:1600:0:0.webp',
        ),
      );
    }
    for (final uri in candidates) {
      try {
        return await _fetch(uri).timeout(const Duration(seconds: 12));
      } catch (_) {
        if (uri == candidates.last) rethrow;
      }
    }
    throw const FormatException('图片不可用');
  }

  Future<BookImageData> _fetch(Uri uri) async {
    for (var redirect = 0; redirect <= 3; redirect++) {
      if (!allowed(uri)) throw const FormatException('图片地址不受支持');
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://fanqienovel.com/',
        });
      final response = await client.send(request);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        await response.stream.listen((_) {}).cancel();
        final location = response.headers['location'];
        if (location == null) break;
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes) {
        await response.stream.listen((_) {}).cancel();
        throw const FormatException('图片下载失败或超过 8 MB');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 8),
      )) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('图片超过 8 MB');
        }
        bytes.add(chunk);
      }
      return validate(bytes.takeBytes());
    }
    throw const FormatException('图片重定向过多');
  }
}
