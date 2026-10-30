import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../services/tts_service.dart';

/// 听书控制底栏面板
class TtsPlayerPanel extends StatelessWidget {
  final VoidCallback onClose;

  const TtsPlayerPanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final ttsService = TtsService();

    return AnimatedBuilder(
      animation: ttsService,
      builder: (context, _) {
        if (!ttsService.isActive) {
          return const SizedBox.shrink();
        }

        final currentText = ttsService.currentText;
        final isPlaying = ttsService.isPlaying;
        final isBuffering = ttsService.state == TtsPlayState.buffering;
        final curIdx = ttsService.currentIndex;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部状态与当前朗读段落摘要
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryLight,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        ttsService.engineType == TtsEngineType.openAi ? 'AI 语音' : '系统原生',
                        style: const TextStyle(fontSize: 10, color: AppTheme.primaryColor, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentText.isNotEmpty ? currentText : '准备播放中...',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        ttsService.stop();
                        onClose();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // 控制按键
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 定时按钮
                    IconButton(
                      icon: Badge(
                        isLabelVisible: ttsService.timerRemainingMinutes > 0 || ttsService.stopAfterCurrentChapter,
                        label: Text(
                          ttsService.stopAfterCurrentChapter
                              ? '本章止'
                              : '${ttsService.timerRemainingMinutes}m',
                          style: const TextStyle(fontSize: 8),
                        ),
                        child: Icon(
                          Icons.timer_outlined,
                          size: 22,
                          color: ttsService.stopAfterCurrentChapter || ttsService.timerRemainingMinutes > 0
                              ? AppTheme.primaryColor
                              : AppTheme.textSecondary,
                        ),
                      ),
                      tooltip: '定时停止',
                      onPressed: () => _showSleepTimerDialog(context, ttsService),
                    ),
                    // 上一句
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded, size: 28, color: AppTheme.textPrimary),
                      tooltip: '上一句',
                      onPressed: curIdx > 0 ? () => ttsService.previousChunk() : null,
                    ),
                    // 播放 / 暂停 / 缓冲
                    FloatingActionButton.small(
                      backgroundColor: AppTheme.primaryColor,
                      elevation: 2,
                      onPressed: () {
                        if (isPlaying) {
                          ttsService.pause();
                        } else if (ttsService.isPaused) {
                          ttsService.resume();
                        }
                      },
                      child: isBuffering
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 26),
                    ),
                    // 下一句
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded, size: 28, color: AppTheme.textPrimary),
                      tooltip: '下一句',
                      onPressed: curIdx < ttsService.chunks.length - 1 ? () => ttsService.nextChunk() : null,
                    ),
                    // 发音设置
                    IconButton(
                      icon: const Icon(Icons.tune_rounded, size: 22, color: AppTheme.textSecondary),
                      tooltip: '发音与引擎设置',
                      onPressed: () => _showTtsSettingsModal(context, ttsService),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSleepTimerDialog(BuildContext context, TtsService tts) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('睡眠定时停止'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              tts.setSleepTimer(0);
              tts.setStopAfterCurrentChapter(false);
              Navigator.pop(ctx);
            },
            child: const Text('不开启定时'),
          ),
          SimpleDialogOption(
            onPressed: () {
              tts.setSleepTimer(0);
              tts.setStopAfterCurrentChapter(true);
              Navigator.pop(ctx);
            },
            child: Row(
              children: [
                const Text('读完本章后停止'),
                if (tts.stopAfterCurrentChapter) ...[
                  const Spacer(),
                  const Icon(Icons.check, size: 18, color: AppTheme.primaryColor),
                ],
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () {
              tts.setStopAfterCurrentChapter(false);
              tts.setSleepTimer(15);
              Navigator.pop(ctx);
            },
            child: const Text('15 分钟后停止'),
          ),
          SimpleDialogOption(
            onPressed: () {
              tts.setStopAfterCurrentChapter(false);
              tts.setSleepTimer(30);
              Navigator.pop(ctx);
            },
            child: const Text('30 分钟后停止'),
          ),
          SimpleDialogOption(
            onPressed: () {
              tts.setStopAfterCurrentChapter(false);
              tts.setSleepTimer(60);
              Navigator.pop(ctx);
            },
            child: const Text('60 分钟后停止'),
          ),
        ],
      ),
    );
  }

  void _showTtsSettingsModal(BuildContext context, TtsService tts) {
    final urlCtrl = TextEditingController(text: tts.openAiBaseUrl);
    final keyCtrl = TextEditingController(text: tts.openAiApiKey);
    final modelCtrl = TextEditingController(text: tts.openAiModel);
    final voiceCtrl = TextEditingController(text: tts.openAiVoice);
    var selectedEngine = tts.engineType;
    var speechRate = tts.speechRate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'TTS 听书发音设置',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 16),
                    // 引擎选择
                    SegmentedButton<TtsEngineType>(
                      segments: const [
                        ButtonSegment(value: TtsEngineType.native, label: Text('系统原生 TTS')),
                        ButtonSegment(value: TtsEngineType.openAi, label: Text('OpenAI 兼容 TTS')),
                      ],
                      selected: {selectedEngine},
                      onSelectionChanged: (val) {
                        setModalState(() => selectedEngine = val.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    // 语速调节
                    Row(
                      children: [
                        const Text('朗读语速', style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
                        const Spacer(),
                        Text('${speechRate.toStringAsFixed(1)}x', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: speechRate,
                      min: 0.5,
                      max: 2.0,
                      divisions: 6,
                      label: '${speechRate.toStringAsFixed(1)}x',
                      onChanged: (v) {
                        setModalState(() => speechRate = v);
                      },
                    ),
                    if (selectedEngine == TtsEngineType.openAi) ...[
                      const Divider(height: 24),
                      const Text('OpenAI 兼容接口配置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'API Base URL',
                          hintText: 'https://api.openai.com',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: keyCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'API Key (密钥)',
                          hintText: 'sk-...',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: modelCtrl,
                              decoration: const InputDecoration(
                                labelText: '模型 (Model)',
                                hintText: 'tts-1',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: voiceCtrl,
                              decoration: const InputDecoration(
                                labelText: '音色 (可自定义输入)',
                                hintText: '如 alloy, nova',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('常用预设音色：', style: TextStyle(fontSize: 11, color: AppTheme.textHint)),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final v in ['alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer']) ...[
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: ActionChip(
                                        label: Text(v, style: const TextStyle(fontSize: 11)),
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () {
                                          setModalState(() {
                                            voiceCtrl.text = v;
                                          });
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '注：支持自由输入任意模型音色名称（如 alloy、nova、zh-CN-XiaoxiaoNeural 等）。系统已内置双缓冲预加载管道，后台自动提前拉取后续切片，杜绝切句等待。',
                        style: TextStyle(fontSize: 11, color: AppTheme.textHint),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          tts.saveSettings(
                            engineType: selectedEngine,
                            openAiBaseUrl: urlCtrl.text,
                            openAiApiKey: keyCtrl.text,
                            openAiModel: modelCtrl.text,
                            openAiVoice: voiceCtrl.text,
                            speechRate: speechRate,
                          );
                          Navigator.pop(ctx);
                        },
                        child: const Text('保存配置'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
