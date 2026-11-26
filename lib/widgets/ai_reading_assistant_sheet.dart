import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../immersive/models/immersive_entities.dart';
import '../immersive/widgets/immersive_settings_sheet.dart';
import '../models/chapter.dart';
import '../services/ai_reading_assistant_service.dart';

/// 防剧透 AI 阅读助手弹窗（支持前情提要与人物/设定速查）
class AiReadingAssistantSheet extends StatefulWidget {
  final String bookId;
  final String bookName;
  final List<Chapter> chapters;
  final int currentChapterIndex;
  final int currentParagraphIndex;
  final Future<String?> Function(int chapterIndex) chapterLoader;
  final String? initialTerm;
  final AiReadingAssistantService? service;

  const AiReadingAssistantSheet({
    super.key,
    required this.bookId,
    required this.bookName,
    required this.chapters,
    required this.currentChapterIndex,
    required this.currentParagraphIndex,
    required this.chapterLoader,
    this.initialTerm,
    this.service,
  });

  static Future<void> show(
    BuildContext context, {
    required String bookId,
    required String bookName,
    required List<Chapter> chapters,
    required int currentChapterIndex,
    required int currentParagraphIndex,
    required Future<String?> Function(int chapterIndex) chapterLoader,
    String? initialTerm,
    AiReadingAssistantService? service,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => AiReadingAssistantSheet(
        bookId: bookId,
        bookName: bookName,
        chapters: chapters,
        currentChapterIndex: currentChapterIndex,
        currentParagraphIndex: currentParagraphIndex,
        chapterLoader: chapterLoader,
        initialTerm: initialTerm,
        service: service,
      ),
    );
  }

  @override
  State<AiReadingAssistantSheet> createState() =>
      _AiReadingAssistantSheetState();
}

