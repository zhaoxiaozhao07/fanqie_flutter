import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/discussion_post_content.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const _book = '7322304923511557182';
const _chapter = '7561721731426026009';
const _forum = '7322385134131368766';

class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }
}

class _Response extends Fake implements HttpClientResponse {
  final Object json;
  @override
  final int statusCode;
  _Response(this.json, {this.statusCode = 200});
  @override
  Future<T> fold<T>(T initial, T Function(T, List<int>) combine) async =>
      combine(initial, utf8.encode(jsonEncode(json)));
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final Uri uri;
  final bool post;
  final Future<HttpClientResponse> Function(_Request) respond;
  final bytes = <int>[];
  @override
  final _Headers headers = _Headers();
  _Request(this.uri, this.post, this.respond);
  Map<String, dynamic> get body => bytes.isEmpty
      ? {}
      : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() => respond(this);
}

class _Client extends Fake implements HttpClient {
  final Future<HttpClientResponse> Function(_Request) respond;
  final requests = <_Request>[];
  _Client(this.respond);
  Future<HttpClientRequest> request(Uri uri, bool post) async {
    final request = _Request(uri, post, respond);
    requests.add(request);
    return request;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri uri) => request(uri, false);
  @override
  Future<HttpClientRequest> postUrl(Uri uri) => request(uri, true);
}

