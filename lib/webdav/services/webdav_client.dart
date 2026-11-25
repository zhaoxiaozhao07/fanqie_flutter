import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../models/webdav_config.dart';

/// WebDAV 网络或协议异常（错误描述不含密码与内置目录名）
class WebDavException implements Exception {
  final String message;
  final int? statusCode;
  final Object? cause;

  const WebDavException(this.message, {this.statusCode, this.cause});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// WebDAV 乐观锁并发冲突异常（HTTP 412 或 ETag 不匹配）
class WebDavPreconditionFailedException extends WebDavException {
  final String? expectedEtag;
  final String? actualEtag;

  const WebDavPreconditionFailedException(
    super.message, {
    this.expectedEtag,
    this.actualEtag,
  }) : super(statusCode: 412);
}

/// WebDAV 远端文件或目录条目
class WebDavRemoteEntry {
  final String name;
  final String href;
  final bool isDirectory;
  final int contentLength;
  final String? etag;
  final DateTime? lastModified;

  const WebDavRemoteEntry({
    required this.name,
    required this.href,
    required this.isDirectory,
    this.contentLength = 0,
    this.etag,
    this.lastModified,
  });
}

/// 标准 RFC 4918 WebDAV 客户端（内部自动隔离至隐藏根目录 FanQieReader）
class WebDavClient {
  final String serverUrl;
  final String username;
  final String password;
  final Duration timeout;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;

  WebDavClient({
    required String serverUrl,
    required this.username,
    required this.password,
    this.timeout = const Duration(seconds: 30),
    HttpClient? httpClient,
  }) : serverUrl = WebDavConfig.normalizeServerUrl(serverUrl),
       _httpClient =
           httpClient ??
           (HttpClient()..connectionTimeout = const Duration(seconds: 20)),
       _ownsHttpClient = httpClient == null;

