import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../services/compatible_tts_client.dart';
import '../../services/reader_platform.dart';
import '../models/immersive_config.dart';

/// TTS 合成错误分类
enum TtsAdapterErrorKind {
  authFailed,
  rateLimited,
  invalidConfiguration,
  invalidAudioPayload,
  transientNetwork,
  cancelled,
}

/// TTS 适配器异常（脱敏：绝不含密钥或完整正文）
class TtsAdapterException implements Exception {
  final TtsAdapterErrorKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  const TtsAdapterException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
  });

  bool get isRetryable =>
      kind == TtsAdapterErrorKind.rateLimited ||
      kind == TtsAdapterErrorKind.transientNetwork;

  bool get isBlocking =>
      kind == TtsAdapterErrorKind.authFailed ||
      kind == TtsAdapterErrorKind.invalidConfiguration;

  @override
  String toString() => message;
}

/// 固化后的精确合成规格（与缓存 request_key 一一对应）
class RenderSpec {
  final String accountScope;
  final String providerId;
  final String adapterVersion;
  final String endpointUrl;
  final String modelKey;
  final String exactModelId;
  final String voiceProfileId;
  final String exactVoiceId;
  final String inputText;
  final String audioFormat;
  final double speed;
  final bool supportsSpeed;
  final String? instructions;
  final bool supportsInstructions;
  final Map<String, dynamic> extraBody;
  final Map<String, String> nonSecretExtraHeaders;
  final String preprocessVersion;
  final String renderSpecHash;
  final String requestKey;

  const RenderSpec({
    required this.accountScope,
    required this.providerId,
    required this.adapterVersion,
    required this.endpointUrl,
    required this.modelKey,
    required this.exactModelId,
    required this.voiceProfileId,
    required this.exactVoiceId,
    required this.inputText,
    required this.audioFormat,
    required this.speed,
    required this.supportsSpeed,
    required this.instructions,
    required this.supportsInstructions,
    required this.extraBody,
    required this.nonSecretExtraHeaders,
    required this.preprocessVersion,
    required this.renderSpecHash,
    required this.requestKey,
  });

  /// 由解析好的音色配置与精确朗读正文固化 RenderSpec（绝不含密钥/显示名/备注/playback_epoch）
  factory RenderSpec.fromResolution({
    required VoiceProfileResolution resolution,
    required String inputText,
    String accountScope = 'local_default',
    String preprocessVersion = 'v1',
  }) {
    final provider = resolution.provider;
    final model = resolution.model;
    final voice = resolution.voice;
    final url = joinProviderUrl(provider.baseUrl, provider.endpoint).toString();
    final mergedExtra = resolution.mergedExtraBody();

    final nonSecretHeaders = <String, String>{};
    provider.extraHeaders.forEach((k, v) {
      if (!ProtectedProtocolFields.headersLower.contains(k.toLowerCase())) {
        nonSecretHeaders[k] = v;
      }
    });

    final renderHash = resolution.computeRenderSpecHash(
      preprocessVersion: preprocessVersion,
    );

    // request_key：规范 JSON 序列化后取 SHA-256，严格区分 model_id / voice_id 大小写
    final keyMaterial = canonicalJsonEncode({
      'account_scope': accountScope,
      'provider_id': provider.providerId,
      'adapter_version': '${provider.adapter}:v1',
      'endpoint_url': url,
      'exact_model_id': model.modelId,
      'exact_voice_id': voice.voiceId,
      'input_text': inputText,
      'audio_format': voice.renderSettings.audioFormat,
      'speed': voice.renderSettings.speed,
      'instructions': voice.renderSettings.instructions,
      'extra_body': mergedExtra,
      'extra_headers': nonSecretHeaders,
      'preprocess_version': preprocessVersion,
    });
    final requestKey = sha256.convert(utf8.encode(keyMaterial)).toString();

    return RenderSpec(
      accountScope: accountScope,
      providerId: provider.providerId,
      adapterVersion: '${provider.adapter}:v1',
      endpointUrl: url,
      modelKey: model.modelKey,
      exactModelId: model.modelId,
      voiceProfileId: voice.voiceProfileId,
      exactVoiceId: voice.voiceId,
      inputText: inputText,
      audioFormat: voice.renderSettings.audioFormat,
      speed: voice.renderSettings.speed,
      supportsSpeed: model.capabilities.supportsSpeed,
      instructions: voice.renderSettings.instructions,
      supportsInstructions: model.capabilities.supportsInstructions,
      extraBody: mergedExtra,
      nonSecretExtraHeaders: nonSecretHeaders,
      preprocessVersion: preprocessVersion,
      renderSpecHash: renderHash,
      requestKey: requestKey,
    );
  }
}

