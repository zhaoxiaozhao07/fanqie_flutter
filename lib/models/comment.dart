/// 段落/章节/书籍评论条目
class CommentItem {
  final String id;
  final String bookId;
  final String chapterId;
  final int paraIndex;
  final String userName;
  final String userId;
  final String avatar;
  final bool isAuthor;
  final bool isVip;
  final List<String> titles;
  final String text;
  final List<String> images;
  final int createTime;
  final int diggCount;
  final int replyCount;
  final int? score;
  final String? paraSrcContent;

  const CommentItem({
    required this.id,
    required this.bookId,
    required this.chapterId,
    this.paraIndex = 0,
    required this.userName,
    this.userId = '',
    this.avatar = '',
    this.isAuthor = false,
    this.isVip = false,
    this.titles = const [],
    required this.text,
    this.images = const [],
    this.createTime = 0,
    this.diggCount = 0,
    this.replyCount = 0,
    this.score,
    this.paraSrcContent,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'bookId': bookId,
      'chapterId': chapterId,
      'paraIndex': paraIndex,
      'userName': userName,
      'userId': userId,
      'avatar': avatar,
      'isAuthor': isAuthor,
      'isVip': isVip,
      'titles': titles,
      'text': text,
      'images': images,
      'createTime': createTime,
      'diggCount': diggCount,
      'replyCount': replyCount,
      if (score != null) 'score': score,
      if (paraSrcContent != null) 'paraSrcContent': paraSrcContent,
    };
  }

