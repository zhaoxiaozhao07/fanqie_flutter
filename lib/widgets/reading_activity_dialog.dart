import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../services/reading_activity_service.dart';

/// 本地阅读与听书统计报表弹窗（支持看书/沉浸式与常规听书汇总、趋势柱状图与 12 周热力图）
class ReadingActivityDialog extends StatefulWidget {
  const ReadingActivityDialog({super.key});

  @override
  State<ReadingActivityDialog> createState() => _ReadingActivityDialogState();
}

class _ReadingActivityDialogState extends State<ReadingActivityDialog> {
  int _chartDays = 7;

  String _formatDuration(int millis) {
    final totalMinutes = millis ~/ 60000;
    if (totalMinutes <= 0 && millis > 0) return '<1 分钟';
    if (totalMinutes < 60) return '$totalMinutes 分钟';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return mins == 0 ? '$hours 小时' : '$hours 小时 $mins 分';
  }

  String _formatCompactDuration(int millis) {
    final totalMinutes = millis ~/ 60000;
    if (totalMinutes < 60) return '${totalMinutes}m';
    final hours = totalMinutes / 60.0;
    return '${hours.toStringAsFixed(hours >= 10 ? 0 : 1)}h';
  }

  @override
  Widget build(BuildContext context) {
    final activity = ReadingActivityService();
    final isDark = AppTheme.isDark(context);
    final surface = isDark ? const Color(0xFF252830) : const Color(0xFFF6F7F9);
    final textPrimary = AppTheme.textPrimaryOf(context);
    final textSecondary = AppTheme.textSecondaryOf(context);

    return AnimatedBuilder(
      animation: activity,
      builder: (context, _) {
        final books = activity.books.entries.toList()
          ..sort(
            (a, b) => ((b.value as Map)['last_active']?.toString() ?? '')
                .compareTo((a.value as Map)['last_active']?.toString() ?? ''),
          );
        final now = DateTime.now();
        final todayKey = ReadingActivityService.dayKeyOf(now);
        final today = activity.days[todayKey] as Map? ?? {};
        final todayReadMs = (today['reading_ms'] as num?)?.toInt() ?? 0;
        final todayListenMs = (today['listening_ms'] as num?)?.toInt() ?? 0;
        final totalReadMs = activity.totalReadingMs;
        final totalListenMs = activity.totalListeningMs;
        final totalAllMs = totalReadMs + totalListenMs;
        final streak = activity.currentStreakDays(anchor: now);
        final speed = activity.averageCharsPerMinute;
        final dailySeries = activity.recentDailyStats(_chartDays, anchor: now);
        final heatmapSeries = activity.recentDailyStats(84, anchor: now);

        return AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('阅读与听书统计')),
              Text(
                '仅本机存储',
                style: TextStyle(fontSize: 12, color: textSecondary),
              ),
            ],
          ),
          content: SizedBox(
            width: math.min(540, MediaQuery.sizeOf(context).width * 0.9),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用本地阅读统计'),
                    subtitle: Text(
                      '区分看书与听书（含普通朗读与沉浸式多角色听书）；忽略后台空置停留。',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                    value: activity.enabled,
                    onChanged: (value) => activity.setEnabled(value),
                  ),
                  const SizedBox(height: 8),
                  // 顶部四格汇总 KPI 卡片
                  GridView.count(
                    crossAxisCount: MediaQuery.sizeOf(context).width < 460 ? 2 : 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.55,
                    children: [
                      _kpiCard(
                        label: '今日看书',
                        value: _formatDuration(todayReadMs),
                        accent: AppTheme.primaryColor,
                        bg: surface,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                      ),
                      _kpiCard(
                        label: '今日听书',
                        value: _formatDuration(todayListenMs),
                        accent: const Color(0xFF3B82F6),
                        bg: surface,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                      ),
                      _kpiCard(
                        label: '累计活跃',
                        value: _formatCompactDuration(totalAllMs),
                        accent: const Color(0xFF10B981),
                        bg: surface,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                      ),
                      _kpiCard(
                        label: '连续活跃',
                        value: '$streak 天',
                        accent: const Color(0xFFF59E0B),
                        bg: surface,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                      ),
                    ],
                  ),
                  if (speed != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '累计看书 ${_formatDuration(totalReadMs)} · 累计听书 ${_formatDuration(totalListenMs)} · 平均阅读速度约 ${speed.round()} 字/分钟',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                  ] else if (totalAllMs > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '累计看书 ${_formatDuration(totalReadMs)} · 累计听书 ${_formatDuration(totalListenMs)}',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // 趋势柱状图区块
                  Row(
                    children: [
                      Text(
                        '每日趋势',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                      const Spacer(),
                      ChoiceChip(
                        label: const Text('7 天'),
                        selected: _chartDays == 7,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _chartDays = 7),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('30 天'),
                        selected: _chartDays == 30,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _chartDays = 30),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 124,
                          width: double.infinity,
                          child: CustomPaint(
                            key: const ValueKey('reading-activity-bar-chart'),
                            painter: _DailyTrendBarPainter(
                              series: dailySeries,
                              readingColor: AppTheme.primaryColor,
                              listeningColor: const Color(0xFF3B82F6),
                              labelColor: textSecondary,
                              gridColor: AppTheme.dividerOf(context),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _legendDot(AppTheme.primaryColor, '看书', textSecondary),
                            const SizedBox(width: 12),
                            _legendDot(const Color(0xFF3B82F6), '听书', textSecondary),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 近 12 周阅读热力图
                  Text(
                    '近 12 周活跃热力图',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _ReadingHeatmapGrid(
                      key: const ValueKey('reading-activity-heatmap'),
                      series: heatmapSeries,
                      isDark: isDark,
                    ),
                  ),
                  const Divider(height: 24),
                  if (activity.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        activity.errorMessage!,
                        style: const TextStyle(color: AppTheme.errorColor),
                      ),
                    ),
                  Text(
                    '单书时长明细',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (books.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '暂无阅读或听书记录',
                        style: TextStyle(color: textSecondary),
                      ),
                    ),
                  for (final entry in books.take(30))
                    _buildBookRow(
                      entry.value as Map,
                      maxBookMs: math.max(
                        1,
                        books
                            .take(30)
                            .map(
                              (e) =>
                                  (((e.value as Map)['reading_ms'] as num?)?.toInt() ?? 0) +
                                  (((e.value as Map)['listening_ms'] as num?)?.toInt() ?? 0),
                            )
                            .fold<int>(1, math.max),
                      ),
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    ),
                  const SizedBox(height: 8),
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

  Widget _kpiCard({
    required String label,
    required String value,
    required Color accent,
    required Color bg,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label, Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: textColor)),
      ],
    );
  }

  Widget _buildBookRow(
    Map stats, {
    required int maxBookMs,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final readMs = (stats['reading_ms'] as num?)?.toInt() ?? 0;
    final listenMs = (stats['listening_ms'] as num?)?.toInt() ?? 0;
    final chars = (stats['characters'] as num?)?.toInt() ?? 0;
    final totalMs = readMs + listenMs;
    final ratio = (totalMs / maxBookMs).clamp(0.0, 1.0);
    final readRatio = totalMs > 0 ? (readMs / totalMs).clamp(0.0, 1.0) : 1.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            stats['title']?.toString() ?? '未知书籍',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '看书 ${_formatDuration(readMs)} · 听书 ${_formatDuration(listenMs)}'
            '${chars > 0 ? ' · 约 ${(chars / 10000).toStringAsFixed(chars >= 10000 ? 1 : 2)} 万字' : ''}',
            style: TextStyle(fontSize: 11, color: textSecondary),
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final barWidth = constraints.maxWidth * ratio;
                return Container(
                  height: 5,
                  width: double.infinity,
                  color: textSecondary.withValues(alpha: 0.14),
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: barWidth,
                    child: Row(
                      children: [
                        if (readMs > 0)
                          Expanded(
                            flex: math.max(1, (readRatio * 100).round()),
                            child: Container(color: AppTheme.primaryColor),
                          ),
                        if (listenMs > 0)
                          Expanded(
                            flex: math.max(1, ((1 - readRatio) * 100).round()),
                            child: Container(color: const Color(0xFF3B82F6)),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 纯 Flutter 自绘按日阅读+听书堆叠柱状图
class _DailyTrendBarPainter extends CustomPainter {
  final List<({DateTime date, int readingMs, int listeningMs})> series;
  final Color readingColor;
  final Color listeningColor;
  final Color labelColor;
  final Color gridColor;

  const _DailyTrendBarPainter({
    required this.series,
    required this.readingColor,
    required this.listeningColor,
    required this.labelColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty) return;
    const bottomLabelHeight = 18.0;
    const topPad = 14.0;
    final chartHeight = math.max(10.0, size.height - bottomLabelHeight - topPad);
    final maxMinutes = series.fold<double>(
      10.0,
      (best, item) => math.max(best, (item.readingMs + item.listeningMs) / 60000.0),
    );

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.8;
    // 绘制基线与中线
    canvas.drawLine(
      Offset(0, topPad + chartHeight),
      Offset(size.width, topPad + chartHeight),
      gridPaint,
    );
    canvas.drawLine(
      Offset(0, topPad + chartHeight * 0.5),
      Offset(size.width, topPad + chartHeight * 0.5),
      gridPaint,
    );

    // 右上角最大值刻度
    final maxPainter = TextPainter(
      text: TextSpan(
        text: '峰值 ${maxMinutes.ceil()} 分钟',
        style: TextStyle(fontSize: 10, color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    maxPainter.paint(canvas, Offset(size.width - maxPainter.width, 0));

    final n = series.length;
    final slotWidth = size.width / n;
    final barWidth = math.max(3.0, math.min(20.0, slotWidth * 0.56));
    final readPaint = Paint()..color = readingColor;
    final listenPaint = Paint()..color = listeningColor;

    for (var i = 0; i < n; i++) {
      final item = series[i];
      final readMin = item.readingMs / 60000.0;
      final listenMin = item.listeningMs / 60000.0;
      final totalMin = readMin + listenMin;
      final cx = i * slotWidth + slotWidth / 2;
      final left = cx - barWidth / 2;
      final baseY = topPad + chartHeight;

      if (totalMin > 0) {
        final readH = (readMin / maxMinutes) * chartHeight;
        final listenH = (listenMin / maxMinutes) * chartHeight;
        if (readH > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, baseY - readH, barWidth, readH),
              const Radius.circular(3),
            ),
            readPaint,
          );
        }
        if (listenH > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, baseY - readH - listenH, barWidth, listenH),
              const Radius.circular(3),
            ),
            listenPaint,
          );
        }
      }

      final showLabel = n <= 7 || i == 0 || i == n - 1 || i % 7 == 0;
      if (showLabel) {
        final label = '${item.date.month}/${item.date.day}';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(fontSize: 9, color: labelColor),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(
            (cx - tp.width / 2).clamp(0, math.max(0, size.width - tp.width)),
            baseY + 3,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DailyTrendBarPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.readingColor != readingColor ||
      oldDelegate.listeningColor != listeningColor;
}

/// 近 12 周阅读活跃热力图网格
class _ReadingHeatmapGrid extends StatelessWidget {
  final List<({DateTime date, int readingMs, int listeningMs})> series;
  final bool isDark;

  const _ReadingHeatmapGrid({
    super.key,
    required this.series,
    required this.isDark,
  });

  Color _cellColor(int totalMs) {
    final minutes = totalMs ~/ 60000;
    if (minutes <= 0) {
      return isDark ? const Color(0xFF1A1C22) : const Color(0xFFE5E7EB);
    }
    if (minutes < 15) return AppTheme.primaryColor.withValues(alpha: 0.28);
    if (minutes < 45) return AppTheme.primaryColor.withValues(alpha: 0.55);
    if (minutes < 90) return AppTheme.primaryColor.withValues(alpha: 0.78);
    return AppTheme.primaryColor;
  }

  @override
  Widget build(BuildContext context) {
    // 12 列（每周一列）× 7 行（7 天）
    final weeks = (series.length / 7).ceil();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var w = 0; w < weeks; w++)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Column(
                children: [
                  for (var d = 0; d < 7; d++)
                    if (w * 7 + d < series.length)
                      Builder(
                        builder: (context) {
                          final item = series[w * 7 + d];
                          final totalMs = item.readingMs + item.listeningMs;
                          final mins = totalMs ~/ 60000;
                          return Tooltip(
                            message:
                                '${item.date.year}-${item.date.month.toString().padLeft(2, '0')}-${item.date.day.toString().padLeft(2, '0')}：$mins 分钟',
                            child: Container(
                              width: 12,
                              height: 12,
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: _cellColor(totalMs),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          );
                        },
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
