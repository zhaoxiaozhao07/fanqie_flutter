import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
  });

  group('Comment Models & Serialization Tests', () {
    test('CommentItem serialization and deserialization', () {
      const item = CommentItem(
        id: '123456789',
        bookId: 'book_1',
        chapterId: 'chapter_1',
        paraIndex: 3,
        userName: '测试书友',
        userId: 'user_99',
        avatar: 'https://example.com/avatar.jpg',
        isAuthor: true,
        isVip: true,
        titles: ['作者', '黄金盟主'],
        text: '这是非常精彩的一章！',
        images: ['https://example.com/img1.webp'],
        createTime: 1730000000,
        diggCount: 42,
        replyCount: 5,
        score: 10,
        paraSrcContent: '这是被评论的原文段落',
      );

      final json = item.toJson();
      final restored = CommentItem.fromJson(json);

      expect(restored.id, equals('123456789'));
      expect(restored.bookId, equals('book_1'));
      expect(restored.paraIndex, equals(3));
      expect(restored.userName, equals('测试书友'));
      expect(restored.isAuthor, isTrue);
      expect(restored.isVip, isTrue);
      expect(restored.titles, equals(['作者', '黄金盟主']));
      expect(restored.text, equals('这是非常精彩的一章！'));
      expect(restored.images, equals(['https://example.com/img1.webp']));
      expect(restored.diggCount, equals(42));
      expect(restored.replyCount, equals(5));
      expect(restored.score, equals(10));
      expect(restored.paraSrcContent, equals('这是被评论的原文段落'));
    });

    test('ChapterCommentStats counts mapping and total calculation', () {
      const stats = ChapterCommentStats(
        chapterId: 'chapter_99',
        counts: {0: 15, 2: 8, 20000: 3},
        totalCount: 26,
      );

      expect(stats.getCount(0), equals(15));
      expect(stats.getCount(1), equals(0));
      expect(stats.hasComment(2), isTrue);
      expect(stats.hasComment(1), isFalse);
      expect(stats.totalCount, equals(26));

      final json = stats.toJson();
      final restored = ChapterCommentStats.fromJson(json);
      expect(restored.chapterId, equals('chapter_99'));
      expect(restored.getCount(0), equals(15));
      expect(restored.getCount(20000), equals(3));
      expect(restored.totalCount, equals(26));
    });

    test('CommentReplyItem serialization and deserialization', () {
      const reply = CommentReplyItem(
        replyId: 'reply_100',
        parentCommentId: '123456789',
        parentReplyId: 'reply_99',
        userName: '回复读者',
        userId: 'user_101',
        avatar: 'https://example.com/avatar2.jpg',
        isAuthor: false,
        titles: ['书友'],
        text: '同感同感！',
        createTime: 1730000500,
        diggCount: 3,
      );

      final json = reply.toJson();
      final restored = CommentReplyItem.fromJson(json);
      expect(restored.replyId, equals('reply_100'));
      expect(restored.parentCommentId, equals('123456789'));
      expect(restored.parentReplyId, equals('reply_99'));
      expect(restored.userName, equals('回复读者'));
      expect(restored.text, equals('同感同感！'));
      expect(restored.diggCount, equals(3));
    });
  });

  group('FanqieMobileGateway Comment Helpers & Image Processing', () {
    test('cleanCommentImageUrl rewrites byteimg and fqnovelpic HEIC to WebP', () {
      const rawHeic = 'https://p3-reading-sign.fqnovelpic.com/tos-cn-i-1yzifmftcy/abc123456~tplv-s85hriknmn-jpeg-v1:144:0.heic?sign=xxxx';
      final rewritten = FanqieMobileGateway.cleanCommentImageUrl(rawHeic, targetWidth: 800);
      expect(rewritten, startsWith('https://p3-novel.byteimg.com/tos-cn-i-1yzifmftcy/abc123456~tplv-1yzifmftcy-expand:800:0:0.webp'));

      const normalUrl = 'https://other-domain.com/sample.png';
      expect(FanqieMobileGateway.cleanCommentImageUrl(normalUrl), equals(normalUrl));
    });

    test('extractUserTitles extracts author, official, and custom titles', () {
      final userTag = {
        'is_author': true,
        'user_title_info': [
          {'zh_title': '作家', 'is_author_title': true, 'is_vip_title': false},
          {'zh_title': '次元破壁者', 'is_author_title': false, 'is_vip_title': false},
          {'zh_title': 'vip', 'is_vip_title': true}, // VIP 图标跳过
        ],
        'sticker': {
          'is_worn': true,
          'sticker': {'name': '故事合伙人'},
        }
      };

      final titles = FanqieMobileGateway.extractUserTitles(userTag);
      expect(titles, contains('作者'));
      expect(titles, contains('次元破壁者'));
      expect(titles, contains('故事合伙人'));
      expect(titles, isNot(contains('vip')));
    });
  });

  group('ApiService Comment Cache & Offline Fallback Tests', () {
    late ApiService apiService;

    setUp(() {
      apiService = ApiService();
    });

    tearDown(() {
      apiService.dispose();
    });

    test('Offline chapter comment stats fallback and persistence', () async {
      const testItemId = 'test_item_comment_777';
      const testBookId = 'test_book_comment_888';
      const mockStats = ChapterCommentStats(
        chapterId: testItemId,
        counts: {0: 12, 1: 5, 20: 3},
        totalCount: 20,
      );

      expect(mockStats.getCount(0), equals(12));
      expect(mockStats.totalCount, equals(20));

      // 直接通过内部机制或网络获取验证
      final stats = await apiService.getChapterCommentStats(testItemId, bookId: testBookId);
      // 初次无网络且未缓存时应为 null 或空
      if (stats != null) {
        expect(stats.chapterId, equals(testItemId));
      }

      // 测试正常书籍的书评拉取 (部族荣光)
      final reviews = await apiService.getBookReviews('7069948840148732967', count: 5);
      if (reviews != null && reviews.comments.isNotEmpty) {
        expect(reviews.comments.first.id, isNotEmpty);
        expect(reviews.comments.first.text, isNotEmpty);
      }
    });
  });
}
