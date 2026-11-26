import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../models/reading_position.dart';
import '../../services/reader_platform.dart';
import '../../widgets/reader_modal.dart';
import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import '../services/immersive_playback_coordinator.dart';

/// 本书角色档案、音色绑定修改、角色合并/撤销与待确认片段修正面板
class ImmersiveCharactersSheet extends StatefulWidget {
  final String bookId;
  final ImmersivePlaybackCoordinator? coordinator;
  final void Function(int chapterIndex, ReadingPosition position)? onJumpToSource;

  const ImmersiveCharactersSheet({
    super.key,
    required this.bookId,
    this.coordinator,
    this.onJumpToSource,
  });

  static Future<void> show(
    BuildContext context, {
    required String bookId,
    ImmersivePlaybackCoordinator? coordinator,
    void Function(int chapterIndex, ReadingPosition position)? onJumpToSource,
  }) {
    final sheet = ImmersiveCharactersSheet(
      bookId: bookId,
      coordinator: coordinator,
      onJumpToSource: onJumpToSource,
    );
    if (ReaderPlatform.isDesktop) {
      return showReaderModal<void>(
        context: context,
        backgroundColor: AppTheme.surfaceOf(context),
        heightFactor: 0.84,
        desktopWidth: 700,
        builder: (_) => sheet,
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.82,
        child: sheet,
      ),
    );
  }

  @override
  State<ImmersiveCharactersSheet> createState() =>
      _ImmersiveCharactersSheetState();
}

