import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../app_theme.dart';
import '../main.dart';
import '../models/book.dart';
import '../services/bookshelf_service.dart';

/// 现代化书籍卡片组件
class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  final bool showAbstract;
  final bool showWordCount;

  const BookCard({
    super.key,
    required this.book,
    this.onTap,
    this.showAbstract = true,
    this.showWordCount = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(),
                const SizedBox(width: 16),
                Expanded(child: _buildInfo(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建封面图片
  Widget _buildCover() {
    return Container(
      width: 86,
      height: 118,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: book.thumbUrl != null && book.thumbUrl!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: book.thumbUrl!,
                fit: BoxFit.cover,
                cacheManager: BookCoverCacheManager.instance,
                memCacheWidth: 172,
                memCacheHeight: 236,
                fadeInDuration: const Duration(milliseconds: 150),
                fadeOutDuration: const Duration(milliseconds: 100),
                placeholder: (context, url) => Container(
                  color: AppTheme.primaryLight,
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                errorWidget: (context, url, error) => _buildPlaceholderCover(),
              )
            : _buildPlaceholderCover(),
      ),
    );
  }

  /// 构建占位封面
  Widget _buildPlaceholderCover() {
    return Container(
      color: AppTheme.primaryLight,
      child: Center(
        child: Icon(
          Icons.book,
          size: 32,
          color: AppTheme.primaryColor.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  /// 构建书籍信息
  Widget _buildInfo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 书名与加入书架快捷按钮
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                book.bookName,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: BookshelfService().changeNotifier,
              builder: (context, value, child) {
                final isInBookshelf = BookshelfService().isInBookshelf(book.bookId);
                return InkWell(
                  onTap: () async {
                    final added = await BookshelfService().toggleBookshelf(book);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(added ? '已加入书架：《${book.bookName}》' : '已移出书架：《${book.bookName}》'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Icon(
                      isInBookshelf ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
                      size: 20,
                      color: isInBookshelf ? AppTheme.primaryColor : AppTheme.textHint,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 6),

        // 作者
        Row(
          children: [
            const Icon(
              Icons.person_outline_rounded,
              size: 14,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                book.author,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),

        // 简介
        if (showAbstract) ...[
          const SizedBox(height: 8),
          Text(
            book.abstractPreview,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary.withValues(alpha: 0.8),
              height: 1.4,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 10),

        // 标签栏
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (book.score != null && book.score!.isNotEmpty)
              _buildScoreTag(book.score!),
            _buildStatusTag(book.creationStatus, book.creationStatus == '完结'),
            if (book.category != null && book.category!.isNotEmpty)
              _buildSimpleTag(book.category!),
            if (showWordCount && book.wordNumber > 0)
              _buildSimpleTag(book.formattedWordCount),
          ],
        ),
      ],
    );
  }

  /// 状态标签
  Widget _buildStatusTag(String text, bool isCompleted) {
    final color = isCompleted ? AppTheme.tagCompleted : AppTheme.tagSerializing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSimpleTag(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
    );
  }

  Widget _buildScoreTag(String score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 12, color: Colors.amber),
          const SizedBox(width: 2),
          Text(
            score,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.amber,
            ),
          ),
        ],
      ),
    );
  }
}