/// 验证通过的可播放音频合成结果
class SynthesizedAudioPayload {
  final Uint8List bytes;
  final String detectedFormat;
  final int durationMs;
  final int latencyMs;

  const SynthesizedAudioPayload({
    required this.bytes,
    required this.detectedFormat,
    required this.durationMs,
    required this.latencyMs,
  });
}

/// 音色连接测试结果
class VoiceProfileTestResult {
  final bool success;
  final String message;
  final String? audioFormat;
  final int? durationMs;
  final int? byteLength;
  final int latencyMs;
  final Uint8List? audioBytes;

  const VoiceProfileTestResult({
    required this.success,
    required this.message,
    this.audioFormat,
    this.durationMs,
    this.byteLength,
    required this.latencyMs,
    this.audioBytes,
  });
}

/// TTS 供应商适配器抽象接口
abstract class TtsProviderAdapter {
  Future<SynthesizedAudioPayload> synthesize({
    required RenderSpec spec,
    required String apiKey,
    required int timeoutMs,
    bool Function()? isCancelled,
  });

  Future<VoiceProfileTestResult> testVoiceProfile({
    required VoiceProfileResolution resolution,
    required String apiKey,
    String sampleText = '你好，这是沉浸式听书音色连接测试。',
  });

  void cancelAll();
}

