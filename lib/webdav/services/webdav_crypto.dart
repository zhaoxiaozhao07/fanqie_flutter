import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// WebDAV 云端敏感配置加解密异常
class WebDavCryptoException implements Exception {
  final String message;
  const WebDavCryptoException(this.message);

  @override
  String toString() => message;
}

/// WebDAV 云端敏感数据端到端加解密工具（PBKDF2-HMAC-SHA256 + AES-256-GCM）
/// 用于保护上传至远端 WebDAV 的 AI 密钥配置，确保云端存储零明文 API Key。
class WebDavCrypto {
  static const String cipherName = 'PBKDF2-HMAC-SHA256/AES-256-GCM';
  static const int defaultIterations = 50000;
  static const int _saltBytes = 16;
  static const int _ivBytes = 12;
  static const int _keyBytes = 32;
  static const int _tagBits = 128;

  static final Random _secureRandom = Random.secure();

  static bool isEncryptedEnvelope(Map<String, dynamic> map) {
    return map['encrypted'] == true &&
        map['ciphertext'] is String &&
        map['salt'] is String &&
        map['iv'] is String;
  }

  /// 将明文 JSON 荷载使用口令加密为标准认证加密信封（外层可附带非敏感元信息）
  static Map<String, dynamic> encryptJson(
    Map<String, dynamic> plainPayload, {
    required String passphrase,
    int iterations = defaultIterations,
    Map<String, dynamic>? outerMetadata,
  }) {
    if (passphrase.isEmpty) {
      throw const WebDavCryptoException('端到端加密口令不能为空');
    }
    final salt = _randomBytes(_saltBytes);
    final iv = _randomBytes(_ivBytes);
    final key = _deriveKey(passphrase, salt, iterations);

    final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(plainPayload)));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), _tagBits, iv, Uint8List(0)),
      );
    final ciphertext = cipher.process(plaintext);

    return {
      'version': 2,
      'encrypted': true,
      'cipher': cipherName,
      'iterations': iterations,
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'ciphertext': base64Encode(ciphertext),
      if (outerMetadata != null) ...outerMetadata,
    };
  }

  /// 解密认证加密信封并校验完整性标签；口令不匹配或数据被篡改将抛出异常
  static Map<String, dynamic> decryptJson(
    Map<String, dynamic> envelope, {
    required String passphrase,
  }) {
    if (!isEncryptedEnvelope(envelope)) {
      throw const WebDavCryptoException('不是有效的 WebDAV 加密信封');
    }
    if (passphrase.isEmpty) {
      throw const WebDavCryptoException('缺少解密口令，无法还原云端加密配置');
    }
    try {
      final iterations =
          (envelope['iterations'] as num?)?.toInt() ?? defaultIterations;
      if (iterations < 1000 || iterations > 500000) {
        throw const WebDavCryptoException('加密迭代参数不合法');
      }
      final salt = Uint8List.fromList(base64Decode(envelope['salt'] as String));
      final iv = Uint8List.fromList(base64Decode(envelope['iv'] as String));
      final ciphertext = Uint8List.fromList(
        base64Decode(envelope['ciphertext'] as String),
      );
      final key = _deriveKey(passphrase, salt, iterations);

      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), _tagBits, iv, Uint8List(0)),
        );
      final plainBytes = cipher.process(ciphertext);
      final decoded = jsonDecode(utf8.decode(plainBytes));
      if (decoded is! Map) {
        throw const WebDavCryptoException('解密后的云端配置不是合法 JSON 对象');
      }
      return Map<String, dynamic>.from(decoded);
    } on WebDavCryptoException {
      rethrow;
    } catch (_) {
      throw const WebDavCryptoException(
        '云端加密配置解密失败，请确认 WebDAV 密码或同步加密口令与上传时一致',
      );
    }
  }

  static Uint8List _deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, _keyBytes));
    return derivator.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _secureRandom.nextInt(256);
    }
    return out;
  }
}
