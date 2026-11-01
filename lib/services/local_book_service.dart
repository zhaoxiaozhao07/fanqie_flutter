import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import '../models/chapter.dart';
import 'atomic_file.dart';
import 'bookshelf_service.dart';
import 'local_book_parser.dart';
import 'local_text_encoding.dart';
import 'reader_text.dart';
import 'safe_zip_reader.dart';

export 'local_book_parser.dart' show LocalChapterRule, LocalImportCancelled;
export 'local_text_encoding.dart' show LocalImportToken;

class LocalImportResult {
  final Book book;
  final List<Chapter> chapters;
  final int chapterCount;
  final bool alreadyExists;
  LocalImportResult({
    required this.book,
    required this.chapters,
    required this.chapterCount,
    this.alreadyExists = false,
  });
}

class LocalImportOptions {
  final String encoding;
  final LocalChapterRule chapterRule;
  const LocalImportOptions({
    this.encoding = 'auto',
    this.chapterRule = LocalChapterRule.automatic,
  });
}

class LocalImportPreview {
  final Book book;
  final List<Chapter> chapters;
  final String encoding, sourceHash;
  final Directory destination;
  final Directory? staging;
  final String sample;
  final bool alreadyExists;
  final String? coverPreview;
  final String? legacyAlias;
  bool _committed = false;
  LocalImportPreview({
    required this.book,
    required this.chapters,
    required this.encoding,
    required this.sourceHash,
    required this.destination,
    required this.sample,
    this.staging,
    this.alreadyExists = false,
    this.coverPreview,
    this.legacyAlias,
  });

  Future<void> dispose() async {
    if (!_committed && staging != null && await staging!.exists()) {
      await staging!.delete(recursive: true);
    }
  }
}

typedef LocalNormalizer =
    Future<NormalizedLocalText> Function(
      File file,
      String encoding,
      Directory temporary,
      LocalImportToken token,
    );

class LocalBookService {
  static final LocalBookService _instance = LocalBookService._();
  factory LocalBookService() => _instance;
  LocalBookService._()
    : documents = _documents,
      normalizer = normalizeLocalText;
  @visibleForTesting
  LocalBookService.forTesting({
    required this.documents,
    LocalNormalizer? normalizer,
  }) : normalizer = normalizer ?? normalizeLocalText;
  final Future<Directory> Function() documents;
  final LocalNormalizer normalizer;
  static final Map<String, Future<void>> _commits = {};

  static Future<Directory> _documents() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<LocalImportResult> importLocalFile(
    File file, {
    LocalImportOptions options = const LocalImportOptions(),
    LocalImportToken? token,
    void Function(String)? onProgress,
  }) async {
    final preview = await prepare(
      file,
      options: options,
      token: token,
      onProgress: onProgress,
    );
    try {
      return await commit(preview, token: token);
    } finally {
      await preview.dispose();
    }
  }

  Future<LocalImportResult> importLocalTxt(File file) => importLocalFile(file);
  Future<LocalImportResult> importLocalEpub(File file) => importLocalFile(file);