/// 音频完整性与时长验证工具（纯字节解析 + Android 原生 MediaMetadataRetriever）
class AudioFormatInspector {
  /// 校验音频二进制头部并计算时长（毫秒）；损坏或无法解码时抛出 TtsAdapterException
  static ({String format, int durationMs}) inspectBytes(Uint8List bytes) {
    if (bytes.length < 32) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidAudioPayload,
        message: '返回音频字节过短，无法解码',
      );
    }
    final String format;
    try {
      format = CompatibleTtsClient.audioFormat(bytes);
    } on TtsRequestFailure catch (e) {
      throw TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidAudioPayload,
        message: e.message,
      );
    }

    if (format == 'wav') {
      final durationMs = _wavDurationMs(bytes);
      if (durationMs <= 0) {
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidAudioPayload,
          message: 'WAV 音频时长无效',
        );
      }
      return (format: 'wav', durationMs: durationMs);
    }

    final mp3Ms = _mp3DurationMs(bytes);
    if (mp3Ms <= 0) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidAudioPayload,
        message: 'MP3 音频帧时长无效，无法播放',
      );
    }
    return (format: 'mp3', durationMs: mp3Ms);
  }

  /// 在 Android 平台上通过原生 MediaMetadataRetriever 二次校验文件可解码性与准确时长
  static Future<({bool valid, int durationMs})> probeFileOnPlatform(
    String filePath, {
    required int fallbackDurationMs,
  }) async {
    if (!ReaderPlatform.capabilities.mediaPlayback) {
      final exists = await File(filePath).exists();
      return (valid: exists && fallbackDurationMs > 0, durationMs: fallbackDurationMs);
    }
    try {
      final result = await ReaderPlatform.invoke<Map<dynamic, dynamic>>(
        'probeAudioDuration',
        {'filePath': filePath},
      );
      if (result == null) {
        return (valid: fallbackDurationMs > 0, durationMs: fallbackDurationMs);
      }
      final valid = result['valid'] == true;
      final dur = (result['durationMs'] as num?)?.toInt() ?? 0;
      if (!valid || dur <= 0) {
        return (valid: false, durationMs: 0);
      }
      return (valid: true, durationMs: dur);
    } catch (_) {
      // 单元测试无原生插件实现时回退字节帧解析时长
      return (valid: fallbackDurationMs > 0, durationMs: fallbackDurationMs);
    }
  }

  static int _wavDurationMs(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    var at = 12;
    var byteRate = 0;
    var dataBytes = 0;
    while (at + 8 <= bytes.length) {
      final size = bd.getUint32(at + 4, Endian.little);
      if (size > bytes.length - at - 8) break;
      final tag = ascii.decode(bytes.sublist(at, at + 4), allowInvalid: true);
      if (tag == 'fmt ' && size >= 16) {
        byteRate = bd.getUint32(at + 16, Endian.little);
      } else if (tag == 'data') {
        dataBytes += size;
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (byteRate <= 0 || dataBytes <= 0) return 0;
    return ((dataBytes * 1000) / byteRate).round().clamp(1, 3600000);
  }

  static int _mp3DurationMs(Uint8List bytes) {
    var i = 0;
    if (bytes.length >= 10 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      final tagSize =
          (bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9];
      i = 10 + tagSize;
    }

    var totalSamples = 0;
    var sampleRate = 0;
    var frames = 0;

    while (i + 4 <= bytes.length) {
      if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
        final versionBits = (bytes[i + 1] >> 3) & 3;
        final layerBits = (bytes[i + 1] >> 1) & 3;
        final bitrateIdx = (bytes[i + 2] >> 4) & 0x0F;
        final sampleIdx = (bytes[i + 2] >> 2) & 3;
        final padding = (bytes[i + 2] >> 1) & 1;

        if (versionBits != 1 &&
            layerBits == 1 &&
            bitrateIdx > 0 &&
            bitrateIdx < 15 &&
            sampleIdx < 3) {
          final isMpeg1 = versionBits == 3;
          final rates = isMpeg1
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
          final baseSample = const [44100, 48000, 32000][sampleIdx];
          final sr = isMpeg1
              ? baseSample
              : (versionBits == 2 ? baseSample ~/ 2 : baseSample ~/ 4);
          final frameLen =
              ((isMpeg1 ? 144 : 72) * rates[bitrateIdx] * 1000 ~/ sr) + padding;
          if (frameLen > 4 && i + frameLen <= bytes.length) {
            sampleRate = sr;
            totalSamples += isMpeg1 ? 1152 : 576;
            frames++;
            i += frameLen;
            continue;
          }
        }
      }
      i++;
      // 若扫描很长一段都找不到有效帧头则退出
      if (frames == 0 && i > 4096) break;
    }

    if (frames == 0 || sampleRate <= 0) return 0;
    return ((totalSamples * 1000) / sampleRate).round().clamp(1, 3600000);
  }
}

/// OpenAI Speech 兼容完整文件 TTS 适配器（严格保持大小写与参数契约）
class OpenAiSpeechTtsAdapter implements TtsProviderAdapter {
  static const maxAudioBytes = 16 * 1024 * 1024;

  final http.Client _client;
  final Set<Completer<void>> _active = {};

  OpenAiSpeechTtsAdapter(this._client);

