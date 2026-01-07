import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/download_history.dart';
import '../app_theme.dart';

/// 历史记录卡片组件
/// 用于下载历史列表展示，支持选择模式
class HistoryCard extends StatelessWidget {
  final DownloadHistory history;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool?>? onCheckChanged;

  const HistoryCard({
    super.key,
    required this.history,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.onCheckChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: isSelected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.primaryColor, width: 2),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 选择模式下显示 Checkbox
                if (isSelectionMode) ...[
                  Checkbox(
                    value: isSelected,
                    onChanged: onCheckChanged,
                    activeColor: AppTheme.primaryColor,
                  ),
                  const SizedBox(width: 8),
                ],
                // 封面图片
                _buildCover(),
                const SizedBox(width: 12),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 80,
        height: 110,
        child: history.thumbUrl != null && history.thumbUrl!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: history.thumbUrl!,
                fit: BoxFit.cover,
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
          history.bookName,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),

        // 作者
        Row(
          children: [
            Icon(Icons.person_outline, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                history.author,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),

        // 下载信息
        Row(
          children: [
            Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(
              history.formattedDownloadTime,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.folder_outlined,
              size: 14,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              history.formattedFileSize,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // 标签
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            // 格式标签
            _buildTag(history.format, AppTheme.accentColor),
            // 分类标签
            if (history.category != null && history.category!.isNotEmpty)
              _buildTag(history.category!, AppTheme.tagCategory),
            // 连载状态标签
            _buildTag(
              history.creationStatus,
              history.creationStatus == '完结'
                  ? AppTheme.tagCompleted
                  : AppTheme.tagSerializing,
            ),
          ],
        ),
      ],
    );
  }

  /// 构建标签
  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
