import 'bookmark_service.dart';
import 'bookshelf_service.dart';
import 'reader_trash_service.dart';

class ReaderTrashCoordinator {
  static Future<void> restore(ReaderTrashEntry entry) async {
    final valid = ReaderTrashEntry.fromJson(entry.toJson());
    if (valid.targetKey == 'bookshelf_books_v1') {
      await BookshelfService().restoreSnapshots(valid);
    } else {
      await BookmarkService().restoreSnapshot(valid);
    }
    // If this fails, the copied record remains and a retry is idempotent.
    await ReaderTrashService().discard(valid.id);
  }
}