  @override
  void cancelAll() {
    for (final c in _active.toList()) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// 构建对外 POST /audio/speech 请求体（校验受保护字段、null 省略、能力约束）
  static Map<String, dynamic> buildRequestBody(RenderSpec spec) {
    for (final k in spec.extraBody.keys) {
      if (ProtectedProtocolFields.ttsBody.contains(k)) {
        throw TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidConfiguration,
          message: 'TTS extra_body 禁止覆盖受保护字段 $k',
        );
      }
    }
    if (!spec.supportsInstructions &&
        spec.instructions != null &&
        spec.instructions!.trim().isNotEmpty) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidConfiguration,
        message: '模型不支持 instructions 参数，已拒绝请求',
      );
    }
    if (!spec.supportsSpeed && (spec.speed - 1.0).abs() > 1e-6) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidConfiguration,
        message: '模型不支持非默认 speed 参数，已拒绝请求',
      );
    }

    final body = <String, dynamic>{
      ...spec.extraBody,
      'model': spec.exactModelId,
      'voice': spec.exactVoiceId,
      'input': spec.inputText,
      'response_format': spec.audioFormat,
    };

    if (spec.supportsSpeed) {
      body['speed'] = spec.speed;
    }
    if (spec.supportsInstructions &&
        spec.instructions != null &&
        spec.instructions!.isNotEmpty) {
      body['instructions'] = spec.instructions;
    }
    return body;
  }

  @override
  Future<SynthesizedAudioPayload> synthesize({
    required RenderSpec spec,
    required String apiKey,
    required int timeoutMs,
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.cancelled,
        message: 'TTS 请求已取消',
      );
    }
    if (isExampleReservedEndpoint(spec.endpointUrl) ||
        isTemplatePlaceholderValue(spec.exactModelId) ||
        isTemplatePlaceholderValue(spec.exactVoiceId) ||
        isTemplatePlaceholderValue(apiKey)) {
      throw const TtsAdapterException(
        kind: TtsAdapterErrorKind.invalidConfiguration,
        message: 'TTS 配置包含示例占位值，已拒绝发出真实请求',
      );
    }

    final uri = Uri.parse(spec.endpointUrl);
    final body = buildRequestBody(spec);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      ...spec.nonSecretExtraHeaders,
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };

    final abort = Completer<void>();
    _active.add(abort);
    var timedOut = false;
    final sw = Stopwatch()..start();
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });

    try {
      final request = http.AbortableRequest('POST', uri, abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll(headers)
        ..body = jsonEncode(body);

      final sending = _client.send(request);
      unawaited(
        sending.then<void>((resp) async {
          if (abort.isCompleted) {
            await resp.stream.listen((_) {}).cancel();
          }
        }, onError: (Object _, StackTrace _) {}),
      );

      final response = await Future.any<http.StreamedResponse>([
        sending,
        abort.future.then<http.StreamedResponse>((_) {
          if (!timedOut || isCancelled?.call() == true) {
            throw const TtsAdapterException(
              kind: TtsAdapterErrorKind.cancelled,
              message: 'TTS 请求已取消',
            );
          }
          throw const TtsAdapterException(
            kind: TtsAdapterErrorKind.transientNetwork,
            message: 'TTS 合成请求超时',
          );
        }),
      ]);

      final status = response.statusCode;
      if (status != 200) {
        await response.stream.listen((_) {}).cancel();
        if (status >= 300 && status < 400) {
          throw TtsAdapterException(
            kind: TtsAdapterErrorKind.invalidConfiguration,
            message: 'TTS 接口重定向已拒绝（HTTP $status），避免转发凭证',
            statusCode: status,
          );
        }
        if (status == 401 || status == 403) {
          throw TtsAdapterException(
            kind: TtsAdapterErrorKind.authFailed,
            message: 'TTS 接口鉴权失败（HTTP $status），请检查密钥或权限',
            statusCode: status,
          );
        }
        if (status == 404 || status == 400 || status == 422) {
          throw TtsAdapterException(
            kind: TtsAdapterErrorKind.invalidConfiguration,
            message: 'TTS 模型或音色配置被服务端拒绝（HTTP $status）',
            statusCode: status,
          );
        }
        if (status == 429) {
          final raSec = int.tryParse(response.headers['retry-after'] ?? '');
          throw TtsAdapterException(
            kind: TtsAdapterErrorKind.rateLimited,
            message: 'TTS 接口触发限流（HTTP 429）',
            statusCode: status,
            retryAfter: raSec == null ? null : Duration(seconds: raSec.clamp(1, 60)),
          );
        }
        throw TtsAdapterException(
          kind: TtsAdapterErrorKind.transientNetwork,
          message: 'TTS 接口返回异常 HTTP $status',
          statusCode: status,
        );
      }

      final ct = (response.headers['content-type'] ?? '').toLowerCase();
      if (ct.contains('json') || ct.contains('html') || ct.startsWith('text/')) {
        await response.stream.listen((_) {}).cancel();
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidAudioPayload,
          message: 'TTS 接口返回文本/JSON 而非有效音频二进制流',
        );
      }
      if ((response.contentLength ?? 0) > maxAudioBytes) {
        await response.stream.listen((_) {}).cancel();
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidAudioPayload,
          message: 'TTS 响应体积超过 16 MB 上限',
        );
      }

      final builder = BytesBuilder(copy: false);
      final done = Completer<Uint8List>();
      StreamSubscription<List<int>>? sub;
      sub = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          if (builder.length + chunk.length > maxAudioBytes) {
            done.completeError(
              const TtsAdapterException(
                kind: TtsAdapterErrorKind.invalidAudioPayload,
                message: 'TTS 响应体积超过 16 MB 上限',
              ),
            );
            unawaited(sub?.cancel());
          } else {
            builder.add(chunk);
          }
        },
        onError: (Object e, StackTrace s) {
          if (!done.isCompleted) done.completeError(e, s);
        },
        onDone: () {
          if (!done.isCompleted) done.complete(builder.takeBytes());
        },
      );

      final Uint8List payload;
      try {
        payload = await Future.any<Uint8List>([
          done.future,
          abort.future.then<Uint8List>((_) {
            if (!timedOut || isCancelled?.call() == true) {
              throw const TtsAdapterException(
                kind: TtsAdapterErrorKind.cancelled,
                message: 'TTS 请求已取消',
              );
            }
            throw const TtsAdapterException(
              kind: TtsAdapterErrorKind.transientNetwork,
              message: 'TTS 下载超时',
            );
          }),
        ]);
      } finally {
        await sub.cancel();
      }

      if (response.contentLength != null &&
          response.headers['content-encoding'] == null &&
          response.contentLength != payload.length) {
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.invalidAudioPayload,
          message: 'TTS 音频响应长度不完整（已截断）',
        );
      }

      final inspected = AudioFormatInspector.inspectBytes(payload);
      sw.stop();
      return SynthesizedAudioPayload(
        bytes: payload,
        detectedFormat: inspected.format,
        durationMs: inspected.durationMs,
        latencyMs: sw.elapsedMilliseconds,
      );
    } on TtsAdapterException {
      rethrow;
    } catch (e) {
      if (isCancelled?.call() == true) {
        throw const TtsAdapterException(
          kind: TtsAdapterErrorKind.cancelled,
          message: 'TTS 请求已取消',
        );
      }
      throw TtsAdapterException(
        kind: TtsAdapterErrorKind.transientNetwork,
        message: 'TTS 网络请求失败：$e',
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _active.remove(abort);
    }
  }

  @override
  Future<VoiceProfileTestResult> testVoiceProfile({
    required VoiceProfileResolution resolution,
    required String apiKey,
    String sampleText = '你好，这是沉浸式听书音色连接测试。',
  }) async {
    final sw = Stopwatch()..start();
    try {
      final spec = RenderSpec.fromResolution(
        resolution: resolution,
        inputText: sampleText,
      );
      final audio = await synthesize(
        spec: spec,
        apiKey: apiKey,
        timeoutMs: resolution.provider.requestTimeoutMs.clamp(10000, 60000),
      );
      sw.stop();
      return VoiceProfileTestResult(
        success: true,
        message:
            '音色在线合成通过（model=${spec.exactModelId}, voice=${spec.exactVoiceId}, ${audio.detectedFormat.toUpperCase()} ${(audio.durationMs / 1000).toStringAsFixed(1)}s, ${sw.elapsedMilliseconds}ms）',
        audioFormat: audio.detectedFormat,
        durationMs: audio.durationMs,
        byteLength: audio.bytes.length,
        latencyMs: sw.elapsedMilliseconds,
        audioBytes: audio.bytes,
      );
    } on TtsAdapterException catch (e) {
      sw.stop();
      return VoiceProfileTestResult(
        success: false,
        message: e.message,
        latencyMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return VoiceProfileTestResult(
        success: false,
        message: '音色连接测试失败：$e',
        latencyMs: sw.elapsedMilliseconds,
      );
    }
  }
}
