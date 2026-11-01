import 'dart:io';

/// Same-directory staging + rename keeps readers on the old or the new file,
/// never an empty/truncated intermediate value.
class AtomicFile {
  static final Map<String, Future<void>> _writes = {};

  static Future<void> writeString(File file, String value) {
    late final Future<void> next;
    next = (_writes[file.path] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          await file.parent.create(recursive: true);
          final staging = File('${file.path}.pending');
          try {
            await staging.writeAsString(value, flush: true);
            await staging.rename(file.path);
          } finally {
            if (await staging.exists()) await staging.delete();
          }
        })
        .whenComplete(() {
          if (identical(_writes[file.path], next)) _writes.remove(file.path);
        });
    _writes[file.path] = next;
    return next;
  }
}
