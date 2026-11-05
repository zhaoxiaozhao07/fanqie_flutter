import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;
}

class _Response extends Fake implements HttpClientResponse {
  final Object value;
  @override
  final int statusCode;
  _Response(this.value, [this.statusCode = 200]);
  @override
  Future<T> fold<T>(T initial, T Function(T, List<int>) combine) async =>
      combine(initial, utf8.encode(jsonEncode(value)));
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final Uri uri;
  final Future<HttpClientResponse> Function(_Request) respond;
  final bytes = <int>[];
  @override
  final _Headers headers = _Headers();
  _Request(this.uri, this.respond);
  Map<String, dynamic> get body =>
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() => respond(this);
}

class _Client extends Fake implements HttpClient {
  final Future<HttpClientResponse> Function(_Request) respond;
  final requests = <_Request>[];
  _Client(this.respond);
  @override
  Future<HttpClientRequest> postUrl(Uri uri) async {
    final request = _Request(uri, respond);
    requests.add(request);
    return request;
  }
}

Map<String, dynamic> _postComments({Object hasMore = true}) => {
  'code': 0,
  'data': {
    'common_list_info': {
      'cursor': '{"session_id":"fixture-session","offset":20}',
      'has_more': hasMore,
      'total': 24,
    },
    'data_list': [
      {
        'data_type': 4,
        'comment': {
          'comment_id': 'root-comment',
          'common': {
            'group_id': 'post',
            'service_id': 11,
            'create_timestamp': 1700000000,
            'content': {
              'text': '第一条帖子回复 @作者',
              'image_data_list': [
                {'url': 'https://example.com/reply.png'},
              ],
            },
            'user_info': {
              'base_info': {'user_name': '测试作者', 'user_id': 'test-author'},
              'user_tag': {'is_author': true},
            },
          },
          'stat': {'digg_count': 3, 'reply_count': 2},
        },
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'post replies use the post comment protocol and preserve metadata',
    () async {
      final client = _Client((_) async => _Response(_postComments()));
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchPostReplies('post', bookId: 'book');
      expect(page?.total, 24);
      expect(page?.hasMore, true);
      final reply = page!.replies.single;
      expect(reply.replyId, 'root-comment');
      expect(reply.parentCommentId, 'post');
      expect(reply.replyCount, 2);
      expect(reply.isAuthor, true);
      expect(reply.text, contains('@作者'));
      expect(reply.images, ['https://example.com/reply.png']);
      expect(reply.diggCount, 3);
      final request = client.requests.single;
      expect(request.uri.path, '/novel/commentapi/comment/list/post/v1/');
      expect(request.body['comment_source'], 5);
      expect(request.body['comment_type'], 11);
      expect(request.body['group_type'], 3);
      expect(request.body['server_channel'], 35);
      expect(request.body['group_id'], 'post');
      expect((request.body['business_param'] as Map)['book_id'], 'book');
      expect(request.headers.values, contains('x-argus'));
      expect(request.headers.values, isNot(contains('x-ss-stub')));
      expect(CommentReplyItem.fromJson(reply.toJson()).replyCount, 2);
    },
  );

  test(
    'post pagination passes JSON cursors verbatim and deduplicates',
    () async {
      final value = _postComments();
      (value['data']['data_list'] as List).add(value['data']['data_list'][0]);
      final client = _Client((_) async => _Response(value));
      const cursor = '{"session_id":"fixture-session","offset":20}';
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchPostReplies('post', cursor: cursor, count: 100);
      expect(page?.replies, hasLength(1));
      expect(client.requests.single.body['cursor'], cursor);
      expect(client.requests.single.body['count'], 50);
    },
  );

  for (final flag in [false, 0, '0', 'false']) {
    test('post replies respect terminal has_more=$flag', () async {
      final client = _Client(
        (_) async => _Response(_postComments(hasMore: flag)),
      );
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchPostReplies('post');
      expect(page?.hasMore, false);
    });
  }

  test(
    'failed post reply requests do not claim an empty successful result',
    () async {
      for (final response in [
        _Response({'code': 103001, 'data': {}}),
        _Response({}, 503),
        _Response({
          'code': 0,
          'data': {'data_list': []},
        }),
      ]) {
        final client = _Client((_) async => response);
        expect(
          await FanqieMobileGateway(client: client).fetchPostReplies('post'),
          isNull,
        );
        expect(client.requests, hasLength(1));
      }
    },
  );

  test('empty post IDs do not issue network requests', () async {
    final client = _Client((_) async => _Response(_postComments()));
    expect(
      await FanqieMobileGateway(client: client).fetchPostReplies(' '),
      isNull,
    );
    expect(client.requests, isEmpty);
  });

  test(
    'nested post replies use comment IDs with the original post context',
    () async {
      final raw = {
        'reply_id': 'child',
        'reply_to_reply_id': 'earlier-child',
        'reply_to_user_info': {
          'base_info': {'user_name': '目标书友'},
        },
        'Common': {
          'content': {'text': '楼中楼正文'},
          'user_info': {
            'base_info': {'user_id': 'fixture-user', 'user_name': '测试书友'},
            'user_tag': {'is_author': true},
          },
          'create_timestamp': 1700000000,
        },
        'stat': {'digg_count': 2},
      };
      final client = _Client(
        (_) async => _Response({
          'code': 0,
          'data': {
            'comment_list_info': {'cursor': '6', 'has_more': '1', 'total': 14},
            'reply_list': [raw, raw],
          },
        }),
      );
      final page = await FanqieMobileGateway(client: client)
          .fetchPostCommentReplies(
            'post',
            'root-comment',
            bookId: 'book',
            cursor: '3',
            count: 3,
          );
      expect(page?.replies, hasLength(1));
      expect(page?.total, 14);
      expect(page?.hasMore, true);
      expect(page?.cursor, '6');
      expect(page?.replies.single.parentCommentId, 'root-comment');
      expect(page?.replies.single.parentReplyId, 'earlier-child');
      expect(page?.replies.single.replyToUserName, '目标书友');
      expect(
        CommentReplyItem.fromJson(
          page!.replies.single.toJson(),
        ).replyToUserName,
        '目标书友',
      );
      expect(page.replies.single.isAuthor, true);
      final request = client.requests.single;
      expect(request.uri.path, '/novel/commentapi/reply/list/root-comment/v1/');
      expect(request.body['group_id'], 'post');
      expect(request.body['comment_id'], 'root-comment');
      expect(request.body['comment_source'], 5);
      expect(request.body['comment_type'], 11);
      expect(request.body['group_type'], 3);
      expect(request.body['cursor'], '3');
      expect(request.body['count'], 3);
    },
  );

  test(
    'nested reply failure and malformed entries are not empty success',
    () async {
      final client = _Client(
        (_) async => _Response({
          'code': 0,
          'data': {
            'comment_list_info': {'has_more': false, 'total': 1},
            'reply_list': [
              {'text': 'missing reply ID'},
            ],
          },
        }),
      );
      final gateway = FanqieMobileGateway(client: client);
      expect(await gateway.fetchPostCommentReplies('post', ''), isNull);
      expect(client.requests, isEmpty);
      expect(await gateway.fetchPostCommentReplies('post', 'comment'), isNull);
    },
  );

  test(
    'unknown post reply shapes fail explicitly instead of silently disappearing',
    () async {
      final response = _postComments();
      response['data']['data_list'] = [
        {'data_type': 99},
      ];
      final client = _Client((_) async => _Response(response));
      expect(
        await FanqieMobileGateway(client: client).fetchPostReplies('post'),
        isNull,
      );
    },
  );
}
