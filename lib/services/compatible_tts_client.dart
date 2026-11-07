import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class TtsRequestFailure implements Exception {
  final String message;
  final int? status;
  const TtsRequestFailure(this.message, {this.status});
  @override
  String toString() => message; // Never include body/input, authorization or URL.
}

class TtsRequestCancelled implements Exception {
  const TtsRequestCancelled();
}

class TtsAudio {
  final Uint8List bytes;
  final String format;
  const TtsAudio(this.bytes, this.format);
}

/// Android-compatible POST audio/speech. Bounded binary streaming, no automatic
/// redirects carrying Bearer credentials, cancellable preloads, finite retries.
class CompatibleTtsClient {
  static const maxAudioBytes = 16 * 1024 * 1024;
  final http.Client client;
  final Duration timeout, retryDelay;
  CompatibleTtsClient(
    this.client, {
    this.timeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(milliseconds: 300),
  });
  final _active = <Completer<void>>{};
  void cancel() {
    for (final signal in _active.toList()) {
      if (!signal.isCompleted) signal.complete();
    }
  }

  static Uri endpoint(String base) {
    final uri = Uri.tryParse(base.trim());
    final local =
        uri != null &&
        ['localhost', '127.0.0.1', '::1', '10.0.2.2'].contains(uri.host);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw const FormatException('语音接口须为 HTTPS 且不含账号、查询参数或片段（本机调试地址除外）');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/audio/speech')
          ? path
          : path.endsWith('/v1')
          ? '$path/audio/speech'
          : '$path/v1/audio/speech',
    );
  }

  static String audioFormat(Uint8List bytes) {
    if (bytes.length >= 44 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE') {
      final data = ByteData.sublistView(bytes);
      if (data.getUint32(4, Endian.little) + 8 > bytes.length) {
        throw const TtsRequestFailure('接口音频被截断');
      }
      var at = 12, format = false, samples = false;
      while (at + 8 <= bytes.length) {
        final size = data.getUint32(at + 4, Endian.little);
        if (size > bytes.length - at - 8) {
          throw const TtsRequestFailure('接口音频块越界');
        }
        final tag = ascii.decode(bytes.sublist(at, at + 4), allowInvalid: true);
        if (tag == 'fmt ' && size >= 16) {
          final codec = data.getUint16(at + 8, Endian.little);
          final channels = data.getUint16(at + 10, Endian.little);
          final rate = data.getUint32(at + 12, Endian.little);
          format =
              [1, 3].contains(codec) &&
              channels > 0 &&
              channels <= 8 &&
              rate >= 8000 &&
              rate <= 192000;
        }
        if (tag == 'data' && size > 0) samples = true;
        at += 8 + size + (size.isOdd ? 1 : 0);
      }
      if (format && samples) return 'wav';
      throw const TtsRequestFailure('接口返回的 WAV 不可播放');
    }
    var start = 0;
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      if (bytes.sublist(6, 10).any((e) => e > 127)) {
        throw const TtsRequestFailure('接口音频标记无效');
      }
      start =
          10 + (bytes[6] << 21) + (bytes[7] << 14) + (bytes[8] << 7) + bytes[9];
    }
    final limit = (start + 2048).clamp(
      0,
      bytes.length - 3 < 0 ? 0 : bytes.length - 3,
    );
    for (var i = start; i < limit; i++) {
      if (bytes[i] == 0xff &&
          (bytes[i + 1] & 0xe0) == 0xe0 &&
          ((bytes[i + 1] >> 3) & 3) != 1 &&
          ((bytes[i + 1] >> 1) & 3) == 1 &&
          (bytes[i + 2] >> 4) > 0 &&
          (bytes[i + 2] >> 4) < 15 &&
          ((bytes[i + 2] >> 2) & 3) != 3) {
        final version = (bytes[i + 1] >> 3) & 3;
        final index = bytes[i + 2] >> 4;
        final rates = version == 3
            ? const [
                0,
                32,
                40,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                160,
                192,
                224,
                256,
                320,
                0,
              ]
            : const [
                0,
                8,
                16,
                24,
                32,
                40,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                144,
                160,
                0,
              ];
        final sample =
            [44100, 48000, 32000][(bytes[i + 2] >> 2) & 3] ~/
            (version == 3
                ? 1
                : version == 2
                ? 2
                : 4);
        final frame =
            (version == 3 ? 144 : 72) * rates[index] * 1000 ~/ sample +
            ((bytes[i + 2] >> 1) & 1);
        if (frame > 4 && i + frame <= bytes.length) return 'mp3';
      }
    }
    throw const TtsRequestFailure('接口没有返回有效 MP3 / WAV 音频');
  }

  Future<TtsAudio> synthesize({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String voice,
    required String text,
    required double speed,
    bool Function()? isCancelled,
  }) async {
    final uri = endpoint(baseUrl);
    if (text.isEmpty ||
        text.length > 4096 ||
        model.trim().isEmpty ||
        voice.trim().isEmpty ||
        !speed.isFinite ||
        speed < .25 ||
        speed > 4) {
      throw const TtsRequestFailure('语音参数或正文长度无效');
    }
    void check() {
      if (isCancelled?.call() == true) throw const TtsRequestCancelled();
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      check();
      final abort = Completer<void>();
      _active.add(abort);
      var timedOut = false;
      final deadline = Timer(timeout, () {
        timedOut = true;
        if (!abort.isCompleted) abort.complete();
      });
      try {
        final request =
            http.AbortableRequest('POST', uri, abortTrigger: abort.future)
              ..followRedirects = false
              ..maxRedirects = 0
              ..headers.addAll({
                'Content-Type': 'application/json',
                if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
              })
              ..body = jsonEncode({
                'model': model,
                'input': text,
                'voice': voice,
                'response_format': 'mp3',
                'speed': speed,
              });
        final sending = client.send(request);
        unawaited(
          sending.then<void>((response) async {
            if (abort.isCompleted) {
              await response.stream.listen((_) {}).cancel();
            }
          }, onError: (Object _, StackTrace _) {}),
        );
        final response = await Future.any([
          sending,
          abort.future.then<http.StreamedResponse>((_) {
            if (!timedOut || isCancelled?.call() == true) {
              throw const TtsRequestCancelled();
            }
            throw const TtsRequestFailure('语音请求超时或已取消');
          }),
        ]);
        check();
        final status = response.statusCode;
        if (status != 200) {
          await response.stream.listen((_) {}).cancel();
          if (status >= 300 && status < 400) {
            throw TtsRequestFailure('接口重定向已拒绝，避免转发密钥', status: status);
          }
          if (status == 401 || status == 403) {
            throw TtsRequestFailure('接口鉴权失败（$status），请检查密钥或权限', status: status);
          }
          if ((status == 429 || status >= 500) && attempt == 0) {
            final retry = int.tryParse(response.headers['retry-after'] ?? '');
            await _wait(
              retry == null ? retryDelay : Duration(seconds: retry.clamp(0, 2)),
              isCancelled,
            );
            continue;
          }
          throw TtsRequestFailure('语音接口返回 HTTP $status', status: status);
        }
        final type = (response.headers['content-type'] ?? '').toLowerCase();
        if (type.contains('json') ||
            type.contains('html') ||
            type.startsWith('text/')) {
          await response.stream.listen((_) {}).cancel();
          throw const TtsRequestFailure('接口返回文本而非音频');
        }
        if ((response.contentLength ?? 0) > maxAudioBytes) {
          await response.stream.listen((_) {}).cancel();
          throw const TtsRequestFailure('接口音频超过 16 MB');
        }
        final result = Completer<Uint8List>();
        final bytes = BytesBuilder(copy: false);
        StreamSubscription<List<int>>? subscription;
        subscription = response.stream.listen(
          (chunk) {
            if (result.isCompleted) return;
            if (bytes.length + chunk.length > maxAudioBytes) {
              result.completeError(const TtsRequestFailure('接口音频超过 16 MB'));
              unawaited(subscription?.cancel());
            } else {
              bytes.add(chunk);
            }
          },
          onError: (Object e, StackTrace s) {
            if (!result.isCompleted) result.completeError(e, s);
          },
          onDone: () {
            if (!result.isCompleted) result.complete(bytes.takeBytes());
          },
        );
        Uint8List payload;
        try {
          payload = await Future.any([
            result.future,
            abort.future.then<Uint8List>((_) {
              if (!timedOut || isCancelled?.call() == true) {
                throw const TtsRequestCancelled();
              }
              throw const TtsRequestFailure('语音请求超时或已取消');
            }),
          ]);
        } finally {
          await subscription.cancel();
        }
        check();
        if (response.contentLength != null &&
            response.headers['content-encoding'] == null &&
            response.contentLength != payload.length) {
          throw const TtsRequestFailure('接口音频被截断');
        }
        return TtsAudio(payload, audioFormat(payload));
      } on TtsRequestCancelled {
        rethrow;
      } on TtsRequestFailure {
        rethrow;
      } catch (_) {
        check();
        if (attempt == 1) throw const TtsRequestFailure('语音网络请求失败，请检查接口与网络');
        await _wait(retryDelay, isCancelled);
      } finally {
        deadline.cancel();
        if (!abort.isCompleted) abort.complete();
        _active.remove(abort);
      }
    }
    throw const TtsRequestFailure('语音请求未完成');
  }

  Future<void> _wait(Duration delay, bool Function()? cancelled) async {
    var remaining = delay.inMilliseconds;
    while (remaining > 0) {
      if (cancelled?.call() == true) throw const TtsRequestCancelled();
      final step = remaining < 50 ? remaining : 50;
      await Future<void>.delayed(Duration(milliseconds: step));
      remaining -= step;
    }
  }
}
