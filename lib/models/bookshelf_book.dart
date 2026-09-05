import 'book.dart';

/// 书架书籍模型
class BookshelfBook {
  final String bookId;
  final String bookName;
  final String author;
  final String? thumbUrl;
  final String? category;
  final String creationStatus;
  final String? score;
  final String? abstract;
  final String? lastReadChapterTitle;
  final int? lastReadChapterIndex;
  final DateTime? lastReadTime;
  final DateTime addedTime;

  BookshelfBook({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.thumbUrl,
    this.category,
    this.creationStatus = '连载中',
    this.score,
    this.abstract,
    this.lastReadChapterTitle,
    this.lastReadChapterIndex,
    this.lastReadTime,
    DateTime? addedTime,
  }) : addedTime = addedTime ?? DateTime.now();

  factory BookshelfBook.fromBook(
    Book book, {
    int? chapterIndex,
    String? chapterTitle,
    DateTime? readTime,
  }) {
    return BookshelfBook(
      bookId: book.bookId,
      bookName: book.bookName,
      author: book.author,
      thumbUrl: book.thumbUrl,
      category: book.category,
      creationStatus: book.creationStatus,
      score: book.score,
      abstract: book.abstract,
      lastReadChapterIndex: chapterIndex,
      lastReadChapterTitle: chapterTitle,
      lastReadTime: readTime,
      addedTime: DateTime.now(),
    );
  }

  Book toBook() {
    return Book(
      bookId: bookId,
      bookName: bookName,
      author: author,
      thumbUrl: thumbUrl,
      category: category,
      creationStatus: creationStatus,
      score: score,
      abstract: abstract,
    );
  }

  BookshelfBook copyWith({
    String? lastReadChapterTitle,
    int? lastReadChapterIndex,
    DateTime? lastReadTime,
  }) {
    return BookshelfBook(
      bookId: bookId,
      bookName: bookName,
      author: author,
      thumbUrl: thumbUrl,
      category: category,
      creationStatus: creationStatus,
      score: score,
      abstract: abstract,
      lastReadChapterTitle: lastReadChapterTitle ?? this.lastReadChapterTitle,
      lastReadChapterIndex: lastReadChapterIndex ?? this.lastReadChapterIndex,
      lastReadTime: lastReadTime ?? this.lastReadTime,
      addedTime: addedTime,
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
      'abstract': abstract,
      'last_read_chapter_title': lastReadChapterTitle,
      'last_read_chapter_index': lastReadChapterIndex,
      'last_read_time': lastReadTime?.toIso8601String(),
      'added_time': addedTime.toIso8601String(),
    };
  }

  factory BookshelfBook.fromJson(Map<String, dynamic> json) {
    return BookshelfBook(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      thumbUrl: json['thumb_url']?.toString(),
      category: json['category']?.toString(),
      creationStatus: json['creation_status']?.toString() ?? '连载中',
      score: json['score']?.toString(),
      abstract: json['abstract']?.toString(),
      lastReadChapterTitle: json['last_read_chapter_title']?.toString(),
      lastReadChapterIndex: json['last_read_chapter_index'] is int
          ? json['last_read_chapter_index'] as int
          : int.tryParse(json['last_read_chapter_index']?.toString() ?? ''),
      lastReadTime: json['last_read_time'] != null
          ? DateTime.tryParse(json['last_read_time'].toString())
          : null,
      addedTime: json['added_time'] != null
          ? DateTime.tryParse(json['added_time'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
