import 'package:flutter/material.dart';

import '../models/immersive_config.dart';

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
}) async {
  final nameCtrl = TextEditingController(text: editing?.displayName ?? '');
  final urlCtrl = TextEditingController(
    text: editing?.baseUrl ?? cfg.primaryTextModel.baseUrl,
  );
  final keyCtrl = TextEditingController(
    text: editing?.apiKey ?? cfg.primaryTextModel.apiKey ?? '',
  );
  final modelIdCtrl = TextEditingController(text: editing?.modelId ?? '');
  var conc = editing?.maxConcurrency ?? 3;
  var thinking = editing?.thinkingLevel ?? TextThinkingLevel.auto;
  var structuredMode = editing?.structuredOutput.mode ?? 'vendor_native';
  var enabled = editing?.enabled ?? true;

  try {
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final insecureHttp = isInsecureRemoteHttpUrl(urlCtrl.text);
          return AlertDialog(
            title: Text(editing == null ? '新增文本提取模型' : '编辑文本提取模型'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '显示名称（如 GLM 5.3 Flash）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL（推荐 https://.../v1）',
                      isDense: true,
                    ),
                    onChanged: (_) => setD(() {}),
                  ),
                  if (insecureHttp) buildInsecureHttpWarningBanner(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key（加密保存至系统密钥库）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: modelIdCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型 ID（严格区分大小写）',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: thinking,
                    decoration: const InputDecoration(
                      labelText: '思考程度（默认自动）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: TextThinkingLevel.auto,
                        child: Text('自动 (auto，标准接口)'),
                      ),
                      DropdownMenuItem(
                        value: TextThinkingLevel.off,
                        child: Text('尽量关闭 (minimal)'),
                      ),
                      DropdownMenuItem(
                        value: TextThinkingLevel.minimal,
                        child: Text('最低 (minimal)'),
                      ),
                      DropdownMenuItem(
                        value: TextThinkingLevel.low,
                        child: Text('低 (low)'),
                      ),
                      DropdownMenuItem(
                        value: TextThinkingLevel.medium,
                        child: Text('中 (medium)'),
                      ),
                      DropdownMenuItem(
                        value: TextThinkingLevel.high,
                        child: Text('高 (high)'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setD(() => thinking = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: structuredMode,
                    decoration: const InputDecoration(
                      labelText: '结构化输出模式',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'vendor_native',
                        child: Text('ToolCall 严格 Schema（推荐）'),
                      ),
                      DropdownMenuItem(
                        value: 'json_schema',
                        child: Text('response_format JSON Schema'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setD(() => structuredMode = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('独立并发数：$conc'),
                      const Spacer(),
                      Text(
                        '复核保留席：${conc <= 1 ? 0 : 1}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: conc.toDouble(),
                    min: 1,
                    max: 8,
                    divisions: 7,
                    label: '$conc',
                    onChanged: (v) => setD(() => conc = v.round()),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('启用该模型'),
                    value: enabled,
                    onChanged: (v) => setD(() => enabled = v),
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
    final baseUrl = urlCtrl.text.trim();
    if (modelId.isEmpty || baseUrl.isEmpty) return null;

    final displayName = nameCtrl.text.trim().isEmpty
        ? modelId
        : nameCtrl.text.trim();
    final safeReserved = conc <= 1 ? 0 : 1;
    final entryId =
        editing?.effectiveId ??
        'tm_${modelId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}_${DateTime.now().millisecondsSinceEpoch % 10000}';

    return TextAnalysisConfig(
      id: entryId,
      providerId: editing?.providerId ?? 'analysis_custom',
      displayName: displayName,
      enabled: enabled,
      adapter: 'openai_chat_completions',
      baseUrl: baseUrl,
      endpoint: editing?.endpoint ?? '/chat/completions',
      apiKey: keyCtrl.text.trim(),
      apiKeyEnv: null,
      modelId: modelId,
      thinkingLevel: thinking,
      extraHeaders: editing?.extraHeaders ?? const {},
      extraBody: const {},
      requestTimeoutMs: editing?.requestTimeoutMs ?? 90000,
      maxConcurrency: conc,
      reservedReconciliationSlots: safeReserved,
      requestsPerMinute: editing?.requestsPerMinute ?? 60,
      tokensPerMinute: editing?.tokensPerMinute,
      contextWindowTokens: editing?.contextWindowTokens ?? 32768,
      maxOutputTokens: editing?.maxOutputTokens ?? 6144,
      outputLimitParameter:
          editing?.outputLimitParameter ?? 'max_completion_tokens',
      temperature: editing?.temperature,
      structuredOutput: StructuredOutputConfig(
        mode: structuredMode,
        schemaNamePrefix: 'immersive_reader_v1',
        strict: true,
        vendorAdapterId: structuredMode == 'vendor_native'
            ? 'openai_tool_call_schema'
            : null,
        allowPromptOnlyFallback: false,
      ),
    );
  } finally {
    nameCtrl.dispose();
    urlCtrl.dispose();
    keyCtrl.dispose();
    modelIdCtrl.dispose();
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

  try {
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(editingModel == null ? '新增 TTS 模型与音色' : '编辑 TTS 模型与音色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
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
        ),
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