  factory CommentItem.fromJson(Map<String, dynamic> json) {
    return CommentItem(
      id: json['id']?.toString() ?? '',
      bookId: json['bookId']?.toString() ?? '',
      chapterId: json['chapterId']?.toString() ?? '',
      paraIndex: json['paraIndex'] is int
          ? json['paraIndex'] as int
          : int.tryParse(json['paraIndex']?.toString() ?? '0') ?? 0,
      userName: json['userName']?.toString() ?? '书友',
      userId: json['userId']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
      isAuthor: json['isAuthor'] == true,
      isVip: json['isVip'] == true,
      titles: (json['titles'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      text: json['text']?.toString() ?? '',
      images: (json['images'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      createTime: json['createTime'] is int
          ? json['createTime'] as int
          : int.tryParse(json['createTime']?.toString() ?? '0') ?? 0,
      diggCount: json['diggCount'] is int
          ? json['diggCount'] as int
          : int.tryParse(json['diggCount']?.toString() ?? '0') ?? 0,
      replyCount: json['replyCount'] is int
          ? json['replyCount'] as int
          : int.tryParse(json['replyCount']?.toString() ?? '0') ?? 0,
      score: json['score'] is int
          ? json['score'] as int
          : int.tryParse(json['score']?.toString() ?? ''),
      paraSrcContent: json['paraSrcContent']?.toString(),
    );
  }
}

/// 二级评论 / 楼中楼回复条目
class CommentReplyItem {
  final String replyId;
  final String parentCommentId;
  final String? parentReplyId;
  final String userName;
  final String userId;
  final String avatar;
  final bool isAuthor;
  final List<String> titles;
  final String text;
  final List<String> images;
  final int createTime;
  final int diggCount;

  const CommentReplyItem({
    required this.replyId,
    required this.parentCommentId,
    this.parentReplyId,
    required this.userName,
    this.userId = '',
    this.avatar = '',
    this.isAuthor = false,
    this.titles = const [],
    required this.text,
    this.images = const [],
    this.createTime = 0,
    this.diggCount = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'replyId': replyId,
      'parentCommentId': parentCommentId,
      if (parentReplyId != null) 'parentReplyId': parentReplyId,
      'userName': userName,
      'userId': userId,
      'avatar': avatar,
      'isAuthor': isAuthor,
      'titles': titles,
      'text': text,
      'images': images,
      'createTime': createTime,
      'diggCount': diggCount,
    };
  }

  factory CommentReplyItem.fromJson(Map<String, dynamic> json) {
    return CommentReplyItem(
      replyId: json['replyId']?.toString() ?? '',
      parentCommentId: json['parentCommentId']?.toString() ?? '',
      parentReplyId: json['parentReplyId']?.toString(),
      userName: json['userName']?.toString() ?? '书友',
      userId: json['userId']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
      isAuthor: json['isAuthor'] == true,
      titles: (json['titles'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      text: json['text']?.toString() ?? '',
      images: (json['images'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
      createTime: json['createTime'] is int
          ? json['createTime'] as int
          : int.tryParse(json['createTime']?.toString() ?? '0') ?? 0,
      diggCount: json['diggCount'] is int
          ? json['diggCount'] as int
          : int.tryParse(json['diggCount']?.toString() ?? '0') ?? 0,
    );
  }
}

/// 章节段评统计信息（段落索引 -> 评论数量映射）
class ChapterCommentStats {
  final String chapterId;
  final Map<int, int> counts;
  final int totalCount;

  const ChapterCommentStats({
    required this.chapterId,
    this.counts = const {},
    this.totalCount = 0,
  });

  int getCount(int paraIndex) => counts[paraIndex] ?? 0;
  bool hasComment(int paraIndex) => (counts[paraIndex] ?? 0) > 0;

  Map<String, dynamic> toJson() {
    return {
      'chapterId': chapterId,
      'counts': counts.map((k, v) => MapEntry(k.toString(), v)),
      'totalCount': totalCount,
    };
  }

  factory ChapterCommentStats.fromJson(Map<String, dynamic> json) {
    final rawCounts = json['counts'] as Map<String, dynamic>? ?? {};
    final counts = <int, int>{};
    var total = 0;
    for (final e in rawCounts.entries) {
      final pIdx = int.tryParse(e.key);
      final c = e.value is int ? e.value as int : int.tryParse(e.value.toString()) ?? 0;
      if (pIdx != null && c > 0) {
        counts[pIdx] = c;
        total += c;
      }
    }
    return ChapterCommentStats(
      chapterId: json['chapterId']?.toString() ?? '',
      counts: counts,
      totalCount: json['totalCount'] is int
          ? json['totalCount'] as int
          : total,
    );
  }
}

/// 评论分页数据包装
class CommentPageData {
  final List<CommentItem> comments;
  final String cursor;
  final bool hasMore;
  final int total;

  const CommentPageData({
    this.comments = const [],
    this.cursor = '',
    this.hasMore = false,
    this.total = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'comments': comments.map((c) => c.toJson()).toList(),
      'cursor': cursor,
      'hasMore': hasMore,
      'total': total,
    };
  }

  factory CommentPageData.fromJson(Map<String, dynamic> json) {
    final list = (json['comments'] as List<dynamic>?)
            ?.map((e) => CommentItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return CommentPageData(
      comments: list,
      cursor: json['cursor']?.toString() ?? '',
      hasMore: json['hasMore'] == true,
      total: json['total'] is int
          ? json['total'] as int
          : int.tryParse(json['total']?.toString() ?? '0') ?? 0,
    );
  }
}

/// 回复分页数据包装
class CommentReplyPageData {
  final List<CommentReplyItem> replies;
  final String cursor;
  final bool hasMore;
  final int total;

  const CommentReplyPageData({
    this.replies = const [],
    this.cursor = '',
    this.hasMore = false,
    this.total = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'replies': replies.map((r) => r.toJson()).toList(),
      'cursor': cursor,
      'hasMore': hasMore,
      'total': total,
    };
  }

  factory CommentReplyPageData.fromJson(Map<String, dynamic> json) {
    final list = (json['replies'] as List<dynamic>?)
            ?.map((e) => CommentReplyItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return CommentReplyPageData(
      replies: list,
      cursor: json['cursor']?.toString() ?? '',
      hasMore: json['hasMore'] == true,
      total: json['total'] is int
          ? json['total'] as int
          : int.tryParse(json['total']?.toString() ?? '0') ?? 0,
    );
  }
}
