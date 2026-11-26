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
  final String? contentUri; // Android MediaStore URI（分区存储下用于精确校验文件存在性）
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
    this.contentUri,
    required this.fileSize,
  });

  /// 结合文件路径、书籍标识与记录字段推断真实格式，修复历史遗留的格式误标
  static String resolveFormat(
    String? rawFormat, {
    String filePath = '',
    String bookId = '',
  }) {
    final lowerPath = filePath.trim().toLowerCase();
    if (lowerPath.endsWith('.epub')) return 'EPUB';
    if (lowerPath.endsWith('.txt')) return 'TXT';
    final lowerId = bookId.trim().toLowerCase();
    if (lowerId.startsWith('local_epub_')) return 'EPUB';
    if (lowerId.startsWith('local_txt_')) return 'TXT';
    final normalized = (rawFormat ?? '').trim().toUpperCase();
    if (normalized.isNotEmpty) return normalized;
    return 'TXT';
  }

  /// 供界面标签展示的规范化格式名称（EPUB / TXT）
  String get displayFormat =>
      resolveFormat(format, filePath: filePath, bookId: bookId);

  /// 从 JSON 创建对象
  factory DownloadHistory.fromJson(Map<String, dynamic> json) {
    final bookId = json['book_id']?.toString() ?? '';
    final filePath = json['file_path']?.toString() ?? '';
    return DownloadHistory(
      bookId: bookId,
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
      format: resolveFormat(
        json['format']?.toString(),
        filePath: filePath,
        bookId: bookId,
      ),
      filePath: filePath,
      contentUri: json['content_uri']?.toString(),
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
      if (contentUri != null && contentUri!.isNotEmpty)
        'content_uri': contentUri,
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

  DownloadHistory copyWithCover(String cover) {
    return DownloadHistory(
      bookId: bookId,
      bookName: bookName,
      author: author,
      thumbUrl: cover,
      category: category,
      creationStatus: creationStatus,
      wordNumber: wordNumber,
      downloadTime: downloadTime,
      format: format,
      filePath: filePath,
      contentUri: contentUri,
      fileSize: fileSize,
    );
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
