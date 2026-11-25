import 'dart:convert';

/// 原文分配类别枚举
class AllocationKind {
  static const narration = 'narration';
  static const dialogue = 'dialogue';
  static const innerMonologue = 'inner_monologue';
  static const quotedText = 'quoted_text';

  static const values = <String>{
    narration,
    dialogue,
    innerMonologue,
    quotedText,
  };

  static bool isDirectDialogue(String kind) => kind == dialogue;
}

/// 分配决策状态
class AllocationStatus {
  static const accepted = 'accepted';
  static const blockedConflict = 'blocked_conflict';
  static const blockedMissingVoice = 'blocked_missing_voice';
  static const pendingReview = 'pending_review';
}

/// 说话人解析状态（与分配是否已接受严格分离）
class SpeakerResolution {
  static const narrator = 'narrator';
  static const resolved = 'resolved';
  static const unresolved = 'unresolved';
  static const conflict = 'conflict';
}

/// 证据类型
class EvidenceType {
  static const explicitAttribution = 'explicit_attribution';
  static const confirmedContinuation = 'confirmed_continuation';
  static const contextInference = 'context_inference';
  static const unresolved = 'unresolved';

  static const values = <String>{
    explicitAttribution,
    confirmedContinuation,
    contextInference,
    unresolved,
  };
}

/// 通用持久任务状态
class ImmersiveJobStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const retryWait = 'retry_wait';
  static const succeeded = 'succeeded';
  static const blocked = 'blocked';
  static const failed = 'failed';
  static const cancelled = 'cancelled';
}

/// 通用持久任务类型
class ImmersiveJobType {
  static const chunkAnalysis = 'chunk_analysis';
  static const identityRecheck = 'identity_recheck';
  static const summaryUpdate = 'summary_update';
  static const ttsSynthesize = 'tts_synthesize';
}

/// 音频段状态
class AudioSegmentStatus {
  static const pending = 'pending';
  static const synthesizing = 'synthesizing';
  static const ready = 'ready';
  static const blocked = 'blocked';
  static const failed = 'failed';
}

/// 书籍不可变正文版本
class BookRevision {
  final String revisionId;
  final String bookId;
  final String sourceFileHash;
  final String normalizedTextHash;
  final String parserVersion;
  final int chapterCount;
  final int createdAtMs;

  const BookRevision({
    required this.revisionId,
    required this.bookId,
    required this.sourceFileHash,
    required this.normalizedTextHash,
    this.parserVersion = 'v1',
    required this.chapterCount,
    required this.createdAtMs,
  });

  Map<String, dynamic> toRow() => {
    'revision_id': revisionId,
    'book_id': bookId,
    'source_file_hash': sourceFileHash,
    'normalized_text_hash': normalizedTextHash,
    'parser_version': parserVersion,
    'chapter_count': chapterCount,
    'created_at_ms': createdAtMs,
  };

  factory BookRevision.fromRow(Map<String, Object?> r) => BookRevision(
    revisionId: r['revision_id'] as String,
    bookId: r['book_id'] as String,
    sourceFileHash: r['source_file_hash'] as String,
    normalizedTextHash: r['normalized_text_hash'] as String,
    parserVersion: r['parser_version'] as String,
    chapterCount: r['chapter_count'] as int,
    createdAtMs: r['created_at_ms'] as int,
  );
}

/// 细粒度原文定位单元（位置唯一，重复句不共享 unit_id）
class SourceUnit {
  final String unitId;
  final String bookRevisionId;
  final String bookId;
  final int chapterIndex;
  final String chapterId;
  final int paragraphIndex;
  final int globalOrder;
  final int startOffset;
  final int endOffset;
  final String text;
  final String? parentUnitId;
  final bool active;

  const SourceUnit({
    required this.unitId,
    required this.bookRevisionId,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterId,
    required this.paragraphIndex,
    required this.globalOrder,
    required this.startOffset,
    required this.endOffset,
    required this.text,
    this.parentUnitId,
    this.active = true,
  });

  /// Unicode 码点长度（严格区分 UTF-16 code unit）
  int get codePointLength => text.runes.length;

  Map<String, dynamic> toRow() => {
    'unit_id': unitId,
    'book_revision_id': bookRevisionId,
    'book_id': bookId,
    'chapter_index': chapterIndex,
    'chapter_id': chapterId,
    'paragraph_index': paragraphIndex,
    'global_order': globalOrder,
    'start_offset': startOffset,
    'end_offset': endOffset,
    'text': text,
    'parent_unit_id': parentUnitId,
    'active': active ? 1 : 0,
  };

  factory SourceUnit.fromRow(Map<String, Object?> r) => SourceUnit(
    unitId: r['unit_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    bookId: r['book_id'] as String,
    chapterIndex: r['chapter_index'] as int,
    chapterId: r['chapter_id'] as String,
    paragraphIndex: r['paragraph_index'] as int,
    globalOrder: r['global_order'] as int,
    startOffset: r['start_offset'] as int,
    endOffset: r['end_offset'] as int,
    text: r['text'] as String,
    parentUnitId: r['parent_unit_id'] as String?,
    active: (r['active'] as int? ?? 1) == 1,
  );
}

/// 分析分块（target_units 相邻不重叠，前后文只读可重叠）
class AnalysisChunk {
  final String chunkId;
  final String bookRevisionId;
  final String bookId;
  final int chapterIndex;
  final String chapterId;
  final int chunkOrder;
  final List<String> targetUnitIds;
  final List<String> contextBeforeUnitIds;
  final List<String> contextAfterUnitIds;
  final int startGlobalOrder;
  final int endGlobalOrder;
  final String plannerVersion;
  final int estimatedTokens;