Future<Map<String, dynamic>> _fixture() async =>
    jsonDecode(
          await File(
            'test/fixtures/chapter_discussion_1521.json',
          ).readAsString(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _legacy() => {
  'code': 0,
  'data': {
    'comment_cnt': 1,
    'has_more': false,
    'next_offset': 1,
    'comment': [
      {'comment_id': '7561684599238148888', 'text': '旧接口只有一条章评'},
    ],
  },
};

Map<String, dynamic> _forumResponse() => {
  'code': 0,
  'data': {
    'forum': {'forum_id': _forum, 'relative_id': _book},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'chapter 1521 gets six discussions, not just the one legacy comment',
    () async {
      final fixture = await _fixture();
      final client = _Client((request) async {
        if (request.uri.path.contains('/forum/desc/')) {
          return _Response({
            'code': 0,
            'data': {
              'forum': {'forum_id': _forum, 'relative_id': _book},
            },
          });
        }
        if (request.uri.path.contains('/articleapi/feed/')) {
          return _Response(fixture);
        }
        return _Response(_legacy());
      });
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments(_book, _chapter);
      expect(page?.total, 6);
      expect(page?.comments.length, 6);
      expect(page?.comments.where((c) => c.isDiscussionPost), hasLength(5));
      expect(page?.warning, isNull);
      expect(page?.hasMore, false);
      expect(page?.comments.map((item) => item.id).toSet(), {
        '7561684599238148888',
        '7561614993045832254',
        '7561640971163746878',
        '7561815023622832702',
        '7561670042644005401',
        '7561736350337286681',
      });
      final feed = client.requests.singleWhere((request) => request.post);
      expect(feed.body['source'], 2);
      expect(feed.body['channel'], 7);
      expect((feed.body['business_param'] as Map)['forum_id'], _forum);
      expect((feed.body['business_param'] as Map)['item_id'], _chapter);
      expect(feed.headers.values, isNot(contains('x-ss-stub')));
      expect(feed.headers.values, contains('x-argus'));
      expect(feed.uri.queryParameters['version_code'], '74332');
      expect(
        client.requests.any((r) => r.uri.path.contains('/novel_comment/')),
        false,
      );
      expect(page?.comments.last.text, contains('@测试作者'));
      expect(page?.comments.last.text, isNot(contains('skeleton')));
    },
  );

  test(
    'opaque feed cursor is passed verbatim and never treated as offset',
    () async {
      final fixture = await _fixture();
      const cursor = '{"post_next_offset":200,"comment_next_offset":1}';
      final client = _Client((request) async {
        if (!request.post) return _Response(_forumResponse());
        return _Response(fixture);
      });
      final gateway = FanqieMobileGateway(client: client);
      await gateway.fetchChapterComments(_book, _chapter, count: 1);
      final next = await gateway.fetchChapterComments(
        _book,
        _chapter,
        cursor: cursor,
        count: 1,
      );
      expect(next?.total, 6);
      expect(client.requests.where((r) => !r.post), hasLength(1));
      expect(client.requests.last.body['cursor'], cursor);
      expect(client.requests.last.body['count'], 20);
    },
  );

  test(
    'a failed continuation never falls back to a legacy first page',
    () async {
      final client = _Client(
        (request) async => request.post
            ? _Response({'code': 103002, 'data': {}})
            : _Response(_forumResponse()),
      );
      final page = await FanqieMobileGateway(client: client)
          .fetchChapterComments(
            _book,
            _chapter,
            cursor: '{"post_next_offset":200}',
          );
      expect(page, isNull);
      expect(client.requests, hasLength(2));
      expect(client.requests.last.post, true);
    },
  );

  test(
    'HTTP feed failure also falls back without claiming completeness',
    () async {
      final client = _Client((request) async {
        if (request.uri.path.contains('/forum/desc/')) {
          return _Response(_forumResponse());
        }
        return request.post
            ? _Response({}, statusCode: 503)
            : _Response(_legacy());
      });
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments(_book, _chapter);
      expect(page?.isLegacySource, true);
      expect(page?.comments, hasLength(1));
    },
  );

  test('initial feed failure returns clearly marked legacy comments', () async {
    final client = _Client((request) async {
      if (request.uri.path.contains('/forum/desc/')) {
        return _Response(_forumResponse());
      }
      return request.post ? _Response({'code': 103002}) : _Response(_legacy());
    });
    final page = await FanqieMobileGateway(
      client: client,
    ).fetchChapterComments(_book, _chapter);
    expect(page?.comments, hasLength(1));
    expect(page?.isLegacySource, true);
    expect(page?.warning, contains('仅显示旧版章评'));
    expect(page?.cursor, '1');
  });

  test('unresolved forum is retried, not negatively cached', () async {
    final fixture = await _fixture();
    var lookups = 0;
    final client = _Client((request) async {
      if (request.uri.path.contains('/forum/desc/')) {
        lookups++;
        return _Response(lookups == 1 ? {'code': 1} : _forumResponse());
      }
      return _Response(request.post ? fixture : _legacy());
    });
    final gateway = FanqieMobileGateway(client: client);
    expect((await gateway.fetchChapterComments(_book, _chapter))?.total, 1);
    expect((await gateway.fetchChapterComments(_book, _chapter))?.total, 6);
    expect(lookups, 2);
  });

  test(
    'forum lookup is coalesced across preview and full-page requests',
    () async {
      final fixture = await _fixture();
      final pending = Completer<HttpClientResponse>();
      final client = _Client(
        (request) =>
            request.post ? Future.value(_Response(fixture)) : pending.future,
      );
      final gateway = FanqieMobileGateway(client: client);
      final full = gateway.fetchChapterComments(_book, _chapter);
      final preview = gateway.fetchChapterComments(_book, _chapter, count: 1);
      pending.complete(_Response(_forumResponse()));
      await Future.wait([full, preview]);
      expect(client.requests.where((r) => !r.post), hasLength(1));
      expect(client.requests.where((r) => r.post), hasLength(2));
    },
  );

  test('mismatched book forum cannot contaminate the chapter feed', () async {
    final client = _Client((request) async {
      if (request.uri.path.contains('/forum/desc/')) {
        return _Response({
          'code': 0,
          'data': {
            'forum': {'forum_id': _forum, 'relative_id': 'other-book'},
          },
        });
      }
      return _Response(_legacy());
    });
    final page = await FanqieMobileGateway(
      client: client,
    ).fetchChapterComments(_book, _chapter);
    expect(page?.isLegacySource, true);
    expect(client.requests.any((r) => r.post), false);
  });

  test(
    'legacy cursors continue the legacy source without a forum lookup',
    () async {
      final client = _Client((_) async => _Response(_legacy()));
      await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments(_book, _chapter, cursor: '30');
      expect(client.requests, hasLength(1));
      expect(client.requests.single.uri.queryParameters['offset'], '30');
    },
  );

  test(
    'deduplication is typed and unknown items keep upstream total',
    () async {
      final fixture = await _fixture();
      final data = fixture['data'] as Map;
      final rows = data['data_list'] as List;
      rows.add(rows.first);
      rows.add({'data_type': 99});
      (rows[1]['post'] as Map)['post_id'] = rows.first['comment']['comment_id'];
      final client = _Client(
        (r) async => _Response(r.post ? fixture : _forumResponse()),
      );
      final page = await FanqieMobileGateway(
        client: client,
      ).fetchChapterComments(_book, _chapter, count: 100);
      expect(page?.comments, hasLength(6));
      expect(page?.total, 6);
      expect(page?.warning, contains('部分讨论类型'));
      expect(client.requests.last.body['count'], 50);
    },
  );

  test(
    'discussion origin and warning survive cache JSON round trips',
    () async {
      final fixture = await _fixture();
      final post = FanqieMobileGateway.parseChapterDiscussion(
        fixture['data']['data_list'][1],
        bookId: _book,
        chapterId: _chapter,
      )!;
      final page = CommentPageData(
        comments: [post],
        cursor: '{"post_next_offset":200}',
        total: 6,
        hasMore: true,
        warning: '缓存提示',
      );
      final restored = CommentPageData.fromJson(
        jsonDecode(jsonEncode(page.toJson())),
      );
      expect(restored.comments.single.isDiscussionPost, true);
      expect(restored.comments.single.identityKey, post.identityKey);
      expect(restored.cursor, page.cursor);
      expect(restored.warning, '缓存提示');
    },
  );

  test(
    'counted author topic is rendered and its origin survives caching',
    () async {
      final fixture = await _fixture();
      final post = fixture['data']['data_list'][1]['post'] as Map;
      final topic = {
        ...post,
        'topic_id': 'author-topic',
        'stat': {'comment_count': 24, 'digg_count': 65},
        'common': {...post['common'] as Map, 'title': '作者有话说'},
      }..remove('post_id');
      final parsed = FanqieMobileGateway.parseChapterDiscussion(
        {'data_type': 6, 'topic': topic},
        bookId: _book,
        chapterId: _chapter,
      )!;
      expect(parsed.isDiscussionTopic, true);
      expect(parsed.isDiscussionPost, false);
      expect(parsed.isForumDiscussion, true);
      expect(parsed.identityKey, 'topic:author-topic');
      expect(parsed.text, startsWith('作者有话说\n'));
      expect(parsed.replyCount, 24);
      final cached = CommentItem.fromJson(parsed.toJson());
      expect(cached.discussionTopicId, 'author-topic');
      expect(cached.identityKey, parsed.identityKey);
    },
  );

  test('rich document safely renders paragraphs, mentions and images', () {
    final content = DiscussionPostContent.parse({
      'text': jsonEncode({
        'skeleton': {
          'type': 'html',
          'data':
              '<p>你好 &amp; 世界<br><cc_material_0></cc_material_0>'
              '<cc_material_1></cc_material_1><cc_material_2></cc_material_2>'
              '<cc_material_99></cc_material_99></p>'
              '<script>alert(1)</script><p>下一段</p>',
        },
        'materials': [
          {
            'type': 'mention_user',
            'data': {'user_name': '作者', 'text': ''},
          },
          {
            'type': 'image',
            'data': {'web_url': 'https://example.com/a.png'},
          },
          {
            'type': 'image',
            'data': {'web_url': 'javascript:alert(1)'},
          },
        ],
      }),
    });
    expect(content.text, contains('你好 & 世界\n@作者'));
    expect(content.text, contains('[图片暂不可用]'));
    expect(content.text, contains('[暂不支持的帖子附件]'));
    expect(content.text, endsWith('下一段'));
    expect(content.text, isNot(contains('alert')));
    expect(content.images, ['https://example.com/a.png']);
  });

  test('unsupported skeleton uses text extensions instead of JSON markup', () {
    final content = DiscussionPostContent.parse({
      'text': jsonEncode({
        'skeleton': {'type': 'unknown', 'data': 'opaque'},
      }),
      'text_exts': [
        {'text': '可读正文'},
        {'text': '@书友'},
      ],
    });
    expect(content.text, '可读正文 @书友');
    expect(DiscussionPostContent.parse({'text': '普通文本'}).text, '普通文本');
  });
}
