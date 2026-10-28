import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../services/download_service.dart';
import 'download_manager_sheet.dart';

/// 主界面右上角常驻的下载管理操作按钮
/// 当有活动后台下载任务时，显示徽章与旋转状态；点击直接展开下载管理器
class DownloadActionButton extends StatefulWidget {
  final Color? color;
  const DownloadActionButton({super.key, this.color});

  @override
  State<DownloadActionButton> createState() => _DownloadActionButtonState();
}

class _DownloadActionButtonState extends State<DownloadActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  final DownloadService _downloadService = DownloadService();

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _downloadService,
      builder: (context, _) {
        final activeCount = _downloadService.activeTasks.length;
        final hasActive = activeCount > 0;
        Widget iconWidget;
        if (hasActive) {
          iconWidget = RotationTransition(
            turns: _animController,
            child: const Icon(
              Icons.sync_rounded,
              color: AppTheme.primaryColor,
              size: 22,
            ),
          );
        } else {
          iconWidget = Icon(
            Icons.download_rounded,
            color: widget.color ?? AppTheme.textPrimary,
            size: 22,
          );
        }

        return IconButton(
          tooltip: hasActive ? '后台正在下载 ($activeCount)' : '下载管理',
          icon: Badge(
            isLabelVisible: hasActive,
            backgroundColor: AppTheme.primaryColor,
            label: Text(
              '$activeCount',
              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            child: iconWidget,
          ),
          onPressed: () {
            DownloadManagerSheet.show(context);
          },
        );
      },
    );
  }
}