  const AnalysisChunk({
    required this.chunkId,
    required this.bookRevisionId,
    required this.bookId,
    required this.chapterIndex,
    required this.chapterId,
    required this.chunkOrder,
    required this.targetUnitIds,
    required this.contextBeforeUnitIds,
    required this.contextAfterUnitIds,
    required this.startGlobalOrder,
    required this.endGlobalOrder,
    this.plannerVersion = 'v1',
    required this.estimatedTokens,
  });

  Map<String, dynamic> toRow() => {
    'chunk_id': chunkId,
    'book_revision_id': bookRevisionId,
    'book_id': bookId,
    'chapter_index': chapterIndex,
    'chapter_id': chapterId,
    'chunk_order': chunkOrder,
    'target_unit_ids_json': jsonEncode(targetUnitIds),
    'context_before_ids_json': jsonEncode(contextBeforeUnitIds),
    'context_after_ids_json': jsonEncode(contextAfterUnitIds),
    'start_global_order': startGlobalOrder,
    'end_global_order': endGlobalOrder,
    'planner_version': plannerVersion,
    'estimated_tokens': estimatedTokens,
  };

  factory AnalysisChunk.fromRow(Map<String, Object?> r) => AnalysisChunk(
    chunkId: r['chunk_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    bookId: r['book_id'] as String,
    chapterIndex: r['chapter_index'] as int,
    chapterId: r['chapter_id'] as String,
    chunkOrder: r['chunk_order'] as int,
    targetUnitIds: (jsonDecode(r['target_unit_ids_json'] as String) as List)
        .cast<String>(),
    contextBeforeUnitIds:
        (jsonDecode(r['context_before_ids_json'] as String) as List)
            .cast<String>(),
    contextAfterUnitIds:
        (jsonDecode(r['context_after_ids_json'] as String) as List)
            .cast<String>(),
    startGlobalOrder: r['start_global_order'] as int,
    endGlobalOrder: r['end_global_order'] as int,
    plannerVersion: r['planner_version'] as String,
    estimatedTokens: r['estimated_tokens'] as int,
  );
}

/// 每本书独立的配音方案快照（不受后续修改全局 book_defaults 自动覆盖）
class BookAudioConfig {
  final String bookId;
  final List<String> selectedVoiceProfileIds;
  final String narratorVoiceProfileId;
  final bool allowVoiceReuse;
  final bool reserveNarratorForNonDialogue;
  final int castRevision;
  final int registryRevision;
  final int manifestRevision;
  final int analysisRunRevision;
  final int updatedAtMs;

  const BookAudioConfig({
    required this.bookId,
    required this.selectedVoiceProfileIds,
    required this.narratorVoiceProfileId,
    this.allowVoiceReuse = true,
    this.reserveNarratorForNonDialogue = true,
    this.castRevision = 1,
    this.registryRevision = 1,
    this.manifestRevision = 1,
    this.analysisRunRevision = 1,
    required this.updatedAtMs,
  });

  /// 传给模型系统消息的去重并集（人物候选池 + 固定旁白）
  List<String> get systemCatalogVoiceProfileIds {
    final seen = <String>{};
    final out = <String>[];
    for (final id in selectedVoiceProfileIds) {
      if (seen.add(id)) out.add(id);
    }
    if (seen.add(narratorVoiceProfileId)) {
      out.add(narratorVoiceProfileId);
    }
    return out;
  }

  BookAudioConfig copyWith({
    List<String>? selectedVoiceProfileIds,
    String? narratorVoiceProfileId,
    bool? allowVoiceReuse,
    bool? reserveNarratorForNonDialogue,
    int? castRevision,
    int? registryRevision,
    int? manifestRevision,
    int? analysisRunRevision,
    int? updatedAtMs,
  }) => BookAudioConfig(
    bookId: bookId,
    selectedVoiceProfileIds:
        selectedVoiceProfileIds ?? this.selectedVoiceProfileIds,
    narratorVoiceProfileId:
        narratorVoiceProfileId ?? this.narratorVoiceProfileId,
    allowVoiceReuse: allowVoiceReuse ?? this.allowVoiceReuse,
    reserveNarratorForNonDialogue:
        reserveNarratorForNonDialogue ?? this.reserveNarratorForNonDialogue,
    castRevision: castRevision ?? this.castRevision,
    registryRevision: registryRevision ?? this.registryRevision,
    manifestRevision: manifestRevision ?? this.manifestRevision,
    analysisRunRevision: analysisRunRevision ?? this.analysisRunRevision,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toRow() => {
    'book_id': bookId,
    'selected_voice_profile_ids_json': jsonEncode(selectedVoiceProfileIds),
    'narrator_voice_profile_id': narratorVoiceProfileId,
    'allow_voice_reuse': allowVoiceReuse ? 1 : 0,
    'reserve_narrator_for_non_dialogue': reserveNarratorForNonDialogue ? 1 : 0,
    'cast_revision': castRevision,
    'registry_revision': registryRevision,
    'manifest_revision': manifestRevision,
    'analysis_run_revision': analysisRunRevision,
    'updated_at_ms': updatedAtMs,
  };

  factory BookAudioConfig.fromRow(Map<String, Object?> r) => BookAudioConfig(
    bookId: r['book_id'] as String,
    selectedVoiceProfileIds:
        (jsonDecode(r['selected_voice_profile_ids_json'] as String) as List)
            .cast<String>(),
    narratorVoiceProfileId: r['narrator_voice_profile_id'] as String,
    allowVoiceReuse: (r['allow_voice_reuse'] as int) == 1,
    reserveNarratorForNonDialogue:
        (r['reserve_narrator_for_non_dialogue'] as int) == 1,
    castRevision: r['cast_revision'] as int,
    registryRevision: r['registry_revision'] as int,
    manifestRevision: r['manifest_revision'] as int,
    analysisRunRevision: r['analysis_run_revision'] as int,
    updatedAtMs: r['updated_at_ms'] as int,
  );
}

/// 书内永久角色档案
class ImmersiveCharacter {
  final String characterId;
  final String bookId;
  final String canonicalName;
  final String gender;
  final String firstSeenUnitId;
  final String status; // active | merged | provisional
  final String? mergedIntoCharacterId;
  final List<String> evidenceUnitIds;
  final String traitsSummary;
  final int version;
  final int updatedAtMs;

