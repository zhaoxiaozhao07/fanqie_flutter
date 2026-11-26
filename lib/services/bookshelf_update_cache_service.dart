import '../models/bookshelf_book.dart';
import '../models/chapter.dart';
import 'api_service.dart';
import 'bookshelf_service.dart';

/// 增量缓存单次任务进度快照
class UpdateCacheProgress {
  final int processedBooks;
  final int totalBooks;
  final int cachedChapters;
  final int failedBooks;
  final String currentBookName;
  final String message;

  const UpdateCacheProgress({
    required this.processedBooks,
    required this.totalBooks,
    required this.cachedChapters,
    required this.failedBooks,
    required this.currentBookName,
    required this.message,
  });
}

/// 增量缓存执行结果汇总
class UpdateCacheSummary {
  final int scannedBooks;
  final int updatedBooks;
  final int cachedChapters;
  final int failedBooks;
  final bool cancelled;

  const UpdateCacheSummary({
    required this.scannedBooks,
    required this.updatedBooks,
    required this.cachedChapters,
    required this.failedBooks,
    required this.cancelled,
  });

  String get summaryText {
    if (cancelled) {
      return '已取消增量缓存：已完成 $updatedBooks 本书共 $cachedChapters 章';
    }
    if (scannedBooks == 0) {
      return '当前书架没有需要增量缓存的连载更新书籍';
    }
    if (cachedChapters == 0 && failedBooks == 0) {
      return '检查完成：$scannedBooks 本更新书籍的新章节均已在本地缓存';
    }
    final failPart = failedBooks > 0 ? '（$failedBooks 本部分失败）' : '';
    return '增量缓存完成：$updatedBooks 本书共缓存 $cachedChapters 章新内容$failPart';
  }
}

/// 书架连载更新一键增量离线缓存服务
/// 仅针对尚未离线的新增章节执行拉取，已离线旧章直接复用零重复请求
class BookshelfUpdateCacheService {
  final Future<List<Chapter>> Function(String bookId) _loadDirectory;
  final Future<bool> Function(String bookId, String itemId) _isChapterOffline;
  final Future<void> Function({
    required String bookId,
    required List<Chapter> chapters,
    void Function(int current, int total, String message)? onProgress,
    bool Function()? isCancelled,
  })
  _downloadChapters;
  final Future<void> Function(String bookId)? _clearUpdateBadge;

  BookshelfUpdateCacheService({
    ApiService? apiService,
    BookshelfService? bookshelfService,
    Future<List<Chapter>> Function(String bookId)? loadDirectory,
    Future<bool> Function(String bookId, String itemId)? isChapterOffline,
    Future<void> Function({
      required String bookId,
      required List<Chapter> chapters,
      void Function(int current, int total, String message)? onProgress,
      bool Function()? isCancelled,
    })?
    downloadChapters,
    Future<void> Function(String bookId)? clearUpdateBadge,
  }) : _loadDirectory =
           loadDirectory ??
           ((bookId) =>
               (apiService ?? ApiService()).getBookDirectory(bookId, refresh: true)),
       _isChapterOffline =
           isChapterOffline ??
           ((bookId, itemId) =>
               (apiService ?? ApiService()).isChapterOffline(bookId, itemId)),
       _downloadChapters =
           downloadChapters ??
           (({
             required String bookId,
             required List<Chapter> chapters,
             void Function(int current, int total, String message)? onProgress,
             bool Function()? isCancelled,
           }) => (apiService ?? ApiService()).downloadChapters(
             bookId: bookId,
             chapters: chapters,
             onProgress: onProgress,
             isCancelled: isCancelled,
             concurrency: 6,
           )),
       _clearUpdateBadge =
           clearUpdateBadge ??
           ((bookId) =>
               (bookshelfService ?? BookshelfService()).clearBookUpdateBadge(bookId));

  /// 对目标书籍集合（通常为书架上有更新的非本地书籍）执行增量新章离线缓存
  Future<UpdateCacheSummary> cacheUpdatedBooks(
    List<BookshelfBook> candidates, {
    int maxChaptersPerBook = 80,
    void Function(UpdateCacheProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final targets = candidates
        .where((b) => !b.bookId.startsWith('local_'))
        .toList();
    if (targets.isEmpty) {
      return const UpdateCacheSummary(
        scannedBooks: 0,
        updatedBooks: 0,
        cachedChapters: 0,
        failedBooks: 0,
        cancelled: false,
      );
    }

    var updatedBooks = 0;
    var totalCachedChapters = 0;
    var failedBooks = 0;
    var cancelled = false;

    for (var i = 0; i < targets.length; i++) {
      if (isCancelled?.call() == true) {
        cancelled = true;
        break;
      }
      final book = targets[i];
      onProgress?.call(
        UpdateCacheProgress(
          processedBooks: i,
          totalBooks: targets.length,
          cachedChapters: totalCachedChapters,
          failedBooks: failedBooks,
          currentBookName: book.bookName,
          message: '正在检查《${book.bookName}》最新目录…',
        ),
      );
      try {
        final chapters = await _loadDirectory(book.bookId);
        if (isCancelled?.call() == true) {
          cancelled = true;
          break;
        }
        if (chapters.isEmpty) continue;

        // 从已记录的旧章数或当前读到的位置向后扫描，仅缓存未离线的新章
        final baseline = book.totalChapters > 0
            ? (book.totalChapters - 1).clamp(0, chapters.length)
            : (book.lastReadChapterIndex ?? 0).clamp(0, chapters.length);
        final windowStart = chapters.length - baseline > maxChaptersPerBook
            ? chapters.length - maxChaptersPerBook
            : baseline;
        final missing = <Chapter>[];
        for (var cIdx = windowStart; cIdx < chapters.length; cIdx++) {
          final ch = chapters[cIdx];
          if (!await _isChapterOffline(book.bookId, ch.itemId)) {
            missing.add(ch);
          }
        }
        if (missing.isEmpty) continue;

        await _downloadChapters(
          bookId: book.bookId,
          chapters: missing,
          isCancelled: isCancelled,
          onProgress: (cur, total, msg) {
            onProgress?.call(
              UpdateCacheProgress(
                processedBooks: i,
                totalBooks: targets.length,
                cachedChapters: totalCachedChapters + cur,
                failedBooks: failedBooks,
                currentBookName: book.bookName,
                message: '正在缓存《${book.bookName}》($cur/$total)',
              ),
            );
          },
        );
        if (isCancelled?.call() == true) {
          cancelled = true;
          break;
        }
        updatedBooks++;
        totalCachedChapters += missing.length;
        await _clearUpdateBadge?.call(book.bookId);
      } catch (_) {
        failedBooks++;
      }
    }

    onProgress?.call(
      UpdateCacheProgress(
        processedBooks: targets.length,
        totalBooks: targets.length,
        cachedChapters: totalCachedChapters,
        failedBooks: failedBooks,
        currentBookName: '',
        message: '增量缓存处理完成',
      ),
    );

    return UpdateCacheSummary(
      scannedBooks: targets.length,
      updatedBooks: updatedBooks,
      cachedChapters: totalCachedChapters,
      failedBooks: failedBooks,
      cancelled: cancelled,
    );
  }
}
