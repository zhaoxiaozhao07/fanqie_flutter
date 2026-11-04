import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/reader_illustration.dart';
import 'atomic_file.dart';
import 'book_image_fetcher.dart';
import 'online_chapter.dart';
import 'reader_cache_service.dart';
import 'reader_text.dart';

/// Versioned, text-bound sidecars. Old text is never overwritten to repair
/// pictures. Explicit downloads are promoted to the protected offline tree.
class OnlineIllustrationStore {
  final ReaderCacheService cache;
  final BookImageFetcher fetcher;
  OnlineIllustrationStore(this.cache, http.Client client)
    : fetcher = BookImageFetcher(client);

  String _hash(String text) =>
      sha256.convert(utf8.encode(text.trim())).toString();

  Future<File> _file(String book, String chapter, bool permanent) async {
    final root = (await cache.documents()).path;
    return File(
      '$root/${permanent ? 'offline_books' : 'reader_cache_v2'}/'
      '${ReaderCacheService.segment(book)}/${ReaderCacheService.segment(chapter)}.images.json',
    );
  }

  Future<(File, Map<String, dynamic>)?> _read(
    String book,
    String chapter,
    String text,
  ) async {
    for (final permanent in [true, false]) {
      final file = await _file(book, chapter, permanent);
      try {
        if (await FileSystemEntity.isLink(file.parent.path) ||
            await FileSystemEntity.isLink(file.parent.parent.path) ||
            await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.length() > 2 * 1024 * 1024) {
          continue;
        }
        final data = jsonDecode(await file.readAsString());
        if (data is Map<String, dynamic> &&
            data['version'] == 1 &&
            data['textHash'] == _hash(text) &&
            data['images'] is List) {
          return (file, data);
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> saveSources(
    String book,
    String chapter,
    OnlineChapter document, {
    bool replace = false,
  }) async {
    if (book.startsWith('local_')) return;
    final existing = await _read(book, chapter, document.text);
    if (existing != null && !replace) return;
    final file = existing?.$1 ?? await _file(book, chapter, false);
    await AtomicFile.writeString(
      file,
      jsonEncode({
        'version': 1,
        'textHash': _hash(document.text),
        'images': [
          for (var i = 0; i < document.images.length; i++)
            {
              'id': 'online_$i',
              'source': document.images[i].source,
              'alt': document.images[i].alt,
              'rawOffset': document.images[i].offset,
            },
        ],
      }),
    );
  }

  Future<bool> hasSources(String book, String chapter, String text) async =>
      await _read(book, chapter, text) != null;

  Future<List<ReaderIllustration>> read(
    String book,
    String chapter,
    String text, {
    String? title,
  }) async {
    final record = await _read(book, chapter, text);
    if (record == null) return const [];
    return [
      for (final raw in (record.$2['images'] as List).whereType<Map>().take(
        2000,
      ))
        ...ReaderIllustration.parseList([raw]).map((image) {
          final position = ReaderText.positionInRaw(
            text,
            int.tryParse(raw['rawOffset']?.toString() ?? '') ?? 0,
            chapterTitle: title,
          );
          return image.at(position.paragraphIndex, position.characterOffset);
        }),
    ];
  }

  // Serialize per book (including concurrent engine instances) so quota checks,
  // shared assets, retries and download promotion cannot race one another.
  static final _operations = <String, Future<void>>{};
  Future<void> hydrate(
    String book,
    String chapter,
    String text, {
    bool permanent = false,
  }) async {
    final key = '${(await cache.documents()).path}/$book';
    final previous = _operations[key] ?? Future<void>.value();
    final next = previous
        .catchError((_) {})
        .then((_) => _hydrate(book, chapter, text, permanent: permanent));
    _operations[key] = next;
    try {
      await next;
    } finally {
      if (identical(_operations[key], next)) _operations.remove(key);
    }
  }

  Future<void> _hydrate(
    String book,
    String chapter,
    String text, {
    required bool permanent,
  }) async {
    final record = await _read(book, chapter, text);
    if (record == null) throw const FormatException('插图信息未获取，请联网重试');
    final target = permanent ? await _file(book, chapter, true) : record.$1;
    if ((record.$2['images'] as List).isEmpty) {
      await AtomicFile.writeString(target, jsonEncode(record.$2));
      return;
    }
    final directory = Directory('${target.parent.path}/images');
    if (await FileSystemEntity.isLink(target.parent.path) ||
        await FileSystemEntity.isLink(directory.path)) {
      throw const FileSystemException('插图目录不安全');
    }
    await directory.create(recursive: true);
    var total = 0;
    await for (final file in directory.list(followLinks: false)) {
      if (file is File) total += await file.length();
    }
    var failures = 0;
    for (final raw in (record.$2['images'] as List).whereType<Map>()) {
      try {
        final asset = raw['asset']?.toString();
        if (asset != null && ReaderIllustration.assetPattern.hasMatch(asset)) {
          final existing = File('${record.$1.parent.path}/$asset');
          BookImageData? validated;
          if (!await FileSystemEntity.isLink(existing.parent.path) &&
              await FileSystemEntity.type(existing.path, followLinks: false) ==
                  FileSystemEntityType.file &&
              await existing.length() <= BookImageFetcher.maxBytes) {
            try {
              validated = await BookImageFetcher.validate(
                await existing.readAsBytes(),
              );
            } catch (_) {
              // Corrupt bytes should be refetched on this retry, not the next.
            }
          }
          if (validated != null) {
            final destination = File('${target.parent.path}/$asset');
            if (target.path != record.$1.path && !await destination.exists()) {
              if (total + validated.bytes.length > 128 * 1024 * 1024) {
                throw const FormatException('本书插图超过 128 MB');
              }
              await AtomicFile.writeBytes(destination, validated.bytes);
              total += validated.bytes.length;
            }
            raw.remove('error');
            continue;
          }
        }
        final image = await fetcher.fetch(raw['source']?.toString() ?? '');
        final name = 'images/${sha256.convert(image.bytes)}.${image.extension}';
        final file = File('${target.parent.path}/$name');
        final previousSize =
            await FileSystemEntity.type(file.path, followLinks: false) ==
                FileSystemEntityType.file
            ? await file.length()
            : 0;
        if (total - previousSize + image.bytes.length > 128 * 1024 * 1024) {
          throw const FormatException('本书插图超过 128 MB');
        }
        await AtomicFile.writeBytes(file, image.bytes);
        total += image.bytes.length - previousSize;
        raw
          ..['asset'] = name
          ..['width'] = image.width
          ..['height'] = image.height
          ..remove('error');
      } catch (_) {
        // A previous corrupt image must not permanently suppress the network.
        raw
          ..remove('asset')
          ..['error'] = '插图下载失败，请联网重试';
        failures++;
      }
    }
    await AtomicFile.writeString(target, jsonEncode(record.$2));
    if (!permanent) {
      final policy = await ReaderCachePolicy.load();
      await cache.trim(policy.maxBytes);
    }
    if (failures > 0) throw FormatException('$failures 幅插图未下载，请重试');
  }
}
