import 'package:flutter/material.dart';
import '../services/reading_activity_service.dart';

class ReadingActivityDialog extends StatelessWidget {
  const ReadingActivityDialog({super.key});
  @override
  Widget build(BuildContext context) {
    final activity = ReadingActivityService();
    String duration(dynamic millis) {
      final minutes = ((millis as num?)?.toInt() ?? 0) ~/ 60000;
      return minutes < 60
          ? '$minutes 分钟'
          : '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
    }

    return AnimatedBuilder(
      animation: activity,
      builder: (context, _) {
        final books = activity.books.entries.toList()
          ..sort(
            (a, b) => ((b.value as Map)['last_active']?.toString() ?? '')
                .compareTo((a.value as Map)['last_active']?.toString() ?? ''),
          );
        final now = DateTime.now();
        final day =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final today = activity.days[day] as Map? ?? {};
        return AlertDialog(
          title: const Text('阅读统计'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用本地阅读统计'),
                    value: activity.enabled,
                    onChanged: (value) => activity.setEnabled(value),
                  ),
                  const Text(
                    '默认关闭。仅本机保存，区分看书与听书；忽略后台与长时间无操作的看书停留，不上传、不打卡。启用后阅读页显示本章剩余时间估计。',
                  ),
                  const SizedBox(height: 12),
                  Text('今日看书：${duration(today['reading_ms'])}'),
                  Text('今日听书：${duration(today['listening_ms'])}'),
                  const Divider(),
                  if (activity.errorMessage != null)
                    Text(activity.errorMessage!),
                  if (books.isEmpty) const Text('暂无阅读记录'),
                  for (final entry in books.take(30))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        (entry.value as Map)['title']?.toString() ?? '未知书籍',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '看书 ${duration((entry.value as Map)['reading_ms'])} · 听书 ${duration((entry.value as Map)['listening_ms'])}',
                      ),
                    ),
                  TextButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('关闭并清空统计？'),
                          content: const Text('不会删除书籍、进度、书签或笔记。'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        await activity.setEnabled(false, clear: true);
                      }
                    },
                    child: const Text('关闭并清空统计'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
