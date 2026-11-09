import 'book.dart';
import 'chapter.dart';

enum DownloadTaskStatus {
  pending,
  downloading,
  saving,
  paused,
  completed,
  failed,
  cancelled,
}

class DownloadTask {
  final String id;
  final Book book;
  final List<Chapter> chapters;
  final String format;
  DownloadTaskStatus status;
  int current, total;
  String message;
  String? filePath, error;
  final DateTime startTime;
  bool isCancelled = false;
  int retryCount;
  DateTime? nextRetryAt;
  String? errorKind;
  List<String> failedChapterIds;

  DownloadTask({
    required this.id,
    required this.book,
    required List<Chapter> chapters,
    required this.format,
    this.status = DownloadTaskStatus.pending,
    this.current = 0,
    required this.total,
    this.message = '准备中...',
    this.filePath,
    this.error,
    DateTime? startTime,
    this.retryCount = 0,
    this.nextRetryAt,
    this.errorKind,
    this.failedChapterIds = const [],
  }) : chapters = List.unmodifiable(chapters),
       startTime = startTime ?? DateTime.now();

  double get progress => total > 0 ? (current / total).clamp(0.0, 1.0) : 0.0;
  bool get isActive =>
      status == DownloadTaskStatus.downloading ||
      status == DownloadTaskStatus.saving ||
      status == DownloadTaskStatus.pending;
  bool get canResume =>
      status == DownloadTaskStatus.paused ||
      status == DownloadTaskStatus.failed ||
      status == DownloadTaskStatus.cancelled;

  Map<String, Object?> toJson() => {
    'id': id,
    'book': book.toJson(),
    // Bitmap bytes and text live in the offline cache. Keep illustration
    // anchors alongside the catalog so a restored task has lossless metadata.
    'chapters': [
      for (final chapter in chapters)
        {
          'item_id': chapter.itemId,
          'title': chapter.title,
          'order': chapter.order,
          'volume_title': chapter.volumeTitle,
          if (chapter.illustrations.isNotEmpty)
            'illustrations': chapter.illustrations
                .map((image) => image.toJson())
                .toList(),
        },
    ],
    'format': format,
    'status': status.name,
    'current': current,
    'total': total,
    'message': message,
    'file_path': filePath,
    'error': error,
    'start_time': startTime.toIso8601String(),
    'retry_count': retryCount,
    'next_retry_at': nextRetryAt?.toUtc().toIso8601String(),
    'error_kind': errorKind,
    'failed_chapters': failedChapterIds,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final book = Book.fromSearchJson(
      Map<String, dynamic>.from(json['book'] as Map),
    );
    final id = json['id'];
    final rawChapters = json['chapters'];
    final format = json['format'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 512 ||
        book.bookId.isEmpty ||
        rawChapters is! List ||
        rawChapters.isEmpty ||
        rawChapters.length > 50000 ||
        (format != 'TXT' && format != 'EPUB')) {
      throw const FormatException('下载任务元数据无效');
    }
    final chapters = [
      for (var i = 0; i < rawChapters.length; i++)
        Chapter.fromDirectoryJson(
          Map<String, dynamic>.from(rawChapters[i] as Map),
          i,
        ),
    ];
    if (chapters.any((chapter) => chapter.itemId.isEmpty) ||
        chapters.map((chapter) => chapter.itemId).toSet().length !=
            chapters.length) {
      throw const FormatException('下载任务目录不完整');
    }
    final status = DownloadTaskStatus.values
        .where((status) => status.name == json['status'])
        .firstOrNull;
    if (status == null) throw const FormatException('下载任务状态不受支持');
    return DownloadTask(
      id: id,
      book: book,
      chapters: chapters,
      format: format as String,
      status: status,
      total: chapters.length,
      current: (json['current'] is int ? json['current'] as int : 0).clamp(
        0,
        chapters.length,
      ),
      message: json['message']?.toString() ?? '',
      filePath: json['file_path'] as String?,
      error: json['error'] as String?,
      startTime: DateTime.tryParse(json['start_time']?.toString() ?? ''),
      retryCount: (json['retry_count'] is int ? json['retry_count'] as int : 0)
          .clamp(0, 2),
      nextRetryAt: DateTime.tryParse(json['next_retry_at']?.toString() ?? ''),
      errorKind: json['error_kind']?.toString(),
      failedChapterIds:
          (json['failed_chapters'] is List
                  ? json['failed_chapters'] as List
                  : [])
              .whereType<String>()
              .take(20)
              .toList(),
    );
  }
}
