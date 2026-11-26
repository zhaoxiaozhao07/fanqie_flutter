import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../models/immersive_config.dart';
import '../services/text_model_adapter.dart';

/// 远端 `/v1/models` 列表拉取回调类型（支持单测注入桩实现）
typedef RemoteModelsFetcher = Future<List<String>> Function({
  required String baseUrl,
  required String apiKey,
});

/// 解析用户输入的 Token 数量文本（支持空字符串返回 null，支持 1M / 128K / 普通整数 / 千分位逗号）
/// 返回 `(value, error)`，仅当格式非法时 `error != null`
({int? value, String? error}) parseTokenCountInput(String raw) {
  final cleaned = raw.trim().replaceAll(',', '').replaceAll('_', '');
  if (cleaned.isEmpty) {
    return (value: null, error: null);
  }
  final upper = cleaned.toUpperCase();
  final match = RegExp(r'^(\d+(?:\.\d+)?)\s*([KM])?$').firstMatch(upper);
  if (match == null) {
    return (value: null, error: '请输入正整数，或使用 1M / 128K 简写');
  }
  final numPart = double.tryParse(match.group(1)!);
  if (numPart == null || numPart <= 0) {
    return (value: null, error: '数值必须大于 0');
  }
  final unit = match.group(2);
  final multiplier = unit == 'M'
      ? 1000000
      : unit == 'K'
      ? 1000
      : 1;
  final result = (numPart * multiplier).round();
  if (result <= 0) {
    return (value: null, error: '数值必须大于 0');
  }
  return (value: result, error: null);
}

/// 格式化 Token 数量用于卡片摘要展示（如 1000000 -> 1M，128000 -> 128K，null -> 空标签）
String formatTokenCountShort(int? value, {String emptyLabel = '不传'}) {
  if (value == null) return emptyLabel;
  if (value >= 1000000 && value % 1000000 == 0) {
    return '${value ~/ 1000000}M';
  }
  if (value >= 100000 && value % 1000 == 0) {
    return '${value ~/ 1000}K';
  }
  return '$value';
}

/// 非回环明文 HTTP 安全提醒卡片（提醒用户 API Key 明文传输风险）
Widget buildInsecureHttpWarningBanner() {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.orange.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Colors.orange.withValues(alpha: 0.45)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade800),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '当前接口使用明文 HTTP，API Key 在公网传输存在泄露风险，建议改用 HTTPS 或仅在可信内网使用。',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
          ),
        ),
      ],
    ),
  );
}

/// 弹窗：新增或编辑文本分析模型
Future<TextAnalysisConfig?> showTextModelEditorDialog(
  BuildContext context,
  ImmersiveConfig cfg, {
  TextAnalysisConfig? editing,
  RemoteModelsFetcher? modelsFetcher,
}) {
  return showDialog<TextAnalysisConfig>(
    context: context,
    builder: (_) => _TextModelEditorDialog(
      cfg: cfg,
      editing: editing,
      modelsFetcher: modelsFetcher,
    ),
  );
}

class _TextModelEditorDialog extends StatefulWidget {
  final ImmersiveConfig cfg;
  final TextAnalysisConfig? editing;
  final RemoteModelsFetcher? modelsFetcher;

  const _TextModelEditorDialog({
    required this.cfg,
    this.editing,
    this.modelsFetcher,
  });

  @override
  State<_TextModelEditorDialog> createState() => _TextModelEditorDialogState();
}

