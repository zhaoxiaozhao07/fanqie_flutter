import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../services/reader_platform.dart';
import '../../services/reader_system_service.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import '../services/immersive_playback_coordinator.dart';
import '../services/immersive_preset_config.dart';

/// 沉浸式设置 Tab 3：实时管线诊断、首块微切分与分级思考加速、呼吸停顿微调、通勤预合成、蓝牙按键与保活引导
class ImmersivePipelineTab extends StatefulWidget {
  final ImmersiveConfig config;
  final PipelineStatus pipelineStatus;
  final ImmersivePlaybackCoordinator coordinator;
  final bool hasBookContext;
  final bool rebuilding;
  final ValueChanged<ImmersiveConfig> onDraftChanged;
  final Future<bool> Function(ImmersiveConfig updated, String successMessage)
  onApplyAndSaveConfig;
  final VoidCallback onResetFailover;
  final Future<void> Function(int backtrack) onRebuildPressed;
  final Future<void> Function(int chapterCount)? onPreSynthesizePressed;
  final Future<void> Function() onRetryBlocked;
  final Future<void> Function() onClearUnpinnedCache;
  final Future<void> Function() onReload;

  const ImmersivePipelineTab({
    super.key,
    required this.config,
    required this.pipelineStatus,
    required this.coordinator,
    required this.hasBookContext,
    required this.rebuilding,
    required this.onDraftChanged,
    required this.onApplyAndSaveConfig,
    required this.onResetFailover,
    required this.onRebuildPressed,
    this.onPreSynthesizePressed,
    required this.onRetryBlocked,
    required this.onClearUnpinnedCache,
    required this.onReload,
  });

  @override
  State<ImmersivePipelineTab> createState() => _ImmersivePipelineTabState();
}