  const ImmersiveCharacter({
    required this.characterId,
    required this.bookId,
    required this.canonicalName,
    required this.gender,
    required this.firstSeenUnitId,
    this.status = 'active',
    this.mergedIntoCharacterId,
    this.evidenceUnitIds = const [],
    this.traitsSummary = '',
    this.version = 1,
    required this.updatedAtMs,
  });

  ImmersiveCharacter copyWith({
    String? canonicalName,
    String? gender,
    String? status,
    Object? mergedIntoCharacterId = _unset,
    List<String>? evidenceUnitIds,
    String? traitsSummary,
    int? version,
    int? updatedAtMs,
  }) => ImmersiveCharacter(
    characterId: characterId,
    bookId: bookId,
    canonicalName: canonicalName ?? this.canonicalName,
    gender: gender ?? this.gender,
    firstSeenUnitId: firstSeenUnitId,
    status: status ?? this.status,
    mergedIntoCharacterId: identical(mergedIntoCharacterId, _unset)
        ? this.mergedIntoCharacterId
        : mergedIntoCharacterId as String?,
    evidenceUnitIds: evidenceUnitIds ?? this.evidenceUnitIds,
    traitsSummary: traitsSummary ?? this.traitsSummary,
    version: version ?? this.version,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toRow() => {
    'character_id': characterId,
    'book_id': bookId,
    'canonical_name': canonicalName,
    'gender': gender,
    'first_seen_unit_id': firstSeenUnitId,
    'status': status,
    'merged_into_character_id': mergedIntoCharacterId,
    'evidence_unit_ids_json': jsonEncode(evidenceUnitIds),
    'traits_summary': traitsSummary,
    'version': version,
    'updated_at_ms': updatedAtMs,
  };

  factory ImmersiveCharacter.fromRow(Map<String, Object?> r) =>
      ImmersiveCharacter(
        characterId: r['character_id'] as String,
        bookId: r['book_id'] as String,
        canonicalName: r['canonical_name'] as String,
        gender: r['gender'] as String,
        firstSeenUnitId: r['first_seen_unit_id'] as String,
        status: r['status'] as String,
        mergedIntoCharacterId: r['merged_into_character_id'] as String?,
        evidenceUnitIds:
            (jsonDecode(r['evidence_unit_ids_json'] as String) as List)
                .cast<String>(),
        traitsSummary: r['traits_summary'] as String? ?? '',
        version: r['version'] as int,
        updatedAtMs: r['updated_at_ms'] as int,
      );
}

/// 作用域别名证据（禁止把“他/她/黑衣人/父亲”写成无作用域全局别名）
class AliasEvidence {
  final String aliasId;
  final String bookId;
  final String characterId;
  final String aliasText;
  final String scopeType; // global_name | relation | scene | title
  final String scopeKey;
  final String evidenceUnitId;
  final String status; // active | revoked

  const AliasEvidence({
    required this.aliasId,
    required this.bookId,
    required this.characterId,
    required this.aliasText,
    this.scopeType = 'global_name',
    this.scopeKey = '',
    required this.evidenceUnitId,
    this.status = 'active',
  });

  Map<String, dynamic> toRow() => {
    'alias_id': aliasId,
    'book_id': bookId,
    'character_id': characterId,
    'alias_text': aliasText,
    'scope_type': scopeType,
    'scope_key': scopeKey,
    'evidence_unit_id': evidenceUnitId,
    'status': status,
  };

  factory AliasEvidence.fromRow(Map<String, Object?> r) => AliasEvidence(
    aliasId: r['alias_id'] as String,
    bookId: r['book_id'] as String,
    characterId: r['character_id'] as String,
    aliasText: r['alias_text'] as String,
    scopeType: r['scope_type'] as String,
    scopeKey: r['scope_key'] as String? ?? '',
    evidenceUnitId: r['evidence_unit_id'] as String,
    status: r['status'] as String,
  );
}

/// 角色固定音色绑定（book_id + character_id 唯一）
class VoiceBinding {
  final String bookId;
  final String characterId;
  final String voiceProfileId;
  final int bindingRevision;
  final bool manualLocked;
  final int updatedAtMs;

  const VoiceBinding({
    required this.bookId,
    required this.characterId,
    required this.voiceProfileId,
    this.bindingRevision = 1,
    this.manualLocked = false,
    required this.updatedAtMs,
  });

