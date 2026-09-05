import 'book.dart';

/// 阅读历史模型 - 只要打开阅读过的书籍均会记录
class ReadingHistory {
  final String bookId;
  final String bookName;
  final String author;
  final String? thumbUrl;
  final String? category;
  final String creationStatus;
  final String? score;
  final String lastReadChapterTitle;
  final int lastReadChapterIndex;
  final DateTime lastReadTime;

  ReadingHistory({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.thumbUrl,
    this.category,
    this.creationStatus = '连载中',
    this.score,
    required this.lastReadChapterTitle,
    required this.lastReadChapterIndex,
    required this.lastReadTime,
  });

  Book toBook() {
    return Book(
      bookId: bookId,
      bookName: bookName,
      author: author,
      thumbUrl: thumbUrl,
      category: category,
      creationStatus: creationStatus,
      score: score,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'book_id': bookId,
      'book_name': bookName,
      'author': author,
      'thumb_url': thumbUrl,
      'category': category,
      'creation_status': creationStatus,
      'score': score,
      'last_read_chapter_title': lastReadChapterTitle,
      'last_read_chapter_index': lastReadChapterIndex,
      'last_read_time': lastReadTime.toIso8601String(),
    };
  }

  factory ReadingHistory.fromJson(Map<String, dynamic> json) {
    return ReadingHistory(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      thumbUrl: json['thumb_url']?.toString(),
      category: json['category']?.toString(),
      creationStatus: json['creation_status']?.toString() ?? '连载中',
      score: json['score']?.toString(),
      lastReadChapterTitle: json['last_read_chapter_title']?.toString() ?? '开始阅读',
      lastReadChapterIndex: json['last_read_chapter_index'] is int
          ? json['last_read_chapter_index'] as int
          : int.tryParse(json['last_read_chapter_index']?.toString() ?? '0') ?? 0,
      lastReadTime: json['last_read_time'] != null
          ? DateTime.tryParse(json['last_read_time'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