class _TextModelEditorDialogState extends State<_TextModelEditorDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelIdCtrl;
  late final TextEditingController _modelFilterCtrl;
  late final TextEditingController _contextWindowCtrl;
  late final TextEditingController _maxOutputCtrl;

  late int _conc;
  late String _thinking;
  late String _structuredMode;
  late String _outputLimitParam;
  late bool _enabled;

  bool _fetchingModels = false;
  List<String> _fetchedModels = const [];
  String? _fetchError;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    final primary = widget.cfg.primaryTextModel;
    _nameCtrl = TextEditingController(text: editing?.displayName ?? '');
    _urlCtrl = TextEditingController(text: editing?.baseUrl ?? primary.baseUrl);
    _keyCtrl = TextEditingController(
      text: editing?.apiKey ?? primary.apiKey ?? '',
    );
    _modelIdCtrl = TextEditingController(text: editing?.modelId ?? '');
    _modelFilterCtrl = TextEditingController();
    _contextWindowCtrl = TextEditingController(
      text: editing == null
          ? '${TextAnalysisConfig.defaultContextWindowTokens}'
          : (editing.contextWindowTokens?.toString() ?? ''),
    );
    _maxOutputCtrl = TextEditingController(
      text: editing == null
          ? '${TextAnalysisConfig.defaultMaxOutputTokens}'
          : (editing.maxOutputTokens?.toString() ?? ''),
    );

    _conc = editing?.maxConcurrency ?? 3;
    var initThinking = editing?.thinkingLevel ?? TextThinkingLevel.auto;
    if (initThinking == TextThinkingLevel.off) {
      initThinking = TextThinkingLevel.none;
    }
    if (!const {
      TextThinkingLevel.auto,
      TextThinkingLevel.none,
      TextThinkingLevel.minimal,
      TextThinkingLevel.low,
      TextThinkingLevel.medium,
      TextThinkingLevel.high,
      TextThinkingLevel.max,
    }.contains(initThinking)) {
      initThinking = TextThinkingLevel.auto;
    }
    _thinking = initThinking;
    _structuredMode = editing?.structuredOutput.mode ?? 'vendor_native';
    _outputLimitParam =
        editing?.outputLimitParameter ?? 'max_completion_tokens';
    _enabled = editing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _modelIdCtrl.dispose();
    _modelFilterCtrl.dispose();
    _contextWindowCtrl.dispose();
    _maxOutputCtrl.dispose();
    super.dispose();
  }

  Future<void> _doFetchModels() async {
    final fetcher =
        widget.modelsFetcher ??
        ({required String baseUrl, required String apiKey}) =>
            OpenAiChatTextModelAdapter.fetchAvailableModels(
              baseUrl: baseUrl,
              apiKey: apiKey,
            );
    setState(() {
      _fetchingModels = true;
      _fetchError = null;
    });
    try {
      final list = await fetcher(
        baseUrl: _urlCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _fetchedModels = list;
        _fetchError = null;
        if (_modelIdCtrl.text.trim().isEmpty && list.isNotEmpty) {
          _modelIdCtrl.text = list.first;
          if (_nameCtrl.text.trim().isEmpty) {
            _nameCtrl.text = list.first;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchingModels = false;
        _fetchError = '$e'.replaceFirst('FormatException: ', '');
      });
    }
  }

  void _onSavePressed() {
    final modelId = _modelIdCtrl.text.trim();
    final baseUrl = _urlCtrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _formError = '请填写 Base URL');
      return;
    }
    if (modelId.isEmpty) {
      setState(() => _formError = '请填写或下拉选择模型 ID');
      return;
    }
    final parsedCtx = parseTokenCountInput(_contextWindowCtrl.text);
    if (parsedCtx.error != null) {
      setState(() => _formError = '上下文窗口格式错误：${parsedCtx.error}');
      return;
    }
    if (parsedCtx.value != null && parsedCtx.value! < 1024) {
      setState(() => _formError = '上下文窗口不能小于 1024');
      return;
    }
    final parsedMaxOut = parseTokenCountInput(_maxOutputCtrl.text);
    if (parsedMaxOut.error != null) {
      setState(() => _formError = '最大输出格式错误：${parsedMaxOut.error}');
      return;
    }
    if (parsedMaxOut.value != null && parsedMaxOut.value! < 128) {
      setState(() => _formError = '最大输出不能小于 128（若不限制请留空）');
      return;
    }
    if (parsedCtx.value != null &&
        parsedMaxOut.value != null &&
        parsedMaxOut.value! >= parsedCtx.value!) {
      setState(() => _formError = '最大输出 Token 必须小于上下文窗口 Token');
      return;
    }

    final editing = widget.editing;
    final displayName =
        _nameCtrl.text.trim().isEmpty ? modelId : _nameCtrl.text.trim();
    final safeReserved = _conc <= 1 ? 0 : 1;
    final entryId =
        editing?.effectiveId ??
        'tm_${modelId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}_${DateTime.now().millisecondsSinceEpoch % 10000}';

    final nextModel = TextAnalysisConfig(
      id: entryId,
      providerId: editing?.providerId ?? 'analysis_custom',
      displayName: displayName,
      enabled: _enabled,
      adapter: 'openai_chat_completions',
      baseUrl: baseUrl,
      endpoint: editing?.endpoint ?? '/chat/completions',
      apiKey: _keyCtrl.text.trim(),
      apiKeyEnv: null,
      modelId: modelId,
      thinkingLevel: _thinking,
      extraHeaders: editing?.extraHeaders ?? const {},
      extraBody: editing?.extraBody ?? const {},
      requestTimeoutMs: editing?.requestTimeoutMs ?? 90000,
      maxConcurrency: _conc,
      reservedReconciliationSlots: safeReserved,
      requestsPerMinute: editing?.requestsPerMinute ?? 60,
      tokensPerMinute: editing?.tokensPerMinute,
      contextWindowTokens: parsedCtx.value,
      maxOutputTokens: parsedMaxOut.value,
      outputLimitParameter: _outputLimitParam,
      temperature: editing?.temperature,
      structuredOutput: StructuredOutputConfig(
        mode: _structuredMode,
        schemaNamePrefix: 'immersive_reader_v1',
        strict: true,
        vendorAdapterId: _structuredMode == 'vendor_native'
            ? 'openai_tool_call_schema'
            : null,
        allowPromptOnlyFallback: false,
      ),
    );
    Navigator.pop(context, nextModel);
  }

  @override
  Widget build(BuildContext context) {
    final insecureHttp = isInsecureRemoteHttpUrl(_urlCtrl.text);
    final filterKey = _modelFilterCtrl.text.trim().toLowerCase();
    final filteredModels = filterKey.isEmpty
        ? _fetchedModels
        : _fetchedModels
              .where((m) => m.toLowerCase().contains(filterKey))
              .toList();
    final currentId = _modelIdCtrl.text.trim();
    final selectedDropdownModel =
        filteredModels.contains(currentId) ? currentId : null;
    final hasMaxOutput = _maxOutputCtrl.text.trim().isNotEmpty;

    return AlertDialog(
      title: Text(widget.editing == null ? '新增文本提取模型' : '编辑文本提取模型'),
      content: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '显示名称（留空默认取模型 ID）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL（推荐 https://.../v1）',
                  isDense: true,
                ),
                onChanged: (_) => setState(() => _formError = null),
              ),
              if (insecureHttp) buildInsecureHttpWarningBanner(),
              const SizedBox(height: 8),
              TextField(
                controller: _keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key（加密保存至系统密钥库）',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('text-model-id-field'),
                      controller: _modelIdCtrl,
                      decoration: const InputDecoration(
                        labelText: '模型 ID（可手输或右侧拉取下拉）',
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() => _formError = null),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('fetch-text-models-btn'),
                    onPressed: _fetchingModels ? null : _doFetchModels,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                    icon: _fetchingModels
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_download_outlined, size: 16),
                    label: Text(
                      _fetchingModels ? '获取中' : '获取模型',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              if (_fetchError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _fetchError!,
                    style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                  ),
                ),
              if (_fetchedModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                if (_fetchedModels.length > 10)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: TextField(
                      controller: _modelFilterCtrl,
                      decoration: InputDecoration(
                        labelText: '筛选远端模型（共 ${_fetchedModels.length} 个）',
                        prefixIcon: const Icon(Icons.search, size: 16),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'text-models-dropdown-${filteredModels.length}-$selectedDropdownModel',
                  ),
                  initialValue: selectedDropdownModel,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '从 /v1/models 下拉选择（${filteredModels.length} 个可用）',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  hint: const Text('请选择远端模型'),
                  items: [
                    for (final id in filteredModels)
                      DropdownMenuItem(
                        value: id,
                        child: Text(id, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      final prevId = _modelIdCtrl.text.trim();
                      _modelIdCtrl.text = v;
                      if (_nameCtrl.text.trim().isEmpty ||
                          _nameCtrl.text.trim() == prevId) {
                        _nameCtrl.text = v;
                      }
                      _formError = null;
                    });
                  },
                ),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: const ValueKey('text-model-thinking-dropdown'),
                initialValue: _thinking,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '思考程度（支持 none 与 max）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: TextThinkingLevel.auto,
                    child: Text(
                      '自动 (auto，标准接口)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.none,
                    child: Text(
                      '关闭思考 (none)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.minimal,
                    child: Text(
                      '最低 (minimal)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.low,
                    child: Text('低 (low)', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.medium,
                    child: Text('中 (medium)', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.high,
                    child: Text('高 (high)', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: TextThinkingLevel.max,
                    child: Text('最高 (max)', overflow: TextOverflow.ellipsis),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _thinking = v);
                },
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('text-model-context-field'),
                      controller: _contextWindowCtrl,
                      decoration: const InputDecoration(
                        labelText: '上下文窗口 Token',
                        helperText: '默认 1M，可填 1M/128K',
                        helperMaxLines: 2,
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() => _formError = null),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('text-model-max-output-field'),
                      controller: _maxOutputCtrl,
                      decoration: const InputDecoration(
                        labelText: '最大输出 Token',
                        helperText: '默认 12800，留空不传该字段',
                        helperMaxLines: 2,
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() => _formError = null),
                    ),
                  ),
                ],
              ),
              if (hasMaxOutput) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _outputLimitParam,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '最大输出请求字段名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'max_completion_tokens',
                      child: Text(
                        'max_completion_tokens（OpenAI 新标准）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'max_tokens',
                      child: Text(
                        'max_tokens（传统兼容）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _outputLimitParam = v);
                  },
                ),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _structuredMode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '结构化输出模式',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'vendor_native',
                    child: Text(
                      'ToolCall 严格 Schema（推荐）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'json_schema',
                    child: Text(
                      'response_format JSON Schema',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _structuredMode = v);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('独立并发数：$_conc'),
                  const Spacer(),
                  Text(
                    '复核保留席：${_conc <= 1 ? 0 : 1}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondaryOf(context),
                    ),
                  ),
                ],
              ),
              Slider(
                value: _conc.toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                label: '$_conc',
                onChanged: (v) => setState(() => _conc = v.round()),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('启用该模型'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              if (_formError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _formError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('save-text-model-btn'),
          onPressed: _onSavePressed,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 弹窗：新增或编辑 TTS 供应商
Future<TtsProviderConfig?> showTtsProviderEditorDialog(
  BuildContext context, {
  TtsProviderConfig? editing,
}) async {
  final nameCtrl = TextEditingController(text: editing?.displayName ?? '');
  final urlCtrl = TextEditingController(
    text: editing?.baseUrl ?? 'https://oneapi.971218.xyz/v1',
  );
  final endpointCtrl = TextEditingController(
    text: editing?.endpoint ?? '/audio/speech',
  );
  final keyCtrl = TextEditingController(text: editing?.apiKey ?? '');
  var conc = editing?.maxConcurrency ?? 3;

  try {
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final insecureHttp = isInsecureRemoteHttpUrl(urlCtrl.text);
          return AlertDialog(
            title: Text(editing == null ? '新增 TTS 供应商' : '编辑 TTS 供应商'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '供应商名称',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL（推荐 https://...）',
                      isDense: true,
                    ),
                    onChanged: (_) => setD(() {}),
                  ),
                  if (insecureHttp) buildInsecureHttpWarningBanner(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: endpointCtrl,
                    decoration: const InputDecoration(
                      labelText: '接口路径（默认 /audio/speech）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key（加密保存）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [Text('供应商并发上限：$conc')]),
                  Slider(
                    value: conc.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: '$conc',
                    onChanged: (v) => setD(() => conc = v.round()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return null;
    final url = urlCtrl.text.trim();
    if (url.isEmpty) return null;
    final name = nameCtrl.text.trim().isEmpty ? '自定义 TTS' : nameCtrl.text.trim();
    final endpoint = endpointCtrl.text.trim().isEmpty
        ? '/audio/speech'
        : endpointCtrl.text.trim();
    final pid =
        editing?.providerId ??
        'tts_custom_${DateTime.now().millisecondsSinceEpoch % 100000}';
    return TtsProviderConfig(
      providerId: pid,
      displayName: name,
      enabled: editing?.enabled ?? true,
      adapter: 'openai_speech',
      baseUrl: url,
      endpoint: endpoint,
      apiKey: keyCtrl.text.trim(),
      apiKeyEnv: null,
      extraHeaders: editing?.extraHeaders ?? const {},
      requestTimeoutMs: editing?.requestTimeoutMs ?? 120000,
      maxConcurrency: conc,
      reservedForegroundSlots: conc <= 1 ? 0 : 1,
      requestsPerMinute: editing?.requestsPerMinute ?? 60,
      models: editing?.models ?? const [],
    );
  } finally {
    nameCtrl.dispose();
    urlCtrl.dispose();
    endpointCtrl.dispose();
    keyCtrl.dispose();
  }
}

/// 弹窗：新增或编辑 TTS 模型与音色
Future<TtsModelConfig?> showTtsModelEditorDialog(
  BuildContext context, {
  required TtsProviderConfig provider,
  TtsModelConfig? editingModel,
  RemoteModelsFetcher? modelsFetcher,
}) async {
  final existingVoice = editingModel?.voices.firstOrNull;
  final modelIdCtrl = TextEditingController(
    text: editingModel?.modelId ?? '',
  );
  final voiceIdCtrl = TextEditingController(
    text: existingVoice?.voiceId ?? '',
  );
  final nameCtrl = TextEditingController(
    text: existingVoice?.displayName ?? editingModel?.displayName ?? '',
  );
  final notesCtrl = TextEditingController(text: existingVoice?.notes ?? '');
  var gender = existingVoice?.gender ?? 'female';
  var conc = editingModel?.maxConcurrency ?? 3;
  var fetchingModels = false;
  var fetchedModels = <String>[];
  String? fetchError;

  final fetcher =
      modelsFetcher ??
      ({required String baseUrl, required String apiKey}) =>
          OpenAiChatTextModelAdapter.fetchAvailableModels(
            baseUrl: baseUrl,
            apiKey: apiKey,
          );

  try {
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final currentId = modelIdCtrl.text.trim();
          final selectedDropdown =
              fetchedModels.contains(currentId) ? currentId : null;

          void applyPickedModelId(String v) {
            final trimmed = v.trim();
            modelIdCtrl.text = trimmed;
            if (editingModel == null || voiceIdCtrl.text.trim().isEmpty) {
              voiceIdCtrl.text = deriveVoiceIdFromModel(trimmed);
            }
            if (trimmed.endsWith('_male')) {
              gender = 'male';
            } else if (trimmed.endsWith('_female')) {
              gender = 'female';
            }
          }

          return AlertDialog(
            title: Text(editingModel == null ? '新增 TTS 模型与音色' : '编辑 TTS 模型与音色'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: modelIdCtrl,
                          decoration: const InputDecoration(
                            labelText: '远端模型 ID（如 hunyuan_male，保留大小写）',
                            isDense: true,
                          ),
                          onChanged: (v) {
                            if (editingModel == null &&
                                voiceIdCtrl.text.trim().isEmpty) {
                              voiceIdCtrl.text = deriveVoiceIdFromModel(v.trim());
                            }
                            if (v.trim().endsWith('_male')) {
                              setD(() => gender = 'male');
                            } else if (v.trim().endsWith('_female')) {
                              setD(() => gender = 'female');
                            }
                          },
                        ),
                      ),
                      if (provider.adapter != 'native_tts') ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          key: const ValueKey('fetch-tts-models-btn'),
                          onPressed: fetchingModels
                              ? null
                              : () async {
                                  setD(() {
                                    fetchingModels = true;
                                    fetchError = null;
                                  });
                                  try {
                                    final list = await fetcher(
                                      baseUrl: provider.baseUrl,
                                      apiKey: (provider.apiKey ?? '').trim(),
                                    );
                                    if (!ctx.mounted) return;
                                    setD(() {
                                      fetchingModels = false;
                                      fetchedModels = list;
                                    });
                                  } catch (e) {
                                    if (!ctx.mounted) return;
                                    setD(() {
                                      fetchingModels = false;
                                      fetchError = '$e'.replaceFirst(
                                        'FormatException: ',
                                        '',
                                      );
                                    });
                                  }
                                },
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          icon: fetchingModels
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.cloud_download_outlined,
                                  size: 16,
                                ),
                          label: Text(
                            fetchingModels ? '获取中' : '获取模型',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (fetchError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        fetchError!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ),
                  if (fetchedModels.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'tts-models-dropdown-${fetchedModels.length}-$selectedDropdown',
                      ),
                      initialValue: selectedDropdown,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText:
                            '从 /v1/models 下拉选择（${fetchedModels.length} 个）',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final id in fetchedModels)
                          DropdownMenuItem(
                            value: id,
                            child: Text(id, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setD(() => applyPickedModelId(v));
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: voiceIdCtrl,
                    decoration: const InputDecoration(
                      labelText: '远端音色 ID（默认去掉 _female/_male 后缀）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '显示名称（如 混元男声）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: gender,
                    decoration: const InputDecoration(
                      labelText: '性别（用于角色分配与自动同性兜底）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'female', child: Text('女性 (female)')),
                      DropdownMenuItem(value: 'male', child: Text('男性 (male)')),
                      DropdownMenuItem(value: 'neutral', child: Text('中性 (neutral)')),
                      DropdownMenuItem(value: 'unknown', child: Text('未知 (unknown)')),
                    ],
                    onChanged: (v) {
                      if (v != null) setD(() => gender = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: '音色备注（帮助文本模型更准确匹配角色）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [Text('模型子并发上限：$conc')]),
                  Slider(
                    value: conc.toDouble(),
                    min: 1,
                    max: 8,
                    divisions: 7,
                    label: '$conc',
                    onChanged: (v) => setD(() => conc = v.round()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return null;
    final modelId = modelIdCtrl.text.trim();
    if (modelId.isEmpty) return null;
    final voiceId = voiceIdCtrl.text.trim().isEmpty
        ? deriveVoiceIdFromModel(modelId)
        : voiceIdCtrl.text.trim();
    final displayName = nameCtrl.text.trim().isEmpty
        ? '$voiceId ($gender)'
        : nameCtrl.text.trim();

    final modelKey =
        editingModel?.modelKey ??
        '${provider.providerId}_m_${modelId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}_${DateTime.now().millisecondsSinceEpoch % 1000}';
    final vpId =
        existingVoice?.voiceProfileId ??
        'vp_${provider.providerId}_${modelId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}_${DateTime.now().millisecondsSinceEpoch % 1000}';

    final nextVoice = TtsVoiceProfileConfig(
      voiceProfileId: vpId,
      voiceId: voiceId,
      displayName: displayName,
      enabled: existingVoice?.enabled ?? true,
      gender: gender,
      notes: notesCtrl.text.trim(),
      tags: existingVoice?.tags ?? const [],
      sampleAsset: existingVoice?.sampleAsset,
      renderSettings:
          existingVoice?.renderSettings ??
          const VoiceRenderSettings(audioFormat: 'mp3', speed: 1.0),
    );

    return TtsModelConfig(
      modelKey: modelKey,
      modelId: modelId,
      displayName: displayName,
      enabled: editingModel?.enabled ?? true,
      maxConcurrency: conc,
      capabilities:
          editingModel?.capabilities ?? const TtsModelCapabilities(),
      extraBody: editingModel?.extraBody ?? const {},
      voices: [nextVoice],
    );
  } finally {
    modelIdCtrl.dispose();
    voiceIdCtrl.dispose();
    nameCtrl.dispose();
    notesCtrl.dispose();
  }
}

/// 弹窗：确认重建本书编排
Future<bool> showRebuildConfirmDialog(
  BuildContext context, {
  required int backtrack,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重建本书角色与音色编排'),
      content: Text(
        '将清除本书已保存的旧角色档案、对话分配与检查点，'
        '并从当前阅读章节开始（最多向前自动回溯 $backtrack 章）使用当前已启用的模型与音色池重新编排。\n\n'
        '本地已缓存的同文本同音色音频将继续复用，不会重复消耗配额。确定继续吗？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('开始重建'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