class _AiReadingAssistantSheetState extends State<AiReadingAssistantSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: (widget.initialTerm?.trim().isNotEmpty == true) ? 1 : 0,
  );
  late final AiReadingAssistantService _service =
      widget.service ?? AiReadingAssistantService();

  int _windowChapters = 5;
  bool _loadingRecap = false;
  AiRecapResult? _recap;
  String? _recapError;

  final _termController = TextEditingController();
  bool _loadingTerm = false;
  AiTermLookupResult? _termResult;
  String? _termError;
  List<ImmersiveCharacter> _knownCharacters = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadKnownCharacters());
    final initTerm = widget.initialTerm?.trim() ?? '';
    if (initTerm.isNotEmpty) {
      _termController.text = initTerm;
      unawaited(_runTermLookup(initTerm));
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _termController.dispose();
    super.dispose();
  }

  Future<void> _loadKnownCharacters() async {
    final data = await _service.loadKnownCharacters(widget.bookId);
    if (!mounted) return;
    setState(() {
      _knownCharacters = data.characters;
    });
  }

  Future<void> _runRecap({bool forceRefresh = false}) async {
    if (_loadingRecap) return;
    setState(() {
      _loadingRecap = true;
      _recapError = null;
    });
    try {
      final result = await _service.generateRecap(
        bookId: widget.bookId,
        bookName: widget.bookName,
        chapters: widget.chapters,
        currentChapterIndex: widget.currentChapterIndex,
        currentParagraphIndex: widget.currentParagraphIndex,
        chapterLoader: widget.chapterLoader,
        windowChapters: _windowChapters,
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _recap = result;
          _loadingRecap = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recapError = e.toString().replaceFirst('FormatException: ', '');
          _loadingRecap = false;
        });
      }
    }
  }

  Future<void> _runTermLookup([String? explicitTerm]) async {
    final term = (explicitTerm ?? _termController.text).trim();
    if (term.isEmpty || _loadingTerm) return;
    _termController.text = term;
    setState(() {
      _loadingTerm = true;
      _termError = null;
    });
    try {
      final result = await _service.lookupTerm(
        bookId: widget.bookId,
        bookName: widget.bookName,
        term: term,
        chapters: widget.chapters,
        currentChapterIndex: widget.currentChapterIndex,
        currentParagraphIndex: widget.currentParagraphIndex,
        chapterLoader: widget.chapterLoader,
      );
      if (mounted) {
        setState(() {
          _termResult = result;
          _loadingTerm = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _termError = e.toString().replaceFirst('FormatException: ', '');
          _loadingTerm = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeIdx = widget.currentChapterIndex.clamp(0, widget.chapters.length - 1);
    final chapterTitle = widget.chapters[safeIdx].title;
    final secondary = AppTheme.textSecondaryOf(context);

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: Column(
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: AppTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome_outlined,
                  size: 20,
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'AI 防剧透阅读助手',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    ImmersiveSettingsSheet.show(
                      context,
                      bookId: widget.bookId,
                    );
                  },
                  child: const Text('模型配置'),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 14, color: secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '防剧透边界：仅读取截至第 ${safeIdx + 1} 章《$chapterTitle》当前进度的前文内容',
                    style: TextStyle(fontSize: 11, color: secondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabs,
            labelColor: AppTheme.primaryColor,
            indicatorColor: AppTheme.primaryColor,
            tabs: const [
              Tab(text: '前情提要'),
              Tab(text: '人物与设定速查'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildRecapTab(context),
                _buildTermLookupTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecapTab(BuildContext context) {
    final secondary = AppTheme.textSecondaryOf(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('回顾范围：', style: TextStyle(fontSize: 13, color: secondary)),
            for (final w in const [3, 5, 10])
              ChoiceChip(
                label: Text('最近 $w 章'),
                selected: _windowChapters == w,
                onSelected: _loadingRecap
                    ? null
                    : (_) => setState(() => _windowChapters = w),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('ai-recap-generate-btn'),
                onPressed: _loadingRecap ? null : () => _runRecap(),
                icon: _loadingRecap
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.summarize_outlined, size: 18),
                label: Text(
                  _loadingRecap
                      ? '正在梳理前文剧情…'
                      : (_recap == null ? '生成前情提要' : '按当前范围更新'),
                ),
              ),
            ),
            if (_recap != null && !_loadingRecap) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _runRecap(forceRefresh: true),
                child: const Text('重新生成'),
              ),
            ],
          ],
        ),
        if (_recapError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _recapError!,
              style: const TextStyle(color: AppTheme.errorColor, fontSize: 13),
            ),
          ),
        ],
        if (_recap != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.inputFillOf(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已分析第 ${_recap!.fromChapterIndex + 1}–${_recap!.toChapterIndex + 1} 章（共 ${_recap!.analyzedChapters} 章）· 模型：${_recap!.modelName}'
                  '${_recap!.fromCache ? ' · 命中本地缓存' : ' · ${(_recap!.latencyMs / 1000).toStringAsFixed(1)}s'}',
                  style: TextStyle(fontSize: 11, color: secondary),
                ),
                const Divider(height: 16),
                SelectableText(
                  _recap!.content,
                  style: const TextStyle(fontSize: 14, height: 1.65),
                ),
              ],
            ),
          ),
        ] else if (!_loadingRecap && _recapError == null) ...[
          const SizedBox(height: 24),
          Center(
            child: Text(
              '长篇连载隔了很久没看？点击上方按钮，AI 将严格基于你已读过的前文章节梳理剧情脉络与人物状态，绝不剧透后续内容。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: secondary, height: 1.5),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTermLookupTab(BuildContext context) {
    final secondary = AppTheme.textSecondaryOf(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('ai-term-input'),
                controller: _termController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _runTermLookup(),
                decoration: const InputDecoration(
                  hintText: '输入人物姓名、门派、法宝或设定词条…',
                  prefixIcon: Icon(Icons.person_search_outlined, size: 20),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('ai-term-search-btn'),
              onPressed: _loadingTerm ? null : () => _runTermLookup(),
              child: _loadingTerm
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('速查'),
            ),
          ],
        ),
        if (_knownCharacters.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '本书已识别角色（点击直查）：',
            style: TextStyle(fontSize: 12, color: secondary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in _knownCharacters.take(18))
                ActionChip(
                  label: Text(
                    c.canonicalName,
                    style: const TextStyle(fontSize: 12),
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: _loadingTerm
                      ? null
                      : () => _runTermLookup(c.canonicalName),
                ),
            ],
          ),
        ],
        if (_termError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _termError!,
              style: const TextStyle(color: AppTheme.errorColor, fontSize: 13),
            ),
          ),
        ],
        if (_termResult != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.inputFillOf(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '词条：「${_termResult!.term}」',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_termResult!.modelName} · ${(_termResult!.latencyMs / 1000).toStringAsFixed(1)}s',
                      style: TextStyle(fontSize: 11, color: secondary),
                    ),
                  ],
                ),
                if (_termResult!.matchedCharacter != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '关联角色档案：${_termResult!.matchedCharacter!.canonicalName}'
                    '${_termResult!.knownAliases.isNotEmpty ? '（别名：${_termResult!.knownAliases.join(' / ')}）' : ''}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                const Divider(height: 16),
                SelectableText(
                  _termResult!.explanation,
                  style: const TextStyle(fontSize: 14, height: 1.65),
                ),
                if (_termResult!.matchedSnippets.isNotEmpty) ...[
                  const Divider(height: 20),
                  Text(
                    '命中的前文依据（共 ${_termResult!.matchedSnippets.length} 处）：',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: secondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final snippet in _termResult!.matchedSnippets.take(4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        snippet,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ] else if (!_loadingTerm && _termError == null) ...[
          const SizedBox(height: 24),
          Center(
            child: Text(
              '在阅读正文时长按选中人名/地名点击「AI 速查」，或在此输入关键词，仅依据已读前文为你解释人物关系与设定。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: secondary, height: 1.5),
            ),
          ),
        ],
      ],
    );
  }
}
