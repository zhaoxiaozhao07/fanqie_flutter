import 'package:flutter/material.dart';
import '../app_theme.dart';

/// 下载格式选择对话框
class DownloadDialog extends StatelessWidget {
  final String bookName;
  final ValueChanged<String> onFormatSelected;

  const DownloadDialog({
    super.key,
    required this.bookName,
    required this.onFormatSelected,
  });

  /// 显示对话框
  static Future<String?> show(BuildContext context, String bookName) {
    return showDialog<String>(
      context: context,
      builder: (context) => DownloadDialog(
        bookName: bookName,
        onFormatSelected: (format) => Navigator.pop(context, format),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.download_rounded, color: AppTheme.primaryColor),
          const SizedBox(width: 8),
          const Text('选择下载格式'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '《$bookName》',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          const Text(
            '请选择保存格式：',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          // TXT 格式选项
          _buildFormatOption(
            context,
            icon: Icons.description_outlined,
            title: 'TXT 格式',
            subtitle: '纯文本格式，兼容性最好',
            format: 'TXT',
          ),
          const SizedBox(height: 12),
          // EPUB 格式选项
          _buildFormatOption(
            context,
            icon: Icons.menu_book_outlined,
            title: 'EPUB 格式',
            subtitle: '电子书格式，支持目录导航',
            format: 'EPUB',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 构建格式选项
  Widget _buildFormatOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String format,
  }) {
    return InkWell(
      onTap: () => onFormatSelected(format),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppTheme.primaryLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppTheme.primaryColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }
}

/// 下载进度对话框
class DownloadProgressDialog extends StatelessWidget {
  final String bookName;
  final int current;
  final int total;
  final String message;

  const DownloadProgressDialog({
    super.key,
    required this.bookName,
    required this.current,
    required this.total,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total > 0 ? current / total : 0.0;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: total > 0 ? progress : null,
            ),
          ),
          const SizedBox(width: 12),
          const Text('正在下载'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '《$bookName》',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: total > 0 ? progress : null,
            backgroundColor: AppTheme.primaryLight,
            valueColor: const AlwaysStoppedAnimation<Color>(
              AppTheme.primaryColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            total > 0 ? '$current / $total 章' : message,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 确认删除对话框
class DeleteConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final VoidCallback onConfirm;

  const DeleteConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.onConfirm,
  });

  /// 显示对话框
  static Future<bool?> show(
    BuildContext context, {
    required String title,
    required String content,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => DeleteConfirmDialog(
        title: title,
        content: content,
        onConfirm: () => Navigator.pop(context, true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppTheme.warningColor),
          const SizedBox(width: 8),
          Text(title),
        ],
      ),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: onConfirm,
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.errorColor),
          child: const Text('删除'),
        ),
      ],
    );
  }
}
