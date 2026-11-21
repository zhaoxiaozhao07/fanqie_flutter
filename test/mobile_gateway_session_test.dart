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
  final Stream<List<int>>? stream;
  @override
  final int contentLength;
  _Response(Object json, {this.statusCode = 200})
    : body = utf8.encode(jsonEncode(json)),
      stream = null,
      contentLength = -1;
  _Response.stream(this.stream, {this.contentLength = -1})
    : body = const [],
      statusCode = 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => (stream ?? Stream.value(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<T> fold<T>(T initialValue, T Function(T, List<int>) combine) =>
      (stream ?? Stream.value(body)).fold(initialValue, combine);
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final _Headers headers = _Headers();
  final Future<HttpClientResponse> Function() respond;
  final body = <int>[];
  bool aborted = false;
  _Request(this.respond);
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  Future<HttpClientResponse> close() => respond();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
}

class _Client extends Fake implements HttpClient {
  final Future<HttpClientResponse> Function(Uri uri, bool post) handler;
  final requests = <Uri>[];
  final posts = <_Request>[];
  final allRequests = <_Request>[];
  _Client(this.handler);
  Future<HttpClientRequest> request(Uri uri, bool post) async {
    requests.add(uri);
    final r = _Request(() => handler(uri, post));
    allRequests.add(r);
    if (post) posts.add(r);
    return r;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => request(url, false);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => request(url, true);
}

void main() {
  for (final scenario in [
    (mode: 'success', afterUnwind: 2),
    (mode: 'malformed', afterUnwind: 2),
    (mode: 'failed-key', afterUnwind: 2),
    (mode: 'timeout', afterUnwind: 4),
  ]) {
    test(
      'N1 held ${scenario.mode} reservations preserve device reuse and actual quota',
      () async {
        var registrations = 0;
        var negotiations = 0;
        final entered = Completer<void>();
        final bodies = <StreamController<List<int>>>[];
        final reads = <String>[];
        final client = _Client((uri, _) async {
          if (uri.path.contains('device_register')) {
            registrations++;
            return registrations == 1
                ? _Response({
                    'device_id_str': '100001',
                    'install_id_str': '200001',
                  })
                : _Response({}, statusCode: 503);
          }
          final device = uri.queryParameters['device_id']!;
          if (uri.path.contains('registerkey')) {
            if (device != '100001') return _Response({}, statusCode: 403);
            negotiations++;
            if (scenario.mode == 'failed-key' && negotiations > 1) {
              return _Response({}, statusCode: 403);
            }
            return _Response(_registration(1));
          }
          reads.add(device);
          final item = uri.queryParameters['item_id']!;
          if (item == 'held-one' || item == 'held-two') {
            if (bodies.length < 2) {
              final body = StreamController<List<int>>();
              bodies.add(body);
              if (bodies.length == 2) entered.complete();
              return _Response.stream(body.stream);
            }
            return _Response({}, statusCode: 403);
          }
          return _Response(_chapter(1));
        });
        addTearDown(() async {
          for (final body in bodies) {
            await body.close();
          }
        });
        final gateway = FanqieMobileGateway(
          client: client,
          allowDynamicRegistration: true,
          maxRequestsPerSession: 8,
          requestTimeout: const Duration(milliseconds: 250),
        );
        await gateway.prepareDownloadSessionPool(desiredSize: 1);
        final held = Future.wait([
          gateway.fetchChapter('held-one'),
          gateway.fetchChapter('held-two'),
        ]);
        await entered.future.timeout(const Duration(seconds: 2));
        // Two actual requests plus six held slots fill the device's quota.
        expect(await gateway.fetchChapter('blocked'), isNull);
        expect(reads, ['100001', '100001']);
        expect(registrations, 2);
        if (scenario.mode != 'timeout') {
          for (final body in bodies) {
            body.add(
              scenario.mode == 'malformed'
                  ? [255]
                  : utf8.encode(
                      jsonEncode(
                        scenario.mode == 'failed-key'
                            ? {
                                'code': 0,
                                'data': {
                                  'content': 'Invalid',
                                  'key_version': 2,
                                },
                              }
                            : _chapter(1),
                      ),
                    ),
            );
            await body.close();
          }
        }
        expect(
          await held,
          everyElement(scenario.mode == 'success' ? isNotNull : isNull),
        );
        expect(reads.length, scenario.afterUnwind);
        expect(
          await gateway.fetchChapter('reused'),
          isNotNull,
          reason:
              'Released retry slots must rediscover the original negotiated device during cooldown',
        );
        // Consume the remaining real quota with single-attempt operations, then
        // prove neither failure cleanup nor reacquisition reset actual usage.
        for (var i = scenario.afterUnwind + 1; i < 8; i++) {
          expect(
            await gateway.fetchChapter('fill-$i', retryCount: 3),
            isNotNull,
          );
        }
        expect(await gateway.fetchChapter('over-quota', retryCount: 3), isNull);
        expect(reads, List.filled(8, '100001'));
        expect(registrations, 2);
      },
    );
  }

  test(
    'N1 busy prewarmed pool stays bounded and reuses all five devices after unwind',
    () async {
      var registrations = 0;
      final entered = Completer<void>();
      final bodies = <StreamController<List<int>>>[];
      final reads = <String>[];
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          final n = ++registrations;
          return n <= 5
              ? _Response({
                  'device_id_str': '${100000 + n}',
                  'install_id_str': '200001',
                })
              : _Response({}, statusCode: 503);
        }
        final device = uri.queryParameters['device_id']!;
        if (uri.path.contains('registerkey')) {
          return device == '2187355326004404'
              ? _Response({}, statusCode: 403)
              : _Response(_registration(1));
        }
        reads.add(device);
        if (uri.queryParameters['item_id']!.startsWith('held-')) {
          final body = StreamController<List<int>>();
          bodies.add(body);
          if (bodies.length == 10) entered.complete();
          return _Response.stream(body.stream);
        }
        return _Response(_chapter(1));
      });
      addTearDown(() async {
        for (final body in bodies) {
          await body.close();
        }
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 8,
      );
      await gateway.prepareDownloadSessionPool(desiredSize: 5);
      final held = Future.wait([
        for (var i = 0; i < 10; i++) gateway.fetchChapter('held-$i'),
      ]);
      await entered.future.timeout(const Duration(seconds: 2));
      final blocked = await gateway.fetchChapter('blocked');
      for (final body in bodies) {
        body.add(utf8.encode(jsonEncode(_chapter(1))));
        await body.close();
      }
      expect(await held, everyElement(isNotNull));
      expect(blocked, isNull);
      expect(
        registrations,
        5,
        reason:
            'Temporary occupancy must not evict five proven devices and register replacements',
      );
      for (var i = 0; i < 5; i++) {
        expect(await gateway.fetchChapter('reused-$i'), isNotNull);
      }
      expect(registrations, 5);
      expect(reads.skip(10).toSet(), {
        '100001',
        '100002',
        '100003',
        '100004',
        '100005',
      });
    },
  );

  test(
    'R3 expired keys charge every physical request while reserving same-session recovery',
    () async {
      var devices = 0;
      final versions = <String, int>{};
      final requests = <String, List<String>>{};
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          final n = ++devices;
          return _Response({
            'device_id_str': '${100000 + n}',
            'install_id_str': '${200000 + n}',
          });
        }
        final device = uri.queryParameters['device_id']!;
        if (uri.path.contains('registerkey')) {
          versions[device] = (versions[device] ?? 0) + 1;
          return _Response(_registration(versions[device]!));
        }
        final item = uri.queryParameters['item_id']!;
        final reads = requests.putIfAbsent(device, () => []);
        reads.add(item);
        if (reads.where((id) => id == item).length == 1) {
          return _Response({
            'code': 0,
            'data': {
              'content': 'Invalid',
              'key_version': versions[device]! + 1,
            },
          });
        }
        return _Response(_chapter(versions[device]!));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 2,
      );
      expect(await gateway.fetchChapter('one'), isNotNull);
      expect(await gateway.fetchChapter('two'), isNotNull);
      expect(
        requests.values.map((ids) => ids.length),
        everyElement(lessThanOrEqualTo(2)),
      );
      expect(
        requests.values.toList(),
        [
          ['one', 'one'],
          ['two', 'two'],
        ],
        reason:
            'Each refreshed key must retry on its own device, not rotate away',
      );
    },
  );

  test(
    'R3 network retries cannot exceed a two-request physical device quota',
    () async {
      var device = 100000;
      final reads = <String, int>{};
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          return _Response({
            'device_id_str': '${++device}',
            'install_id_str': '200000',
          });
        }
        if (uri.path.contains('registerkey')) {
          return _Response(_registration(1));
        }
        final id = uri.queryParameters['device_id']!;
        reads[id] = (reads[id] ?? 0) + 1;
        throw const SocketException('bounded retry failure');
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 2,
      );
      expect(await gateway.fetchChapter('unavailable'), isNull);
      expect(reads.values, everyElement(lessThanOrEqualTo(2)));
      expect(reads.length, 1);
    },
  );

  test(
    'R4 repeated sequential registration outages reuse the negotiated seed',
    () async {
      var registrations = 0;
      final client = _Client((uri, post) async {
        if (uri.path.contains('device_register')) {
          registrations++;
          return _Response({}, statusCode: 503);
        }
        return _Response(post ? _registration(1) : _chapter(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      for (var i = 0; i < 4; i++) {
        expect(await gateway.fetchChapter('cached-fallback-$i'), isNotNull);
      }
      expect(registrations, 1);
    },
  );

  test(
    'R3 concurrent expired keys reserve their same-device retry quotas',
    () async {
      var devices = 0;
      final reads = <String, List<String>>{};
      final versions = <String, int>{};
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          return _Response({
            'device_id_str': '${100000 + ++devices}',
            'install_id_str': '200000',
          });
        }
        final device = uri.queryParameters['device_id']!;
        if (uri.path.contains('registerkey')) {
          versions[device] = (versions[device] ?? 0) + 1;
          return _Response(_registration(versions[device]!));
        }
        final item = uri.queryParameters['item_id']!;
        final requests = reads.putIfAbsent(device, () => []);
        requests.add(item);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (requests.where((id) => id == item).length == 1) {
          return _Response({
            'code': 0,
            'data': {'content': 'Invalid', 'key_version': 2},
          });
        }
        return _Response(_chapter(2));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 2,
      );
      final results = await Future.wait([
        for (var i = 0; i < 6; i++)
          gateway.fetchChapterDocument('chapter-$i', useSessionPool: true),
      ]);
      expect(results, everyElement(isNotNull));
      expect(reads.length, 6);
      for (final requests in reads.values) {
        expect(requests.length, 2);
        expect(requests.first, requests.last);
      }
    },
  );

  test(
    'R3 seed fallback cannot reset physical quota on each acquisition',
    () async {
      var registrations = 0;
      var reads = 0;
      final client = _Client((uri, post) async {
        if (uri.path.contains('device_register')) {
          registrations++;
          return _Response({}, statusCode: 503);
        }
        if (post) return _Response(_registration(1));
        reads++;
        return _Response(_chapter(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 2,
      );
      expect(await gateway.fetchChapter('one'), isNotNull);
      expect(await gateway.fetchChapter('two'), isNotNull);
      expect(await gateway.fetchChapter('three'), isNull);
      expect(reads, 2);
      expect(registrations, 1);
    },
  );

  test(
    'R4 repeated pooled prewarming suppresses registration during outage',
    () async {
      var registrations = 0;
      final client = _Client((uri, post) async {
        if (uri.path.contains('device_register')) {
          registrations++;
          return _Response({}, statusCode: 503);
        }
        return _Response(post ? _registration(1) : _chapter(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      await gateway.prepareDownloadSessionPool();
      for (var i = 0; i < 4; i++) {
        await gateway.prepareDownloadSessionPool();
        expect(
          await gateway.fetchChapterDocument(
            'fallback-$i',
            useSessionPool: true,
          ),
          isNotNull,
        );
      }
      expect(registrations, 3);
    },
  );

  test(
    'anonymous registration trickle has a total deadline before seed fallback',
    () async {
      var cancelled = 0;
      Timer? ticker;
      late StreamController<List<int>> body;
      final client = _Client((uri, post) async {
        if (uri.path.contains('device_register')) {
          body = StreamController<List<int>>(
            onCancel: () {
              cancelled++;
              ticker?.cancel();
            },
          );
          ticker = Timer.periodic(
            const Duration(milliseconds: 10),
            (_) => body.add([32]),
          );
          return _Response.stream(body.stream);
        }
        return _Response(post ? _registration(1) : _chapter(1));
      });
      addTearDown(() async {
        ticker?.cancel();
        await body.close();
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        requestTimeout: const Duration(milliseconds: 60),
      );
      expect(
        await gateway
            .fetchChapter('trickle')
            .timeout(const Duration(seconds: 2), onTimeout: () => null),
        isNotNull,
      );
      expect(cancelled, 1);
    },
  );

  test(
    'registration outages fall back once without repeated anonymous-device load',
    () async {
      var registrations = 0;
      final client = _Client((uri, post) async {
        if (uri.path.contains('device_register')) {
          registrations++;
          return _Response({}, statusCode: 503);
        }
        return _Response(post ? _registration(1) : _chapter(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      expect(await gateway.fetchChapter('fallback'), isNotEmpty);
      expect(registrations, 1);
    },
  );

  test(
    'concurrent seed key expiry shares renegotiation without guessing keys',
    () async {
      var registrations = 0;
      final client = _Client((uri, post) async {
        if (post) {
          registrations++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _Response(_registration(registrations));
        }
        return _Response(_chapter(2));
      });
      final gateway = FanqieMobileGateway(client: client);
      await gateway.refreshKey();
      final chapters = await Future.wait([
        gateway.fetchChapter('one'),
        gateway.fetchChapter('two'),
      ]);
      expect(registrations, 2);
      expect(chapters, everyElement(isNotNull));
    },
  );

  test(
    'pool quotas remain bounded while cold readers acquire concurrently',
    () async {
      var devices = 0;
      final requestsPerDevice = <String, int>{};
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          final n = ++devices;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _Response({
            'device_id_str': '${100000 + n}',
            'install_id_str': '${200000 + n}',
          });
        }
        if (uri.path.contains('registerkey')) {
          return _Response(_registration(1));
        }
        final id = uri.queryParameters['device_id']!;
        requestsPerDevice[id] = (requestsPerDevice[id] ?? 0) + 1;
        return _Response(_chapter(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
        maxRequestsPerSession: 2,
      );
      final results = await Future.wait(
        List.generate(
          10,
          (i) =>
              gateway.fetchChapterDocument('chapter-$i', useSessionPool: true),
        ),
      );
      expect(results, everyElement(isNotNull));
      expect(requestsPerDevice.values, everyElement(lessThanOrEqualTo(2)));
    },
  );

  test(
    'empty-body throttling rotates devices and stops after four attempts',
    () async {
      var devices = 0;
      final reads = <String>[];
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          return _Response({
            'device_id_str': '${100000 + ++devices}',
            'install_id_str': '200000',
          });
        }
        if (uri.path.contains('registerkey')) {
          return _Response(_registration(1));
        }
        reads.add(uri.queryParameters['device_id']!);
        return _Response.stream(Stream.value(const []));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      expect(await gateway.fetchChapter('throttled'), isNull);
      expect(reads.length, 4);
      expect(reads.toSet().length, 4);
    },
  );

  test(
    'three expired pool keys recover on their own refreshed sessions',
    () async {
      var nextId = 100000000000001;
      final versions = <String, int>{};
      final reads = <String>[];
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          return _Response({
            'device_id_str': '${nextId++}',
            'install_id_str': '${nextId++}',
          });
        }
        final device = uri.queryParameters['device_id']!;
        if (uri.path.contains('registerkey')) {
          final version = (versions[device] ?? 0) + 1;
          versions[device] = version;
          final key = List.generate(
            16,
            (i) => int.parse(device) % 200 + i + version,
          );
          return _Response({
            'code': 0,
            'data': {'key': _encrypt(key, _shared), 'keyver': version},
          });
        }
        reads.add(device);
        if (versions[device] == 1) {
          return _Response({
            'code': 0,
            'data': {'key_version': 2, 'content': 'Invalid'},
          });
        }
        final key = List.generate(16, (i) => int.parse(device) % 200 + i + 2);
        return _Response({
          'code': 0,
          'data': {
            'key_version': 2,
            'compress_status': 0,
            'content': _encrypt(utf8.encode('<p>已刷新设备 $device 正文</p>'), key),
          },
        });
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      await gateway.prepareDownloadSessionPool();
      for (var i = 0; i < 3; i++) {
        expect(await gateway.fetchChapter('chapter-$i'), contains('已刷新设备'));
      }
      expect(reads.length, 6);
      expect(reads[0], reads[1]);
      expect(reads[2], reads[3]);
      expect(reads[4], reads[5]);
      expect(reads.toSet().length, 3);
      expect(versions.values, everyElement(2));
    },
  );

  test(
    'concurrent prewarming keeps device registrations bounded to five',
    () async {
      var registrations = 0;
      final client = _Client((uri, _) async {
        if (uri.path.contains('device_register')) {
          final n = ++registrations;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return _Response({
            'device_id_str': '${100000 + n}',
            'install_id_str': '${200000 + n}',
          });
        }
        return _Response(_registration(1));
      });
      final gateway = FanqieMobileGateway(
        client: client,
        allowDynamicRegistration: true,
      );
      await Future.wait(
        List.generate(
          10,
          (_) => gateway.prepareDownloadSessionPool(desiredSize: 5),
        ),
      );
      expect(registrations, 5);
    },
  );

  for (final stage in ['registration', 'chapter']) {
    test(
      '$stage headers followed by stalled body have a total deadline and cleanup',
      () async {
        final streams = <StreamController<List<int>>>[];
        var cancelled = 0;
        var released = false;
        final client = _Client((_, post) async {
          if (released) return _Response({}, statusCode: 403);
          if ((stage == 'registration') == post) {
            final body = StreamController<List<int>>(
              onCancel: () => cancelled++,
            );
            streams.add(body);
            body.add([32]); // headers arrived, but body never finishes
            return _Response.stream(body.stream);
          }
          return _Response(post ? _registration(1) : _chapter(1));
        });
        addTearDown(() async {
          released = true;
          for (final stream in streams) {
            await stream.close();
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        final gateway = FanqieMobileGateway(
          client: client,
          requestTimeout: const Duration(milliseconds: 60),
        );
        expect(
          await gateway
              .fetchChapter('stall')
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => 'body deadline missing',
              ),
          isNull,
        );
        expect(cancelled, streams.length);
        expect(
          client.allRequests.where((request) => request.aborted).length,
          streams.length,
        );
      },
    );
  }

  test(
    'registration rejects oversized chunked JSON even with a valid key',
    () async {
      var cancelled = false;
      final bytes = utf8.encode(
        jsonEncode({..._registration(1), 'padding': 'x' * (1024 * 1024)}),
      );
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(body.close);
      final client = _Client((_, post) async {
        if (!post) return _Response(_chapter(1));
        scheduleMicrotask(() {
          body.add(bytes);
          body.close();
        });
        return _Response.stream(body.stream);
      });
      expect(
        await FanqieMobileGateway(client: client).fetchChapter('large'),
        isNull,
      );
      expect(
        client.requests.where((uri) => uri.path.contains('/full/')),
        isEmpty,
      );
      expect(cancelled, true);
    },
  );

  test(
    'chapter rejects oversized declared body before accepting valid ciphertext',
    () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(body.close);
      final client = _Client((_, post) async {
        if (post) return _Response(_registration(1));
        scheduleMicrotask(() {
          body.add(utf8.encode(jsonEncode(_chapter(1))));
          body.close();
        });
        return _Response.stream(
          body.stream,
          contentLength: 32 * 1024 * 1024 + 1,
        );
      });
      expect(
        await FanqieMobileGateway(client: client).fetchChapter('large'),
        isNull,
      );
      expect(cancelled, true);
    },
  );

  test(
    'encrypted mobile payload preserves pictures before plain-text cleaning',
    () async {
      final response = _chapter(1);
      (response['data'] as Map)['content'] = _encrypt(
        utf8.encode(
          '<h1>第一章</h1><p>图前<img src="https://p3-novel.byteimg.com/a.png"/>图后</p>',
        ),
        _key,
      );
      final client = _Client(
        (uri, post) async => _Response(post ? _registration(1) : response),
      );
      final document = await FanqieMobileGateway(
        client: client,
      ).fetchChapterDocument('illustrated');
      expect(document!.text, '图前图后');
      expect(document.images.single.offset, 2);
      expect(
        document.images.single.source,
        'https://p3-novel.byteimg.com/a.png',
      );
    },
  );
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