  VoiceBinding copyWith({
    String? voiceProfileId,
    int? bindingRevision,
    bool? manualLocked,
    int? updatedAtMs,
  }) => VoiceBinding(
    bookId: bookId,
    characterId: characterId,
    voiceProfileId: voiceProfileId ?? this.voiceProfileId,
    bindingRevision: bindingRevision ?? this.bindingRevision,
    manualLocked: manualLocked ?? this.manualLocked,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toRow() => {
    'book_id': bookId,
    'character_id': characterId,
    'voice_profile_id': voiceProfileId,
    'binding_revision': bindingRevision,
    'manual_locked': manualLocked ? 1 : 0,
    'updated_at_ms': updatedAtMs,
  };

  factory VoiceBinding.fromRow(Map<String, Object?> r) => VoiceBinding(
    bookId: r['book_id'] as String,
    characterId: r['character_id'] as String,
    voiceProfileId: r['voice_profile_id'] as String,
    bindingRevision: r['binding_revision'] as int,
    manualLocked: (r['manual_locked'] as int) == 1,
    updatedAtMs: r['updated_at_ms'] as int,
  );
}

/// 可逆的身份变更审计记录（不随调试日志过期删除）
class IdentityChange {
  final String changeId;
  final String bookId;
  final String changeType; // merge | split | speaker_override | conflict_resolve
  final String oldMappingJson;
  final String newMappingJson;
  final String affectedScopeJson;
  final String operatorType; // system | user
  final List<String> evidenceUnitIds;
  final bool undone;
  final int createdAtMs;

  const IdentityChange({
    required this.changeId,
    required this.bookId,
    required this.changeType,
    required this.oldMappingJson,
    required this.newMappingJson,
    required this.affectedScopeJson,
    required this.operatorType,
    this.evidenceUnitIds = const [],
    this.undone = false,
    required this.createdAtMs,
  });

  Map<String, dynamic> toRow() => {
    'change_id': changeId,
    'book_id': bookId,
    'change_type': changeType,
    'old_mapping_json': oldMappingJson,
    'new_mapping_json': newMappingJson,
    'affected_scope_json': affectedScopeJson,
    'operator_type': operatorType,
    'evidence_unit_ids_json': jsonEncode(evidenceUnitIds),
    'undone': undone ? 1 : 0,
    'created_at_ms': createdAtMs,
  };

  factory IdentityChange.fromRow(Map<String, Object?> r) => IdentityChange(
    changeId: r['change_id'] as String,
    bookId: r['book_id'] as String,
    changeType: r['change_type'] as String,
    oldMappingJson: r['old_mapping_json'] as String,
    newMappingJson: r['new_mapping_json'] as String,
    affectedScopeJson: r['affected_scope_json'] as String,
    operatorType: r['operator_type'] as String,
    evidenceUnitIds:
        (jsonDecode(r['evidence_unit_ids_json'] as String) as List)
            .cast<String>(),
    undone: (r['undone'] as int) == 1,
    createdAtMs: r['created_at_ms'] as int,
  );
}

/// 角色记忆检查点（记录有序确认前沿）
class MemoryCheckpoint {
  final String checkpointId;
  final String bookId;
  final String bookRevisionId;
  final int confirmedChunkOrder;
  final int confirmedThroughGlobalOrder;
  final String? parentCheckpointId;
  final String contextHash;
  final List<String> activeSceneCharacterIds;
  final List<Map<String, dynamic>> recentDialogueTurns;
  final int registryRevision;
  final String chapterSummary;
  final int createdAtMs;

  const MemoryCheckpoint({
    required this.checkpointId,
    required this.bookId,
    required this.bookRevisionId,
    required this.confirmedChunkOrder,
    required this.confirmedThroughGlobalOrder,
    this.parentCheckpointId,
    required this.contextHash,
    this.activeSceneCharacterIds = const [],
    this.recentDialogueTurns = const [],
    required this.registryRevision,
    this.chapterSummary = '',
    required this.createdAtMs,
  });

  Map<String, dynamic> toRow() => {
    'checkpoint_id': checkpointId,
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'confirmed_chunk_order': confirmedChunkOrder,
    'confirmed_through_global_order': confirmedThroughGlobalOrder,
    'parent_checkpoint_id': parentCheckpointId,
    'context_hash': contextHash,
    'active_scene_character_ids_json': jsonEncode(activeSceneCharacterIds),
    'recent_dialogue_turns_json': jsonEncode(recentDialogueTurns),
    'registry_revision': registryRevision,
    'chapter_summary': chapterSummary,
    'created_at_ms': createdAtMs,
  };

  factory MemoryCheckpoint.fromRow(Map<String, Object?> r) => MemoryCheckpoint(
    checkpointId: r['checkpoint_id'] as String,
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    confirmedChunkOrder: r['confirmed_chunk_order'] as int,
    confirmedThroughGlobalOrder: r['confirmed_through_global_order'] as int,
    parentCheckpointId: r['parent_checkpoint_id'] as String?,
    contextHash: r['context_hash'] as String,
    activeSceneCharacterIds:
        (jsonDecode(r['active_scene_character_ids_json'] as String) as List)
            .cast<String>(),
    recentDialogueTurns:
        (jsonDecode(r['recent_dialogue_turns_json'] as String) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
    registryRevision: r['registry_revision'] as int,
    chapterSummary: r['chapter_summary'] as String? ?? '',
    createdAtMs: r['created_at_ms'] as int,
  );
}

/// 并发分析草稿（未经有序提交器审核，不得触发 TTS）
class AnalysisDraft {
  final String draftId;
  final String bookId;
  final String bookRevisionId;
  final String chunkId;
  final int chunkOrder;
  final int analysisRunRevision;
  final int snapshotRegistryRevision;
  final int castRevision;
  final String payloadJson;
  final String validationStatus; // valid | committed | stale | invalid
  final int createdAtMs;

