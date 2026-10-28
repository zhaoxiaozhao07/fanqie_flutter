import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../screens/reader_screen.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';

/// 下载任务管理面板 (ModalBottomSheet)
/// 点击主界面右上角下载图标后弹出，实时查看后台下载进度与历史
class DownloadManagerSheet extends StatefulWidget {
  const DownloadManagerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const DownloadManagerSheet(),
    );
  }

  @override
  State<DownloadManagerSheet> createState() => _DownloadManagerSheetState();
}

class _DownloadManagerSheetState extends State<DownloadManagerSheet> {
  final DownloadService _downloadService = DownloadService();
  final ApiService _apiService = ApiService();

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: screenHeight * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 顶部拖拽手柄与标题栏
          _buildHeader(context),
          const Divider(height: 1),
          // 任务列表内容
          Expanded(
            child: AnimatedBuilder(
              animation: _downloadService,
              builder: (context, _) {
                final activeTasks = _downloadService.activeTasks;
                final allTasks = _downloadService.tasks;

                if (allTasks.isEmpty) {
                  return _buildEmptyState();
                }

                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    if (activeTasks.isNotEmpty) ...[
                      _buildSectionTitle('正在下载 (${activeTasks.length})'),
                      const SizedBox(height: 8),
                      for (final task in activeTasks) ...[
                        _buildActiveTaskCard(task),
                        const SizedBox(height: 12),
                      ],
                      const SizedBox(height: 12),
                    ],
                    // 其他已完成或已取消任务
                    if (allTasks.any((t) => !t.isActive)) ...[
                      _buildSectionTitle('最近任务'),
                      const SizedBox(height: 8),
                      for (final task in allTasks.where((t) => !t.isActive)) ...[
                        _buildFinishedTaskCard(task),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 12, 12),
      child: Column(
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.downloading_rounded, color: AppTheme.primaryColor, size: 22),
              const SizedBox(width: 8),
              const Text(
                '下载任务管理',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: AppTheme.textSecondary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppTheme.textSecondary,
      ),
    );
  }

  Widget _buildActiveTaskCard(DownloadTask task) {
    final percentStr = (task.progress * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryColor.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 封面图
              _buildBookThumb(task.book.thumbUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.book.bookName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryLight,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            task.format,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.primaryColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${task.current} / ${task.total} 章',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textHint),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 取消按钮
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.redAccent, width: 0.8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _confirmCancel(task),
                child: const Text('取消', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 进度条与百分比
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: task.progress > 0 ? task.progress : null,
                    backgroundColor: AppTheme.primaryLight,
                    color: AppTheme.primaryColor,
                    minHeight: 5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$percentStr%',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            task.message,
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildFinishedTaskCard(DownloadTask task) {
    final isSuccess = task.status == DownloadTaskStatus.completed;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          _buildBookThumb(task.book.thumbUrl),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.book.bookName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  isSuccess ? '下载成功 (${task.format})' : (task.status == DownloadTaskStatus.cancelled ? '已取消' : '下载失败'),
                  style: TextStyle(
                    fontSize: 12,
                    color: isSuccess ? Colors.green : (task.status == DownloadTaskStatus.cancelled ? Colors.grey : Colors.red),
                  ),
                ),
              ],
            ),
          ),
          if (isSuccess) ...[
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _openReader(task.book),
              child: const Text('立即阅读', style: TextStyle(fontSize: 12)),
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
              onPressed: () => _downloadService.removeTask(task.id),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBookThumb(String? thumbUrl) {
    if (thumbUrl != null && thumbUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          thumbUrl,
          width: 36,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildThumbPlaceholder(),
        ),
      );
    }
    return _buildThumbPlaceholder();
  }

  Widget _buildThumbPlaceholder() {
    return Container(
      width: 36,
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.book, size: 18, color: Colors.grey),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_download_outlined, size: 54, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          const Text(
            '暂无进行中的下载任务',
            style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 6),
          const Text(
            '在书籍详情页点击下载，即可在后台高速下载',
            style: TextStyle(fontSize: 12, color: AppTheme.textHint),
          ),
        ],
      ),
    );
  }

  void _confirmCancel(DownloadTask task) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消下载'),
        content: Text('确定要取消《${task.book.bookName}》的下载吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('继续下载'),
          ),
          TextButton(
            onPressed: () {
              _downloadService.cancelDownload(task.book.bookId);
              Navigator.pop(ctx);
            },
            child: const Text('取消下载', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _openReader(Book book) async {
    Navigator.pop(context);
    final chapters = await _apiService.getBookChapters(book.bookId);
    if (!mounted || chapters.isEmpty) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReaderScreen(
          book: book,
          chapters: chapters,
          initialChapterIndex: 0,
        ),
      ),
    );
  }
}
