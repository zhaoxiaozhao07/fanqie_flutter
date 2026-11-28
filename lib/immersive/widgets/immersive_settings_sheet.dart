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
    final bg = AppTheme.surfaceOf(context);
    if (ReaderPlatform.isDesktop) {
      return showReaderModal<void>(
        context: context,
        backgroundColor: bg,
        heightFactor: 0.88,
        desktopWidth: 760,
        builder: (_) => sheet,
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: bg,
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
  String _voiceGenderFilter = 'all';

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
      case TextThinkingLevel.none:
        return '关闭思考 (none)';
      case TextThinkingLevel.off:
        return '关闭思考 (off)';
      case TextThinkingLevel.minimal:
        return '最低 (minimal)';
      case TextThinkingLevel.low:
        return '低 (low)';
      case TextThinkingLevel.medium:
        return '中 (medium)';
      case TextThinkingLevel.high:
        return '高 (high)';
      case TextThinkingLevel.max:
        return '最高 (max)';
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
              const Expanded(
                child: Text(
                  '沉浸式多角色听书设置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
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
                color: _statusIsError
                    ? (AppTheme.isDark(context)
                          ? Colors.redAccent.shade100
                          : Colors.red.shade800)
                    : AppTheme.textPrimaryOf(context),
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
    final enabledTextModels = cfg.enabledTextModels;
    final selectedPrimaryValue = enabledTextModels.any(
      (m) => m.effectiveId == primaryId,
    )
        ? primaryId
        : (enabledTextModels.isNotEmpty
              ? enabledTextModels.first.effectiveId
              : null);
    final fallbackCandidates = enabledTextModels
        .where((m) => m.effectiveId != selectedPrimaryValue)
        .toList();
    final selectedFallbackValue = fallbackCandidates.any(
      (m) => m.effectiveId == fallbackId,
    )
        ? fallbackId
        : '';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Material(
          color: AppTheme.inputFillOf(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppTheme.dividerOf(context)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                '启用沉浸式多角色听书',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              subtitle: const Text(
                '密钥加密保存于系统安全存储，关闭时自动使用原有普通听书',
                style: TextStyle(fontSize: 11.5),
              ),
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
          ),
        ),
        const SizedBox(height: 14),
        // ==================== 1. 多文本提取模型管理 ====================
        Row(
          children: [
            const Expanded(
              child: Text(
                '1. 文本提取模型（失败重试与主备切换）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增模型', style: TextStyle(fontSize: 12)),
              onPressed: () => _showTextModelEditorDialog(cfg),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (enabledTextModels.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceOf(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.dividerOf(context)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'primary-model-select-$selectedPrimaryValue-${enabledTextModels.length}',
                        ),
                        initialValue: selectedPrimaryValue,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '主模型',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final m in enabledTextModels)
                            DropdownMenuItem(
                              value: m.effectiveId,
                              child: Text(
                                m.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                        ],
                        onChanged: (val) async {
                          if (val == null || val == primaryId) return;
                          final nextFallback =
                              cfg.fallbackTextModelId == val
                              ? cfg.primaryTextModelId
                              : cfg.fallbackTextModelId;
                          await _applyAndSaveConfig(
                            cfg.copyWith(
                              primaryTextModelId: val,
                              fallbackTextModelId: nextFallback,
                            ),
                            successMessage: '已切换主模型（已重置旧报错并重新调度）',
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'fallback-model-select-$selectedFallbackValue-${fallbackCandidates.length}',
                        ),
                        initialValue: selectedFallbackValue,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '兜底模型',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text(
                              '不启用兜底',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12.5),
                            ),
                          ),
                          for (final m in fallbackCandidates)
                            DropdownMenuItem(
                              value: m.effectiveId,
                              child: Text(
                                m.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                        ],
                        onChanged: (val) async {
                          if (val == null) return;
                          final nextFb = val.isEmpty ? null : val;
                          await _applyAndSaveConfig(
                            cfg.copyWith(fallbackTextModelId: nextFb),
                            successMessage: nextFb == null
                                ? '已取消兜底模型设置'
                                : '已更新兜底模型配置',
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '主模型请求失败时自动重试 ${cfg.textFailoverThreshold} 次，仍失败自动切换至兜底模型；默认上下文 1M、最大输出 8192。',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textSecondaryOf(context),
                  ),
                ),
              ],
            ),
          ),
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
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (!cfg.tts.providers.any((p) => p.adapter == 'native_tts'))
              ActionChip(
                key: const ValueKey('immersive-add-native-tts-btn'),
                avatar: const Icon(Icons.record_voice_over_outlined, size: 16),
                label: const Text('添加系统朗读（免费离线旁白）', style: TextStyle(fontSize: 12)),
                onPressed: () async {
                  final next = ImmersivePresetConfig.ensureNativeSystemTts(cfg);
                  await _applyAndSaveConfig(
                    next,
                    successMessage: '已添加本地系统朗读供应商，可在「本书配音」或下方设为固定旁白',
                  );
                },
              ),
            ActionChip(
              key: const ValueKey('immersive-set-global-native-narrator-btn'),
              avatar: const Icon(Icons.campaign_outlined, size: 16),
              label: Text(
                cfg.bookDefaults.narratorVoiceProfileId ==
                        ImmersivePresetConfig.nativeSystemVoiceProfileId
                    ? '全局默认旁白：系统朗读'
                    : '将系统朗读设为全局默认旁白',
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: () async {
                final withNative = ImmersivePresetConfig.ensureNativeSystemTts(
                  cfg,
                );
                final updated = withNative.copyWith(
                  bookDefaults: withNative.bookDefaults.copyWith(
                    narratorVoiceProfileId:
                        ImmersivePresetConfig.nativeSystemVoiceProfileId,
                  ),
                );
                await _applyAndSaveConfig(
                  updated,
                  successMessage: '已将「系统默认朗读 (本地离线)」设为全局默认旁白',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '可按供应商折叠管理模型与音色并逐个试听；若已编排数据使用的 TTS 模型被禁用或移除，'
          '系统自动按同性别寻找可用音色兜底。',
          style: TextStyle(
            fontSize: 11,
            color: AppTheme.textSecondaryOf(context),
          ),
        ),
        if (cfg.allVoiceProfiles.length > 4) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final item in const [
                  ('all', '全部音色'),
                  ('female', '女声'),
                  ('male', '男声'),
                  ('neutral', '中性/系统'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(item.$2, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      selected: _voiceGenderFilter == item.$1,
                      onSelected: (_) =>
                          setState(() => _voiceGenderFilter = item.$1),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        for (final provider in cfg.tts.providers)
          _buildTtsProviderCard(cfg, provider),
      ],
    );
  }

  Widget _paramChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: AppTheme.inputFillOf(context),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          color: AppTheme.textSecondaryOf(context),
          fontWeight: FontWeight.w500,
        ),
      ),
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
    final missingKey =
        (tm.apiKey ?? '').trim().isEmpty &&
        (tm.apiKeyEnv ?? '').trim().isEmpty;
    final ctxShort = formatTokenCountShort(tm.effectiveContextWindowTokens);
    final outShort = formatTokenCountShort(tm.maxOutputTokens);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isPrimary
              ? AppTheme.primaryColor.withValues(alpha: 0.55)
              : isFallback
              ? Colors.orange.withValues(alpha: 0.55)
              : AppTheme.dividerOf(context),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showTextModelEditorDialog(cfg, editing: tm),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
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
                            fontSize: 14,
                            color: tm.enabled
                                ? AppTheme.textPrimaryOf(context)
                                : AppTheme.textHintOf(context),
                          ),
                        ),
                        if (isPrimary)
                          _badge('主模型', AppTheme.primaryColor)
                        else if (isFallback)
                          _badge('兜底模型', Colors.orange.shade800)
                        else
                          _badge(tm.enabled ? '备选' : '已停用', Colors.grey),
                        if (missingKey)
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
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _paramChip(context, tm.modelId),
                  _paramChip(context, '上下文 $ctxShort'),
                  _paramChip(context, '输出 $outShort'),
                  _paramChip(context, '并发 ${tm.maxConcurrency}'),
                  _paramChip(context, '思考 ${_thinkingLabel(tm.thinkingLevel)}'),
                  _paramChip(context, tm.structuredOutput.mode),
                ],
              ),
              if (testRes != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: (testRes.ok ? Colors.green : Colors.red).withValues(
                      alpha: 0.08,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    testRes.message,
                    style: TextStyle(
                      fontSize: 11,
                      color: testRes.ok
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 6),
              Row(
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
                  const SizedBox(width: 6),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    label: const Text('配置', style: TextStyle(fontSize: 12)),
                    onPressed: () => _showTextModelEditorDialog(cfg, editing: tm),
                  ),
                  const Spacer(),
                  if ((!isPrimary && tm.enabled) || isFallback || canDelete)
                    PopupMenuButton<String>(
                    tooltip: '更多操作',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 20,
                      color: AppTheme.textSecondaryOf(context),
                    ),
                    onSelected: (action) async {
                      if (action == 'primary') {
                        final nextFallback =
                            cfg.fallbackTextModelId == tm.effectiveId
                            ? cfg.primaryTextModelId
                            : cfg.fallbackTextModelId;
                        await _applyAndSaveConfig(
                          cfg.copyWith(
                            primaryTextModelId: tm.effectiveId,
                            fallbackTextModelId: nextFallback,
                          ),
                          successMessage:
                              '已将 ${tm.modelId} 设为主文本提取模型（已重置旧报错并重新调度）',
                        );
                      } else if (action == 'fallback') {
                        await _applyAndSaveConfig(
                          cfg.copyWith(fallbackTextModelId: tm.effectiveId),
                          successMessage: '已将 ${tm.modelId} 设为兜底模型',
                        );
                      } else if (action == 'clear_fallback') {
                        await _applyAndSaveConfig(
                          cfg.copyWith(fallbackTextModelId: null),
                          successMessage: '已取消兜底模型设置',
                        );
                      } else if (action == 'delete') {
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
                      }
                    },
                    itemBuilder: (_) => [
                      if (!isPrimary && tm.enabled)
                        const PopupMenuItem(
                          value: 'primary',
                          child: Text('设为主模型'),
                        ),
                      if (!isPrimary && !isFallback && tm.enabled)
                        const PopupMenuItem(
                          value: 'fallback',
                          child: Text('设为兜底模型'),
                        ),
                      if (isFallback)
                        const PopupMenuItem(
                          value: 'clear_fallback',
                          child: Text('取消兜底设置'),
                        ),
                      if (canDelete)
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            '删除该模型',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _matchesGenderFilter(String gender) {
    if (_voiceGenderFilter == 'all') return true;
    if (_voiceGenderFilter == 'neutral') {
      return gender != 'male' && gender != 'female';
    }
    return gender == _voiceGenderFilter;
  }

  Widget _buildTtsProviderCard(
    ImmersiveConfig cfg,
    TtsProviderConfig provider,
  ) {
    final totalVoices = provider.models.fold<int>(
      0,
      (sum, m) => sum + m.voices.length,
    );
    final enabledVoices = provider.models.fold<int>(
      0,
      (sum, m) => sum + (m.enabled ? m.voices.where((v) => v.enabled).length : 0),
    );
    final filteredModels = [
      for (final model in provider.models)
        if (model.voices.any((v) => _matchesGenderFilter(v.gender))) model,
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.dividerOf(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: totalVoices <= 2,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        title: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    provider.displayName,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: provider.enabled
                          ? AppTheme.textPrimaryOf(context)
                          : AppTheme.textHintOf(context),
                    ),
                  ),
                  if (provider.adapter == 'native_tts')
                    _badge('本地离线', Colors.green.shade700)
                  else ...[
                    if ((provider.apiKey ?? '').trim().isEmpty &&
                        (provider.apiKeyEnv ?? '').trim().isEmpty)
                      _badge('未填密钥', Colors.red.shade700),
                  ],
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
          '已启 $enabledVoices/$totalVoices 音色 · 并发 ${provider.maxConcurrency} · 点击展开音色库',
          style: TextStyle(
            fontSize: 11,
            color: AppTheme.textSecondaryOf(context),
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('新增音色', style: TextStyle(fontSize: 12)),
                  onPressed: () =>
                      _showTtsModelEditorDialog(cfg, provider: provider),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('编辑供应商', style: TextStyle(fontSize: 12)),
                  onPressed: () =>
                      _showTtsProviderEditorDialog(cfg, editing: provider),
                ),
                const Spacer(),
                if (cfg.tts.providers.length > 1)
                  IconButton(
                    tooltip: '删除供应商',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
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
          const Divider(height: 1),
          if (filteredModels.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                '当前性别筛选下无匹配音色',
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondaryOf(context),
                ),
              ),
            )
          else
            for (final model in filteredModels)
              if (model.voices.length == 1)
                _buildFlatSingleVoiceTile(cfg, provider, model, model.voices.first)
              else
                _buildTtsModelBlock(cfg, provider, model),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 单音色模型扁平化展示：消除模型外框与音色复选框双重开关冗余
  Widget _buildFlatSingleVoiceTile(
    ImmersiveConfig cfg,
    TtsProviderConfig provider,
    TtsModelConfig model,
    TtsVoiceProfileConfig voice,
  ) {
    final effectiveEnabled = model.enabled && voice.enabled;
    final genderText = switch (voice.gender) {
      'female' => '女',
      'male' => '男',
      _ => '中性',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.dividerOf(context), width: 0.6),
        ),
      ),
      child: Row(
        children: [
          Checkbox(
            visualDensity: VisualDensity.compact,
            value: effectiveEnabled,
            onChanged: (checked) async {
              final nextVal = checked ?? true;
              final nextModels = provider.models
                  .map(
                    (m) => m.modelKey == model.modelKey
                        ? m.copyWith(
                            enabled: nextVal,
                            voices: [voice.copyWith(enabled: nextVal)],
                          )
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
                cfg.copyWith(tts: cfg.tts.copyWith(providers: nextProviders)),
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        voice.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: (provider.enabled && effectiveEnabled)
                              ? AppTheme.textPrimaryOf(context)
                              : AppTheme.textHintOf(context),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _badge(
                      genderText,
                      voice.gender == 'female'
                          ? Colors.pink.shade400
                          : voice.gender == 'male'
                          ? Colors.blue.shade600
                          : Colors.teal,
                    ),
                  ],
                ),
                if (voice.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      voice.notes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondaryOf(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (voice.sampleAsset != null)
            IconButton(
              tooltip: '本地样本试听',
              visualDensity: VisualDensity.compact,
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
            tooltip: provider.adapter == 'native_tts' ? '本地系统朗读试听' : '在线合成试听',
            visualDensity: VisualDensity.compact,
            icon: _testingVoiceId == voice.voiceProfileId
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    provider.adapter == 'native_tts'
                        ? Icons.play_circle_outline
                        : Icons.cloud_done_outlined,
                    size: 18,
                  ),
            onPressed: _testingVoiceId != null
                ? null
                : () => _testVoiceOnline(voice.voiceProfileId),
          ),
          PopupMenuButton<String>(
            tooltip: '音色操作',
            icon: Icon(
              Icons.more_vert,
              size: 17,
              color: AppTheme.textSecondaryOf(context),
            ),
            onSelected: (action) async {
              if (action == 'edit') {
                await _showTtsModelEditorDialog(
                  cfg,
                  provider: provider,
                  editingModel: model,
                );
              } else if (action == 'delete') {
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
                  cfg.copyWith(tts: cfg.tts.copyWith(providers: nextProviders)),
                  successMessage: '已删除音色 ${voice.displayName}（已编排数据将自动按同性别兜底）',
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑模型与音色')),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除', style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTtsModelBlock(
    ImmersiveConfig cfg,
    TtsProviderConfig provider,
    TtsModelConfig model,
  ) {
    final isDark = AppTheme.isDark(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: model.enabled
            ? AppTheme.inputFillOf(context)
            : (isDark
                  ? AppTheme.darkBackgroundColor
                  : Colors.grey.shade100),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.dividerOf(context)),
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
                        color: model.enabled
                            ? AppTheme.textPrimaryOf(context)
                            : AppTheme.textHintOf(context),
                      ),
                    ),
                    Text(
                      '子并发 ${model.maxConcurrency} · ${model.enabled ? '已启用' : '已停用'}',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.textSecondaryOf(context),
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
                                ? AppTheme.textPrimaryOf(context)
                                : AppTheme.textHintOf(context),
                          ),
                        ),
                        Text(
                          'voice_id: ${voice.voiceId}',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondaryOf(context),
                          ),
                        ),
                        if (voice.notes.isNotEmpty)
                          Text(
                            voice.notes,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondaryOf(context),
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
                    tooltip: provider.adapter == 'native_tts'
                        ? '本地系统朗读试听'
                        : '在线合成试听',
                    icon: _testingVoiceId == voice.voiceProfileId
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            provider.adapter == 'native_tts'
                                ? Icons.play_circle_outline
                                : Icons.cloud_done_outlined,
                            size: 19,
                          ),
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
                key: ValueKey('immersive-narrator-$dropdownNarrator-${enabledVoices.length}'),
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
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ActionChip(
                    key: const ValueKey('immersive-use-native-narrator-btn'),
                    avatar: const Icon(Icons.record_voice_over_outlined, size: 16),
                    label: Text(
                      dropdownNarrator ==
                              ImmersivePresetConfig.nativeSystemVoiceProfileId
                          ? '当前已设为系统朗读旁白'
                          : '一键设为系统朗读旁白（本地离线免费）',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () async {
                      final withNative =
                          ImmersivePresetConfig.ensureNativeSystemTts(cfg);
                      if (!identical(withNative, cfg)) {
                        final saved = await _applyAndSaveConfig(
                          withNative,
                          successMessage: '已添加系统朗读供应商并切换为本书固定旁白',
                        );
                        if (!saved || !mounted) return;
                      }
                      final nextBookCfg = bookCfg.copyWith(
                        narratorVoiceProfileId:
                            ImmersivePresetConfig.nativeSystemVoiceProfileId,
                      );
                      await _coord.updateBookVoicePool(
                        bookId: nextBookCfg.bookId,
                        selectedVoiceProfileIds:
                            nextBookCfg.selectedVoiceProfileIds,
                        narratorVoiceProfileId:
                            nextBookCfg.narratorVoiceProfileId,
                      );
                      if (!mounted) return;
                      setState(() {
                        _bookConfig = nextBookCfg;
                        _statusMessage = '已将本书固定旁白设为「系统默认朗读 (本地离线)」';
                        _statusIsError = false;
                      });
                    },
                  ),
                ],
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
      onPreSynthesizePressed: (count) async {
        final book = widget.book ?? _coord.currentBook;
        final chapters = widget.chapters;
        if (book == null || chapters == null || chapters.isEmpty) {
          setState(() {
            _statusMessage = '请先进入书籍阅读页后再触发通勤离线预合成';
            _statusIsError = true;
          });
          return;
        }
        final startIdx = widget.currentChapterIndex ?? _coord.currentChapterIndex;
        unawaited(
          _coord.preSynthesizeUpcomingChapters(
            book: book,
            chapters: chapters,
            startChapterIndex: startIdx,
            chapterCount: count,
            contentLoader: widget.contentLoader,
            offlineOnly: widget.offlineOnly,
          ),
        );
        setState(() {
          _statusMessage = '已启动后续 $count 章通勤离线预合成，可随时在此查看进度或停止';
          _statusIsError = false;
        });
      },
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
      cfg: cfg,
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