  const AnalysisDraft({
    required this.draftId,
    required this.bookId,
    required this.bookRevisionId,
    required this.chunkId,
    required this.chunkOrder,
    required this.analysisRunRevision,
    required this.snapshotRegistryRevision,
    required this.castRevision,
    required this.payloadJson,
    this.validationStatus = 'valid',
    required this.createdAtMs,
  });

  Map<String, dynamic> toRow() => {
    'draft_id': draftId,
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'chunk_id': chunkId,
    'chunk_order': chunkOrder,
    'analysis_run_revision': analysisRunRevision,
    'snapshot_registry_revision': snapshotRegistryRevision,
    'cast_revision': castRevision,
    'payload_json': payloadJson,
    'validation_status': validationStatus,
    'created_at_ms': createdAtMs,
  };

  factory AnalysisDraft.fromRow(Map<String, Object?> r) => AnalysisDraft(
    draftId: r['draft_id'] as String,
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    chunkId: r['chunk_id'] as String,
    chunkOrder: r['chunk_order'] as int,
    analysisRunRevision: r['analysis_run_revision'] as int,
    snapshotRegistryRevision: r['snapshot_registry_revision'] as int,
    castRevision: r['cast_revision'] as int,
    payloadJson: r['payload_json'] as String,
    validationStatus: r['validation_status'] as String,
    createdAtMs: r['created_at_ms'] as int,
  );
}

/// 正式审核提交后的原文分配决策
class Allocation {
  final String allocationId;
  final String bookId;
  final String bookRevisionId;
  final String chunkId;
  final int chapterIndex;
  final int orderInBook;
  final List<String> sourceUnitIds;
  final String kind;
  final String? speakerRef; // narrator | char_xxx | null(unresolved)
  final String? originalSpeakerRef; // 合并前原始引用，用于可逆拆分
  final String allocationStatus;
  final String speakerResolution;
  final String? effectiveVoiceProfileId;
  final String? fallbackVoiceProfileId;
  final List<String> evidenceUnitIds;
  final String evidenceType;
  final int allocationVersion;
  final String? conflictNote;

  const Allocation({
    required this.allocationId,
    required this.bookId,
    required this.bookRevisionId,
    required this.chunkId,
    required this.chapterIndex,
    required this.orderInBook,
    required this.sourceUnitIds,
    required this.kind,
    required this.speakerRef,
    this.originalSpeakerRef,
    required this.allocationStatus,
    required this.speakerResolution,
    required this.effectiveVoiceProfileId,
    this.fallbackVoiceProfileId,
    required this.evidenceUnitIds,
    required this.evidenceType,
    this.allocationVersion = 1,
    this.conflictNote,
  });

  /// 放行 TTS 与缓冲的统一硬条件：分配已接受且实际音色明确
  bool get isReadyForTts =>
      allocationStatus == AllocationStatus.accepted &&
      effectiveVoiceProfileId != null &&
      effectiveVoiceProfileId!.isNotEmpty;

  Allocation copyWith({
    Object? speakerRef = _unset,
    Object? originalSpeakerRef = _unset,
    String? allocationStatus,
    String? speakerResolution,
    Object? effectiveVoiceProfileId = _unset,
    Object? fallbackVoiceProfileId = _unset,
    int? allocationVersion,
    Object? conflictNote = _unset,
  }) => Allocation(
    allocationId: allocationId,
    bookId: bookId,
    bookRevisionId: bookRevisionId,
    chunkId: chunkId,
    chapterIndex: chapterIndex,
    orderInBook: orderInBook,
    sourceUnitIds: sourceUnitIds,
    kind: kind,
    speakerRef: identical(speakerRef, _unset)
        ? this.speakerRef
        : speakerRef as String?,
    originalSpeakerRef: identical(originalSpeakerRef, _unset)
        ? this.originalSpeakerRef
        : originalSpeakerRef as String?,
    allocationStatus: allocationStatus ?? this.allocationStatus,
    speakerResolution: speakerResolution ?? this.speakerResolution,
    effectiveVoiceProfileId: identical(effectiveVoiceProfileId, _unset)
        ? this.effectiveVoiceProfileId
        : effectiveVoiceProfileId as String?,
    fallbackVoiceProfileId: identical(fallbackVoiceProfileId, _unset)
        ? this.fallbackVoiceProfileId
        : fallbackVoiceProfileId as String?,
    evidenceUnitIds: evidenceUnitIds,
    evidenceType: evidenceType,
    allocationVersion: allocationVersion ?? this.allocationVersion,
    conflictNote: identical(conflictNote, _unset)
        ? this.conflictNote
        : conflictNote as String?,
  );

  Map<String, dynamic> toRow() => {
    'allocation_id': allocationId,
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'chunk_id': chunkId,
    'chapter_index': chapterIndex,
    'order_in_book': orderInBook,
    'source_unit_ids_json': jsonEncode(sourceUnitIds),
    'kind': kind,
    'speaker_ref': speakerRef,
    'original_speaker_ref': originalSpeakerRef,
    'allocation_status': allocationStatus,
    'speaker_resolution': speakerResolution,
    'effective_voice_profile_id': effectiveVoiceProfileId,
    'fallback_voice_profile_id': fallbackVoiceProfileId,
    'evidence_unit_ids_json': jsonEncode(evidenceUnitIds),
    'evidence_type': evidenceType,
    'allocation_version': allocationVersion,
    'conflict_note': conflictNote,
  };

