import 'dart:async';

import 'book_page_route.dart';
import 'book_cover_widget.dart';
import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/book.dart';
import '../screens/reader_screen.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/reader_settings_repository.dart';
import '../services/reader_platform.dart';
import 'reader_modal.dart';

/// 下载任务管理面板 (ModalBottomSheet)
/// 点击主界面右上角下载图标后弹出，实时查看后台下载进度与历史
class DownloadManagerSheet extends StatefulWidget {
  final ApiService? apiService;
  final DownloadService? downloadService;
  const DownloadManagerSheet({
    super.key,
    this.apiService,
    this.downloadService,
  });

  static Future<void> show(BuildContext context) async {
    await showReaderModal<void>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => const DownloadManagerSheet(),
    );
  }

  @override
  State<DownloadManagerSheet> createState() => _DownloadManagerSheetState();
}

class _DownloadManagerSheetState extends State<DownloadManagerSheet> {
  late final DownloadService _downloadService =
      widget.downloadService ?? DownloadService();
  late final ApiService _apiService = widget.apiService ?? ApiService();
  bool _openingReader = false;

  @override
  void initState() {
    super.initState();
    unawaited(_downloadService.initialize());
  }

  @override
  void dispose() {
    _apiService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: ReaderPlatform.isMacOS ? null : screenHeight * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // 顶部拖拽手柄与标题栏
          AnimatedBuilder(
            animation: _downloadService,
            builder: (_, _) => _buildHeader(context),
          ),
          const Divider(height: 1),
          // 任务列表内容
          Expanded(
            child: AnimatedBuilder(
              animation: _downloadService,
              builder: (context, _) {
                final activeTasks = _downloadService.activeTasks.reversed
                    .toList();
                final allTasks = _downloadService.tasks;

                final error = _downloadService.queueError;
                if (allTasks.isEmpty && error == null) {
                  return _buildEmptyState();
                }

                final rows = <Object>[
                  if (error != null) 'queue-error',
                  if (activeTasks.isNotEmpty) ...[
                    '下载中／排队 (${activeTasks.length})',
                    ...activeTasks,
                  ],
                  if (allTasks.any((task) => !task.isActive)) ...[
                    '暂停及最近任务',
                    ...allTasks.where((task) => !task.isActive),
                  ],
                ];
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: row == 'queue-error'
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  error!,
                                  style: const TextStyle(color: Colors.red),
                                ),
                                TextButton(
                                  onPressed: _downloadService.retryLoadQueue,
                                  child: const Text('重新读取队列'),
                                ),
                              ],
                            )
                          : row is String
                          ? _buildSectionTitle(row)
                          : (row as DownloadTask).isActive
                          ? _buildActiveTaskCard(row)
                          : _buildFinishedTaskCard(row),
                    );
                  },
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
          if (!ReaderPlatform.isMacOS)
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
              const Icon(
                Icons.downloading_rounded,
                color: AppTheme.primaryColor,
                size: 22,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '下载任务管理',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close,
                  size: 20,
                  color: AppTheme.textSecondary,
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          if (ReaderPlatform.isMacOS)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('并行书籍'),
                DropdownButton<int>(
                  value: _downloadService.maxConcurrentTasks,
                  items: [
                    for (final n in [1, 2, 3, 4])
                      DropdownMenuItem(value: n, child: Text('$n 本')),
                  ],
                  onChanged: (v) => _concurrency(books: v),
                ),
                const Text('每书并行'),
                DropdownButton<int>(
                  value: _downloadService.chapterConcurrency,
                  items: [
                    for (final n in [3, 6, 12])
                      DropdownMenuItem(value: n, child: Text('$n 章')),
                  ],
                  onChanged: (v) => _concurrency(chapters: v),
                ),
                const Text('降低并行数不会丢弃正在完成的请求。', style: TextStyle(fontSize: 11)),
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
              _buildBookThumb(task.book),
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
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
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.textHint,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 取消按钮
              IconButton(
                key: ValueKey('download-pause-${task.id}'),
                tooltip: '暂停下载（保留已下载章节）',
                onPressed: () => _downloadService.pauseDownload(task.id),
                icon: const Icon(Icons.pause_circle_outline),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.redAccent, width: 0.8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
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
          Wrap(
            spacing: 8,
            children: [
              if (task.status == DownloadTaskStatus.pending &&
                  !_downloadService.isRunning(task.id))
                TextButton.icon(
                  key: ValueKey('download-prioritize-${task.id}'),
                  onPressed: () => _downloadService.prioritize(task.id),
                  icon: const Icon(Icons.vertical_align_top, size: 16),
                  label: const Text('优先下载'),
                ),
              TextButton(
                onPressed: () => _details(task),
                child: const Text('任务详情'),
              ),
            ],
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
          _buildBookThumb(task.book),
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
                TextButton(
                  onPressed: () => _details(task),
                  child: const Text('任务详情'),
                ),
                const SizedBox(height: 4),
                Text(
                  isSuccess ? '下载成功 (${task.format})' : task.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isSuccess
                        ? Colors.green
                        : (task.status == DownloadTaskStatus.cancelled ||
                                  task.status == DownloadTaskStatus.paused
                              ? Colors.grey
                              : Colors.red),
                  ),
                ),
              ],
            ),
          ),
          if (isSuccess) ...[
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _openReader(task.book),
              child: const Text('立即阅读', style: TextStyle(fontSize: 12)),
            ),
          ],
          if (task.canResume)
            IconButton(
              key: ValueKey('download-resume-${task.id}'),
              tooltip: task.status == DownloadTaskStatus.paused
                  ? '继续下载'
                  : '重试下载／导出',
              onPressed: _downloadService.isRunning(task.id)
                  ? null
                  : () => _resume(task),
              icon: const Icon(Icons.play_circle_outline),
            ),
          IconButton(
            key: ValueKey('download-remove-${task.id}'),
            tooltip: '移除任务（保留正文和导出文件）',
            icon: const Icon(
              Icons.delete_outline,
              size: 18,
              color: Colors.grey,
            ),
            onPressed: _downloadService.isRunning(task.id)
                ? null
                : () => _downloadService.removeTask(task.id),
          ),
        ],
      ),
    );
  }

  Future<void> _concurrency({int? books, int? chapters}) async {
    try {
      await _downloadService.setConcurrency(books: books, chapters: chapters);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('并行设置未保存')));
      }
    }
  }

  Future<void> _details(DownloadTask task) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(task.book.bookName),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: SelectableText(
            '状态：${task.status.name} · ${task.format}\n'
            '进度：${task.current}/${task.total} 章\n'
            '网络退避重试：${task.retryCount}/2\n'
            '${task.nextRetryAt == null ? '' : '下次尝试：${task.nextRetryAt!.toLocal()}\n'}'
            '${task.errorKind == null ? '' : '错误类型：${task.errorKind}\n'}'
            '${task.error ?? task.message}\n'
            '${task.failedChapterIds.isEmpty ? '' : '失败章节（最多显示 20 个）：\n${task.failedChapterIds.map((id) => task.chapters.where((c) => c.itemId == id).firstOrNull?.title ?? id).join('\n')}\n'}'
            '暂停、取消、调整顺序和重试均保留已下载的完整正文；权限或存储错误不会自动无限重试。',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _resume(DownloadTask task) async {
    try {
      await _downloadService.resumeDownload(task.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('任务无法继续：$error')));
      }
    }
  }

  Widget _buildBookThumb(Book book) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: SizedBox(
      width: 36,
      height: 48,
      child: BookCoverWidget(
        bookId: book.bookId,
        bookName: book.bookName,
        thumbUrl: book.thumbUrl,
        iconSize: 18,
      ),
    ),
  );

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 54,
            color: Colors.grey.shade400,
          ),
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
    if (_openingReader) return;
    _openingReader = true;
    try {
      // Keep this route/context alive until the asynchronous catalog succeeds.
      final chapters = await _apiService.getBookChapters(book.bookId);
      if (!mounted) return;
      if (chapters.isEmpty) throw const FormatException('章节目录暂不可用，请重试');
      final settings = await ReaderSettingsRepository().load(book.bookId);
      if (!mounted) return;
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.push(
        BookPageRoute(
          builder: (context) => ReaderScreen(
            book: book,
            chapters: chapters,
            initialChapterIndex: 0,
            initialSettings: settings,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _openingReader = false;
    }
  }
}
