import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/book.dart';
import '../app_theme.dart';
import '../main.dart'; // 访问 BookCoverCacheManager

/// 书籍卡片组件
/// 现代化扁平设计
class BookCard extends StatelessWidget {
  final Book book;
  final VoidCallback? onTap;
  final bool showWordCount;
  final bool showAbstract;

  const BookCard({
    super.key,
    required this.book,
    this.onTap,
    this.showWordCount = false,
    this.showAbstract = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0F0F0), width: 1),
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
                // 封面图片
                _buildCover(),
                const SizedBox(width: 16),
                // 书籍信息
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
            color: Colors.black.withOpacity(0.05),
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
                // 使用自定义缓存管理器（30 天有效期）
                cacheManager: BookCoverCacheManager.instance,
                // 限制内存缓存尺寸，显著减少内存占用和解码时间
                memCacheWidth: 172, // 2x 显示宽度
                memCacheHeight: 236, // 2x 显示高度
                // 更快的淡入动画
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
          color: AppTheme.primaryColor.withOpacity(0.5),
        ),
      ),
    );
  }

  /// 构建书籍信息
  Widget _buildInfo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 书名
        Text(
          book.bookName,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            fontSize: 17,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),

        // 作者
        Row(
          children: [
            Icon(
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

        // 简介 (根据参数显示/隐藏)
        if (showAbstract) ...[
          const SizedBox(height: 8),
          Text(
            book.abstractPreview,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary.withOpacity(0.8),
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
            // 评分标签（优先显示）
            if (book.score != null && book.score!.isNotEmpty)
              _buildScoreTag(book.score!),

            // 连载状态标签
            _buildStatusTag(book.creationStatus, book.creationStatus == '完结'),

            // 分类标签
            if (book.category != null && book.category!.isNotEmpty)
              _buildSimpleTag(book.category!),

            // 字数标签
            if (showWordCount && book.wordNumber > 0)
              _buildSimpleTag(book.formattedWordCount),
          ],
        ),
      ],
    );
  }

  /// 状态标签 - 实心
  Widget _buildStatusTag(String text, bool isCompleted) {
    final color = isCompleted ? AppTheme.tagCompleted : AppTheme.tagSerializing;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
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

  /// 简单标签 - 灰色文字
  Widget _buildSimpleTag(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
    );
  }

  /// 评分标签 - 金色星星
  Widget _buildScoreTag(String score) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.star_rounded,
          size: 14,
          color: Color(0xFFFF9500), // 橙色/金色
        ),
        const SizedBox(width: 2),
        Text(
          score,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFFF9500),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