  factory Allocation.fromRow(Map<String, Object?> r) => Allocation(
    allocationId: r['allocation_id'] as String,
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    chunkId: r['chunk_id'] as String,
    chapterIndex: r['chapter_index'] as int,
    orderInBook: r['order_in_book'] as int,
    sourceUnitIds: (jsonDecode(r['source_unit_ids_json'] as String) as List)
        .cast<String>(),
    kind: r['kind'] as String,
    speakerRef: r['speaker_ref'] as String?,
    originalSpeakerRef: r['original_speaker_ref'] as String?,
    allocationStatus: r['allocation_status'] as String,
    speakerResolution: r['speaker_resolution'] as String,
    effectiveVoiceProfileId: r['effective_voice_profile_id'] as String?,
    fallbackVoiceProfileId: r['fallback_voice_profile_id'] as String?,
    evidenceUnitIds:
        (jsonDecode(r['evidence_unit_ids_json'] as String) as List)
            .cast<String>(),
    evidenceType: r['evidence_type'] as String,
    allocationVersion: r['allocation_version'] as int,
    conflictNote: r['conflict_note'] as String?,
  );
}

/// 播放清单中的单调有序合成音频段
class AudioSegment {
  final String segmentId;
  final String bookId;
  final String bookRevisionId;
  final int manifestRevision;
  final int chapterIndex;
  final String chapterId;
  final int segmentOrder;
  final List<String> sourceUnitIds;
  final int startGlobalOrder;
  final int endGlobalOrder;
  final int startParagraphIndex;
  final int startCharOffset;
  final int endParagraphIndex;
  final int endCharOffset;
  final String spokenText;
  final String kind;
  final String? speakerRef;
  final String speakerDisplayName;
  final String voiceProfileId;
  final int bindingRevision;
  final String renderSpecHash;
  final String requestKey;
  final String status;
  final String? errorMessage;

  const AudioSegment({
    required this.segmentId,
    required this.bookId,
    required this.bookRevisionId,
    required this.manifestRevision,
    required this.chapterIndex,
    required this.chapterId,
    required this.segmentOrder,
    required this.sourceUnitIds,
    required this.startGlobalOrder,
    required this.endGlobalOrder,
    required this.startParagraphIndex,
    required this.startCharOffset,
    required this.endParagraphIndex,
    required this.endCharOffset,
    required this.spokenText,
    required this.kind,
    required this.speakerRef,
    required this.speakerDisplayName,
    required this.voiceProfileId,
    required this.bindingRevision,
    required this.renderSpecHash,
    required this.requestKey,
    this.status = AudioSegmentStatus.pending,
    this.errorMessage,
  });

  int get codePointLength => spokenText.runes.length;

  AudioSegment copyWith({
    int? manifestRevision,
    int? segmentOrder,
    String? status,
    Object? errorMessage = _unset,
  }) => AudioSegment(
    segmentId: segmentId,
    bookId: bookId,
    bookRevisionId: bookRevisionId,
    manifestRevision: manifestRevision ?? this.manifestRevision,
    chapterIndex: chapterIndex,
    chapterId: chapterId,
    segmentOrder: segmentOrder ?? this.segmentOrder,
    sourceUnitIds: sourceUnitIds,
    startGlobalOrder: startGlobalOrder,
    endGlobalOrder: endGlobalOrder,
    startParagraphIndex: startParagraphIndex,
    startCharOffset: startCharOffset,
    endParagraphIndex: endParagraphIndex,
    endCharOffset: endCharOffset,
    spokenText: spokenText,
    kind: kind,
    speakerRef: speakerRef,
    speakerDisplayName: speakerDisplayName,
    voiceProfileId: voiceProfileId,
    bindingRevision: bindingRevision,
    renderSpecHash: renderSpecHash,
    requestKey: requestKey,
    status: status ?? this.status,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
  );

  Map<String, dynamic> toRow() => {
    'segment_id': segmentId,
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'manifest_revision': manifestRevision,
    'chapter_index': chapterIndex,
    'chapter_id': chapterId,
    'segment_order': segmentOrder,
    'source_unit_ids_json': jsonEncode(sourceUnitIds),
    'start_global_order': startGlobalOrder,
    'end_global_order': endGlobalOrder,
    'start_paragraph_index': startParagraphIndex,
    'start_char_offset': startCharOffset,
    'end_paragraph_index': endParagraphIndex,
    'end_char_offset': endCharOffset,
    'spoken_text': spokenText,
    'kind': kind,
    'speaker_ref': speakerRef,
    'speaker_display_name': speakerDisplayName,
    'voice_profile_id': voiceProfileId,
    'binding_revision': bindingRevision,
    'render_spec_hash': renderSpecHash,
    'request_key': requestKey,
    'status': status,
    'error_message': errorMessage,
  };

