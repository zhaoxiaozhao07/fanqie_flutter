import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Response extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 200;
  final Map<String, dynamic> data;
  _Response(this.data);
  @override
  Future<T> fold<T>(T initial, T Function(T, List<int>) combine) async =>
      combine(initial, utf8.encode(jsonEncode({'code': 0, 'data': data})));
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final HttpHeaders headers = _Headers();
  final Map<String, dynamic> data;
  _Request(this.data);
  @override
  Future<HttpClientResponse> close() async => _Response(data);
}

class _Client extends Fake implements HttpClient {
  final Map<String, dynamic> data;
  final List<Uri> requests = [];
  _Client(this.data);
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requests.add(uri);
    return _Request(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> data() => {
    'comment_cnt': 15,
    'comment': [
      {'comment_id': 'a', 'text': '第一条'},
      {'comment_id': 'b', 'text': '第二条'},
    ],
  };

  for (final flag in [true, 1, '1', 'true']) {
    test('chapter pagination accepts has_more=$flag', () async {
      final client = _Client({...data(), 'has_more': flag, 'next_offset': 50});
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments('book', 'chapter');
      expect(page?.hasMore, true);
      expect(page?.cursor, '50');
      expect(page?.comments.length, 2);
    });
  }

  for (final flag in [false, 0, '0', 'false']) {
    test('chapter pagination respects terminal has_more=$flag', () async {
      final client = _Client({...data(), 'has_more': flag, 'next_offset': 15});
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments('book', 'chapter');
      expect(page?.hasMore, false);
      expect(page?.cursor, '15');
    });
  }

  test('missing offset advances by raw entries, not parsed comments', () async {
    final client = _Client({
      ...data(),
      'has_more': true,
      'comment': [
        {'comment_id': 'a'},
        {'text': 'filtered because the ID is absent'},
        {'comment_id': 'b'},
      ],
    });
    final page = await FanqieMobileGateway(
      client: client,
    ).fetchChapterComments('book', 'chapter', offset: 10);
    expect(page?.comments.length, 2);
    expect(page?.cursor, '13');
    expect(page?.hasMore, true);
  });

  test('stalled offsets fall back to consumed raw entries', () async {
    final client = _Client({...data(), 'has_more': true, 'next_offset': 10});
    final page = await FanqieMobileGateway(
      client: client,
    ).fetchChapterComments('book', 'chapter', offset: 10);
    expect(page?.cursor, '12');
    expect(client.requests.single.queryParameters['offset'], '10');
  });

  test(
    'absent has_more can be inferred without overriding an explicit false',
    () async {
      final client = _Client(data());
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments('book', 'chapter', offset: 10);
      expect(page?.hasMore, true);
      expect(page?.cursor, '12');
    },
  );
}
