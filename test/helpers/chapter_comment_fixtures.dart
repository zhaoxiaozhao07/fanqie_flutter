import 'package:fanqie_flutter/models/comment.dart';
import 'package:fanqie_flutter/services/api_service.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

CommentItem chapterComment(String id) => CommentItem(
  id: id,
  bookId: 'book',
  chapterId: 'chapter',
  userName: '书友$id',
  text: '评论-$id',
);

CommentPageData chapterCommentPage(
  List<String> ids, {
  int total = 15,
  String cursor = '',
  bool hasMore = false,
}) => CommentPageData(
  comments: List.unmodifiable(ids.map(chapterComment)),
  total: total,
  cursor: cursor,
  hasMore: hasMore,
);

class ChapterCommentRequest {
  final int offset, count;
  final bool preferCache;
  const ChapterCommentRequest(this.offset, this.count, this.preferCache);
}

class ChapterCommentGateway extends Fake implements FanqieMobileGateway {
  final Future<CommentPageData?> Function(int offset, int count) load;
  final List<ChapterCommentRequest> requests = [];
  ChapterCommentGateway(this.load);

  @override
  Future<CommentPageData?> fetchChapterComments(
    String bookId,
    String itemId, {
    int offset = 0,
    int count = 20,
  }) {
    requests.add(ChapterCommentRequest(offset, count, false));
    return load(offset, count);
  }
}

class ChapterCommentApi extends ApiService {
  final Future<CommentPageData?> Function(ChapterCommentRequest) load;
  final List<ChapterCommentRequest> requests = [];
  bool disposed = false;
  ChapterCommentApi(this.load);

  @override
  Future<CommentPageData?> getChapterComments(
    String bookId,
    String itemId, {
    int offset = 0,
    int count = 20,
    bool preferCache = true,
  }) {
    final request = ChapterCommentRequest(offset, count, preferCache);
    requests.add(request);
    return load(request);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
