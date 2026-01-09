/// 书籍数据模型
class Book {
  final String bookId;
  final String bookName;
  final String author;
  final String? abstract;
  final String? category;
  final String? thumbUrl;
  final int wordNumber;
  final int serialCount;
  final String creationStatus; // "完结" / "连载中"
  final List<String>? tags;

  Book({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.abstract,
    this.category,
    this.thumbUrl,
    this.wordNumber = 0,
    this.serialCount = 0,
    this.creationStatus = '连载中',
    this.tags,
  });

  /// 从搜索结果 JSON 创建 Book 对象
  factory Book.fromSearchJson(Map<String, dynamic> json) {
    return Book(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      abstract: json['abstract']?.toString(),
      category: json['category']?.toString(),
      thumbUrl: json['thumb_url']?.toString(),
      wordNumber: _parseWordNumber(json['word_number']),
      serialCount: _parseInt(json['serial_count']),
      creationStatus: _parseCreationStatus(json['creation_status']),
      tags: _parseTags(json['tags']),
    );
  }

  /// 从详情 JSON 创建 Book 对象
  factory Book.fromDetailJson(Map<String, dynamic> json) {
    return Book(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      abstract:
          json['abstract']?.toString() ?? json['book_abstract_v2']?.toString(),
      category: json['category']?.toString(),
      thumbUrl: json['thumb_url']?.toString(),
      wordNumber: _parseWordNumber(json['word_number']),
      serialCount: _parseInt(json['serial_count']),
      creationStatus: _parseCreationStatus(json['creation_status']),
      tags: _parseTags(json['tags']),
    );
  }

  /// 从发现/推荐 JSON 创建 Book 对象（巅峰榜等）
  factory Book.fromDiscoverJson(Map<String, dynamic> json) {
    // 优先使用 creation_status 字段（数字格式），回退到 status 字段
    // creation_status: 1 = 连载中, 其他 = 完结
    // status: 可能是文字 "连载中"/"完结"，也可能是数字
    String status;
    if (json['creation_status'] != null) {
      status = _parseCreationStatus(json['creation_status']);
    } else if (json['status'] != null) {
      final rawStatus = json['status'].toString();
      // 如果是数字，使用 _parseCreationStatus 解析
      if (rawStatus == '1' ||
          rawStatus == '0' ||
          int.tryParse(rawStatus) != null) {
        status = _parseCreationStatus(rawStatus);
      } else {
        // 如果是文字，直接使用
        status = (rawStatus == '完结' || rawStatus == '连载中') ? rawStatus : '连载中';
      }
    } else {
      status = '连载中';
    }

    return Book(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      abstract: json['abstract']?.toString(),
      category: json['category']?.toString(),
      thumbUrl: json['thumb_url']?.toString(),
      wordNumber: _parseWordNumber(json['word_number']),
      serialCount: 0,
      creationStatus: status,
      tags: _parseTags(json['tags']),
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'book_id': bookId,
      'book_name': bookName,
      'author': author,
      'abstract': abstract,
      'category': category,
      'thumb_url': thumbUrl,
      'word_number': wordNumber,
      'serial_count': serialCount,
      'creation_status': creationStatus,
      'tags': tags,
    };
  }

  /// 获取格式化的字数显示
  String get formattedWordCount {
    if (wordNumber >= 10000) {
      return '${(wordNumber / 10000).toStringAsFixed(1)}万字';
    }
    return '$wordNumber字';
  }

  /// 获取简介预览（截取前100字符）
  String get abstractPreview {
    if (abstract == null || abstract!.isEmpty) {
      return '暂无简介';
    }
    if (abstract!.length > 100) {
      return '${abstract!.substring(0, 100)}...';
    }
    return abstract!;
  }

  // 私有辅助方法
  static int _parseWordNumber(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static String _parseCreationStatus(dynamic value) {
    if (value == null) return '连载中';
    final status = value.toString();
    // 1 = 连载中, 其他值 = 完结
    return status == '1' ? '连载中' : '完结';
  }

  static List<String>? _parseTags(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    if (value is String && value.isNotEmpty) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return null;
  }
}