  Future<LocalImportPreview> prepare(
    File file, {
    LocalImportOptions options = const LocalImportOptions(),
    LocalImportToken? token,
    void Function(String)? onProgress,
  }) async {
    final cancel = token ?? LocalImportToken();
    cancel.check();
    final extension = path.extension(file.path).toLowerCase();
    if (extension != '.txt' && extension != '.epub') {
      throw const FormatException('仅支持 TXT / EPUB 文件');
    }
    final length = await file.length();
    if (length == 0 || length > SafeZipReader.maxFileBytes) {
      throw const FormatException('文件为空或超过 128 MB');
    }
    onProgress?.call('正在校验文件…');
    final sourceHash =
        (await sha256
                .bind(
                  file.openRead().map((chunk) {
                    cancel.check();
                    return chunk;
                  }),
                )
                .first)
            .toString();
    final base = await documents();
    final stagingRoot = Directory('${base.path}/import_staging');
    await stagingRoot.create(recursive: true);
    final stage = await stagingRoot.createTemp('book-');
    NormalizedLocalText? normalized;
    final progress = ReceivePort();
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    final subscription = progress.listen((event) {
      if (event is SendPort) {
        cancel.worker = event;
        if (cancel.cancelled) event.send('cancel');
      } else if (event is Map && event['message'] is String) {
        final now = DateTime.now();
        if (now.difference(lastProgress).inMilliseconds >= 80) {
          lastProgress = now;
          onProgress?.call(event['message'] as String);
        }
      }
    });
    try {
      final epub = extension == '.epub';
      var input = file;
      var encoding = 'EPUB';
      if (!epub) {
        onProgress?.call('正在解码文本，可取消…');
        normalized = await normalizer(file, options.encoding, stage, cancel);
        input = normalized.file;
        encoding = normalized.encoding;
      }
      cancel.check();
      final identity = sha256
          .convert(
            utf8.encode('$sourceHash|$encoding|${options.chapterRule.name}|2'),
          )
          .toString();
      final id = 'local_${epub ? 'epub' : 'txt'}_$identity';
      final destination = Directory('${base.path}/offline_books/$id');
      final existing = await _existing(destination, sourceHash);
      if (existing != null) {
        await stage.delete(recursive: true);
        return existing;
      }
      await BookshelfService().initialize();
      // An adopted legacy identity remains authoritative on future imports.
      for (final shelf in BookshelfService().books.where(
        (b) => b.bookId.startsWith('local_'),
      )) {
        final directory = Directory(
          '${base.path}/offline_books/${shelf.bookId}',
        );
        final metadata = await _metadata(directory);
        if ((metadata?['aliases'] as List?)?.contains(id) == true) {
          final alias = await _existing(directory, sourceHash);
          if (alias != null) {
            await stage.delete(recursive: true);
            return alias;
          }
        }
      }
      onProgress?.call('正在解析目录与正文…');
      final parsed = await compute(
        parseLocalBook,
        LocalParseRequest(
          inputPath: input.path,
          stagingPath: stage.path,
          title: path.basenameWithoutExtension(file.path),
          idPrefix: identity.substring(0, 16),
          epub: epub,
          rule: options.chapterRule,
          progress: progress.sendPort,
        ),
      );
      cancel.check();
      final book = Book(
        bookId: id,
        bookName: parsed.title,
        author: parsed.author,
        category: '本地图书',
        creationStatus: '已完结',
        serialCount: parsed.chapters.length,
        thumbUrl: parsed.coverFile == null
            ? null
            : '${destination.path}/${parsed.coverFile}',
        abstract:
            '本地导入的 ${epub ? 'EPUB' : 'TXT'} 小说，共 ${parsed.chapters.length} 章。',
      );
      await AtomicFile.writeString(
        File('${stage.path}/directory.json'),
        jsonEncode(parsed.chapters.map((c) => c.toJson()).toList()),
      );
      await AtomicFile.writeString(
        File('${stage.path}/metadata.json'),
        jsonEncode({
          'version': 2,
          'source_sha256': sourceHash,
          'encoding': encoding,
          'chapter_rule': options.chapterRule.name,
          'source_name': path.basename(file.path),
          'source_file': 'source.original',
          'book': book.toJson(),
          'aliases': <String>[],
        }),
      );
      await file.copy('${stage.path}/source.original');
      cancel.check();
      final legacy = await _adoptLegacy(
        base,
        stage,
        book,
        parsed.chapters,
        sourceHash,
        encoding,
        cancel,
      );
      if (legacy != null) return legacy;
      final sample = await File(
        '${stage.path}/${parsed.chapters.first.itemId}.txt',
      ).readAsString();
      return LocalImportPreview(
        book: book,
        chapters: parsed.chapters,
        encoding: encoding,
        sourceHash: sourceHash,
        destination: destination,
        staging: stage,
        sample: sample.length > 600
            ? sample.substring(0, ReaderText.safeOffset(sample, 600))
            : sample,
        coverPreview: parsed.coverFile == null
            ? null
            : '${stage.path}/${parsed.coverFile}',
      );
    } catch (_) {
      if (await stage.exists()) await stage.delete(recursive: true);
      if (cancel.cancelled) throw const LocalImportCancelled();
      rethrow;
    } finally {
      if (normalized?.temporary == true && await normalized!.file.exists()) {
        await normalized.file.delete();
      }
      cancel.worker = null;
      await subscription.cancel();
      progress.close();
    }
  }