class _ImmersivePipelineTabState extends State<ImmersivePipelineTab>
    with WidgetsBindingObserver {
  bool? _ignoringBatteryOpt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ReaderSystemService.loadMediaButtonBehavior());
    _refreshBatteryOptStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshBatteryOptStatus();
    }
  }

  Future<void> _refreshBatteryOptStatus() async {
    if (!ReaderPlatform.isAndroid) return;
    final ignoring = await ReaderSystemService.isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() => _ignoringBatteryOpt = ignoring);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final coordinator = widget.coordinator;
    final hasBookContext = widget.hasBookContext;
    final rebuilding = widget.rebuilding;
    final onDraftChanged = widget.onDraftChanged;
    final onApplyAndSaveConfig = widget.onApplyAndSaveConfig;
    final onResetFailover = widget.onResetFailover;
    final onRebuildPressed = widget.onRebuildPressed;
    final onPreSynthesizePressed = widget.onPreSynthesizePressed;
    final onRetryBlocked = widget.onRetryBlocked;
    final onClearUnpinnedCache = widget.onClearUnpinnedCache;
    final onReload = widget.onReload;
    final st = widget.pipelineStatus;
    final mb = (st.cacheUsedBytes / (1024 * 1024)).toStringAsFixed(2);
    final backtrack = config.analysisPipeline.maxPrefixBacktrackChapters;
    final firstChunkTokens = config.analysisPipeline.firstChunkTargetTokens;
    final tieredThinking = config.analysisPipeline.tieredThinking;
    final playback = config.playback;

    final secondaryColor = AppTheme.textSecondaryOf(context);
    final isCompactGap =
        playback.sameSpeakerGapMs <= 60 && playback.speakerSwitchGapMs <= 160;
    final isRelaxedGap =
        playback.sameSpeakerGapMs >= 160 || playback.speakerSwitchGapMs >= 360;
    final gapPreset = isCompactGap
        ? 'compact'
        : isRelaxedGap
        ? 'relaxed'
        : 'natural';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ==================== 实时管线仪表盘 ====================
        Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppTheme.dividerOf(context)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '管线状态',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        st.phaseLabel,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '执勤模型：${coordinator.activeTextModelLabel}'
                        '${coordinator.isUsingFallbackTextModel ? '（兜底中）' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: coordinator.isUsingFallbackTextModel
                              ? Colors.orange.shade700
                              : AppTheme.textPrimaryOf(context),
                        ),
                      ),
                    ),
                    if (coordinator.isUsingFallbackTextModel)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: onResetFailover,
                        child: const Text(
                          '切回主模型',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
                if (st.retryStatusText != null &&
                    st.retryStatusText!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '重试进度：${st.retryStatusText}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        st.progressSummaryText.isNotEmpty
                            ? st.progressSummaryText
                            : '综合管线进度',
                        style: TextStyle(fontSize: 11, color: secondaryColor),
                      ),
                    ),
                    Text(
                      '${(st.progressRatio.clamp(0.0, 1.0) * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: st.progressRatio.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: AppTheme.dividerOf(context),
                    color: AppTheme.primaryColor,
                  ),
                ),
                const Divider(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _metricCell(
                        context,
                        '分析 / 确认 / 总块',
                        '${st.candidateAnalyzedChunks} / ${st.confirmedChunks} / ${st.totalPlannedChunks}',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricCell(
                        context,
                        '就绪段 / 总段数',
                        '${st.readyAudioSegments} / ${st.totalManifestSegments}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _metricCell(
                        context,
                        '可播 / 在途缓冲',
                        '${st.continuousReadySeconds.toStringAsFixed(1)}s / ${st.estimatedPendingSeconds.toStringAsFixed(1)}s',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _metricCell(
                        context,
                        '并发（文本/TTS/队列）',
                        '${st.activeTextRequests} / ${st.activeTtsRequests} / ${st.pendingTtsJobs}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _metricCell(
                  context,
                  '音频缓存占用（命中 : 未命中）',
                  '$mb MB  (${st.cacheHits} : ${st.cacheMisses})',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        // ==================== 常用编排与播放调优 ====================
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('启用分级思考加速（推荐）'),
          subtitle: Text(
            '自动档位下常规分块降档至 minimal 提速，跨块身份冲突复核保留原档位',
            style: TextStyle(fontSize: 11, color: secondaryColor),
          ),
          value: tieredThinking,
          onChanged: (v) {
            unawaited(
              onApplyAndSaveConfig(
                config.copyWith(
                  analysisPipeline: config.analysisPipeline.copyWith(
                    tieredThinking: v,
                  ),
                ),
                v ? '已开启分级思考加速' : '已关闭分级思考加速',
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Expanded(
              child: Text(
                '段间呼吸停顿节奏',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final preset in const [
                  ('compact', '紧凑', 40, 140, 280),
                  ('natural', '自然', 100, 240, 480),
                  ('relaxed', '舒缓', 180, 400, 720),
                ])
                  ChoiceChip(
                    label: Text(preset.$2, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    selected: gapPreset == preset.$1,
                    onSelected: (_) => unawaited(
                      onApplyAndSaveConfig(
                        config.copyWith(
                          playback: playback.copyWith(
                            sameSpeakerGapMs: preset.$3,
                            speakerSwitchGapMs: preset.$4,
                            chapterSwitchGapMs: preset.$5,
                          ),
                        ),
                        '已将段间停顿节奏切换为「${preset.$2}」',
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: false,
          title: const Text(
            '高级切分与停顿微调',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          subtitle: Text(
            '首块 $firstChunkTokens tok · 停顿 ${playback.sameSpeakerGapMs}/${playback.speakerSwitchGapMs}/${playback.chapterSwitchGapMs}ms',
            style: TextStyle(fontSize: 11, color: secondaryColor),
          ),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '锚点章首块微切分目标 Token',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                  ),
                ),
                Text(
                  '$firstChunkTokens tok',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.primaryColor,
                  ),
                ),
              ],
            ),
            Text(
              '起播章第 1 块采用较小切分粒度，让首句对话更早完成分析并开始合成，后续块自动恢复大块吞吐。',
              style: TextStyle(fontSize: 11, color: secondaryColor),
            ),
            Slider(
              value: firstChunkTokens.toDouble().clamp(300, 1500),
              min: 300,
              max: 1500,
              divisions: 24,
              label: '$firstChunkTokens tok',
              onChanged: (v) {
                final nextVal = (v / 50).round() * 50;
                onDraftChanged(
                  config.copyWith(
                    analysisPipeline: config.analysisPipeline.copyWith(
                      firstChunkTargetTokens: nextVal,
                    ),
                  ),
                );
              },
              onChangeEnd: (v) {
                final nextVal = (v / 50).round() * 50;
                unawaited(
                  onApplyAndSaveConfig(
                    config.copyWith(
                      analysisPipeline: config.analysisPipeline.copyWith(
                        firstChunkTargetTokens: nextVal,
                      ),
                    ),
                    '已将首块微切分目标保存为 $nextVal Token',
                  ),
                );
              },
            ),
            _buildGapSlider(
              label: '同角色连读停顿',
              valueMs: playback.sameSpeakerGapMs,
              minMs: 0,
              maxMs: 400,
              stepMs: 20,
              onChanged: (ms) => onDraftChanged(
                config.copyWith(
                  playback: playback.copyWith(sameSpeakerGapMs: ms),
                ),
              ),
              onChangeEnd: (ms) => unawaited(
                onApplyAndSaveConfig(
                  config.copyWith(
                    playback: playback.copyWith(sameSpeakerGapMs: ms),
                  ),
                  '已将同角色段间停顿调整为 ${ms}ms',
                ),
              ),
            ),
            _buildGapSlider(
              label: '切换角色停顿',
              valueMs: playback.speakerSwitchGapMs,
              minMs: 80,
              maxMs: 700,
              stepMs: 20,
              onChanged: (ms) => onDraftChanged(
                config.copyWith(
                  playback: playback.copyWith(speakerSwitchGapMs: ms),
                ),
              ),
              onChangeEnd: (ms) => unawaited(
                onApplyAndSaveConfig(
                  config.copyWith(
                    playback: playback.copyWith(speakerSwitchGapMs: ms),
                  ),
                  '已将切换角色停顿调整为 ${ms}ms',
                ),
              ),
            ),
            _buildGapSlider(
              label: '跨章节停顿',
              valueMs: playback.chapterSwitchGapMs,
              minMs: 160,
              maxMs: 1000,
              stepMs: 40,
              onChanged: (ms) => onDraftChanged(
                config.copyWith(
                  playback: playback.copyWith(chapterSwitchGapMs: ms),
                ),
              ),
              onChangeEnd: (ms) => unawaited(
                onApplyAndSaveConfig(
                  config.copyWith(
                    playback: playback.copyWith(chapterSwitchGapMs: ms),
                  ),
                  '已将跨章节停顿调整为 ${ms}ms',
                ),
              ),
            ),
          ],
        ),
        const Divider(),
        // ==================== 通勤离线预合成（后续 N 章） ====================
        if (hasBookContext && onPreSynthesizePressed != null) ...[
          AnimatedBuilder(
            animation: coordinator,
            builder: (context, _) {
              final running = coordinator.isPreSynthesizing;
              final completed = coordinator.preSynthCompletedChapters;
              final total = coordinator.preSynthTotalChapters;
              final progress = total > 0 ? (completed / total).clamp(0.0, 1.0) : null;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: AppTheme.dividerOf(context)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.offline_bolt_outlined,
                            size: 18,
                            color: AppTheme.primaryColor,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '通勤离线预合成',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          if (running)
                            TextButton(
                              onPressed: coordinator.cancelPreSynthesis,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                foregroundColor: Colors.redAccent,
                              ),
                              child: const Text('停止', style: TextStyle(fontSize: 12)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        running
                            ? coordinator.preSynthProgressText
                            : (coordinator.preSynthProgressText.isNotEmpty
                                  ? coordinator.preSynthProgressText
                                  : '在 Wi-Fi 下提前完成角色台词分析与语音合成，地铁或弱网零等待畅听。'),
                        style: TextStyle(fontSize: 11.5, color: secondaryColor),
                      ),
                      const SizedBox(height: 8),
                      if (running)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 5,
                            color: AppTheme.primaryColor,
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            for (final count in const [3, 5, 10])
                              OutlinedButton(
                                key: ValueKey('presynth-$count-btn'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                ),
                                onPressed: () =>
                                    unawaited(onPreSynthesizePressed(count)),
                                child: Text(
                                  '预合成后 $count 章',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
        // ==================== 蓝牙耳机 / 车载切歌按键自定义 ====================
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppTheme.dividerOf(context)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.bluetooth_audio_rounded,
                      size: 18,
                      color: AppTheme.primaryColor,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '蓝牙 / 车载「上/下一曲」按键行为',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '统一控制蓝牙耳机双击、车载方向盘切歌与锁屏上下曲按钮的响应动作（沉浸式与普通听书共用）。',
                  style: TextStyle(fontSize: 11.5, color: secondaryColor),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<MediaButtonBehavior>(
                  valueListenable:
                      ReaderSystemService.mediaButtonBehaviorNotifier,
                  builder: (context, currentBehavior, _) => Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final option in MediaButtonBehavior.values)
                        ChoiceChip(
                          key: ValueKey('media-btn-${option.storageValue}'),
                          label: Text(
                            option.label,
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: currentBehavior == option,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => unawaited(
                            ReaderSystemService.setMediaButtonBehavior(option),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // ==================== Android 后台防杀保活引导 ====================
        if (ReaderPlatform.isAndroid)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: AppTheme.dividerOf(context)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    _ignoringBatteryOpt == true
                        ? Icons.verified_user_outlined
                        : Icons.battery_alert_outlined,
                    size: 20,
                    color: _ignoringBatteryOpt == true
                        ? Colors.green.shade600
                        : Colors.orange.shade700,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _ignoringBatteryOpt == true
                              ? '后台听书保活已就绪'
                              : '建议开启后台听书保活',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _ignoringBatteryOpt == true
                              ? '当前已设为不受电池优化限制，锁屏长时间听书不易中断。'
                              : '国产定制系统锁屏后可能清理后台音频，建议在电池设置中设为无限制。',
                          style: TextStyle(fontSize: 11, color: secondaryColor),
                        ),
                      ],
                    ),
                  ),
                  if (_ignoringBatteryOpt != true) ...[
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () async {
                        await ReaderSystemService
                            .openBatteryOptimizationSettings();
                        await _refreshBatteryOptStatus();
                      },
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      child: const Text('去设置', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        // ==================== 空降最大回溯章数设置 ====================
        Row(
          children: [
            const Expanded(
              child: Text(
                '空降与重建最多回溯前文章数',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
            Text(
              '$backtrack 章',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryColor,
              ),
            ),
          ],
        ),
        Text(
          '从长书中间章节直接开听或重建编排时，最多往前自动回溯这么多章建立人物档案（默认 5 章），不拉取更早章节。',
          style: TextStyle(fontSize: 11, color: secondaryColor),
        ),
        Slider(
          value: backtrack.toDouble().clamp(0, 10),
          min: 0,
          max: 10,
          divisions: 10,
          label: '$backtrack 章',
          onChanged: (v) {
            final nextVal = v.round();
            onDraftChanged(
              config.copyWith(
                analysisPipeline: config.analysisPipeline.copyWith(
                  maxPrefixBacktrackChapters: nextVal,
                ),
              ),
            );
          },
          onChangeEnd: (v) {
            final nextVal = v.round();
            unawaited(
              onApplyAndSaveConfig(
                config.copyWith(
                  analysisPipeline: config.analysisPipeline.copyWith(
                    maxPrefixBacktrackChapters: nextVal,
                  ),
                ),
                '已将空降最大回溯章数保存为 $nextVal 章',
              ),
            );
          },
        ),
        if (hasBookContext) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: rebuilding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_fix_high, size: 18),
              label: Text(
                rebuilding
                    ? '正在重建编排…'
                    : '重建本书编排（从当前章节起，最多回溯 $backtrack 章）',
              ),
              onPressed: rebuilding ? null : () => onRebuildPressed(backtrack),
            ),
          ),
        ],
        if (st.blockingReason != null || st.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Card(
              color: Colors.red.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '当前诊断信息：${st.blockingReason ?? st.lastError}',
                        style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                      ),
                    ),
                    IconButton(
                      tooltip: '清除提示',
                      icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        coordinator.dismissIssue();
                        unawaited(onReload());
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试阻塞任务'),
              onPressed: onRetryBlocked,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: const Text('清理未用音频缓存'),
              onPressed: onClearUnpinnedCache,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('恢复默认预置模型'),
              onPressed: () async {
                // 保留用户已填写的文本与 TTS 密钥，不因恢复模型列表导致密钥丢失
                final existingTextKey = config.textAnalysisModels
                    .map((m) => (m.apiKey ?? '').trim())
                    .firstWhere((k) => k.isNotEmpty, orElse: () => '');
                final existingTtsKey = config.tts.providers
                    .map((p) => (p.apiKey ?? '').trim())
                    .firstWhere((k) => k.isNotEmpty, orElse: () => '');
                final preset = ImmersivePresetConfig.createConfiguredDefault(
                  textApiKey: existingTextKey,
                  ttsApiKey: existingTtsKey,
                  featureEnabled: config.featureEnabled,
                );
                await onApplyAndSaveConfig(
                  preset,
                  '已恢复 3 个文本模型（MiniMax / GLM / Qwen）与 OneAPI 13 音色预置（已保留现有密钥）',
                );
                await onReload();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _metricCell(BuildContext context, String label, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.inputFillOf(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              color: AppTheme.textSecondaryOf(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimaryOf(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGapSlider({
    required String label,
    required int valueMs,
    required int minMs,
    required int maxMs,
    required int stepMs,
    required ValueChanged<int> onChanged,
    required ValueChanged<int> onChangeEnd,
  }) {
    final clamped = valueMs.clamp(minMs, maxMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Text(
              '${clamped}ms',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryColor,
              ),
            ),
          ],
        ),
        Slider(
          value: clamped.toDouble(),
          min: minMs.toDouble(),
          max: maxMs.toDouble(),
          divisions: ((maxMs - minMs) / stepMs).round(),
          label: '${clamped}ms',
          onChanged: (v) => onChanged((v / stepMs).round() * stepMs),
          onChangeEnd: (v) => onChangeEnd((v / stepMs).round() * stepMs),
        ),
      ],
    );
  }
}
