import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import 'bookmark_service.dart';
import 'file_export_service.dart';
import 'note_library_service.dart';

class ReaderExportService {
  final Future<Directory> Function() temporary;
  ReaderExportService({Future<Directory> Function()? temporary})
    : temporary = temporary ?? getTemporaryDirectory;
  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAllMapped(RegExp(r'[\\`*_\[\]#!]'), (match) => '\\${match[0]}');

  Future<File> exportNoteLibrary(
    List<IndexedReadingNote> entries, {
    bool markdown = true,
  }) async {
    final groups = <String, List<IndexedReadingNote>>{};
    for (final entry in entries) {
      groups.putIfAbsent(entry.book.bookId, () => []).add(entry);
    }
    final root = await temporary();
    final directory = Directory('${root.path}/reader_exports');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/note-library-${DateTime.now().microsecondsSinceEpoch}.${markdown ? 'md' : 'json'}',
    );
    if (!markdown) {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'fanqie-note-library',
          'version': 1,
          'books': [
            for (final group in groups.values)
              {
                'book': group.first.book.toJson(),
                'notes': group.map((entry) => entry.note.toJson()).toList(),
              },
          ],
        }),
        flush: true,
      );
    } else {
      final text = StringBuffer('# 笔记工作台\n\n');
      for (final group in groups.values) {
        text.writeln('## ${_escape(group.first.book.bookName)}\n');
        text.writeln('作者：${_escape(group.first.book.author)}\n');
        for (final entry in group) {
          final note = entry.note;
          text.writeln('### ${_escape(note.chapterTitle)}\n');
          text.writeln(
            note.text
                .split('\n')
                .map((line) => '> ${_escape(line)}')
                .join('\n'),
          );
          if (note.note.isNotEmpty) text.writeln('\n${_escape(note.note)}');
          if (note.tags.isNotEmpty) {
            text.writeln('\n标签：${note.tags.map(_escape).join('、')}');
          }
          text.writeln('\n---\n');
        }
      }
      await file.writeAsString(text.toString(), flush: true);
    }
    return file;
  }

  Future<File> exportNotes(Book book, {bool markdown = true}) async {
    final notes = await BookmarkService().getNotes(book.bookId);
    final bookmarks = await BookmarkService().getBookmarks(book.bookId);
    final root = await temporary();
    final directory = Directory('${root.path}/reader_exports');
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/notes-${DateTime.now().millisecondsSinceEpoch}.${markdown ? 'md' : 'json'}',
    );
    if (!markdown) {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'fanqie-notes',
          'version': 2,
          'book': book.toJson(),
          'notes': notes.map((n) => n.toJson()).toList(),
          'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
        }),
        flush: true,
      );
    } else {
      final text = StringBuffer('# ${_escape(book.bookName)}\n\n');
      for (final note in notes.reversed) {
        text.writeln('## ${_escape(note.chapterTitle)}\n');
        text.writeln(
          note.text.split('\n').map((line) => '> ${_escape(line)}').join('\n'),
        );
        if (note.note.isNotEmpty) text.writeln('\n${_escape(note.note)}');
        if (note.tags.isNotEmpty) {
          text.writeln('\n标签：${note.tags.map(_escape).join('、')}');
        }
        text.writeln('\n---\n');
      }
      await file.writeAsString(text.toString(), flush: true);
    }
    return file;
  }

  Future<String?> saveToDownloads(File file, {String? name}) async {
    final fileName = (name ?? file.uri.pathSegments.last).replaceAll(
      RegExp(r'[/\\\x00]'),
      '_',
    );
    final result = await FileExportService().save(
      file,
      name: fileName,
      mimeType: fileName.endsWith('.zip')
          ? 'application/zip'
          : fileName.endsWith('.json')
          ? 'application/json'
          : 'text/markdown',
    );
    if (result.status == FileExportStatus.cancelled) return null;
    if (result.status == FileExportStatus.failed) {
      throw FileSystemException(result.error ?? '导出保存失败');
    }
    return result.path;
  }
}
