/// 与屏幕尺寸、字号及阅读模式无关的原文锚点。
class ReadingPosition {
  final String chapterId;
  final int paragraphIndex;
  final int characterOffset;
  final double viewportFraction;
  final String? imageId;

  const ReadingPosition({
    required this.chapterId,
    this.paragraphIndex = 0,
    this.characterOffset = 0,
    this.viewportFraction = 0,
    this.imageId,
  });

  Map<String, dynamic> toJson() => {
    'chapter_id': chapterId,
    'paragraph_index': paragraphIndex,
    'character_offset': characterOffset,
    'viewport_fraction': viewportFraction,
    if (imageId != null) 'image_id': imageId,
  };

  factory ReadingPosition.fromJson(Map<String, dynamic> json) =>
      ReadingPosition(
        chapterId: json['chapter_id']?.toString() ?? '',
        paragraphIndex: ((json['paragraph_index'] as num?)?.toInt() ?? 0).clamp(
          0,
          1 << 30,
        ),
        characterOffset: ((json['character_offset'] as num?)?.toInt() ?? 0)
            .clamp(0, 1 << 30),
        viewportFraction: ((json['viewport_fraction'] as num?)?.toDouble() ?? 0)
            .clamp(0.0, 1.0),
        imageId: json['image_id']?.toString(),
      );
}
