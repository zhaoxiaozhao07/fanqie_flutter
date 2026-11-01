import 'chapter.dart';
import 'reading_position.dart';

/// One versioned record is the authority for both chapter summary and text anchor.
/// Derived bookshelf/history summaries may be refreshed after this is committed.
class ReadingSnapshot {
  static const version = 2;
  final ReadingPosition position;
  final int chapterIndex;
  final String chapterTitle;
  final String? previousChapterId;
  final String? nextChapterId;
  final DateTime updatedAt;

  const ReadingSnapshot({
    required this.position,
    required this.updatedAt,
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.previousChapterId,
    this.nextChapterId,
  });

  Map<String, dynamic> toJson() => {
    ...position.toJson(),
    'schema_version': version,
    'chapter_index': chapterIndex,
    'chapter_title': chapterTitle,
    'previous_chapter_id': previousChapterId,
    'next_chapter_id': nextChapterId,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ReadingSnapshot.fromJson(Map<String, dynamic> json) {
    final schema = (json['schema_version'] as num?)?.toInt() ?? 1;
    if (schema < 1 || schema > version) {
      throw const FormatException('不支持的阅读进度版本');
    }
    final position = ReadingPosition.fromJson(json);
    if (position.chapterId.isEmpty) {
      throw const FormatException('阅读进度缺少章节标识');
    }
    return ReadingSnapshot(
      position: position,
      chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
      chapterTitle: json['chapter_title']?.toString() ?? '',
      previousChapterId: json['previous_chapter_id']?.toString(),
      nextChapterId: json['next_chapter_id']?.toString(),
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  ResumeTarget? resolve(List<Chapter> chapters) {
    if (chapters.isEmpty) return null;
    final exact = chapters.indexWhere((c) => c.itemId == position.chapterId);
    if (exact >= 0) return ResumeTarget(exact, position);

    // Never reuse an offset in a different chapter. Ambiguous titles aren't IDs.
    final sameTitles = [
      for (var i = 0; i < chapters.length; i++)
        if (chapterTitle.isNotEmpty && chapters[i].title == chapterTitle) i,
    ];
    var fallback = sameTitles.length == 1 ? sameTitles.single : -1;
    for (final id in [nextChapterId, previousChapterId]) {
      if (fallback >= 0) break;
      if (id != null) fallback = chapters.indexWhere((c) => c.itemId == id);
    }
    if (fallback < 0) fallback = chapterIndex.clamp(0, chapters.length - 1);
    return ResumeTarget(
      fallback,
      ReadingPosition(chapterId: chapters[fallback].itemId),
      notice: '原阅读章节已变动，已定位到「${chapters[fallback].title}」章首',
    );
  }
}

class ResumeTarget {
  final int chapterIndex;
  final ReadingPosition position;
  final String? notice;

  const ResumeTarget(this.chapterIndex, this.position, {this.notice});
}
