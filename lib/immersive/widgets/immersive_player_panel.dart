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
  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final ValueChanged<bool>? onModalChanged;
  final void Function(int chapterIndex, ReadingPosition position)? onJumpToSource;
  final ImmersivePlaybackCoordinator? coordinator;

  const ImmersivePlayerPanel({
    super.key,
    required this.onClose,
    this.backgroundColor = Colors.white,
    this.textColor = AppTheme.textPrimary,
    this.secondaryColor = AppTheme.textSecondary,
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

  @override
  Widget build(BuildContext context) {
    if (!ReaderPlatform.capabilities.tts) return const SizedBox.shrink();
    final coord = _coord;
    if (!coord.isActive) return const SizedBox.shrink();

    final seg = coord.currentSegment;
    final speakerLabel = seg?.speakerDisplayName ?? '准备中';
    final spokenText = seg?.spokenText ?? _status.phaseLabel;
    final isPlaying = coord.isPlaying;
    final isBuffering = coord.isBuffering;
    final isBlocked = coord.state == ImmersivePlayState.blocked;
    final issueText =
        coord.errorMessage ?? _status.blockingReason ?? coord.notice;

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
      );
    }

    return Container(
      key: const ValueKey('immersive-player-panel'),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
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
                      color: widget.textColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: widget.secondaryColor,
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
                runSpacing: 2,
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
                  if (_coord.isUsingFallbackTextModel)
                    Text(
                      '兜底模型:${_coord.activeTextModelLabel}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (_status.isPreparingPrefix)
                    Text(
                      '前文档案 ${_status.prefixCompletedChunks}/${_status.prefixTotalChunks}',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.secondaryColor,
                      ),
                    )
                  else ...[
                    Text(
                      '已确认 ${_status.confirmedChunks}/${_status.totalPlannedChunks} 块',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.secondaryColor,
                      ),
                    ),
                    Text(
                      '已生成 ${_status.readyAudioSegments}/${_status.totalManifestSegments} 段',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.secondaryColor,
                      ),
                    ),
                    Text(
                      '可播 ${_status.continuousReadySeconds.toStringAsFixed(0)}s',
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.secondaryColor,
                      ),
                    ),
                  ],
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
                        style: TextStyle(fontSize: 11, color: widget.textColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(coord.retryBlockedRange()),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                      ),
                      child: const Text('重试', style: TextStyle(fontSize: 11)),
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
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  child: Text(
                    '${coord.playbackRate.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '')}x',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: widget.textColor,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.skip_previous_rounded,
                    size: 26,
                    color: widget.textColor,
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
                    color: widget.textColor,
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
                      size: 21,
                      color: widget.secondaryColor,
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
                    size: 21,
                    color: widget.secondaryColor,
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
      color: widget.backgroundColor,
      elevation: 8,
      child: SizedBox(
        height: ImmersivePlayerPanel.desktopHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：沉浸式说话角色 + 书章信息 + 倍速 / 角色 / 设置 / 关闭
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
                          color: widget.textColor,
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
                          color: widget.textColor,
                        ),
                      ),
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
                          color: widget.secondaryColor,
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
                        color: widget.secondaryColor,
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
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: widget.secondaryColor,
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
                        color: widget.textColor,
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
                        color: widget.textColor,
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
                    if (coord.isUsingFallbackTextModel) ...[
                      const SizedBox(width: 8),
                      Text(
                        '兜底模型:${coord.activeTextModelLabel}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade800,
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
                          color: widget.secondaryColor,
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
                                color: widget.textColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                unawaited(coord.retryBlockedRange()),
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
                        ],
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          spokenText,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.secondaryColor,
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
