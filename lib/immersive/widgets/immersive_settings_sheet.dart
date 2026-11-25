import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../models/reading_position.dart';
import '../../services/reader_platform.dart';
import '../../widgets/reader_modal.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import '../services/immersive_playback_coordinator.dart';
import '../services/immersive_preset_config.dart';
import 'immersive_pipeline_tab.dart';
import 'immersive_settings_dialogs.dart';

/// 沉浸式听书全可视化应用内设置弹窗：
/// Tab 1: 多文本分析模型（增删改、独立并发、思考程度、主备自动切换、逐个测试 JSON 能力）
///        + TTS 供应商 / 模型 / 音色（增删改、启用开关、逐个本地/在线试听、停用自动同性兜底）
/// Tab 2: 本书独立配音方案（固定旁白 + 人物候选池）
/// Tab 3: 实时管线状态、空降回溯章数（默认 5 章）、重建本书编排与缓存管理
class ImmersiveSettingsSheet extends StatefulWidget {
  final String? bookId;
  final Book? book;
  final List<Chapter>? chapters;
  final int? currentChapterIndex;
  final ReadingPosition? currentPosition;
  final Future<String?> Function(Chapter)? contentLoader;
  final bool offlineOnly;
  final ImmersivePlaybackCoordinator? coordinator;

  const ImmersiveSettingsSheet({
    super.key,
    this.bookId,
    this.book,
    this.chapters,
    this.currentChapterIndex,
    this.currentPosition,
    this.contentLoader,
    this.offlineOnly = false,
    this.coordinator,
  });

  static Future<void> show(
    BuildContext context, {
    String? bookId,
    Book? book,
    List<Chapter>? chapters,
    int? currentChapterIndex,
    ReadingPosition? currentPosition,
    Future<String?> Function(Chapter)? contentLoader,
    bool offlineOnly = false,
    ImmersivePlaybackCoordinator? coordinator,
  }) {
    final sheet = ImmersiveSettingsSheet(
      bookId: bookId ?? book?.bookId,
      book: book,
      chapters: chapters,
      currentChapterIndex: currentChapterIndex,
      currentPosition: currentPosition,
      contentLoader: contentLoader,
      offlineOnly: offlineOnly,
      coordinator: coordinator,
    );
    if (ReaderPlatform.isDesktop) {
      return showReaderModal<void>(
        context: context,
        backgroundColor: Colors.white,
        heightFactor: 0.88,
        desktopWidth: 760,
        builder: (_) => sheet,
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: sheet,
      ),
    );
  }

  @override
  State<ImmersiveSettingsSheet> createState() => _ImmersiveSettingsSheetState();
}

