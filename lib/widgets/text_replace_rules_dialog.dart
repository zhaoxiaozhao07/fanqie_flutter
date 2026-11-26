import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../services/text_replace_rule_service.dart';

/// 正文净化与替换规则管理弹窗（支持增删改查、内置网文净化模板、沙盒测试与 JSON 导入导出）
class TextReplaceRulesDialog extends StatefulWidget {
  final String? bookId;

  const TextReplaceRulesDialog({super.key, this.bookId});

  @override
  State<TextReplaceRulesDialog> createState() => _TextReplaceRulesDialogState();
}

class _TextReplaceRulesDialogState extends State<TextReplaceRulesDialog> {
  final _service = TextReplaceRuleService();
  final _sandboxController = TextEditingController();
  bool _sandboxOpen = false;

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  @override
  void dispose() {
    _sandboxController.dispose();
    super.dispose();
  }

  Future<void> _editRule({TextReplaceRule? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final patternCtrl = TextEditingController(text: existing?.pattern ?? '');
    final replaceCtrl = TextEditingController(text: existing?.replacement ?? '');
    var isRegex = existing?.isRegex ?? false;
    var onlyCurrentBook =
        existing != null
            ? existing.scopeBookId.isNotEmpty
            : false;
    var applyToReader = existing?.applyToReader ?? true;
    var applyToTts = existing?.applyToTts ?? true;
    String? error;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(existing == null ? '新建净化规则' : '编辑净化规则'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '规则名称',
                      hintText: '如：去除章末求票广告',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: patternCtrl,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: isRegex ? '匹配正则表达式' : '匹配原文关键词',
                      hintText: isRegex ? r'如：求月票[^\n]*' : '如：求月票求推荐',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: replaceCtrl,
                    decoration: const InputDecoration(
                      labelText: '替换为（留空表示删除）',
                      hintText: '留空即清除匹配文本',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('使用正则表达式'),
                    value: isRegex,
                    onChanged: (v) => setModalState(() => isRegex = v),
                  ),
                  if (widget.bookId != null && widget.bookId!.isNotEmpty)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('仅对当前书籍生效'),
                      subtitle: const Text('关闭后对所有书籍全局生效'),
                      value: onlyCurrentBook,
                      onChanged: (v) => setModalState(() => onlyCurrentBook = v),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('应用于阅读正文展示'),
                    value: applyToReader,
                    onChanged: (v) => setModalState(() => applyToReader = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('应用于听书朗读（过滤广告播报）'),
                    value: applyToTts,
                    onChanged: (v) => setModalState(() => applyToTts = v),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: AppTheme.errorColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final err = TextReplaceRuleService.validateRule(
                  name: nameCtrl.text,
                  pattern: patternCtrl.text,
                  isRegex: isRegex,
                );
                if (err != null) {
                  setModalState(() => error = err);
                  return;
                }
                final rule = TextReplaceRule(
                  id:
                      existing?.id ??
                      'rule_${DateTime.now().microsecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  pattern: patternCtrl.text,
                  replacement: replaceCtrl.text,
                  isRegex: isRegex,
                  enabled: existing?.enabled ?? true,
                  scopeBookId: onlyCurrentBook ? (widget.bookId ?? '') : '',
                  applyToReader: applyToReader,
                  applyToTts: applyToTts,
                );
                try {
                  await _service.upsertRule(rule);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  setModalState(() => error = e.toString());
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    patternCtrl.dispose();
    replaceCtrl.dispose();
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('净化规则已保存')));
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (raw.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('剪贴板为空，请先复制规则 JSON')));
      return;
    }
    try {
      final count = await _service.importRulesJson(raw);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已成功导入 $count 条净化规则')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final rules = _service.rules;
        final sandboxInput = _sandboxController.text;
        final sandboxOutput = sandboxInput.isEmpty
            ? ''
            : _service
                .applyForDisplay(sandboxInput, bookId: widget.bookId)
                .text;

        return AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('正文净化与替换规则')),
              IconButton(
                tooltip: '新建规则',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () => _editRule(),
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '规则仅影响展示与听书清洗，不修改底层原文与划线批注锚点，并随 WebDAV 与备份同步。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondaryOf(context),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('一键添加常用网文模板'),
                      avatar: const Icon(Icons.auto_fix_high, size: 16),
                      onPressed: () async {
                        final added = await _service.installBuiltinTemplates();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              added > 0 ? '已添加 $added 条常用网文净化模板' : '常用模板已全部添加',
                            ),
                          ),
                        );
                      },
                    ),
                    ActionChip(
                      label: Text(_sandboxOpen ? '收起测试沙盒' : '规则测试沙盒'),
                      avatar: const Icon(Icons.science_outlined, size: 16),
                      onPressed: () =>
                          setState(() => _sandboxOpen = !_sandboxOpen),
                    ),
                    ActionChip(
                      label: const Text('复制导出 JSON'),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: _service.exportRulesJson()),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制规则 JSON 到剪贴板')),
                        );
                      },
                    ),
                    ActionChip(
                      label: const Text('从剪贴板导入'),
                      onPressed: _importFromClipboard,
                    ),
                  ],
                ),
                if (_sandboxOpen) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _sandboxController,
                    maxLines: 2,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '输入测试文本（实时预览当前已启用规则效果）',
                      hintText: '例如：本章完，求月票求推荐票！书友群：12345678',
                    ),
                  ),
                  if (sandboxInput.isNotEmpty)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.inputFillOf(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '净化后：${sandboxOutput.isEmpty ? '（已全部清除）' : sandboxOutput}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                const Divider(height: 20),
                Expanded(
                  child: rules.isEmpty
                      ? Center(
                          child: Text(
                            '暂无净化规则，点击上方「新建规则」或「一键添加常用网文模板」',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppTheme.textSecondaryOf(context),
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: rules.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final rule = rules[index];
                            final scopeText = rule.scopeBookId.isEmpty
                                ? '全局'
                                : (rule.scopeBookId == widget.bookId
                                      ? '仅本书'
                                      : '指定书');
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      rule.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppTheme.inputFillOf(context),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '$scopeText${rule.isRegex ? ' · 正则' : ''}',
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                '${rule.pattern}  ->  ${rule.replacement.isEmpty ? '删除' : rule.replacement}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: rule.enabled,
                                    onChanged: (v) =>
                                        unawaited(_service.toggleRule(rule.id, v)),
                                  ),
                                  IconButton(
                                    tooltip: '编辑',
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                    onPressed: () => _editRule(existing: rule),
                                  ),
                                  IconButton(
                                    tooltip: '删除',
                                    icon: const Icon(Icons.delete_outline, size: 18),
                                    onPressed: () =>
                                        unawaited(_service.deleteRule(rule.id)),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        );
      },
    );
  }
}
