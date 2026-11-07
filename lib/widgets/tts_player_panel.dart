import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../services/tts_service.dart';
import '../services/reader_platform.dart';
import 'reader_modal.dart';
import 'dart:async';

/// 听书控制底栏面板
class TtsPlayerPanel extends StatelessWidget {
  static const desktopHeight = 128.0;
  static void showSettings(
    BuildContext context, {
    Color backgroundColor = Colors.white,
    Color textColor = AppTheme.textPrimary,
    Color secondaryColor = AppTheme.textSecondary,
    ValueChanged<bool>? onModalChanged,
  }) {
    TtsPlayerPanel(
      onClose: () {},
      backgroundColor: backgroundColor,
      textColor: textColor,
      secondaryColor: secondaryColor,
      onModalChanged: onModalChanged,
    )._showTtsSettingsModal(context, TtsService());
  }

  final VoidCallback onClose;

  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final ValueChanged<bool>? onModalChanged;
  final TtsService? service;

  const TtsPlayerPanel({
    super.key,
    required this.onClose,
    this.backgroundColor = Colors.white,
    this.textColor = AppTheme.textPrimary,
    this.secondaryColor = AppTheme.textSecondary,
    this.onModalChanged,
    this.service,
  });

  @override
  Widget build(BuildContext context) {
    if (!ReaderPlatform.capabilities.tts) return const SizedBox.shrink();
    final ttsService = service ?? TtsService();

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
        if (ReaderPlatform.isMacOS) return _desktop(context, ttsService);

        return Container(
          decoration: BoxDecoration(
            color: backgroundColor,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryLight,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        (ttsService.actualEngine ?? ttsService.engineType) ==
                                TtsEngineType.openAi
                            ? 'AI 语音'
                            : '系统原生',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentText.isNotEmpty ? currentText : '准备播放中...',
                        style: TextStyle(
                          fontSize: 12,
                          color: textColor,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(Icons.close, size: 18, color: secondaryColor),
                      tooltip: '停止听书',
                      onPressed: () {
                        ttsService.stop().catchError((_) {});
                        onClose();
                      },
                    ),
                  ],
                ),
                if (ttsService.errorMessage != null ||
                    ttsService.notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      ttsService.errorMessage ?? ttsService.notice!,
                      style: TextStyle(color: textColor, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 6),
                // 控制按键
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // 定时按钮
                    IconButton(
                      icon: Badge(
                        isLabelVisible:
                            ttsService.timerRemainingMinutes > 0 ||
                            ttsService.stopAfterCurrentChapter,
                        label: Text(
                          ttsService.stopAfterCurrentChapter
                              ? '本章止'
                              : '${ttsService.timerRemainingMinutes}m',
                          style: TextStyle(fontSize: 8),
                        ),
                        child: Icon(
                          Icons.timer_outlined,
                          size: 22,
                          color:
                              ttsService.stopAfterCurrentChapter ||
                                  ttsService.timerRemainingMinutes > 0
                              ? AppTheme.primaryColor
                              : secondaryColor,
                        ),
                      ),
                      tooltip: '定时停止',
                      onPressed: () =>
                          _showSleepTimerDialog(context, ttsService),
                    ),
                    // 上一句
                    IconButton(
                      icon: Icon(
                        Icons.skip_previous_rounded,
                        size: 28,
                        color: textColor,
                      ),
                      tooltip: '上一句',
                      onPressed: curIdx > 0
                          ? () => ttsService.previousChunk()
                          : null,
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
                    // 下一句
                    IconButton(
                      icon: Icon(
                        Icons.skip_next_rounded,
                        size: 28,
                        color: textColor,
                      ),
                      tooltip: '下一句',
                      onPressed: curIdx < ttsService.chunks.length - 1
                          ? () => ttsService.nextChunk()
                          : null,
                    ),
                    // 发音设置
                    IconButton(
                      icon: Icon(
                        Icons.tune_rounded,
                        size: 22,
                        color: secondaryColor,
                      ),
                      tooltip: '发音与引擎设置',
                      onPressed: () =>
                          _showTtsSettingsModal(context, ttsService),
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

  Widget _desktop(BuildContext context, TtsService tts) {
    final message = tts.errorMessage ?? tts.notice;
    final engine = (tts.actualEngine ?? tts.engineType) == TtsEngineType.openAi
        ? 'AI 合成语音'
        : '系统语音';
    Widget button(IconData icon, String tooltip, VoidCallback? action) =>
        IconButton(
          tooltip: tooltip,
          onPressed: action,
          icon: Icon(icon, color: textColor),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: const EdgeInsets.all(6),
        );
    return Material(
      key: const ValueKey('desktop-tts-player'),
      color: backgroundColor,
      elevation: 8,
      child: SizedBox(
        height: desktopHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            children: [
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$engine · ${tts.currentBookTitle} · ${tts.currentChapterTitle}',
                        style: TextStyle(color: textColor, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    button(
                      Icons.timer_outlined,
                      tts.stopAfterCurrentChapter
                          ? '本章停止'
                          : tts.timerRemainingMinutes > 0
                          ? '${tts.timerRemainingMinutes} 分钟后停止'
                          : '定时停止',
                      () => _showSleepTimerDialog(context, tts),
                    ),
                    button(
                      Icons.tune,
                      '发音与接口设置',
                      () => _showTtsSettingsModal(context, tts),
                    ),
                    button(Icons.close, '停止听书', () {
                      unawaited(tts.stop());
                      onClose();
                    }),
                  ],
                ),
              ),
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    button(
                      Icons.skip_previous,
                      '上一句',
                      tts.currentIndex > 0
                          ? () => unawaited(tts.previousChunk())
                          : null,
                    ),
                    tts.state == TtsPlayState.buffering
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : button(
                            tts.isPlaying ? Icons.pause : Icons.play_arrow,
                            tts.isPlaying ? '暂停听书' : '继续听书',
                            () => unawaited(
                              tts.isPlaying ? tts.pause() : tts.resume(),
                            ),
                          ),
                    button(
                      Icons.skip_next,
                      '下一句',
                      tts.currentIndex < tts.chunks.length - 1
                          ? () => unawaited(tts.nextChunk())
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        tts.currentText.isEmpty ? '正在准备正文…' : tts.currentText,
                        style: TextStyle(color: secondaryColor, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${tts.currentIndex + 1}/${tts.chunks.length}',
                      style: TextStyle(color: secondaryColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              LinearProgressIndicator(value: tts.progress, minHeight: 2),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: message ?? '当前段落进度；网络语音由所配置的服务合成',
                    child: Text(
                      message ?? '网络语音会发送当前及后续两段原文；系统语音暂停后重播本段。',
                      style: TextStyle(
                        color: message == null ? secondaryColor : textColor,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _themed(BuildContext context, Widget child) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppTheme.primaryColor,
      brightness: backgroundColor.computeLuminance() < 0.25
          ? Brightness.dark
          : Brightness.light,
      surface: backgroundColor,
      onSurface: textColor,
    );
    return Theme(
      data: ThemeData(
        colorScheme: scheme,
        textTheme: Theme.of(
          context,
        ).textTheme.apply(bodyColor: textColor, displayColor: textColor),
      ),
      child: child,
    );
  }

  void _showSleepTimerDialog(BuildContext context, TtsService tts) {
    onModalChanged?.call(true);
    showDialog(
      context: context,
      builder: (ctx) => _themed(
        ctx,
        SimpleDialog(
          title: Text('睡眠定时停止'),
          children: [
            SimpleDialogOption(
              onPressed: () {
                tts.setSleepTimer(0);
                tts.setStopAfterCurrentChapter(false);
                Navigator.pop(ctx);
              },
              child: Text('不开启定时'),
            ),
            SimpleDialogOption(
              onPressed: () {
                tts.setSleepTimer(0);
                tts.setStopAfterCurrentChapter(true);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  Text('读完本章后停止'),
                  if (tts.stopAfterCurrentChapter) ...[
                    const Spacer(),
                    Icon(Icons.check, size: 18, color: AppTheme.primaryColor),
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
              child: Text('15 分钟后停止'),
            ),
            SimpleDialogOption(
              onPressed: () {
                tts.setStopAfterCurrentChapter(false);
                tts.setSleepTimer(30);
                Navigator.pop(ctx);
              },
              child: Text('30 分钟后停止'),
            ),
            SimpleDialogOption(
              onPressed: () {
                tts.setStopAfterCurrentChapter(false);
                tts.setSleepTimer(60);
                Navigator.pop(ctx);
              },
              child: Text('60 分钟后停止'),
            ),
          ],
        ),
      ),
    ).whenComplete(() => onModalChanged?.call(false));
  }

  void _showTtsSettingsModal(BuildContext context, TtsService tts) {
    final urlCtrl = TextEditingController(text: tts.openAiBaseUrl);
    final keyCtrl = TextEditingController(text: tts.openAiApiKey);
    final modelCtrl = TextEditingController(text: tts.openAiModel);
    final voiceCtrl = TextEditingController(text: tts.openAiVoice);
    var selectedEngine = tts.engineType;
    var speechRate = tts.speechRate;
    var nativeVoice = tts.nativeVoice;
    var nativeVoices = <Map<String, dynamic>>[];
    StateSetter? updateModal;
    BuildContext? modalContext;
    bool saving = false;
    bool closed = false;
    if (!tts.nativeSpeechAvailable && selectedEngine == TtsEngineType.native) {
      selectedEngine = TtsEngineType.openAi;
    }
    unawaited(
      tts.nativeVoices().then((voices) {
        if (closed || modalContext?.mounted == false) return;
        nativeVoices = voices;
        if (nativeVoice.isNotEmpty &&
            !voices.any((voice) => voice['id'] == nativeVoice)) {
          nativeVoice = '';
        }
        updateModal?.call(() {});
      }),
    );

    onModalChanged?.call(true);
    showReaderModal<void>(
      context: context,
      backgroundColor: backgroundColor,
      builder: (ctx) {
        return ReaderModalLifetime(
          onDispose: () {
            closed = true;
            urlCtrl.dispose();
            keyCtrl.dispose();
            modelCtrl.dispose();
            voiceCtrl.dispose();
          },
          child: _themed(
            ctx,
            StatefulBuilder(
              builder: (context, setModalState) {
                modalContext = context;
                updateModal = setModalState;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    MediaQuery.of(context).viewInsets.bottom + 20,
                  ),
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
                        Text(
                          'TTS 听书发音设置',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 引擎选择
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('系统原生 TTS'),
                              selected: selectedEngine == TtsEngineType.native,
                              onSelected: saving || !tts.nativeSpeechAvailable
                                  ? null
                                  : (_) => setModalState(
                                      () =>
                                          selectedEngine = TtsEngineType.native,
                                    ),
                            ),
                            ChoiceChip(
                              label: const Text('OpenAI 兼容 TTS'),
                              selected: selectedEngine == TtsEngineType.openAi,
                              onSelected: saving
                                  ? null
                                  : (_) => setModalState(
                                      () =>
                                          selectedEngine = TtsEngineType.openAi,
                                    ),
                            ),
                          ],
                        ),
                        if (!tts.nativeSpeechAvailable)
                          const Text('未检测到可用系统声音；请使用兼容接口或在系统设置中下载声音。'),
                        if (ReaderPlatform.isMacOS &&
                            selectedEngine == TtsEngineType.native)
                          DropdownButton<String>(
                            isExpanded: true,
                            value:
                                nativeVoices.any(
                                  (voice) => voice['id'] == nativeVoice,
                                )
                                ? nativeVoice
                                : '',
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('默认中文系统声音'),
                              ),
                              for (final voice in nativeVoices)
                                DropdownMenuItem(
                                  value: voice['id'] as String,
                                  child: Text(
                                    '${voice['name']} · ${voice['language']}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: saving
                                ? null
                                : (voice) => setModalState(
                                    () => nativeVoice = voice ?? '',
                                  ),
                          ),
                        const SizedBox(height: 16),
                        // 语速调节
                        Row(
                          children: [
                            Text(
                              '朗读语速',
                              style: TextStyle(
                                fontSize: 14,
                                color: secondaryColor,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${speechRate.toStringAsFixed(1)}x',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
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
                          Text(
                            'OpenAI 兼容接口配置',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
                            autocorrect: false,
                            enableSuggestions: false,
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
                              Text(
                                '常用预设音色：',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textHint,
                                ),
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      for (final v in [
                                        'alloy',
                                        'echo',
                                        'fable',
                                        'onyx',
                                        'nova',
                                        'shimmer',
                                      ]) ...[
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: ActionChip(
                                            label: Text(
                                              v,
                                              style: TextStyle(fontSize: 11),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 4,
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
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
                          Text(
                            '沿用安卓端 POST /v1/audio/speech 协议：模型、音色可自定义。网络语音会发送当前及后续两段原文；密钥只保存在设备安全存储，不进入阅读备份。服务决定支持哪些模型和音色。系统语音暂停后重播本段，手动翻页或滚动会停止听书。',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textHint,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: saving
                                ? null
                                : () async {
                                    setModalState(() => saving = true);
                                    try {
                                      await tts.saveSettings(
                                        engineType: selectedEngine,
                                        openAiBaseUrl:
                                            selectedEngine ==
                                                TtsEngineType.openAi
                                            ? urlCtrl.text
                                            : null,
                                        openAiApiKey:
                                            selectedEngine ==
                                                TtsEngineType.openAi
                                            ? keyCtrl.text
                                            : null,
                                        openAiModel: modelCtrl.text,
                                        openAiVoice: voiceCtrl.text,
                                        speechRate: speechRate,
                                        nativeVoice: nativeVoice,
                                      );
                                      if (ctx.mounted) Navigator.pop(ctx);
                                    } catch (error) {
                                      if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                          SnackBar(
                                            content: Text('保存失败：$error'),
                                          ),
                                        );
                                      }
                                    } finally {
                                      if (ctx.mounted) {
                                        setModalState(() => saving = false);
                                      }
                                    }
                                  },
                            child: Text('保存配置'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    ).whenComplete(() {
      closed = true;
      onModalChanged?.call(false);
    });
  }
}