class _ImmersiveSettingsSheetState extends State<ImmersiveSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  ImmersivePlaybackCoordinator get _coord =>
      widget.coordinator ?? ImmersivePlaybackCoordinator();

  ImmersiveConfig? _draftConfig;
  BookAudioConfig? _bookConfig;
  PipelineStatus _pipelineStatus = const PipelineStatus();
  String? _statusMessage;
  bool _statusIsError = false;
  String? _testingTextModelId;
  final Map<String, ({bool ok, String message})> _textTestResults = {};
  String? _testingVoiceId;
  bool _rebuilding = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (!_coord.isInitialized) {
      await _coord.loadAndValidateConfig();
    }
    final cfg = _coord.config ?? ImmersivePresetConfig.createConfiguredDefault();
    final effectiveBookId = widget.bookId ?? _coord.currentBookId;
    BookAudioConfig? bookCfg;
    if (effectiveBookId != null && _coord.stateStore != null) {
      bookCfg = await _coord.stateStore!.getBookAudioConfig(effectiveBookId);
      bookCfg ??= BookAudioConfig(
        bookId: effectiveBookId,
        selectedVoiceProfileIds: List.of(cfg.bookDefaults.selectedVoiceProfileIds),
        narratorVoiceProfileId: cfg.bookDefaults.narratorVoiceProfileId,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final st = await _coord.getPipelineStatus();
    if (!mounted) return;
    setState(() {
      _draftConfig = cfg;
      _bookConfig = bookCfg;
      _pipelineStatus = st;
    });
  }

  /// 校验并立即持久化保存配置，不依赖手工编辑外部文件
  Future<bool> _applyAndSaveConfig(
    ImmersiveConfig updated, {
    required String successMessage,
  }) async {
    final res = await _coord.saveConfig(updated);
    if (!mounted) return false;
    if (res.issues.isEmpty && res.config != null) {
      setState(() {
        _draftConfig = res.config;
        _statusMessage = successMessage;
        _statusIsError = false;
      });
      return true;
    }
    setState(() {
      _statusMessage = '配置校验失败：${res.issues.first}';
      _statusIsError = true;
    });
    return false;
  }

  Future<void> _testSingleTextModel(TextAnalysisConfig model) async {
    setState(() {
      _testingTextModelId = model.effectiveId;
      _statusMessage = '正在测试 ${model.modelId} 的 JSON 结构化返回能力…';
      _statusIsError = false;
    });
    final result = await _coord.testAnalysisProvider(override: model);
    if (!mounted) return;
    setState(() {
      _testingTextModelId = null;
      _textTestResults[model.effectiveId] = (
        ok: result.success,
        message: result.message,
      );
      _statusMessage = result.success
          ? '测试通过：${result.message}'
          : '测试失败：${result.message}';
      _statusIsError = !result.success;
    });
  }

  Future<void> _testVoiceOnline(String voiceProfileId) async {
    setState(() {
      _testingVoiceId = voiceProfileId;
      _statusMessage = '正在在线合成试听音色 $voiceProfileId…';
      _statusIsError = false;
    });
    final result = await _coord.testVoiceProfile(
      voiceProfileId,
      playResult: true,
    );
    if (!mounted) return;
    setState(() {
      _testingVoiceId = null;
      _statusMessage = result.success ? result.message : '音色试听失败：${result.message}';
      _statusIsError = !result.success;
    });
  }

  String _thinkingLabel(String level) {
    switch (level) {
      case TextThinkingLevel.auto:
        return '自动 (auto)';
      case TextThinkingLevel.off:
        return '尽量关闭';
      case TextThinkingLevel.minimal:
        return '最低 (minimal)';
      case TextThinkingLevel.low:
        return '低 (low)';
      case TextThinkingLevel.medium:
        return '中 (medium)';
      case TextThinkingLevel.high:
        return '高 (high)';
      default:
        return level;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _draftConfig;
    if (cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.record_voice_over, color: AppTheme.primaryColor),
              const SizedBox(width: 8),
              const Text(
                '沉浸式多角色听书设置',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        if (_statusMessage != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: (_statusIsError ? Colors.red : AppTheme.primaryColor)
                  .withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _statusMessage!,
              style: TextStyle(
                fontSize: 12,
                color: _statusIsError ? Colors.red.shade800 : Colors.black87,
              ),
            ),
          ),
        TabBar(
          controller: _tabs,
          labelColor: AppTheme.primaryColor,
          tabs: const [
            Tab(text: '模型与音色'),
            Tab(text: '本书配音'),
            Tab(text: '管线与重建'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _buildProvidersTab(cfg),
              _buildBookVoiceTab(cfg),
              _buildPipelineTab(cfg),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProvidersTab(ImmersiveConfig cfg) {
    final primaryId = cfg.primaryTextModel.effectiveId;
    final fallbackId = cfg.fallbackTextModel?.effectiveId;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用沉浸式多角色听书'),
          subtitle: const Text('所有模型与音色均在应用内管理并加密保存，关闭时原有普通听书照常运行'),
          value: cfg.featureEnabled,
          onChanged: (v) {
            unawaited(
              _applyAndSaveConfig(
                cfg.copyWith(featureEnabled: v),
                successMessage: v ? '已启用沉浸式多角色听书' : '已关闭沉浸式多角色听书',
              ),
            );
          },
        ),
        const Divider(),
        // ==================== 1. 多文本提取模型管理 ====================
        Row(
          children: [
            const Expanded(
              child: Text(
                '1. 文本提取模型（主备自动切换 · 独立并发）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增模型'),
              onPressed: () => _showTextModelEditorDialog(cfg),
            ),
          ],
        ),
        Text(
          '支持同时配置多个 OpenAI 兼容模型并选择性启用；设 1 个主模型与 1 个兜底模型，'
          '主模型连续失败 ${cfg.textFailoverThreshold} 次自动切换至兜底模型。',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        for (final tm in cfg.textAnalysisModels)
          _buildTextModelCard(
            cfg,
            tm,
            isPrimary: tm.effectiveId == primaryId,
            isFallback: tm.effectiveId == fallbackId,
          ),
        const Divider(height: 28),
        // ==================== 2. TTS 供应商 / 模型 / 音色管理 ====================
        Row(
          children: [
            const Expanded(
              child: Text(
                '2. TTS 供应商 / 模型 / 音色（停用自动同性兜底）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add_business_outlined, size: 16),
              label: const Text('新增供应商'),
              onPressed: () => _showTtsProviderEditorDialog(cfg),
            ),
          ],
        ),
        const Text(
          '可选择性启用模型与音色并逐个试听；若已编排数据使用的 TTS 模型被禁用、删除或失效，'
          '系统自动按男对男、女对女寻找可用音色兜底。',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        for (final provider in cfg.tts.providers)
          _buildTtsProviderCard(cfg, provider),
      ],
    );
  }

  Widget _buildTextModelCard(
    ImmersiveConfig cfg,
    TextAnalysisConfig tm, {
    required bool isPrimary,
    required bool isFallback,
  }) {
    final testRes = _textTestResults[tm.effectiveId];
    final isTesting = _testingTextModelId == tm.effectiveId;
    final canDelete = cfg.textAnalysisModels.length > 1;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isPrimary
              ? AppTheme.primaryColor.withValues(alpha: 0.6)
              : isFallback
              ? Colors.orange.withValues(alpha: 0.6)
              : Colors.grey.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        tm.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: tm.enabled ? Colors.black87 : Colors.black38,
                        ),
                      ),
                      if (isPrimary)
                        _badge('主模型', AppTheme.primaryColor)
                      else if (isFallback)
                        _badge('兜底模型', Colors.orange.shade800)
                      else
                        _badge(tm.enabled ? '备选' : '已停用', Colors.grey),
                      if (isInsecureRemoteHttpUrl(tm.baseUrl))
                        _badge('明文 HTTP', Colors.deepOrange),
                      if ((tm.apiKey ?? '').trim().isEmpty &&
                          (tm.apiKeyEnv ?? '').trim().isEmpty)
                        _badge('未填密钥', Colors.red.shade700),
                    ],
                  ),
                ),
                Switch(
                  value: tm.enabled,
                  onChanged: (v) async {
                    final nextModels = cfg.textAnalysisModels
                        .map(
                          (m) => m.effectiveId == tm.effectiveId
                              ? m.copyWith(enabled: v)
                              : m,
                        )
                        .toList();
                    var nextPrimary = cfg.primaryTextModelId;
                    var nextFallback = cfg.fallbackTextModelId;
                    if (!v && nextPrimary == tm.effectiveId) {
                      final other = nextModels.where((m) => m.enabled);
                      if (other.isNotEmpty) {
                        nextPrimary = other.first.effectiveId;
                      }
                    }
                    if (!v && nextFallback == tm.effectiveId) {
                      nextFallback = null;
                    }
                    await _applyAndSaveConfig(
                      cfg.copyWith(
                        textAnalysisModels: nextModels,
                        primaryTextModelId: nextPrimary,
                        fallbackTextModelId: nextFallback,
                      ),
                      successMessage: v
                          ? '已启用文本模型 ${tm.modelId}'
                          : '已停用文本模型 ${tm.modelId}',
                    );
                  },
                ),
              ],
            ),
            Text(
              '模型 ID: ${tm.modelId} · 并发: ${tm.maxConcurrency} · 思考: ${_thinkingLabel(tm.thinkingLevel)}',
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
            Text(
              '接口: ${tm.baseUrl}${tm.endpoint}',
              style: const TextStyle(fontSize: 10, color: Colors.black54),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (testRes != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  testRes.message,
                  style: TextStyle(
                    fontSize: 11,
                    color: testRes.ok
                        ? Colors.green.shade800
                        : Colors.red.shade700,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: isTesting
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt, size: 15),
                  label: const Text('测试 JSON', style: TextStyle(fontSize: 11)),
                  onPressed: _testingTextModelId != null
                      ? null
                      : () => _testSingleTextModel(tm),
                ),
                if (!isPrimary && tm.enabled)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: () async {
                      final nextFallback =
                          cfg.fallbackTextModelId == tm.effectiveId
                          ? cfg.primaryTextModelId
                          : cfg.fallbackTextModelId;
                      await _applyAndSaveConfig(
                        cfg.copyWith(
                          primaryTextModelId: tm.effectiveId,
                          fallbackTextModelId: nextFallback,
                        ),
                        successMessage: '已将 ${tm.modelId} 设为主文本提取模型',
                      );
                    },
                    child: const Text('设为主模型', style: TextStyle(fontSize: 11)),
                  ),
                if (!isPrimary && !isFallback && tm.enabled)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: () async {
                      await _applyAndSaveConfig(
                        cfg.copyWith(fallbackTextModelId: tm.effectiveId),
                        successMessage: '已将 ${tm.modelId} 设为兜底模型',
                      );
                    },
                    child: const Text('设为兜底', style: TextStyle(fontSize: 11)),
                  ),
                if (isFallback)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      await _applyAndSaveConfig(
                        cfg.copyWith(fallbackTextModelId: null),
                        successMessage: '已取消兜底模型设置',
                      );
                    },
                    child: const Text('取消兜底', style: TextStyle(fontSize: 11)),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('编辑', style: TextStyle(fontSize: 11)),
                  onPressed: () => _showTextModelEditorDialog(cfg, editing: tm),
                ),
                if (canDelete)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: Colors.redAccent,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: const Text('删除', style: TextStyle(fontSize: 11)),
                    onPressed: () async {
                      final nextModels = cfg.textAnalysisModels
                          .where((m) => m.effectiveId != tm.effectiveId)
                          .toList();
                      final nextPrimary =
                          cfg.primaryTextModelId == tm.effectiveId
                          ? (nextModels
                                    .where((m) => m.enabled)
                                    .firstOrNull
                                    ?.effectiveId ??
                                nextModels.first.effectiveId)
                          : cfg.primaryTextModelId;
                      final nextFallback =
                          cfg.fallbackTextModelId == tm.effectiveId
                          ? null
                          : cfg.fallbackTextModelId;
                      await _applyAndSaveConfig(
                        cfg.copyWith(
                          textAnalysisModels: nextModels,
                          primaryTextModelId: nextPrimary,
                          fallbackTextModelId: nextFallback,
                        ),
                        successMessage: '已删除文本模型 ${tm.modelId}',
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTtsProviderCard(
    ImmersiveConfig cfg,
    TtsProviderConfig provider,
  ) {
    final enabledModelCount = provider.models.where((m) => m.enabled).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${provider.displayName} (${provider.providerId})',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: provider.enabled ? Colors.black87 : Colors.black38,
                    ),
                  ),
                  if (isInsecureRemoteHttpUrl(provider.baseUrl))
                    _badge('明文 HTTP', Colors.deepOrange),
                  if ((provider.apiKey ?? '').trim().isEmpty &&
                      (provider.apiKeyEnv ?? '').trim().isEmpty)
                    _badge('未填密钥', Colors.red.shade700),
                ],
              ),
            ),
            Switch(
              value: provider.enabled,
              onChanged: (v) async {
                final nextProviders = cfg.tts.providers
                    .map(
                      (p) => p.providerId == provider.providerId
                          ? p.copyWith(enabled: v)
                          : p,
                    )
                    .toList();
                await _applyAndSaveConfig(
                  cfg.copyWith(tts: cfg.tts.copyWith(providers: nextProviders)),
                  successMessage: v
                      ? '已启用 TTS 供应商 ${provider.displayName}'
                      : '已停用 TTS 供应商 ${provider.displayName}（已编排数据将自动按同性别兜底）',
                );
              },
            ),
          ],
        ),
        subtitle: Text(
          '${provider.baseUrl}${provider.endpoint} · 并发 ${provider.maxConcurrency} · 启用 $enabledModelCount/${provider.models.length} 模型',
          style: const TextStyle(fontSize: 11),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('新增模型与音色', style: TextStyle(fontSize: 12)),
                  onPressed: () =>
                      _showTtsModelEditorDialog(cfg, provider: provider),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('编辑供应商', style: TextStyle(fontSize: 12)),
                  onPressed: () =>
                      _showTtsProviderEditorDialog(cfg, editing: provider),
                ),
                if (cfg.tts.providers.length > 1)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('删除供应商', style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      final nextProviders = cfg.tts.providers
                          .where((p) => p.providerId != provider.providerId)
                          .toList();
                      await _applyAndSaveConfig(
                        cfg.copyWith(
                          tts: cfg.tts.copyWith(providers: nextProviders),
                        ),
                        successMessage:
                            '已删除 TTS 供应商 ${provider.displayName}（已编排数据将自动按同性别兜底）',
                      );
                    },
                  ),
              ],
            ),
          ),
          for (final model in provider.models)
            _buildTtsModelBlock(cfg, provider, model),
        ],
      ),
    );
  }

  Widget _buildTtsModelBlock(
    ImmersiveConfig cfg,
    TtsProviderConfig provider,
    TtsModelConfig model,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: model.enabled ? Colors.grey.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '模型：${model.modelId}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: model.enabled ? Colors.black87 : Colors.black38,
                      ),
                    ),
                    Text(
                      '子并发 ${model.maxConcurrency} · ${model.enabled ? '已启用' : '已停用'}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '编辑模型与音色',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 17),
                onPressed: () => _showTtsModelEditorDialog(
                  cfg,
                  provider: provider,
                  editingModel: model,
                ),
              ),
              IconButton(
                tooltip: '删除模型',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 17,
                  color: Colors.redAccent,
                ),
                onPressed: () async {
                  final nextModels = provider.models
                      .where((m) => m.modelKey != model.modelKey)
                      .toList();
                  final nextProviders = cfg.tts.providers
                      .map(
                        (p) => p.providerId == provider.providerId
                            ? p.copyWith(models: nextModels)
                            : p,
                      )
                      .toList();
                  await _applyAndSaveConfig(
                    cfg.copyWith(
                      tts: cfg.tts.copyWith(providers: nextProviders),
                    ),
                    successMessage:
                        '已删除模型 ${model.modelId}（已编排数据将自动按同性别兜底）',
                  );
                },
              ),
              Switch(
                value: model.enabled,
                onChanged: (v) async {
                  final nextModels = provider.models
                      .map(
                        (m) => m.modelKey == model.modelKey
                            ? m.copyWith(enabled: v)
                            : m,
                      )
                      .toList();
                  final nextProviders = cfg.tts.providers
                      .map(
                        (p) => p.providerId == provider.providerId
                            ? p.copyWith(models: nextModels)
                            : p,
                      )
                      .toList();
                  await _applyAndSaveConfig(
                    cfg.copyWith(
                      tts: cfg.tts.copyWith(providers: nextProviders),
                    ),
                    successMessage: v
                        ? '已启用 TTS 模型 ${model.modelId}'
                        : '已停用 TTS 模型 ${model.modelId}（已编排数据将自动按同性别兜底）',
                  );
                },
              ),
            ],
          ),
          const Divider(height: 10),
          for (final voice in model.voices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Checkbox(
                    visualDensity: VisualDensity.compact,
                    value: voice.enabled,
                    onChanged: (checked) async {
                      final nextVal = checked ?? true;
                      final nextVoices = model.voices
                          .map(
                            (v) => v.voiceProfileId == voice.voiceProfileId
                                ? v.copyWith(enabled: nextVal)
                                : v,
                          )
                          .toList();
                      final nextModels = provider.models
                          .map(
                            (m) => m.modelKey == model.modelKey
                                ? m.copyWith(voices: nextVoices)
                                : m,
                          )
                          .toList();
                      final nextProviders = cfg.tts.providers
                          .map(
                            (p) => p.providerId == provider.providerId
                                ? p.copyWith(models: nextModels)
                                : p,
                          )
                          .toList();
                      await _applyAndSaveConfig(
                        cfg.copyWith(
                          tts: cfg.tts.copyWith(providers: nextProviders),
                        ),
                        successMessage: nextVal
                            ? '已启用音色 ${voice.displayName}'
                            : '已停用音色 ${voice.displayName}（已编排数据将自动同性别兜底）',
                      );
                    },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${voice.displayName}  [${voice.gender}]',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: (provider.enabled &&
                                    model.enabled &&
                                    voice.enabled)
                                ? Colors.black87
                                : Colors.black38,
                          ),
                        ),
                        Text(
                          'voice_id: ${voice.voiceId}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.black54,
                          ),
                        ),
                        if (voice.notes.isNotEmpty)
                          Text(
                            voice.notes,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.black54,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (voice.sampleAsset != null)
                    IconButton(
                      tooltip: '本地样本试听',
                      icon: Icon(
                        _coord.previewingVoiceProfileId == voice.voiceProfileId
                            ? Icons.volume_up
                            : Icons.play_circle_outline,
                        size: 20,
                        color: AppTheme.primaryColor,
                      ),
                      onPressed: () => unawaited(
                        _coord.playLocalVoiceSample(
                          voiceProfileId: voice.voiceProfileId,
                          assetPath: voice.sampleAsset!,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '在线合成试听',
                    icon: _testingVoiceId == voice.voiceProfileId
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_done_outlined, size: 19),
                    onPressed: _testingVoiceId != null
                        ? null
                        : () => _testVoiceOnline(voice.voiceProfileId),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBookVoiceTab(ImmersiveConfig cfg) {
    final bookCfg = _bookConfig;
    final enabledVoices = cfg.allEnabledVoiceProfiles;
    if (bookCfg == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('请先打开一本书后再为本书单独配置人物候选音色与固定旁白。'),
        ),
      );
    }
    if (enabledVoices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('当前没有已启用的 TTS 音色，请先在“模型与音色”页启用至少一个音色。'),
        ),
      );
    }

    final selectedSet = bookCfg.selectedVoiceProfileIds.toSet();
    final currentNarratorValid = enabledVoices.any(
      (v) => v.voice.voiceProfileId == bookCfg.narratorVoiceProfileId,
    );
    final dropdownNarrator = currentNarratorValid
        ? bookCfg.narratorVoiceProfileId
        : enabledVoices.first.voice.voiceProfileId;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '固定旁白（独立于人物候选池，专职叙述、内心独白与引用）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              if (!currentNarratorValid)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '提示：原旁白音色已停用或移除，播放时将自动按同性别兜底，也可下方重新指定。',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: dropdownNarrator,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final v in enabledVoices)
                    DropdownMenuItem(
                      value: v.voice.voiceProfileId,
                      child: Text(
                        '${v.voice.displayName} (${v.model.modelId}/${v.voice.voiceId})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _bookConfig = bookCfg.copyWith(narratorVoiceProfileId: v);
                  });
                },
              ),
              const SizedBox(height: 16),
              Text(
                '本书人物候选音色池（当前已启用音色 ${enabledVoices.length} 个，已选 ${selectedSet.where((id) => enabledVoices.any((v) => v.voice.voiceProfileId == id)).length} 个）',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              for (final res in enabledVoices)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: selectedSet.contains(res.voice.voiceProfileId),
                  title: Text(
                    '${res.voice.displayName} [${res.voice.gender}]',
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '${res.model.modelId} -> ${res.voice.voiceId} · ${res.voice.notes}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  secondary: IconButton(
                    tooltip: res.voice.sampleAsset != null ? '本地试听' : '在线试听',
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    onPressed: () {
                      if (res.voice.sampleAsset != null) {
                        unawaited(
                          _coord.playLocalVoiceSample(
                            voiceProfileId: res.voice.voiceProfileId,
                            assetPath: res.voice.sampleAsset!,
                          ),
                        );
                      } else {
                        unawaited(_testVoiceOnline(res.voice.voiceProfileId));
                      }
                    },
                  ),
                  onChanged: (checked) {
                    final next = List<String>.from(
                      bookCfg.selectedVoiceProfileIds,
                    );
                    if (checked == true) {
                      if (!next.contains(res.voice.voiceProfileId)) {
                        next.add(res.voice.voiceProfileId);
                      }
                    } else {
                      next.remove(res.voice.voiceProfileId);
                    }
                    setState(() {
                      _bookConfig = bookCfg.copyWith(
                        selectedVoiceProfileIds: next,
                      );
                    });
                  },
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                await _coord.updateBookVoicePool(
                  bookId: bookCfg.bookId,
                  selectedVoiceProfileIds: bookCfg.selectedVoiceProfileIds,
                  narratorVoiceProfileId: dropdownNarrator,
                );
                if (!mounted) return;
                setState(() {
                  _statusMessage = '本书配音方案已应用（正在播放时将于下一句原文边界平滑切换）';
                  _statusIsError = false;
                });
              },
              child: const Text('应用到本书'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPipelineTab(ImmersiveConfig cfg) {
    final hasBookContext =
        (widget.book != null && (widget.chapters?.isNotEmpty ?? false)) ||
        _coord.currentBook != null;
    return ImmersivePipelineTab(
      config: cfg,
      pipelineStatus: _pipelineStatus,
      coordinator: _coord,
      hasBookContext: hasBookContext,
      rebuilding: _rebuilding,
      onDraftChanged: (nextCfg) => setState(() => _draftConfig = nextCfg),
      onApplyAndSaveConfig: (updated, msg) =>
          _applyAndSaveConfig(updated, successMessage: msg),
      onResetFailover: () {
        _coord.scheduler?.resetTextModelFailover();
        setState(() {
          _statusMessage = '已手动切回主文本模型';
          _statusIsError = false;
        });
      },
      onRebuildPressed: _confirmAndRebuild,
      onRetryBlocked: () async {
        await _coord.retryBlockedRange();
        await _loadData();
      },
      onClearUnpinnedCache: () async {
        final removed = await _coord.cacheManager?.clearAllUnpinnedCache() ?? 0;
        await _loadData();
        if (!mounted) return;
        setState(() {
          _statusMessage = '已清理 $removed 个未占用音频缓存文件';
          _statusIsError = false;
        });
      },
      onReload: _loadData,
    );
  }

  Future<void> _confirmAndRebuild(int backtrack) async {
    final confirmed = await showRebuildConfirmDialog(
      context,
      backtrack: backtrack,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _rebuilding = true;
      _statusMessage = '正在清空旧编排并从当前章节重建…';
      _statusIsError = false;
    });
    try {
      await _coord.rebuildArrangementFromCurrentChapter(
        book: widget.book,
        chapters: widget.chapters,
        chapterIndex: widget.currentChapterIndex,
        position: widget.currentPosition,
        contentLoader: widget.contentLoader,
        offlineOnly: widget.offlineOnly,
        restartPlayback: true,
      );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rebuilding = false;
        _statusMessage = '重建编排失败：$e';
        _statusIsError = true;
      });
    }
  }

  /// 新增或编辑文本分析模型弹窗
  Future<void> _showTextModelEditorDialog(
    ImmersiveConfig cfg, {
    TextAnalysisConfig? editing,
  }) async {
    final nextModel = await showTextModelEditorDialog(
      context,
      cfg,
      editing: editing,
    );
    if (nextModel == null || !mounted) return;

    final nextList = editing == null
        ? [...cfg.textAnalysisModels, nextModel]
        : cfg.textAnalysisModels
              .map((m) => m.effectiveId == editing.effectiveId ? nextModel : m)
              .toList();

    await _applyAndSaveConfig(
      cfg.copyWith(textAnalysisModels: nextList),
      successMessage: editing == null
          ? '已新增文本提取模型 ${nextModel.modelId}（并发 ${nextModel.maxConcurrency}）'
          : '已更新文本提取模型 ${nextModel.modelId}（并发 ${nextModel.maxConcurrency}）',
    );
  }

  /// 新增或编辑 TTS 供应商弹窗
  Future<void> _showTtsProviderEditorDialog(
    ImmersiveConfig cfg, {
    TtsProviderConfig? editing,
  }) async {
    final provider = await showTtsProviderEditorDialog(
      context,
      editing: editing,
    );
    if (provider == null || !mounted) return;

    final nextProviders = editing == null
        ? [...cfg.tts.providers, provider]
        : cfg.tts.providers
              .map((p) => p.providerId == editing.providerId ? provider : p)
              .toList();
    await _applyAndSaveConfig(
      cfg.copyWith(tts: cfg.tts.copyWith(providers: nextProviders)),
      successMessage: editing == null
          ? '已新增 TTS 供应商 ${provider.displayName}，请继续为其添加模型与音色'
          : '已更新 TTS 供应商 ${provider.displayName}',
    );
  }

  /// 新增或编辑 TTS 模型与音色弹窗
  Future<void> _showTtsModelEditorDialog(
    ImmersiveConfig cfg, {
    required TtsProviderConfig provider,
    TtsModelConfig? editingModel,
  }) async {
    final nextModel = await showTtsModelEditorDialog(
      context,
      provider: provider,
      editingModel: editingModel,
    );
    if (nextModel == null || !mounted) return;

    final nextModels = editingModel == null
        ? [...provider.models, nextModel]
        : provider.models
              .map((m) => m.modelKey == editingModel.modelKey ? nextModel : m)
              .toList();
    final nextProviders = cfg.tts.providers
        .map(
          (p) => p.providerId == provider.providerId
              ? p.copyWith(models: nextModels)
              : p,
        )
        .toList();

    final firstVoiceId = nextModel.voices.firstOrNull?.voiceId ?? '';
    await _applyAndSaveConfig(
      cfg.copyWith(tts: cfg.tts.copyWith(providers: nextProviders)),
      successMessage: editingModel == null
          ? '已新增模型 ${nextModel.modelId}（voice_id=$firstVoiceId），可直接点击试听'
          : '已更新模型 ${nextModel.modelId}（voice_id=$firstVoiceId）',
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
