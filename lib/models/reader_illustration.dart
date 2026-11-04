import 'dart:math' as math;

/// An illustration anchored to the unchanged canonical text. Paths are local,
/// content-addressed assets, never URLs or arbitrary archive paths.
class ReaderIllustration {
  final String id;
  final String? asset;
  final String alt;
  final String? error;
  final int width, height, paragraphIndex, characterOffset;

  const ReaderIllustration({
    required this.id,
    this.asset,
    this.alt = '',
    this.error,
    this.width = 512,
    this.height = 384,
    this.paragraphIndex = 0,
    this.characterOffset = 0,
  });

  static final assetPattern = RegExp(
    r'^images/[a-f0-9]{64}\.(png|jpg|gif|webp|bmp|svg)$',
  );

  ReaderIllustration at(int paragraph, int offset) => ReaderIllustration(
    id: id,
    asset: asset,
    alt: alt,
    error: error,
    width: width,
    height: height,
    paragraphIndex: paragraph,
    characterOffset: offset,
  );

  double displayHeight(double availableWidth, double maxHeight) {
    if (error != null || asset == null) {
      return math.min(80, maxHeight).toDouble();
    }
    return math
        .min(
          math.min(availableWidth, width.toDouble()) * height / width,
          maxHeight,
        )
        .clamp(1, maxHeight)
        .toDouble();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'asset': asset,
    'alt': alt,
    'error': error,
    'width': width,
    'height': height,
    'paragraph': paragraphIndex,
    'offset': characterOffset,
  };

  static List<ReaderIllustration> parseList(dynamic data) {
    if (data is! List) return const [];
    final result = <ReaderIllustration>[];
    for (final value in data.take(2000)) {
      if (value is! Map) continue;
      final width = int.tryParse(value['width']?.toString() ?? '') ?? 512;
      final height = int.tryParse(value['height']?.toString() ?? '') ?? 384;
      final asset = value['asset']?.toString();
      final valid = asset == null || assetPattern.hasMatch(asset);
      result.add(
        ReaderIllustration(
          id: value['id']?.toString() ?? 'image_${result.length}',
          asset: valid ? asset : null,
          alt: String.fromCharCodes(
            (value['alt']?.toString() ?? '')
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim()
                .runes
                .take(200),
          ),
          error: valid ? value['error']?.toString() : '插图路径无效',
          width: width > 0 && width <= 16000 ? width : 512,
          height: height > 0 && height <= 16000 ? height : 384,
          paragraphIndex: math.max(
            0,
            int.tryParse(value['paragraph']?.toString() ?? '') ?? 0,
          ),
          characterOffset: math.max(
            0,
            int.tryParse(value['offset']?.toString() ?? '') ?? 0,
          ),
        ),
      );
    }
    return List.unmodifiable(result);
  }
}
