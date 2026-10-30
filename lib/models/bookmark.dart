/// 书签数据模型
class Bookmark {
  final String id;
  final String bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int paragraphIndex;
  final String contentPreview;
  final DateTime createdAt;

  Bookmark({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.paragraphIndex = 0,
    required this.contentPreview,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'chapter_index': chapterIndex,
        'chapter_title': chapterTitle,
        'paragraph_index': paragraphIndex,
        'content_preview': contentPreview,
        'created_at': createdAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) {
    return Bookmark(
      id: json['id']?.toString() ?? '',
      bookId: json['book_id']?.toString() ?? '',
      chapterIndex: json['chapter_index'] as int? ?? 0,
      chapterTitle: json['chapter_title']?.toString() ?? '',
      paragraphIndex: json['paragraph_index'] as int? ?? 0,
      contentPreview: json['content_preview']?.toString() ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// 划线与阅读笔记模型
class ReadingNote {
  final String id;
  final String bookId;
  final int chapterIndex;
  final String chapterTitle;
  final int paragraphIndex;
  final String text; // 划线文本内容
  final String note; // 读者感悟笔记
  final DateTime createdAt;

  ReadingNote({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.paragraphIndex = 0,
    required this.text,
    this.note = '',
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'book_id': bookId,
        'chapter_index': chapterIndex,
        'chapter_title': chapterTitle,
        'paragraph_index': paragraphIndex,
        'text': text,
        'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  factory ReadingNote.fromJson(Map<String, dynamic> json) {
    return ReadingNote(
      id: json['id']?.toString() ?? '',
      bookId: json['book_id']?.toString() ?? '',
      chapterIndex: json['chapter_index'] as int? ?? 0,
      chapterTitle: json['chapter_title']?.toString() ?? '',
      paragraphIndex: json['paragraph_index'] as int? ?? 0,
      text: json['text']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}