  factory WebDavClient.fromConfig(
    WebDavConfig config, {
    Duration timeout = const Duration(seconds: 30),
    HttpClient? httpClient,
  }) {
    return WebDavClient(
      serverUrl: config.normalizedServerUrl,
      username: config.username.trim(),
      password: config.password,
      timeout: timeout,
      httpClient: httpClient,
    );
  }

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close(force: true);
    }
  }

  /// 构造根地址 URI（仅用于连接连通性验证）
  Uri _buildRootUri() {
    if (serverUrl.isEmpty) {
      throw const WebDavException('请先填写 WebDAV 服务器地址');
    }
    final parsed = Uri.tryParse(serverUrl);
    if (parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const WebDavException('WebDAV 服务器地址格式不正确，请使用 http:// 或 https://');
    }
    final basePath = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed.replace(path: basePath);
  }

  /// 构造隐藏根目录（FanQieReader）下的完整资源 URI
  Uri buildAppUri(String relativePath, {bool isDirectory = false}) {
    final root = _buildRootUri();
    final segments = <String>[
      ...root.pathSegments.where((s) => s.isNotEmpty),
      WebDavConfig.hiddenRootFolder,
      ...relativePath
          .split('/')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty),
    ];
    final encoded = segments.map(Uri.encodeComponent).join('/');
    final fullPath = isDirectory ? '/$encoded/' : '/$encoded';
    return root.replace(path: fullPath);
  }

  /// 测试连接并初始化隐藏同步目录结构
  Future<WebDavConnectionTestResult> testConnection() async {
    final sw = Stopwatch()..start();
    try {
      final rootUri = _buildRootUri();
      final probeResp = await _sendRaw(
        'PROPFIND',
        rootUri,
        headers: const {'Depth': '0'},
      );
      if (probeResp.statusCode == 401 || probeResp.statusCode == 403) {
        sw.stop();
        return WebDavConnectionTestResult(
          success: false,
          message: '账号或密码校验失败，请检查 WebDAV 凭据',
          statusCode: probeResp.statusCode,
          durationMs: sw.elapsedMilliseconds,
        );
      }
      if (probeResp.statusCode != 207 &&
          probeResp.statusCode != 200 &&
          probeResp.statusCode != 204) {
        // 部分服务端禁止对根路径发 PROPFIND，降级使用 OPTIONS 检查
        final optResp = await _sendRaw('OPTIONS', rootUri);
        if (optResp.statusCode == 401 || optResp.statusCode == 403) {
          sw.stop();
          return WebDavConnectionTestResult(
            success: false,
            message: '账号或密码校验失败，请检查 WebDAV 凭据',
            statusCode: optResp.statusCode,
            durationMs: sw.elapsedMilliseconds,
          );
        }
        if (optResp.statusCode < 200 || optResp.statusCode >= 300) {
          sw.stop();
          return WebDavConnectionTestResult(
            success: false,
            message: '服务器返回异常状态码 HTTP ${optResp.statusCode}',
            statusCode: optResp.statusCode,
            durationMs: sw.elapsedMilliseconds,
          );
        }
      }

      // 确保内置目录与离线书籍子目录可正常访问或创建
      await ensureAppDirectories();
      sw.stop();
      return WebDavConnectionTestResult(
        success: true,
        message: 'WebDAV 连接测试通过（耗时 ${sw.elapsedMilliseconds}ms）',
        statusCode: 200,
        durationMs: sw.elapsedMilliseconds,
      );
    } on WebDavException catch (e) {
      sw.stop();
      return WebDavConnectionTestResult(
        success: false,
        message: e.message,
        statusCode: e.statusCode,
        durationMs: sw.elapsedMilliseconds,
      );
    } on SocketException catch (e) {
      sw.stop();
      return WebDavConnectionTestResult(
        success: false,
        message: '无法连接 WebDAV 服务器：${e.message}',
        durationMs: sw.elapsedMilliseconds,
      );
    } on HandshakeException catch (e) {
      sw.stop();
      return WebDavConnectionTestResult(
        success: false,
        message: 'HTTPS 证书握手失败：${e.message}',
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      sw.stop();
      return WebDavConnectionTestResult(
        success: false,
        message: '连接 WebDAV 服务器超时，请检查网络或地址',
        durationMs: sw.elapsedMilliseconds,
      );
    } catch (e) {
      sw.stop();
      return WebDavConnectionTestResult(
        success: false,
        message: '连接测试失败：$e',
        durationMs: sw.elapsedMilliseconds,
      );
    }
  }

  /// 确保内置同步根目录与离线书籍子目录存在
  Future<void> ensureAppDirectories() async {
    await ensureDirectory('');
    await ensureDirectory(WebDavConfig.booksSubFolder);
  }

  /// 逐级确保隐藏根目录下的指定子目录存在（relativeDir 为空表示内置根目录本身）
  Future<void> ensureDirectory(String relativeDir) async {
    final parts = relativeDir
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 先确保隐藏根目录本身
    await _ensureSingleDirectory(buildAppUri('', isDirectory: true));

    // 再逐级创建子目录
    final acc = <String>[];
    for (final part in parts) {
      acc.add(part);
      await _ensureSingleDirectory(
        buildAppUri(acc.join('/'), isDirectory: true),
      );
    }
  }

  Future<void> _ensureSingleDirectory(Uri dirUri) async {
    final check = await _sendRaw(
      'PROPFIND',
      dirUri,
      headers: const {'Depth': '0'},
    );
    if (check.statusCode == 207 || check.statusCode == 200) {
      return;
    }
    if (check.statusCode == 401 || check.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: check.statusCode);
    }
    final mk = await _sendRaw('MKCOL', dirUri);
    if (mk.statusCode == 201 ||
        mk.statusCode == 200 ||
        mk.statusCode == 204 ||
        mk.statusCode == 405) {
      return;
    }
    // 并发或部分服务端返回 301/409 时二次确认是否已存在
    if (mk.statusCode == 301 || mk.statusCode == 409) {
      final recheck = await _sendRaw(
        'PROPFIND',
        dirUri,
        headers: const {'Depth': '0'},
      );
      if (recheck.statusCode == 207 || recheck.statusCode == 200) {
        return;
      }
    }
    throw WebDavException('初始化远端同步目录失败', statusCode: mk.statusCode);
  }

  /// 列出隐藏根目录下某个目录中的条目（不包含目录自身）
  Future<List<WebDavRemoteEntry>> listDirectory(String relativeDir) async {
    final dirUri = buildAppUri(relativeDir, isDirectory: true);
    final resp = await _sendRaw(
      'PROPFIND',
      dirUri,
      headers: const {'Depth': '1'},
    );
    if (resp.statusCode == 404) {
      return const [];
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode != 207 && resp.statusCode != 200) {
      throw WebDavException('列举远端同步目录失败', statusCode: resp.statusCode);
    }
    final xmlText = utf8.decode(resp.bytes, allowMalformed: true);
    return parseMultistatusXml(xmlText, requestPath: dirUri.path);
  }

  /// 统一规范化强/弱 ETag（去除 W/ 前缀便于跨请求准确比对）
  static String? normalizeEtag(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('W/') || s.startsWith('w/')) {
      s = s.substring(2).trim();
    }
    return s.isEmpty ? null : s;
  }

  /// 查询远端文件 ETag（不存在返回 null）
  Future<String?> headEtag(String relativePath) async {
    final uri = buildAppUri(relativePath);
    final resp = await _sendRaw('HEAD', uri);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return null;
    }
    return normalizeEtag(resp.etag);
  }

  /// 读取远端二进制字节；文件不存在时返回 null
  Future<List<int>?> getBytes(String relativePath) async {
    final res = await _getBytesWithEtag(relativePath);
    return res?.bytes;
  }

  Future<({List<int> bytes, String? etag})?> _getBytesWithEtag(
    String relativePath,
  ) async {
    final uri = buildAppUri(relativePath);
    final resp = await _sendRaw('GET', uri);
    if (resp.statusCode == 404) return null;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WebDavException('读取远端数据失败', statusCode: resp.statusCode);
    }
    return (bytes: resp.bytes, etag: normalizeEtag(resp.etag));
  }

  /// 读取远端 UTF-8 JSON 对象；文件不存在时返回 null
  Future<Map<String, dynamic>?> getJson(String relativePath) async {
    final res = await getJsonWithEtag(relativePath);
    return res.data;
  }

  /// 读取远端 UTF-8 JSON 对象及对应 ETag（用于并发乐观锁校验）
  Future<({Map<String, dynamic>? data, String? etag})> getJsonWithEtag(
    String relativePath,
  ) async {
    final raw = await _getBytesWithEtag(relativePath);
    if (raw == null) return (data: null, etag: null);
    try {
      final decoded = jsonDecode(utf8.decode(raw.bytes));
      if (decoded is Map) {
        return (data: Map<String, dynamic>.from(decoded), etag: raw.etag);
      }
      throw const FormatException('远端数据格式不是有效的 JSON 对象');
    } catch (e) {
      throw WebDavException('解析远端同步数据失败：$e', cause: e);
    }
  }

  /// 上传字节到远端文件（覆盖写，支持可选 If-Match 乐观锁）
  Future<String?> putBytes(
    String relativePath,
    List<int> bytes, {
    String contentType = 'application/octet-stream',
    String? ifMatchEtag,
  }) async {
    final uri = buildAppUri(relativePath);
    final headers = <String, String>{
      'Content-Type': contentType,
      if (ifMatchEtag != null && ifMatchEtag.isNotEmpty)
        'If-Match': ifMatchEtag,
    };
    final resp = await _sendRaw('PUT', uri, headers: headers, bodyBytes: bytes);
    if (resp.statusCode == 412) {
      throw WebDavPreconditionFailedException(
        '远端文件已被其他设备更新，需重新拉取合并',
        expectedEtag: ifMatchEtag,
      );
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WebDavException('上传远端数据失败', statusCode: resp.statusCode);
    }
    return normalizeEtag(resp.etag);
  }

  /// 上传 JSON 对象到远端文件
  Future<String?> putJson(
    String relativePath,
    Map<String, dynamic> data, {
    String? ifMatchEtag,
  }) async {
    final bytes = utf8.encode(jsonEncode(data));
    return putBytes(
      relativePath,
      bytes,
      contentType: 'application/json; charset=utf-8',
      ifMatchEtag: ifMatchEtag,
    );
  }

  /// 远端原子 MOVE（支持 Overwrite 覆盖）
  Future<bool> move(
    String fromRelative,
    String toRelative, {
    bool overwrite = true,
  }) async {
    final fromUri = buildAppUri(fromRelative);
    final toUri = buildAppUri(toRelative);
    final resp = await _sendRaw(
      'MOVE',
      fromUri,
      headers: {
        'Destination': toUri.toString(),
        'Overwrite': overwrite ? 'T' : 'F',
      },
    );
    if (resp.statusCode == 405 || resp.statusCode == 501) {
      return false;
    }
    if (resp.statusCode == 412) {
      throw const WebDavPreconditionFailedException('远端目标已变更，原子移动被拒绝');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WebDavException('远端原子移动失败', statusCode: resp.statusCode);
    }
    return true;
  }

  /// 原子写入 JSON：先执行 ETag 乐观锁核验，再先 PUT 临时文件后 MOVE 覆盖目标；
  /// 若服务端不支持 MOVE 则自动降级为带 If-Match 的直接 PUT。
  Future<String?> putJsonAtomic(
    String relativePath,
    Map<String, dynamic> data, {
    String? expectedEtag,
  }) async {
    final normExpected = normalizeEtag(expectedEtag);
    if (normExpected != null) {
      // 双重乐观锁：即使服务端忽略 If-Match，也能在覆盖前发现并发写冲突
      final currentEtag = await headEtag(relativePath);
      if (currentEtag != null && currentEtag != normExpected) {
        throw WebDavPreconditionFailedException(
          '检测到其他设备刚刚更新了云端数据',
          expectedEtag: normExpected,
          actualEtag: currentEtag,
        );
      }
    }

    final bytes = utf8.encode(jsonEncode(data));
    final tmpPath = '$relativePath.tmp.${DateTime.now().microsecondsSinceEpoch}';
    try {
      await putBytes(
        tmpPath,
        bytes,
        contentType: 'application/json; charset=utf-8',
      );
      final moved = await move(tmpPath, relativePath, overwrite: true);
      if (moved) {
        return await headEtag(relativePath);
      }
      // 服务端不支持 MOVE，清理临时文件后回退为带 If-Match 直接 PUT
      await delete(tmpPath).catchError((_) {});
      return await putBytes(
        relativePath,
        bytes,
        contentType: 'application/json; charset=utf-8',
        ifMatchEtag: normExpected,
      );
    } catch (e) {
      await delete(tmpPath).catchError((_) {});
      rethrow;
    }
  }

  /// 流式上传本地文件（适合较大的离线书籍归档，避免整文件读入内存）
  Future<void> putFile(
    String relativePath,
    File file, {
    String contentType = 'application/zip',
    void Function(int sent, int total)? onProgress,
  }) async {
    final uri = buildAppUri(relativePath);
    final length = await file.length();
    var target = uri;
    for (var hop = 0; hop < 3; hop++) {
      final request = await _httpClient.openUrl('PUT', target).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('Authorization', _authHeader, preserveHeaderCase: true);
      request.headers.set(
        'User-Agent',
        'FanQieReader-WebDAV/1.0',
        preserveHeaderCase: true,
      );
      request.headers.set('Content-Type', contentType, preserveHeaderCase: true);
      request.contentLength = length;
      var sent = 0;
      await for (final chunk in file.openRead()) {
        request.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent, length);
      }
      final response = await request.close().timeout(timeout);
      final body = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (_isRedirect(response.statusCode)) {
        final next = _resolveSafeRedirect(target, response.headers.value('location'));
        if (next != null) {
          target = next;
          continue;
        }
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw WebDavException(
          'WebDAV 鉴权失败，请检查账号密码',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = utf8.decode(body, allowMalformed: true).trim();
        throw WebDavException(
          detail.isEmpty ? '上传离线书籍失败' : '上传离线书籍失败：$detail',
          statusCode: response.statusCode,
        );
      }
      return;
    }
    throw const WebDavException('上传离线书籍时重定向次数过多');
  }

  /// 流式下载远端文件到本地（先写临时文件再原子重命名）；文件不存在返回 false
  Future<bool> downloadToFile(
    String relativePath,
    File destination, {
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = buildAppUri(relativePath);
    var target = uri;
    for (var hop = 0; hop < 3; hop++) {
      final request = await _httpClient.openUrl('GET', target).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('Authorization', _authHeader, preserveHeaderCase: true);
      request.headers.set(
        'User-Agent',
        'FanQieReader-WebDAV/1.0',
        preserveHeaderCase: true,
      );
      final response = await request.close().timeout(timeout);
      if (_isRedirect(response.statusCode)) {
        await response.drain<void>();
        final next = _resolveSafeRedirect(target, response.headers.value('location'));
        if (next != null) {
          target = next;
          continue;
        }
      }
      if (response.statusCode == 404) {
        await response.drain<void>();
        return false;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        await response.drain<void>();
        throw WebDavException(
          'WebDAV 鉴权失败，请检查账号密码',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw WebDavException('下载远端文件失败', statusCode: response.statusCode);
      }

      await destination.parent.create(recursive: true);
      final tempFile = File(
        '${destination.path}.part.${DateTime.now().microsecondsSinceEpoch}',
      );
      final sink = tempFile.openWrite();
      final total = response.contentLength;
      var received = 0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
        if (await destination.exists()) {
          await destination.delete();
        }
        await tempFile.rename(destination.path);
        return true;
      } catch (e) {
        await sink.close().catchError((_) {});
        if (await tempFile.exists()) {
          await tempFile.delete().catchError((_) => tempFile);
        }
        rethrow;
      }
    }
    throw const WebDavException('下载远端文件时重定向次数过多');
  }

  /// 删除远端文件或目录（404 视为已删除）
  Future<void> delete(String relativePath) async {
    final uri = buildAppUri(relativePath);
    final resp = await _sendRaw('DELETE', uri);
    if (resp.statusCode == 404) return;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw WebDavException('WebDAV 鉴权失败，请检查账号密码', statusCode: resp.statusCode);
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw WebDavException('删除远端文件失败', statusCode: resp.statusCode);
    }
  }

  Future<_RawResponse> _sendRaw(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? bodyBytes,
  }) async {
    var target = uri;
    for (var hop = 0; hop < 3; hop++) {
      final request = await _httpClient
          .openUrl(method, target)
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set('Authorization', _authHeader, preserveHeaderCase: true);
      request.headers.set(
        'User-Agent',
        'FanQieReader-WebDAV/1.0',
        preserveHeaderCase: true,
      );
      headers?.forEach((k, v) {
        request.headers.set(k, v, preserveHeaderCase: true);
      });
      if (bodyBytes != null) {
        request.contentLength = bodyBytes.length;
        request.add(bodyBytes);
      }
      final response = await request.close().timeout(timeout);
      final bytes = await response
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(timeout);
      if (_isRedirect(response.statusCode)) {
        final next = _resolveSafeRedirect(
          target,
          response.headers.value('location'),
        );
        if (next != null) {
          target = next;
          continue;
        }
      }
      return _RawResponse(
        response.statusCode,
        bytes,
        etag: response.headers.value('etag'),
      );
    }
    throw const WebDavException('WebDAV 请求重定向次数过多');
  }

  static bool _isRedirect(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  /// 仅允许同源重定向，避免 Basic Auth 凭据泄露至第三方域名
  static Uri? _resolveSafeRedirect(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) return null;
    final resolved = current.resolve(location.trim());
    if (resolved.host.toLowerCase() != current.host.toLowerCase() ||
        resolved.port != current.port ||
        resolved.scheme != current.scheme) {
      return null;
    }
    return resolved;
  }

  /// 解析标准 WebDAV 207 Multi-Status XML（兼容任意 XML 命名空间前缀）
  static List<WebDavRemoteEntry> parseMultistatusXml(
    String xmlText, {
    required String requestPath,
  }) {
    if (xmlText.trim().isEmpty) return const [];
    final doc = XmlDocument.parse(xmlText);
    final normalizedSelf = _normalizePath(requestPath);
    final entries = <WebDavRemoteEntry>[];

    for (final respEl in doc.descendants.whereType<XmlElement>()) {
      if (respEl.name.local.toLowerCase() != 'response') continue;
      final hrefEl = _firstChildByLocal(respEl, 'href');
      if (hrefEl == null) continue;
      final rawHref = hrefEl.innerText.trim();
      final decodedHref = _safeDecodePath(rawHref);
      if (_normalizePath(decodedHref) == normalizedSelf) continue;

      final propstat = _firstChildByLocal(respEl, 'propstat');
      final prop = propstat == null ? null : _firstChildByLocal(propstat, 'prop');

      var isDir = decodedHref.endsWith('/');
      String displayName = '';
      var contentLength = 0;
      String? etag;
      DateTime? lastModified;

      if (prop != null) {
        final rt = _firstChildByLocal(prop, 'resourcetype');
        if (rt != null && _firstChildByLocal(rt, 'collection') != null) {
          isDir = true;
        }
        final dn = _firstChildByLocal(prop, 'displayname');
        if (dn != null && dn.innerText.trim().isNotEmpty) {
          displayName = dn.innerText.trim();
        }
        final cl = _firstChildByLocal(prop, 'getcontentlength');
        if (cl != null) {
          contentLength = int.tryParse(cl.innerText.trim()) ?? 0;
        }
        final et = _firstChildByLocal(prop, 'getetag');
        if (et != null && et.innerText.trim().isNotEmpty) {
          etag = et.innerText.trim();
        }
        final lm = _firstChildByLocal(prop, 'getlastmodified');
        if (lm != null && lm.innerText.trim().isNotEmpty) {
          try {
            lastModified = HttpDate.parse(lm.innerText.trim());
          } catch (_) {
            lastModified = DateTime.tryParse(lm.innerText.trim());
          }
        }
      }

      if (displayName.isEmpty) {
        final segs = decodedHref
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList();
        displayName = segs.isEmpty ? decodedHref : segs.last;
      }

      entries.add(
        WebDavRemoteEntry(
          name: displayName,
          href: decodedHref,
          isDirectory: isDir,
          contentLength: contentLength,
          etag: etag,
          lastModified: lastModified,
        ),
      );
    }
    return entries;
  }

  static XmlElement? _firstChildByLocal(XmlElement parent, String localName) {
    final target = localName.toLowerCase();
    for (final child in parent.childElements) {
      if (child.name.local.toLowerCase() == target) return child;
    }
    return null;
  }

  static String _safeDecodePath(String rawHref) {
    try {
      final parsed = Uri.tryParse(rawHref);
      final pathOnly = parsed != null && parsed.hasScheme
          ? parsed.path
          : rawHref;
      return Uri.decodeComponent(pathOnly);
    } catch (_) {
      return rawHref;
    }
  }

  static String _normalizePath(String path) {
    final trimmed = path.trim().replaceAll(RegExp(r'/+$'), '');
    return trimmed.isEmpty ? '/' : trimmed;
  }
}

class _RawResponse {
  final int statusCode;
  final List<int> bytes;
  final String? etag;
  const _RawResponse(this.statusCode, this.bytes, {this.etag});
}
