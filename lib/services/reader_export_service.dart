import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import 'bookmark_service.dart';

class ReaderExportService {
  static const _channel = MethodChannel('com.fanqie.fanqie_flutter/download');
  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAllMapped(RegExp(r'[\\`*_\[\]#!]'), (match) => '\\${match[0]}');

  Future<File> exportNotes(Book book, {bool markdown = true}) async {
    final notes = await BookmarkService().getNotes(book.bookId);
    final bookmarks = await BookmarkService().getBookmarks(book.bookId);
    final root = await getTemporaryDirectory();
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

  Future<String> saveToDownloads(File file, {String? name}) async {
    final fileName = (name ?? file.uri.pathSegments.last).replaceAll(
      RegExp(r'[/\\\x00]'),
      '_',
    );
    if (!Platform.isAndroid) return file.path;
    final success = await _channel.invokeMethod<bool>('saveToDownloads', {
      'filePath': file.path,
      'fileName': fileName,
      'mimeType': fileName.endsWith('.zip')
          ? 'application/zip'
          : fileName.endsWith('.json')
          ? 'application/json'
          : 'text/markdown',
    });
    if (success != true) throw const FileSystemException('导出保存失败');
    return '下载/fanqie/$fileName';
  }
}
