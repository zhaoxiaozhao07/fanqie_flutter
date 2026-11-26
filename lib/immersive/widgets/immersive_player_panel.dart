import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../models/reading_position.dart';
import '../../services/reader_platform.dart';
import '../models/immersive_entities.dart';
import '../services/immersive_playback_coordinator.dart';
import 'immersive_characters_sheet.dart';
import 'immersive_settings_sheet.dart';

/// 沉浸式多角色听书底部播放控制面板
class ImmersivePlayerPanel extends StatefulWidget {
  static const desktopHeight = 132.0;

  final VoidCallback onClose;
  final Color? backgroundColor;
  final Color? textColor;
  final Color? secondaryColor;
  final ValueChanged<bool>? onModalChanged;
  final void Function(int chapterIndex, ReadingPosition position)? onJumpToSource;
  final ImmersivePlaybackCoordinator? coordinator;

  const ImmersivePlayerPanel({
    super.key,
    required this.onClose,
    this.backgroundColor,
    this.textColor,
    this.secondaryColor,
    this.onModalChanged,
    this.onJumpToSource,
    this.coordinator,
  });

  @override
  State<ImmersivePlayerPanel> createState() => _ImmersivePlayerPanelState();
}

class _ImmersivePlayerPanelState extends State<ImmersivePlayerPanel> {
  PipelineStatus _status = const PipelineStatus();
  Timer? _statusTimer;

  ImmersivePlaybackCoordinator get _coord =>
      widget.coordinator ?? ImmersivePlaybackCoordinator();

