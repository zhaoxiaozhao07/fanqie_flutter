import 'book.dart';

/// 下载历史数据模型
class DownloadHistory {
  final String bookId;
  final String bookName;
  final String author;
  final String? thumbUrl;
  final String? category;
  final String creationStatus;
  final int wordNumber;
  final DateTime downloadTime;
  final String format; // "TXT" / "EPUB"
  final String filePath;
  final int fileSize; // bytes

  DownloadHistory({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.thumbUrl,
    this.category,
    required this.creationStatus,
    required this.wordNumber,
    required this.downloadTime,
    required this.format,
    required this.filePath,
    required this.fileSize,
  });

  /// 从 JSON 创建对象
  factory DownloadHistory.fromJson(Map<String, dynamic> json) {
    return DownloadHistory(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      thumbUrl: json['thumb_url']?.toString(),
      category: json['category']?.toString(),
      creationStatus: json['creation_status']?.toString() ?? '连载中',
      wordNumber: json['word_number'] is int
          ? json['word_number']
          : int.tryParse(json['word_number']?.toString() ?? '0') ?? 0,
      downloadTime:
          DateTime.tryParse(json['download_time']?.toString() ?? '') ??
          DateTime.now(),
      format: json['format']?.toString() ?? 'TXT',
      filePath: json['file_path']?.toString() ?? '',
      fileSize: json['file_size'] is int
          ? json['file_size']
          : int.tryParse(json['file_size']?.toString() ?? '0') ?? 0,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'book_id': bookId,
      'book_name': bookName,
      'author': author,
      'thumb_url': thumbUrl,
      'category': category,
      'creation_status': creationStatus,
      'word_number': wordNumber,
      'download_time': downloadTime.toIso8601String(),
      'format': format,
      'file_path': filePath,
      'file_size': fileSize,
    };
  }

  /// 转换为 Book 对象，用于跳转到详情页
  Book toBook() {
    return Book(
      bookId: bookId,
      bookName: bookName,
      author: author,
      thumbUrl: thumbUrl,
      category: category,
      creationStatus: creationStatus,
      wordNumber: wordNumber,
      abstract: null,
    );
  }

  /// 获取格式化的字数显示
  String get formattedWordCount {
    if (wordNumber >= 10000) {
      return '${(wordNumber / 10000).toStringAsFixed(1)}万字';
    }
    return '$wordNumber字';
  }

  /// 获取格式化的文件大小显示
  String get formattedFileSize {
    if (fileSize >= 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else if (fileSize >= 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '$fileSize B';
  }

  /// 获取格式化的下载时间显示
  String get formattedDownloadTime {
    final now = DateTime.now();
    final diff = now.difference(downloadTime);

    if (diff.inDays > 0) {
      return '${diff.inDays}天前';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}小时前';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}分钟前';
    }
    return '刚刚';
  }

  /// 获取详细的下载时间显示
  String get detailedDownloadTime {
    return '${downloadTime.year}-${downloadTime.month.toString().padLeft(2, '0')}-${downloadTime.day.toString().padLeft(2, '0')} '
        '${downloadTime.hour.toString().padLeft(2, '0')}:${downloadTime.minute.toString().padLeft(2, '0')}';
  }
}
