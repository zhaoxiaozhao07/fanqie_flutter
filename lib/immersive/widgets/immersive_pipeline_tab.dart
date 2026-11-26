import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import '../services/immersive_playback_coordinator.dart';
import '../services/immersive_preset_config.dart';

/// 沉浸式设置 Tab 3：实时管线诊断、首块微切分与分级思考加速、呼吸停顿微调、重建编排与缓存维护
class ImmersivePipelineTab extends StatelessWidget {
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
    required this.onRetryBlocked,
    required this.onClearUnpinnedCache,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    final st = pipelineStatus;
    final mb = (st.cacheUsedBytes / (1024 * 1024)).toStringAsFixed(2);
    final backtrack = config.analysisPipeline.maxPrefixBacktrackChapters;
    final firstChunkTokens = config.analysisPipeline.firstChunkTargetTokens;
    final tieredThinking = config.analysisPipeline.tieredThinking;
    final playback = config.playback;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('当前状态'),
          trailing: Text(
            st.phaseLabel,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppTheme.primaryColor,
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('当前执勤文本模型'),
          subtitle: Text(
            coordinator.isUsingFallbackTextModel
                ? '主模型连续失败，已自动切至兜底模型'
                : '主模型正常运行中',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                coordinator.activeTextModelLabel,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: coordinator.isUsingFallbackTextModel
                      ? Colors.orange.shade800
                      : AppTheme.textPrimaryOf(context),
                ),
              ),
              if (coordinator.isUsingFallbackTextModel)
                TextButton(
                  onPressed: onResetFailover,
                  child: const Text('切回主模型', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('候选分析 / 身份确认 / 窗口总块'),
          trailing: Text(
            '${st.candidateAnalyzedChunks} / ${st.confirmedChunks} / ${st.totalPlannedChunks}',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('音频就绪段 / 清单总段数'),
          trailing: Text('${st.readyAudioSegments} / ${st.totalManifestSegments}'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('连续可播缓冲 / 预计在途缓冲'),
          trailing: Text(
            '${st.continuousReadySeconds.toStringAsFixed(1)}s / ${st.estimatedPendingSeconds.toStringAsFixed(1)}s',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('在途并发（文本 / TTS / 待处理 TTS）'),
          trailing: Text(
            '${st.activeTextRequests} / ${st.activeTtsRequests} / ${st.pendingTtsJobs}',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('音频缓存占用（命中:未命中）'),
          trailing: Text('$mb MB (${st.cacheHits}:${st.cacheMisses})'),
        ),
        const Divider(),
        // ==================== 首句起播加速与分级思考 ====================
        const Text(
          '首句起播加速与分级思考',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('启用分级思考加速（推荐）'),
          subtitle: const Text(
            '模型为“自动”思考档位时，常规分块降档至 minimal 提速降耗；跨块人物身份冲突复核保留原档位。',
            style: TextStyle(fontSize: 11),
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
        Row(
          children: [
            const Expanded(
              child: Text(
                '锚点章首块微切分目标 Token',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
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
        const Text(
          '起播章第 1 块采用较小切分粒度，让首句对话更早完成分析并开始合成，后续块自动恢复大块吞吐。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
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
        const Divider(),
        // ==================== 原生双缓冲段间呼吸停顿 ====================
        const Text(
          '无缝预装与段间自然呼吸停顿',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 2),
        const Text(
          '原生播放服务自动预热下一段音频消除切换卡顿，并按说话人关系插入自然换气停顿。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const SizedBox(height: 6),
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
        const Divider(),
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
        const Text(
          '从长书中间章节直接开听或重建编排时，最多往前自动回溯这么多章建立人物档案（默认 5 章），不拉取更早章节。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
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
