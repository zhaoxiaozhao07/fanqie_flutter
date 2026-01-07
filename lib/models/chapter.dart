/// 章节数据模型
class Chapter {
  final String itemId;
  final String title;
  final int order;
  final String? content;

  Chapter({
    required this.itemId,
    required this.title,
    this.order = 0,
    this.content,
  });

  /// 从目录 JSON 创建 Chapter 对象
  factory Chapter.fromDirectoryJson(Map<String, dynamic> json, int index) {
    return Chapter(
      itemId: json['item_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '第${index + 1}章',
      order: index + 1,
    );
  }

  /// 从完整目录 JSON 创建 Chapter 对象
  factory Chapter.fromBookJson(Map<String, dynamic> json) {
    return Chapter(
      itemId: json['itemId']?.toString() ?? json['item_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      order: int.tryParse(json['realChapterOrder']?.toString() ?? '0') ?? 0,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'item_id': itemId,
      'title': title,
      'order': order,
      'content': content,
    };
  }

  /// 创建带内容的副本
  Chapter copyWithContent(String newContent) {
    return Chapter(
      itemId: itemId,
      title: title,
      order: order,
      content: newContent,
    );
  }
}