  factory AudioSegment.fromRow(Map<String, Object?> r) => AudioSegment(
    segmentId: r['segment_id'] as String,
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    manifestRevision: r['manifest_revision'] as int,
    chapterIndex: r['chapter_index'] as int,
    chapterId: r['chapter_id'] as String,
    segmentOrder: r['segment_order'] as int,
    sourceUnitIds: (jsonDecode(r['source_unit_ids_json'] as String) as List)
        .cast<String>(),
    startGlobalOrder: r['start_global_order'] as int,
    endGlobalOrder: r['end_global_order'] as int,
    startParagraphIndex: r['start_paragraph_index'] as int,
    startCharOffset: r['start_char_offset'] as int,
    endParagraphIndex: r['end_paragraph_index'] as int,
    endCharOffset: r['end_char_offset'] as int,
    spokenText: r['spoken_text'] as String,
    kind: r['kind'] as String,
    speakerRef: r['speaker_ref'] as String?,
    speakerDisplayName: r['speaker_display_name'] as String,
    voiceProfileId: r['voice_profile_id'] as String,
    bindingRevision: r['binding_revision'] as int,
    renderSpecHash: r['render_spec_hash'] as String,
    requestKey: r['request_key'] as String,
    status: r['status'] as String,
    errorMessage: r['error_message'] as String?,
  );
}

/// 不可变可复用音频文件资产元数据
class AudioAsset {
  final String requestKey;
  final String contentSha256;
  final String filePath;
  final String format;
  final int durationMs;
  final int byteSize;
  final String verifyStatus; // valid | evicting | corrupted
  final int lastAccessedAtMs;
  final int createdAtMs;

  const AudioAsset({
    required this.requestKey,
    required this.contentSha256,
    required this.filePath,
    required this.format,
    required this.durationMs,
    required this.byteSize,
    this.verifyStatus = 'valid',
    required this.lastAccessedAtMs,
    required this.createdAtMs,
  });

  double get durationSeconds => durationMs / 1000.0;

  AudioAsset copyWith({
    String? verifyStatus,
    int? lastAccessedAtMs,
  }) => AudioAsset(
    requestKey: requestKey,
    contentSha256: contentSha256,
    filePath: filePath,
    format: format,
    durationMs: durationMs,
    byteSize: byteSize,
    verifyStatus: verifyStatus ?? this.verifyStatus,
    lastAccessedAtMs: lastAccessedAtMs ?? this.lastAccessedAtMs,
    createdAtMs: createdAtMs,
  );

  Map<String, dynamic> toRow() => {
    'request_key': requestKey,
    'content_sha256': contentSha256,
    'file_path': filePath,
    'format': format,
    'duration_ms': durationMs,
    'byte_size': byteSize,
    'verify_status': verifyStatus,
    'last_accessed_at_ms': lastAccessedAtMs,
    'created_at_ms': createdAtMs,
  };

  factory AudioAsset.fromRow(Map<String, Object?> r) => AudioAsset(
    requestKey: r['request_key'] as String,
    contentSha256: r['content_sha256'] as String,
    filePath: r['file_path'] as String,
    format: r['format'] as String,
    durationMs: r['duration_ms'] as int,
    byteSize: r['byte_size'] as int,
    verifyStatus: r['verify_status'] as String,
    lastAccessedAtMs: r['last_accessed_at_ms'] as int,
    createdAtMs: r['created_at_ms'] as int,
  );
}

/// 持久化异步任务（带唯一键、租约、递增 fence 与执行代次）
class ImmersiveJob {
  final String jobKey;
  final String jobType;
  final String bookId;
  final String bookRevisionId;
  final String status;
  final int priority; // 0(P0) ~ 4(P4)
  final int attempt;
  final int executionGeneration;
  final int fence;
  final String? leaseOwner;
  final int? leaseExpiresAtMs;
  final int? notBeforeMs;
  final String? dependencyKey;
  final String inputVersion;
  final String payloadJson;
  final String? errorMessage;
  final int createdAtMs;
  final int updatedAtMs;