  @override
  void initState() {
    super.initState();
    _coord.addListener(_onChanged);
    _refreshStatus();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 900),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _coord.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    if (!_coord.isActive) {
      setState(() => _status = const PipelineStatus());
      return;
    }
    _refreshStatus();
    setState(() {});
  }

  Future<void> _refreshStatus() async {
    if (!_coord.isActive || !mounted) return;
    final st = await _coord.getPipelineStatus();
    if (mounted) {
      setState(() => _status = st);
    }
  }

  Widget _buildActiveModelBadge(ImmersivePlaybackCoordinator coord) {
    final label = coord.activeTextModelLabel;
    if (label.isEmpty) return const SizedBox.shrink();
    final isFallback = coord.isUsingFallbackTextModel;
    final modelId = coord.activeTextModelId;
    final displayText =
        modelId.isNotEmpty && modelId != label
        ? '$label ($modelId)'
        : label;
    final prefix = isFallback ? '兜底模型' : '当前模型';
    final badgeColor = isFallback ? Colors.orange : AppTheme.primaryColor;

    return Container(
      key: const ValueKey('immersive-active-model-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: badgeColor.withValues(alpha: 0.35)),
      ),
      child: Text(
        '$prefix: $displayText',
        style: TextStyle(
          fontSize: 10.5,
          color: badgeColor,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ReaderPlatform.capabilities.tts) return const SizedBox.shrink();
    final coord = _coord;
    if (!coord.isActive) return const SizedBox.shrink();

    final effectiveBg = widget.backgroundColor ?? AppTheme.surfaceOf(context);
    final effectiveText = widget.textColor ?? AppTheme.textPrimaryOf(context);
    final effectiveSecondary =
        widget.secondaryColor ?? AppTheme.textSecondaryOf(context);

    final seg = coord.currentSegment;
    final speakerLabel = seg?.speakerDisplayName ?? '准备中';
    final spokenText = seg?.spokenText ?? _status.phaseLabel;
    final isPlaying = coord.isPlaying;
    final isBuffering = coord.isBuffering;
    final isBlocked = coord.state == ImmersivePlayState.blocked;
    // 有实时调度器时直接以调度器实时阻塞原因为准，避免异步刷新前闪现旧报错残影
    final liveBlockingReason = coord.scheduler != null
        ? coord.scheduler!.blockingReason
        : _status.blockingReason;
    final issueText =
        coord.errorMessage ?? liveBlockingReason ?? coord.notice;

    if (ReaderPlatform.isDesktop) {
      return _buildDesktopPanel(
        context: context,
        coord: coord,
        speakerLabel: speakerLabel,
        spokenText: spokenText,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
        isBlocked: isBlocked,
        issueText: issueText,
        backgroundColor: effectiveBg,
        textColor: effectiveText,
        secondaryColor: effectiveSecondary,
      );
    }

    return Container(
      key: const ValueKey('immersive-player-panel'),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 12,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：沉浸式徽章 + 当前说话角色 + 台词预览 + 关闭
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '沉浸 · $speakerLabel',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spokenText,
                    style: TextStyle(
                      fontSize: 12,
                      color: effectiveText,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('immersive-stop-close-btn'),
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: effectiveSecondary,
                  ),
                  tooltip: '停止沉浸式听书',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    unawaited(coord.stop());
                    widget.onClose();
                  },
                ),
              ],
            ),
            // 第二行：真实多阶段管线状态（区分角色确认、音频生成与连续可播秒数）
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _status.phaseLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: isBlocked
                          ? Colors.redAccent
                          : AppTheme.primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _buildActiveModelBadge(coord),
                  if (_status.isPreparingPrefix)
                    Text(
                      '前文档案 ${_status.prefixCompletedChunks}/${_status.prefixTotalChunks}',
                      style: TextStyle(
                        fontSize: 11,
                        color: effectiveSecondary,
                      ),
                    )
                  else ...[
                    Text(
                      '已确认 ${_status.confirmedChunks}/${_status.totalPlannedChunks} 块',
                      style: TextStyle(
                        fontSize: 11,
                        color: effectiveSecondary,
                      ),
                    ),
                    Text(
                      '已生成 ${_status.readyAudioSegments}/${_status.totalManifestSegments} 段',
                      style: TextStyle(
                        fontSize: 11,
                        color: effectiveSecondary,
                      ),
                    ),
                    Text(
                      '可播 ${_status.continuousReadySeconds.toStringAsFixed(0)}s',
                      style: TextStyle(
                        fontSize: 11,
                        color: effectiveSecondary,
                      ),
                    ),
                  ],
                  if (coord.hasSleepSchedule)
                    Text(
                      coord.stopAfterCurrentChapter
                          ? '定时:播完本章'
                          : '定时:${coord.timerRemainingMinutes}分',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            if (issueText != null && issueText.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: (isBlocked ? Colors.red : Colors.orange).withValues(
                    alpha: 0.1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      isBlocked
                          ? Icons.error_outline
                          : Icons.info_outline_rounded,
                      size: 15,
                      color: isBlocked ? Colors.redAccent : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        issueText,
                        style: TextStyle(fontSize: 11, color: effectiveText),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('immersive-retry-issue-btn'),
                      onPressed: () async {
                        await coord.retryBlockedRange();
                        await _refreshStatus();
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text('重试', style: TextStyle(fontSize: 11)),
                    ),
                    IconButton(
                      key: const ValueKey('immersive-dismiss-issue-btn'),
                      tooltip: '关闭提示',
                      icon: Icon(
                        Icons.close,
                        size: 15,
                        color: effectiveSecondary,
                      ),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 26,
                        height: 26,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () {
                        coord.dismissIssue();
                        unawaited(_refreshStatus());
                      },
                    ),
                  ],
                ),
              ),
            // 第三行：播放控制按钮栏
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 本地倍速调节（不重新合成音频）
                TextButton(
                  onPressed: () => _showRateDialog(context, coord),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(40, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  child: Text(
                    '${coord.playbackRate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '')}x',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: effectiveText,
                    ),
                  ),
                ),
                // 睡眠定时（定时停 / 播完本章停）
                IconButton(
                  key: const ValueKey('immersive-sleep-timer-btn'),
                  icon: Badge(
                    isLabelVisible: coord.hasSleepSchedule,
                    label: Text(
                      coord.stopAfterCurrentChapter
                          ? '章'
                          : '${coord.timerRemainingMinutes}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    child: Icon(
                      Icons.bedtime_outlined,
                      size: 20,
                      color: coord.hasSleepSchedule
                          ? AppTheme.primaryColor
                          : effectiveSecondary,
                    ),
                  ),
                  tooltip: '睡眠定时',
                  onPressed: () => _showSleepTimerDialog(context, coord),
                ),
                IconButton(
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    size: 26,
                    color: effectiveText,
                  ),
                  tooltip: '上一段',
                  onPressed: coord.currentSegmentIndex > 0
                      ? () => unawaited(coord.previousSegment())
                      : null,
                ),
                FloatingActionButton.small(
                  heroTag: 'immersive_play_fab',
                  backgroundColor: AppTheme.primaryColor,
                  elevation: 2,
                  onPressed: () {
                    if (isPlaying) {
                      unawaited(coord.pause());
                    } else if (coord.isPaused) {
                      unawaited(coord.resume());
                    } else if (isBlocked) {
                      unawaited(coord.retryBlockedRange());
                    }
                  },
                  child: isBuffering
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.skip_next_rounded,
                    size: 26,
                    color: effectiveText,
                  ),
                  tooltip: '下一段',
                  onPressed:
                      coord.currentSegmentIndex + 1 <
                          coord.manifestSegments.length
                      ? () => unawaited(coord.nextSegment())
                      : null,
                ),
                // 角色档案与身份修正
                IconButton(
                  icon: Badge(
                    isLabelVisible:
                        _status.unresolvedDialogueCount > 0 ||
                        _status.blockedConflictCount > 0,
                    label: Text(
                      '${_status.unresolvedDialogueCount + _status.blockedConflictCount}',
                      style: const TextStyle(fontSize: 9),
                    ),
                    child: Icon(
                      Icons.people_alt_outlined,
                      size: 20,
                      color: effectiveSecondary,
                    ),
                  ),
                  tooltip: '本书角色与音色',
                  onPressed: coord.currentBookId == null
                      ? null
                      : () => _openCharacters(context, coord.currentBookId!),
                ),
                // 模型、音色与管线设置
                IconButton(
                  icon: Icon(
                    Icons.tune_rounded,
                    size: 20,
                    color: effectiveSecondary,
                  ),
                  tooltip: '沉浸式听书设置',
                  onPressed: () => _openSettings(context, coord.currentBookId),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopPanel({
    required BuildContext context,
    required ImmersivePlaybackCoordinator coord,
    required String speakerLabel,
    required String spokenText,
    required bool isPlaying,
    required bool isBuffering,
    required bool isBlocked,
    required String? issueText,
    required Color backgroundColor,
    required Color textColor,
    required Color secondaryColor,
  }) {
    final rateLabel =
        '${coord.playbackRate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '')}x';
    final bookMeta = [
      if (coord.currentBookTitle.isNotEmpty) coord.currentBookTitle,
      if (coord.currentChapterTitle.isNotEmpty) coord.currentChapterTitle,
    ].join(' · ');
    final statusMetrics = _status.isPreparingPrefix
        ? '前文档案 ${_status.prefixCompletedChunks}/${_status.prefixTotalChunks}'
        : '已确认 ${_status.confirmedChunks}/${_status.totalPlannedChunks} 块 · '
              '已生成 ${_status.readyAudioSegments}/${_status.totalManifestSegments} 段 · '
              '可播 ${_status.continuousReadySeconds.toStringAsFixed(0)}s';

    return Material(
      key: const ValueKey('immersive-player-panel'),
      color: backgroundColor,
      elevation: 8,
      child: SizedBox(
        height: ImmersivePlayerPanel.desktopHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：沉浸式说话角色 + 书章信息 + 倍速 / 定时 / 角色 / 设置 / 关闭
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '沉浸 · $speakerLabel',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        bookMeta.isEmpty ? spokenText : '$bookMeta · $spokenText',
                        style: TextStyle(
                          fontSize: 12,
                          color: textColor,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showRateDialog(context, coord),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(
                        rateLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: textColor,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('immersive-sleep-timer-btn'),
                      icon: Badge(
                        isLabelVisible: coord.hasSleepSchedule,
                        label: Text(
                          coord.stopAfterCurrentChapter
                              ? '章'
                              : '${coord.timerRemainingMinutes}',
                          style: const TextStyle(fontSize: 9),
                        ),
                        child: Icon(
                          Icons.bedtime_outlined,
                          size: 19,
                          color: coord.hasSleepSchedule
                              ? AppTheme.primaryColor
                              : secondaryColor,
                        ),
                      ),
                      tooltip: '睡眠定时',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed: () => _showSleepTimerDialog(context, coord),
                    ),
                    IconButton(
                      icon: Badge(
                        isLabelVisible:
                            _status.unresolvedDialogueCount > 0 ||
                            _status.blockedConflictCount > 0,
                        label: Text(
                          '${_status.unresolvedDialogueCount + _status.blockedConflictCount}',
                          style: const TextStyle(fontSize: 9),
                        ),
                        child: Icon(
                          Icons.people_alt_outlined,
                          size: 19,
                          color: secondaryColor,
                        ),
                      ),
                      tooltip: '本书角色与音色',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed: coord.currentBookId == null
                          ? null
                          : () => _openCharacters(context, coord.currentBookId!),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.tune_rounded,
                        size: 19,
                        color: secondaryColor,
                      ),
                      tooltip: '沉浸式听书设置',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed: () => _openSettings(context, coord.currentBookId),
                    ),
                    IconButton(
                      key: const ValueKey('immersive-stop-close-btn'),
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: secondaryColor,
                      ),
                      tooltip: '停止沉浸式听书',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed: () {
                        unawaited(coord.stop());
                        widget.onClose();
                      },
                    ),
                  ],
                ),
              ),
              // 第二行：播放控制与实时管线状态
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.skip_previous_rounded,
                        size: 22,
                        color: textColor,
                      ),
                      tooltip: '上一段',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed: coord.currentSegmentIndex > 0
                          ? () => unawaited(coord.previousSegment())
                          : null,
                    ),
                    if (isBuffering)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 24,
                          color: AppTheme.primaryColor,
                        ),
                        tooltip: isPlaying ? '暂停听书' : '继续听书',
                        constraints: const BoxConstraints.tightFor(
                          width: 36,
                          height: 36,
                        ),
                        padding: const EdgeInsets.all(6),
                        onPressed: () {
                          if (isPlaying) {
                            unawaited(coord.pause());
                          } else if (coord.isPaused) {
                            unawaited(coord.resume());
                          } else if (isBlocked) {
                            unawaited(coord.retryBlockedRange());
                          }
                        },
                      ),
                    IconButton(
                      icon: Icon(
                        Icons.skip_next_rounded,
                        size: 22,
                        color: textColor,
                      ),
                      tooltip: '下一段',
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: const EdgeInsets.all(6),
                      onPressed:
                          coord.currentSegmentIndex + 1 <
                              coord.manifestSegments.length
                          ? () => unawaited(coord.nextSegment())
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _status.phaseLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: isBlocked
                            ? Colors.redAccent
                            : AppTheme.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildActiveModelBadge(coord),
                    if (coord.hasSleepSchedule) ...[
                      const SizedBox(width: 8),
                      Text(
                        coord.stopAfterCurrentChapter
                            ? '播完本章停'
                            : '定时${coord.timerRemainingMinutes}分',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        statusMetrics,
                        style: TextStyle(
                          fontSize: 11,
                          color: secondaryColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              // 第三行：异常提示/重试 或 当前台词摘要
              Expanded(
                child: issueText != null && issueText.isNotEmpty
                    ? Row(
                        children: [
                          Icon(
                            isBlocked
                                ? Icons.error_outline
                                : Icons.info_outline_rounded,
                            size: 14,
                            color: isBlocked ? Colors.redAccent : Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              issueText,
                              style: TextStyle(
                                fontSize: 11,
                                color: textColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('immersive-retry-issue-btn'),
                            onPressed: () async {
                              await coord.retryBlockedRange();
                              await _refreshStatus();
                            },
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: const Size(0, 26),
                            ),
                            child: const Text(
                              '重试',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('immersive-dismiss-issue-btn'),
                            tooltip: '关闭提示',
                            icon: Icon(
                              Icons.close,
                              size: 14,
                              color: secondaryColor,
                            ),
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                              width: 24,
                              height: 24,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              coord.dismissIssue();
                              unawaited(_refreshStatus());
                            },
                          ),
                        ],
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          spokenText,
                          style: TextStyle(
                            fontSize: 11,
                            color: secondaryColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSleepTimerDialog(
    BuildContext context,
    ImmersivePlaybackCoordinator coord,
  ) {
    widget.onModalChanged?.call(true);
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('沉浸式听书定时关闭'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              coord.setSleepTimer(0);
              Navigator.pop(ctx);
            },
            child: Row(
              children: [
                const Text('关闭定时'),
                if (!coord.hasSleepSchedule) ...[
                  const Spacer(),
                  const Icon(Icons.check, color: AppTheme.primaryColor),
                ],
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () {
              coord.setStopAfterCurrentChapter(true);
              Navigator.pop(ctx);
            },
            child: Row(
              children: [
                const Text('播完本章后停止（不预取下一章）'),
                if (coord.stopAfterCurrentChapter) ...[
                  const Spacer(),
                  const Icon(Icons.check, color: AppTheme.primaryColor),
                ],
              ],
            ),
          ),
          for (final minutes in const [15, 30, 45, 60, 90])
            SimpleDialogOption(
              onPressed: () {
                coord.setSleepTimer(minutes);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  Text('$minutes 分钟后停止'),
                  if (!coord.stopAfterCurrentChapter &&
                      coord.sleepDeadline != null &&
                      coord.timerRemainingMinutes <= minutes &&
                      coord.timerRemainingMinutes > minutes - 15) ...[
                    const Spacer(),
                    const Icon(Icons.check, color: AppTheme.primaryColor),
                  ],
                ],
              ),
            ),
        ],
      ),
    ).whenComplete(() => widget.onModalChanged?.call(false));
  }

  void _showRateDialog(
    BuildContext context,
    ImmersivePlaybackCoordinator coord,
  ) {
    widget.onModalChanged?.call(true);
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('播放倍速（本地变速，不重新合成）'),
        children: [
          for (final rate in const [0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
            SimpleDialogOption(
              onPressed: () {
                unawaited(coord.setPlaybackRate(rate));
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  Text('${rate}x'),
                  if ((coord.playbackRate - rate).abs() < 0.02) ...[
                    const Spacer(),
                    const Icon(Icons.check, color: AppTheme.primaryColor),
                  ],
                ],
              ),
            ),
        ],
      ),
    ).whenComplete(() => widget.onModalChanged?.call(false));
  }

  void _openCharacters(BuildContext context, String bookId) {
    widget.onModalChanged?.call(true);
    ImmersiveCharactersSheet.show(
      context,
      bookId: bookId,
      coordinator: _coord,
      onJumpToSource: widget.onJumpToSource,
    ).whenComplete(() => widget.onModalChanged?.call(false));
  }

  void _openSettings(BuildContext context, String? bookId) {
    widget.onModalChanged?.call(true);
    ImmersiveSettingsSheet.show(
      context,
      bookId: bookId,
      coordinator: _coord,
    ).whenComplete(() => widget.onModalChanged?.call(false));
  }
}
