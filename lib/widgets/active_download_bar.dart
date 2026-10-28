import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../screens/book_detail_screen.dart';
import '../services/download_service.dart';

/// 全局后台下载进度展示条
/// 当有活动下载任务时在主页或列表下方自动呈现
class ActiveDownloadBar extends StatelessWidget {
  const ActiveDownloadBar({super.key});

  @override
  Widget build(BuildContext context) {
    final downloadService = DownloadService();

    return AnimatedBuilder(
      animation: downloadService,
      builder: (context, _) {
        final activeTasks = downloadService.activeTasks;
        if (activeTasks.isEmpty) {
          return const SizedBox.shrink();
        }

        final currentTask = activeTasks.first;

        return Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryColor.withValues(alpha: 0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => BookDetailScreen(book: currentTask.book),
                  ),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '后台下载中：《${currentTask.book.bookName}》 (${currentTask.format})',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${(currentTask.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: '取消下载',
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('取消下载'),
                              content: Text('确定要取消《${currentTask.book.bookName}》的下载吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('继续下载'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    downloadService.cancelDownload(currentTask.book.bookId);
                                    Navigator.pop(ctx);
                                  },
                                  child: const Text('取消下载', style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: currentTask.progress > 0 ? currentTask.progress : null,
                      backgroundColor: AppTheme.primaryLight,
                      color: AppTheme.primaryColor,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          currentTask.message,
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${currentTask.current} / ${currentTask.total}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
