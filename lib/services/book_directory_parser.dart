import '../models/chapter.dart';
import 'book_directory_cache.dart';
import 'font_decryptor.dart';

/// Parse the official directory JSON independently of the marketing/SSR page.
List<Chapter> parseBookDirectory(Map<String, dynamic> data) {
  final byId = <String, Chapter>{};
  final volumes = data['chapterListWithVolume'];
  final names = data['volumeNameList'];
  if (volumes is List) {
    for (var v = 0; v < volumes.length; v++) {
      final volume = volumes[v];
      if (volume is! List) continue;
      for (final entry in volume) {
        if (entry is! Map) continue;
        final id = (entry['itemId'] ?? entry['item_id'])?.toString() ?? '';
        if (id.isEmpty) continue;
        final title = FontDecryptor.decryptText(
          entry['title']?.toString() ?? '',
        );
        byId[id] = Chapter(
          itemId: id,
          title: title,
          volumeTitle: FontDecryptor.decryptText(
            (entry['volume_name'] ??
                        entry['volume_title'] ??
                        (names is List && v < names.length ? names[v] : ''))
                    ?.toString() ??
                '',
          ),
        );
      }
    }
  }
  final rawIds = data['allItemIds'] ?? data['itemIds'];
  final ids = rawIds is List && rawIds.isNotEmpty
      ? rawIds.map((id) => id.toString()).toList()
      : byId.keys.toList();
  final result = [
    for (var i = 0; i < ids.length; i++)
      Chapter(
        itemId: ids[i],
        title: byId[ids[i]]?.title.isNotEmpty == true
            ? byId[ids[i]]!.title
            : '第${i + 1}章',
        volumeTitle: byId[ids[i]]?.volumeTitle ?? '',
        order: i + 1,
      ),
  ];
  // Validate IDs/count before using them as navigation anchors or persisting.
  BookDirectoryCache.parseSaved(result.map((c) => c.toJson()).toList());
  return result;
}