class _ImmersiveCharactersSheetState extends State<ImmersiveCharactersSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  ImmersivePlaybackCoordinator get _coord =>
      widget.coordinator ?? ImmersivePlaybackCoordinator();

  List<ImmersiveCharacter> _characters = const [];
  Map<String, VoiceBinding> _bindings = const {};
  List<AliasEvidence> _aliases = const [];
  List<IdentityChange> _changes = const [];
  List<Allocation> _attentionAllocations = const [];
  Map<String, SourceUnit> _unitById = const {};
  bool _loading = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final store = _coord.stateStore;
    if (store == null) {
      setState(() => _loading = false);
      return;
    }
    final chars = await store.getCharacters(widget.bookId);
    final bindings = await store.getVoiceBindings(widget.bookId);
    final aliases = await store.getAliasEvidences(widget.bookId);
    final changes = await store.getIdentityChanges(widget.bookId);
    final rev = await store.getLatestBookRevision(widget.bookId);
    final allocs = rev == null
        ? const <Allocation>[]
        : await store.getAllocations(widget.bookId, rev.revisionId);
    final units = rev == null
        ? const <SourceUnit>[]
        : await store.getSourceUnits(rev.revisionId);

    if (!mounted) return;
    setState(() {
      _characters = chars;
      _bindings = {for (final b in bindings) b.characterId: b};
      _aliases = aliases;
      _changes = changes;
      _unitById = {for (final u in units) u.unitId: u};
      _attentionAllocations = allocs
          .where(
            (a) =>
                a.speakerResolution == SpeakerResolution.unresolved ||
                a.allocationStatus == AllocationStatus.blockedConflict ||
                a.allocationStatus == AllocationStatus.blockedMissingVoice,
          )
          .toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _coord.config;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.people_alt, color: AppTheme.primaryColor),
              const SizedBox(width: 8),
              const Text(
                '本书角色档案与身份修正',
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
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _notice!,
              style: const TextStyle(fontSize: 12, color: AppTheme.primaryColor),
            ),
          ),
        TabBar(
          controller: _tabs,
          labelColor: AppTheme.primaryColor,
          tabs: [
            Tab(text: '角色列表 (${_characters.where((c) => c.status != 'merged').length})'),
            Tab(text: '待确认/冲突 (${_attentionAllocations.length})'),
          ],
        ),
        Expanded(
          child: _loading || cfg == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildCharactersTab(cfg),
                    _buildAttentionTab(cfg),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildCharactersTab(ImmersiveConfig cfg) {
    final activeChars = _characters.where((c) => c.status != 'merged').toList();
    if (activeChars.isEmpty) {
      return const Center(child: Text('暂未识别出对话角色，开始听书后将按原文顺序建档。'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final ch in activeChars) ...[
          _buildCharacterCard(ch, cfg, activeChars),
          const SizedBox(height: 8),
        ],
        if (_changes.isNotEmpty) ...[
          const Divider(height: 24),
          const Text(
            '身份变更审计记录（可撤销合并）',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 8),
          for (final chg in _changes)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${chg.changeType == 'merge' ? '角色合并' : chg.changeType}${chg.undone ? '（已撤销）' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              subtitle: Text(
                chg.changeId,
                style: const TextStyle(fontSize: 10),
              ),
              trailing: chg.undone || chg.changeType != 'merge'
                  ? null
                  : TextButton(
                      onPressed: () async {
                        final ok = await _coord.undoIdentityChange(
                          bookId: widget.bookId,
                          changeId: chg.changeId,
                        );
                        if (ok) {
                          _notice = '已撤销合并并恢复原角色与音色引用';
                          await _reload();
                        }
                      },
                      child: const Text('撤销合并'),
                    ),
            ),
        ],
      ],
    );
  }

  Widget _buildCharacterCard(
    ImmersiveCharacter ch,
    ImmersiveConfig cfg,
    List<ImmersiveCharacter> activeChars,
  ) {
    final binding = _bindings[ch.characterId];
    final voiceRes = binding == null
        ? null
        : cfg.resolveVoiceProfile(binding.voiceProfileId);
    final charAliases = _aliases
        .where((a) => a.characterId == ch.characterId && a.status == 'active')
        .map((a) => a.aliasText)
        .toList();
    final firstUnit = _unitById[ch.firstSeenUnitId];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  ch.canonicalName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                Chip(
                  label: Text(ch.gender, style: const TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                if (binding?.manualLocked == true) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: AppTheme.primaryColor,
                  ),
                ],
                const Spacer(),
                if (firstUnit != null && widget.onJumpToSource != null)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onJumpToSource!(
                        firstUnit.chapterIndex,
                        ReadingPosition(
                          chapterId: firstUnit.chapterId,
                          paragraphIndex: firstUnit.paragraphIndex,
                          characterOffset: firstUnit.startOffset,
                        ),
                      );
                    },
                    child: const Text('原文证据', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            if (charAliases.isNotEmpty)
              Text(
                '别名：${charAliases.join('、')}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            if (firstUnit != null)
              Text(
                '首次出现：${firstUnit.text}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: voiceRes?.voice.voiceProfileId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '固定音色',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final v in cfg.allVoiceProfiles)
                        DropdownMenuItem(
                          value: v.voice.voiceProfileId,
                          child: Text(
                            '${v.voice.displayName} [${v.voice.gender}]',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await _coord.setCharacterVoice(
                        bookId: widget.bookId,
                        characterId: ch.characterId,
                        voiceProfileId: v,
                        manualLocked: true,
                      );
                      _notice = '已锁定 ${ch.canonicalName} 的音色并仅重建受影响音频';
                      await _reload();
                    },
                  ),
                ),
                if (activeChars.length >= 2) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _showMergeDialog(ch, activeChars, cfg),
                    child: const Text('合并', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttentionTab(ImmersiveConfig cfg) {
    if (_attentionAllocations.isEmpty) {
      return const Center(child: Text('当前没有待确认对白或身份冲突片段。'));
    }
    final activeChars = _characters.where((c) => c.status != 'merged').toList();

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _attentionAllocations.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, idx) {
        final alloc = _attentionAllocations[idx];
        final excerpt = alloc.sourceUnitIds
            .map((id) => _unitById[id]?.text ?? '')
            .join();
        final firstUnit = alloc.sourceUnitIds.isEmpty
            ? null
            : _unitById[alloc.sourceUnitIds.first];

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Chip(
                      label: Text(
                        alloc.allocationStatus == AllocationStatus.blockedConflict
                            ? '身份冲突'
                            : alloc.speakerResolution ==
                                    SpeakerResolution.unresolved
                                ? '待确认对白（旁白兜底）'
                                : '音色缺失',
                        style: const TextStyle(fontSize: 10),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    const Spacer(),
                    if (firstUnit != null && widget.onJumpToSource != null)
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onJumpToSource!(
                            firstUnit.chapterIndex,
                            ReadingPosition(
                              chapterId: firstUnit.chapterId,
                              paragraphIndex: firstUnit.paragraphIndex,
                              characterOffset: firstUnit.startOffset,
                            ),
                          );
                        },
                        child: const Text('定位原文'),
                      ),
                  ],
                ),
                Text(excerpt, style: const TextStyle(fontSize: 13)),
                if (alloc.conflictNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      alloc.conflictNote!,
                      style: const TextStyle(fontSize: 11, color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(
                    labelText: '指派说话人',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'narrator',
                      child: Text('改为旁白'),
                    ),
                    for (final c in activeChars)
                      DropdownMenuItem(
                        value: c.characterId,
                        child: Text(c.canonicalName),
                      ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await _coord.correctAllocationSpeaker(
                      bookId: widget.bookId,
                      allocationId: alloc.allocationId,
                      newSpeakerRef: v,
                    );
                    _notice = '已更新该句说话人并重新规划局部音频';
                    await _reload();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showMergeDialog(
    ImmersiveCharacter source,
    List<ImmersiveCharacter> activeChars,
    ImmersiveConfig cfg,
  ) async {
    final others = activeChars
        .where((c) => c.characterId != source.characterId)
        .toList();
    if (others.isEmpty) return;
    var targetId = others.first.characterId;
    var chosenVoice =
        _bindings[targetId]?.voiceProfileId ??
        _bindings[source.characterId]?.voiceProfileId ??
        cfg.allVoiceProfiles.first.voice.voiceProfileId;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('将「${source.canonicalName}」合并到已有角色'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: targetId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '合并目标主角色'),
                items: [
                  for (final o in others)
                    DropdownMenuItem(
                      value: o.characterId,
                      child: Text(o.canonicalName),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setDlg(() {
                    targetId = v;
                    chosenVoice =
                        _bindings[v]?.voiceProfileId ?? chosenVoice;
                  });
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: chosenVoice,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '合并后使用的音色'),
                items: [
                  for (final v in cfg.allVoiceProfiles)
                    DropdownMenuItem(
                      value: v.voice.voiceProfileId,
                      child: Text(v.voice.displayName),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setDlg(() => chosenVoice = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _coord.resolveIdentityMerge(
                  bookId: widget.bookId,
                  sourceCharacterId: source.characterId,
                  targetCharacterId: targetId,
                  resolvedVoiceProfileId: chosenVoice,
                );
                _notice = '已完成角色合并（可随时在底部审计列表中撤销）';
                await _reload();
              },
              child: const Text('确认合并'),
            ),
          ],
        ),
      ),
    );
  }
}
