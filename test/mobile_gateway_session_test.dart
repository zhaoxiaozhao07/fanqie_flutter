import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';

const _shared = [
  172,
  37,
  198,
  125,
  221,
  143,
  56,
  193,
  179,
  122,
  35,
  72,
  130,
  142,
  34,
  46,
];
final _key = Uint8List.fromList(List.generate(16, (i) => i));

String _encrypt(List<int> plain, List<int> key) {
  final iv = Uint8List(16);
  final pad = 16 - plain.length % 16;
  final bytes = Uint8List.fromList([...plain, ...List.filled(pad, pad)]);
  final cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV(KeyParameter(Uint8List.fromList(key)), iv));
  final encrypted = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i += 16) {
    cipher.processBlock(bytes, i, encrypted, i);
  }
  return base64Encode([...iv, ...encrypted]);
}

Map<String, dynamic> _registration(int version) => {
  'code': 0,
  'data': {'key': _encrypt(_key, _shared), 'keyver': version},
};

Map<String, dynamic> _chapter(int version, {bool compressed = false}) {
  final html = '<h1>测试章</h1><p>${'完整正文，不是网页预览。' * 30}</p>';
  final bytes = utf8.encode(html);
  return {
    'code': 0,
    'data': {
      'key_version': version,
      'compress_status': compressed ? 1 : 0,
      'content': _encrypt(
        compressed ? GZipEncoder().encode(bytes) : bytes,
        _key,
      ),
    },
  };
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;
}

class _Response extends Fake implements HttpClientResponse {
  @override
  final int statusCode;
  final List<int> body;
  _Response(Object json, {this.statusCode = 200})
    : body = utf8.encode(jsonEncode(json));
  @override
  Future<T> fold<T>(T initialValue, T Function(T, List<int>) combine) async =>
      combine(initialValue, body);
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final _Headers headers = _Headers();
  final Future<HttpClientResponse> Function() respond;
  final body = <int>[];
  _Request(this.respond);
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  Future<HttpClientResponse> close() => respond();
}

class _Client extends Fake implements HttpClient {
  final Future<HttpClientResponse> Function(Uri uri, bool post) handler;
  final requests = <Uri>[];
  final posts = <_Request>[];
  _Client(this.handler);
  Future<HttpClientRequest> request(Uri uri, bool post) async {
    requests.add(uri);
    final r = _Request(() => handler(uri, post));
    if (post) posts.add(r);
    return r;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => request(url, false);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => request(url, true);
}

void main() {
  test(
    'malformed UTF-8 is never returned as replacement-character正文',
    () async {
      final corrupted = _chapter(1, compressed: true);
      (corrupted['data'] as Map)['content'] = _encrypt(
        GZipEncoder().encode(List.filled(300, 255)),
        _key,
      );
      final client = _Client(
        (uri, post) async => _Response(post ? _registration(1) : corrupted),
      );
      expect(
        await FanqieMobileGateway(client: client).fetchChapter('invalid'),
        isNull,
      );
      expect(client.requests.length, 2);
    },
  );

  test(
    'first request negotiates a key rather than using an expired seed',
    () async {
      final client = _Client(
        (uri, post) async =>
            _Response(post ? _registration(1) : _chapter(1, compressed: true)),
      );
      final gateway = FanqieMobileGateway(client: client);
      final content = await gateway.fetchChapter('chapter-1');
      expect(content, '完整正文，不是网页预览。' * 30);
      expect(client.requests.map((u) => u.path), [
        '/reading/crypt/registerkey',
        '/reading/reader/full/v',
      ]);
      expect(client.posts.single.headers.values['content-encoding'], 'gzip');
      expect(client.posts.single.headers.values.containsKey('x-argus'), true);
    },
  );

  test('concurrent readers share one in-flight key negotiation', () async {
    final gate = Completer<HttpClientResponse>();
    final client = _Client(
      (uri, post) async => post ? gate.future : _Response(_chapter(1)),
    );
    final gateway = FanqieMobileGateway(client: client);
    final first = gateway.fetchChapter('one');
    final second = gateway.fetchChapter('two');
    await Future<void>.delayed(Duration.zero);
    expect(client.posts.length, 1);
    gate.complete(_Response(_registration(1)));
    expect(await first, isNotEmpty);
    expect(await second, isNotEmpty);
    expect(client.posts.length, 1);
  });

  test(
    'server key rotation triggers a bounded renegotiation and retry',
    () async {
      var registrations = 0, chapters = 0;
      final client = _Client((uri, post) async {
        if (post) return _Response(_registration(++registrations));
        chapters++;
        return _Response(_chapter(2));
      });
      final gateway = FanqieMobileGateway(client: client);
      expect(await gateway.fetchChapter('rotated'), isNotEmpty);
      expect(registrations, 2);
      expect(chapters, 2);
    },
  );

  test('failed negotiation never falls through with a guessed key', () async {
    final client = _Client(
      (uri, post) async => _Response({'code': -1, 'data': {}}, statusCode: 403),
    );
    expect(
      await FanqieMobileGateway(client: client).fetchChapter('chapter'),
      isNull,
    );
    expect(client.requests.length, 1);
    expect(client.requests.single.path, '/reading/crypt/registerkey');
  });

  test(
    'malformed registered key is rejected without a full-content request',
    () async {
      final client = _Client(
        (uri, post) async => _Response({
          'code': 0,
          'data': {'key': 'AA==', 'keyver': 1},
        }),
      );
      expect(
        await FanqieMobileGateway(client: client).fetchChapter('chapter'),
        isNull,
      );
      expect(client.requests.length, 1);
    },
  );
}
