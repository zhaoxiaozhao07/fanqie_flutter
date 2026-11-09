int _number(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;
DateTime _date(dynamic value) =>
    DateTime.tryParse(value?.toString() ?? '') ??
    DateTime.fromMillisecondsSinceEpoch(0);

class Bookmark {
  final String id, bookId, chapterTitle, chapterId, contentPreview;
  final int chapterIndex, paragraphIndex, characterOffset;
  final DateTime createdAt;
  Bookmark({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.chapterId = '',
    this.paragraphIndex = 0,
    this.characterOffset = 0,
    required this.contentPreview,
    required this.createdAt,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'book_id': bookId,
    'chapter_index': chapterIndex,
    'chapter_id': chapterId,
    'chapter_title': chapterTitle,
    'paragraph_index': paragraphIndex,
    'character_offset': characterOffset,
    'content_preview': contentPreview,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id']?.toString() ?? '',
    bookId: json['book_id']?.toString() ?? '',
    chapterIndex: _number(json['chapter_index']),
    chapterId: json['chapter_id']?.toString() ?? '',
    chapterTitle: json['chapter_title']?.toString() ?? '',
    paragraphIndex: _number(json['paragraph_index']),
    characterOffset: _number(json['character_offset']),
    contentPreview: json['content_preview']?.toString() ?? '',
    createdAt: _date(json['created_at']),
  );
}

class ReadingNote {
  final String id,
      bookId,
      chapterTitle,
      chapterId,
      text,
      note,
      chapterHash,
      prefix,
      suffix;
  final int chapterIndex,
      paragraphIndex,
      endParagraphIndex,
      startOffset,
      endOffset,
      colorIndex;
  final List<String> tags;
  final DateTime createdAt, updatedAt;
  ReadingNote({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterTitle,
    this.chapterId = '',
    this.paragraphIndex = 0,
    int? endParagraphIndex,
    required this.text,
    this.note = '',
    this.startOffset = -1,
    this.endOffset = -1,
    this.chapterHash = '',
    this.prefix = '',
    this.suffix = '',
    this.colorIndex = 0,
    this.tags = const [],
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt,
       endParagraphIndex = endParagraphIndex ?? paragraphIndex;
  bool get isSpanning => endParagraphIndex > paragraphIndex;
  bool get validAnchor =>
      paragraphIndex >= 0 &&
      endParagraphIndex >= paragraphIndex &&
      (isSpanning
          ? startOffset >= 0 &&
                endOffset > 0 &&
                text.contains('\n\n') &&
                text.length <= 20000
          : startOffset < 0 || endOffset - startOffset == text.length);
  Map<String, dynamic> toJson() => {
    'version': isSpanning ? 3 : 2,
    'id': id,
    'book_id': bookId,
    'chapter_id': chapterId,
    'chapter_index': chapterIndex,
    'chapter_title': chapterTitle,
    'paragraph_index': paragraphIndex,
    if (isSpanning) 'end_paragraph_index': endParagraphIndex,
    'text': text,
    'note': note,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'chapter_hash': chapterHash,
    'prefix': prefix,
    'suffix': suffix,
    'color_index': colorIndex,
    'tags': tags,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
  factory ReadingNote.fromJson(Map<String, dynamic> json) => ReadingNote(
    id: json['id']?.toString() ?? '',
    bookId: json['book_id']?.toString() ?? '',
    chapterIndex: _number(json['chapter_index']),
    chapterId: json['chapter_id']?.toString() ?? '',
    chapterTitle: json['chapter_title']?.toString() ?? '',
    paragraphIndex: _number(json['paragraph_index']),
    endParagraphIndex: _number(
      json['end_paragraph_index'],
      _number(json['paragraph_index']),
    ),
    text: json['text']?.toString() ?? '',
    note: json['note']?.toString() ?? '',
    startOffset: _number(json['start_offset'], -1),
    endOffset: _number(json['end_offset'], -1),
    chapterHash: json['chapter_hash']?.toString() ?? '',
    prefix: json['prefix']?.toString() ?? '',
    suffix: json['suffix']?.toString() ?? '',
    colorIndex: _number(json['color_index']).clamp(0, 3),
    tags: (json['tags'] is List ? json['tags'] as List : const [])
        .whereType<String>()
        .take(10)
        .toList(),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at'] ?? json['created_at']),
  );
  ReadingNote edited({
    required String note,
    required int colorIndex,
    required List<String> tags,
  }) => ReadingNote(
    id: id,
    bookId: bookId,
    chapterId: chapterId,
    chapterIndex: chapterIndex,
    chapterTitle: chapterTitle,
    paragraphIndex: paragraphIndex,
    endParagraphIndex: endParagraphIndex,
    text: text,
    note: note,
    startOffset: startOffset,
    endOffset: endOffset,
    chapterHash: chapterHash,
    prefix: prefix,
    suffix: suffix,
    colorIndex: colorIndex.clamp(0, 3),
    tags: tags,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );
}