  Future<LocalImportResult> commit(
    LocalImportPreview preview, {
    LocalImportToken? token,
  }) {
    final key = preview.destination.path;
    final operation = (_commits[key] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          token?.check();
          if (preview.legacyAlias != null) {
            final old = await _metadata(preview.destination);
            if (old != null && old['source_sha256'] != preview.sourceHash) {
              throw const FormatException('旧书数据已变化，未执行身份迁移');
            }
            final sourceName =
                'source_${preview.sourceHash.substring(0, 12)}.original';
            final source = File('${preview.destination.path}/$sourceName');
            if (!await source.exists()) {
              await File(
                '${preview.staging!.path}/source.original',
              ).copy(source.path);
            }
            await AtomicFile.writeString(
              File('${preview.destination.path}/metadata.json'),
              jsonEncode({
                ...?old,
                'version': 2,
                'source_sha256': preview.sourceHash,
                'encoding': preview.encoding,
                'source_file': sourceName,
                'book': preview.book.toJson(),
                'aliases': {
                  ...?((old?['aliases'] as List?)?.cast<String>()),
                  preview.legacyAlias!,
                }.toList(),
              }),
            );
            await BookshelfService().addToBookshelf(
              preview.book,
              totalChapters: preview.chapters.length,
            );
            return LocalImportResult(
              book: preview.book,
              chapters: preview.chapters,
              chapterCount: preview.chapters.length,
              alreadyExists: true,
            );
          }
          final existing = await _existing(
            preview.destination,
            preview.sourceHash,
          );
          if (existing != null) {
            await BookshelfService().addToBookshelf(
              existing.book,
              totalChapters: existing.chapters.length,
            );
            return LocalImportResult(
              book: existing.book,
              chapters: existing.chapters,
              chapterCount: existing.chapters.length,
              alreadyExists: true,
            );
          }
          if (preview.staging == null) {
            throw const FormatException('已有导入资源不完整，请重新选择源文件');
          }
          final backup = Directory(
            '$key.previous-${DateTime.now().microsecondsSinceEpoch}',
          );
          var movedOld = false;
          var published = false;
          final wasInShelf = BookshelfService().isInBookshelf(
            preview.book.bookId,
          );
          try {
            await preview.destination.parent.create(recursive: true);
            if (await preview.destination.exists()) {
              final old = await _metadata(preview.destination);
              if (old?['source_sha256'] != preview.sourceHash) {
                throw const FormatException('目标目录校验不一致，未覆盖原书');
              }
              await preview.destination.rename(backup.path);
              movedOld = true;
            }
            await preview.staging!.rename(key);
            published = true;
            await BookshelfService().addToBookshelf(
              preview.book,
              totalChapters: preview.chapters.length,
            );
            preview._committed = true;
            if (movedOld && await backup.exists()) {
              try {
                await backup.delete(recursive: true);
              } catch (_) {}
            }
            return LocalImportResult(
              book: preview.book,
              chapters: preview.chapters,
              chapterCount: preview.chapters.length,
            );
          } catch (_) {
            if (published &&
                !preview._committed &&
                await preview.destination.exists()) {
              // Only remove the complete directory just published by this operation.
              final metadata = await _metadata(preview.destination);
              if (metadata?['source_sha256'] == preview.sourceHash) {
                await preview.destination.delete(recursive: true);
              }
            }
            if (movedOld && await backup.exists()) await backup.rename(key);
            if (!wasInShelf &&
                BookshelfService().isInBookshelf(preview.book.bookId)) {
              try {
                await BookshelfService().removeFromBookshelf(
                  preview.book.bookId,
                );
              } catch (_) {}
            }
            rethrow;
          }
        });
    late final Future<void> completion;
    completion = operation
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() {
          if (identical(_commits[key], completion)) _commits.remove(key);
        });
    _commits[key] = completion;
    return operation;
  }

  Future<Map<String, dynamic>?> _metadata(Directory directory) async {
    try {
      return jsonDecode(
            await File('${directory.path}/metadata.json').readAsString(),
          )
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<LocalImportPreview?> _existing(
    Directory directory,
    String sourceHash,
  ) async {
    final metadata = await _metadata(directory);
    if (metadata == null ||
        metadata['version'] != 2 ||
        metadata['source_sha256'] != sourceHash) {
      return null;
    }
    try {
      final data =
          jsonDecode(
                await File('${directory.path}/directory.json').readAsString(),
              )
              as List;
      final chapters = [
        for (var i = 0; i < data.length; i++)
          Chapter.fromDirectoryJson(data[i] as Map<String, dynamic>, i),
      ];
      if (chapters.isEmpty) return null;
      for (final chapter in chapters) {
        final file = File('${directory.path}/${chapter.itemId}.txt');
        if (!await file.exists() || await file.length() == 0) return null;
      }
      final book = Book.fromDetailJson(
        Map<String, dynamic>.from(metadata['book'] as Map),
      );
      final sample = await File(
        '${directory.path}/${chapters.first.itemId}.txt',
      ).readAsString();
      return LocalImportPreview(
        book: book,
        chapters: chapters,
        encoding: metadata['encoding']?.toString() ?? '未知',
        sourceHash: sourceHash,
        destination: directory,
        alreadyExists: true,
        sample: sample.length > 600
            ? sample.substring(0, ReaderText.safeOffset(sample, 600))
            : sample,
        coverPreview: book.thumbUrl,
      );
    } catch (_) {
      return null;
    }
  }

  Future<LocalImportPreview?> _adoptLegacy(
    Directory base,
    Directory stage,
    Book book,
    List<Chapter> chapters,
    String sourceHash,
    String encoding,
    LocalImportToken token,
  ) async {
    for (final shelf in BookshelfService().books.where(
      (b) =>
          RegExp(r'^local_(txt|epub)_\d+$').hasMatch(b.bookId) &&
          b.bookName == book.bookName,
    )) {
      token.check();
      final directory = Directory('${base.path}/offline_books/${shelf.bookId}');
      if (await File('${directory.path}/metadata.json').exists()) continue;
      try {
        final data =
            jsonDecode(
                  await File('${directory.path}/directory.json').readAsString(),
                )
                as List;
        if (data.length != chapters.length) continue;
        var same = true;
        for (var i = 0; i < data.length; i++) {
          token.check();
          final old = Chapter.fromDirectoryJson(
            data[i] as Map<String, dynamic>,
            i,
          );
          if (old.title != chapters[i].title) {
            same = false;
            break;
          }
          final a = await File(
            '${directory.path}/${old.itemId}.txt',
          ).readAsString();
          final b = await File(
            '${stage.path}/${chapters[i].itemId}.txt',
          ).readAsString();
          if (ReaderText.paragraphs(a, chapterTitle: old.title).join('\n\n') !=
              ReaderText.paragraphs(b, chapterTitle: old.title).join('\n\n')) {
            same = false;
            break;
          }
        }
        if (!same) continue;
        final legacyChapters = [
          for (var i = 0; i < data.length; i++)
            Chapter.fromDirectoryJson(data[i] as Map<String, dynamic>, i),
        ];
        final sample = await File(
          '${directory.path}/${legacyChapters.first.itemId}.txt',
        ).readAsString();
        return LocalImportPreview(
          book: shelf.toBook(),
          chapters: legacyChapters,
          encoding: encoding,
          sourceHash: sourceHash,
          destination: directory,
          staging: stage,
          sample: sample.length > 600
              ? sample.substring(0, ReaderText.safeOffset(sample, 600))
              : sample,
          alreadyExists: true,
          legacyAlias: book.bookId,
          coverPreview: shelf.thumbUrl,
        );
      } on LocalImportCancelled {
        rethrow;
      } catch (_) {
        /* Keep the old book untouched when it cannot be safely matched. */
      }
    }
    return null;
  }
}