  const ImmersiveJob({
    required this.jobKey,
    required this.jobType,
    required this.bookId,
    required this.bookRevisionId,
    required this.status,
    required this.priority,
    this.attempt = 0,
    this.executionGeneration = 1,
    this.fence = 0,
    this.leaseOwner,
    this.leaseExpiresAtMs,
    this.notBeforeMs,
    this.dependencyKey,
    required this.inputVersion,
    required this.payloadJson,
    this.errorMessage,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  ImmersiveJob copyWith({
    String? status,
    int? priority,
    int? attempt,
    int? executionGeneration,
    int? fence,
    Object? leaseOwner = _unset,
    Object? leaseExpiresAtMs = _unset,
    Object? notBeforeMs = _unset,
    String? payloadJson,
    Object? errorMessage = _unset,
    int? updatedAtMs,
  }) => ImmersiveJob(
    jobKey: jobKey,
    jobType: jobType,
    bookId: bookId,
    bookRevisionId: bookRevisionId,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    attempt: attempt ?? this.attempt,
    executionGeneration: executionGeneration ?? this.executionGeneration,
    fence: fence ?? this.fence,
    leaseOwner: identical(leaseOwner, _unset)
        ? this.leaseOwner
        : leaseOwner as String?,
    leaseExpiresAtMs: identical(leaseExpiresAtMs, _unset)
        ? this.leaseExpiresAtMs
        : leaseExpiresAtMs as int?,
    notBeforeMs: identical(notBeforeMs, _unset)
        ? this.notBeforeMs
        : notBeforeMs as int?,
    dependencyKey: dependencyKey,
    inputVersion: inputVersion,
    payloadJson: payloadJson ?? this.payloadJson,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toRow() => {
    'job_key': jobKey,
    'job_type': jobType,
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'status': status,
    'priority': priority,
    'attempt': attempt,
    'execution_generation': executionGeneration,
    'fence': fence,
    'lease_owner': leaseOwner,
    'lease_expires_at_ms': leaseExpiresAtMs,
    'not_before_ms': notBeforeMs,
    'dependency_key': dependencyKey,
    'input_version': inputVersion,
    'payload_json': payloadJson,
    'error_message': errorMessage,
    'created_at_ms': createdAtMs,
    'updated_at_ms': updatedAtMs,
  };

  factory ImmersiveJob.fromRow(Map<String, Object?> r) => ImmersiveJob(
    jobKey: r['job_key'] as String,
    jobType: r['job_type'] as String,
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    status: r['status'] as String,
    priority: r['priority'] as int,
    attempt: r['attempt'] as int,
    executionGeneration: r['execution_generation'] as int,
    fence: r['fence'] as int,
    leaseOwner: r['lease_owner'] as String?,
    leaseExpiresAtMs: r['lease_expires_at_ms'] as int?,
    notBeforeMs: r['not_before_ms'] as int?,
    dependencyKey: r['dependency_key'] as String?,
    inputVersion: r['input_version'] as String,
    payloadJson: r['payload_json'] as String,
    errorMessage: r['error_message'] as String?,
    createdAtMs: r['created_at_ms'] as int,
    updatedAtMs: r['updated_at_ms'] as int,
  );
}

/// 持久化播放光标（支持跨重启、变更音频资产边界恢复与暂停状态保持）
class PlaybackCursor {
  final String bookId;
  final String bookRevisionId;
  final int chapterIndex;
  final String chapterId;
  final int paragraphIndex;
  final int characterOffset;
  final String? segmentId;
  final String? audioRequestKey;
  final String? audioContentSha256;
  final int positionInSegmentMs;
  final double playbackRate;
  final bool userPaused;
  final int updatedAtMs;

  const PlaybackCursor({
    required this.bookId,
    required this.bookRevisionId,
    required this.chapterIndex,
    required this.chapterId,
    required this.paragraphIndex,
    required this.characterOffset,
    this.segmentId,
    this.audioRequestKey,
    this.audioContentSha256,
    this.positionInSegmentMs = 0,
    this.playbackRate = 1.0,
    this.userPaused = false,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toRow() => {
    'book_id': bookId,
    'book_revision_id': bookRevisionId,
    'chapter_index': chapterIndex,
    'chapter_id': chapterId,
    'paragraph_index': paragraphIndex,
    'character_offset': characterOffset,
    'segment_id': segmentId,
    'audio_request_key': audioRequestKey,
    'audio_content_sha256': audioContentSha256,
    'position_in_segment_ms': positionInSegmentMs,
    'playback_rate': playbackRate,
    'user_paused': userPaused ? 1 : 0,
    'updated_at_ms': updatedAtMs,
  };

  factory PlaybackCursor.fromRow(Map<String, Object?> r) => PlaybackCursor(
    bookId: r['book_id'] as String,
    bookRevisionId: r['book_revision_id'] as String,
    chapterIndex: r['chapter_index'] as int,
    chapterId: r['chapter_id'] as String,
    paragraphIndex: r['paragraph_index'] as int,
    characterOffset: r['character_offset'] as int,
    segmentId: r['segment_id'] as String?,
    audioRequestKey: r['audio_request_key'] as String?,
    audioContentSha256: r['audio_content_sha256'] as String?,
    positionInSegmentMs: r['position_in_segment_ms'] as int? ?? 0,
    playbackRate: (r['playback_rate'] as num?)?.toDouble() ?? 1.0,
    userPaused: (r['user_paused'] as int? ?? 0) == 1,
    updatedAtMs: r['updated_at_ms'] as int,
  );
}

/// 管线实时可观测状态（严格区分候选分析、身份确认、音频生成与连续可播秒数）
class PipelineStatus {
  final String phaseLabel; // 给普通用户看的可理解描述
  final bool isPreparingPrefix;
  final int prefixCompletedChunks;
  final int prefixTotalChunks;
  final int candidateAnalyzedChunks;
  final int confirmedChunks;
  final int totalPlannedChunks;
  final int readyAudioSegments;
  final int totalManifestSegments;
  final double continuousReadySeconds;
  final double estimatedPendingSeconds;
  final int activeTextRequests;
  final int activeTtsRequests;
  final int pendingTtsJobs;
  final int unresolvedDialogueCount;
  final int blockedConflictCount;
  final int cacheUsedBytes;
  final int cacheHits;
  final int cacheMisses;
  final int? firstAudioLatencyMs;
  final int stallCount;
  final String? blockingReason;
  final String? lastError;

  const PipelineStatus({
    this.phaseLabel = '待启动',
    this.isPreparingPrefix = false,
    this.prefixCompletedChunks = 0,
    this.prefixTotalChunks = 0,
    this.candidateAnalyzedChunks = 0,
    this.confirmedChunks = 0,
    this.totalPlannedChunks = 0,
    this.readyAudioSegments = 0,
    this.totalManifestSegments = 0,
    this.continuousReadySeconds = 0,
    this.estimatedPendingSeconds = 0,
    this.activeTextRequests = 0,
    this.activeTtsRequests = 0,
    this.pendingTtsJobs = 0,
    this.unresolvedDialogueCount = 0,
    this.blockedConflictCount = 0,
    this.cacheUsedBytes = 0,
    this.cacheHits = 0,
    this.cacheMisses = 0,
    this.firstAudioLatencyMs,
    this.stallCount = 0,
    this.blockingReason,
    this.lastError,
  });
}

const _unset = Object();
