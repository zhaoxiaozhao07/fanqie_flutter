import 'book.dart';

/// Stable protocol values, verified against the official library client.
abstract final class LibraryFilters {
  static const genders = {0: '全部', 1: '男频', 2: '女频'};
  static const sorts = {0: '最热', 1: '最新', 2: '字数'};
  static const statuses = {-1: '全部状态', 1: '连载中', 0: '已完结'};
  static const wordCounts = {
    -1: '全部字数',
    0: '30万以下',
    1: '30-50万',
    2: '50-100万',
    3: '100-200万',
    4: '200万以上',
  };

  static int serverGender(int gender) => switch (gender) {
    1 => 1,
    2 => 0,
    0 => -1,
    _ => throw ArgumentError.value(gender, 'gender'),
  };
}

class LibraryCategory {
  final int id;
  final String name;
  final String group;
  final String description;

  const LibraryCategory({
    required this.id,
    required this.name,
    required this.group,
    this.description = '',
  });

  static const all = LibraryCategory(id: -1, name: '全部分类', group: '');

  static List<LibraryCategory> parseList(List<dynamic> data) {
    final categories = <LibraryCategory>[];
    final seen = <int>{};
    for (final item in data) {
      if (item is! Map) continue;
      final id = int.tryParse(item['category_id']?.toString() ?? '');
      final name = item['name']?.toString().trim() ?? '';
      final group = item['label']?.toString().trim() ?? '';
      if (id == null || id <= 0 || name.isEmpty || !seen.add(id)) continue;
      categories.add(
        LibraryCategory(
          id: id,
          name: name,
          group: group.isEmpty ? '其他' : group,
          description: item['description']?.toString() ?? '',
        ),
      );
    }
    return List.unmodifiable(categories);
  }

  Map<String, dynamic> toJson() => {
    'category_id': id,
    'name': name,
    'label': group,
    'description': description,
  };
}

class CategoryCatalog {
  final List<LibraryCategory> categories;
  final bool isCached;

  const CategoryCatalog(this.categories, {this.isCached = false});
}

class LibraryPage {
  final List<Book> books;
  final bool hasMore;
  final int? total;

  const LibraryPage(this.books, {required this.hasMore, this.total});
}

class FanqieApiException implements Exception {
  final String message;
  const FanqieApiException(this.message);

  @override
  String toString() => message;
}
