import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import 'context_builder.dart';
import 'immersive_database.dart';
import 'text_model_adapter.dart';

/// 草稿业务语义校验异常（区别于 JSON 语法错误）
class DraftSemanticValidationException implements Exception {
  final String message;
  const DraftSemanticValidationException(this.message);

  @override
  String toString() => message;
}

/// 单个分块有序提交结果
class ChunkCommitOutcome {
  final bool committed;
  final String? chunkId;
  final int confirmedChunkOrder;
  final List<Allocation> allocations;
  final int conflictsDetected;
  final int unresolvedCount;
  final String? blockingReason;

  const ChunkCommitOutcome({
    required this.committed,
    this.chunkId,
    required this.confirmedChunkOrder,
    this.allocations = const [],
    this.conflictsDetected = 0,
    this.unresolvedCount = 0,
    this.blockingReason,
  });
}

/// 局部身份复核执行回调（由调度器在保留复核席位上执行，避免事务内等待网络）
typedef IdentityRecheckInvoker =
    Future<StructuredModelResponse?> Function({
      required String systemMessage,
      required String userMessage,
    });

/// 角色记忆、音色选择与有序身份确认协调器（单书单写者）
class IdentityCoordinator {
  /// 禁止作为无证据全书唯一名称自动归并的代词、泛称与关系称谓
  static const nonUniqueGenericLabels = <String>{
    '他',
    '她',
    '它',
    '我',
    '你',
    '您',
    '他们',
    '她们',
    '众人',
    '黑衣人',
    '白衣人',
    '蒙面人',
    '神秘人',
    '陌生人',
    '路人',
    '老人',
    '老者',
    '老头',
    '老妇',
    '男子',
    '女子',
    '青年',
    '少年',
    '少女',
    '小孩',
    '孩子',
    '侍卫',
    '士兵',
    '掌柜',
    '小二',
    '大夫',
    '医生',
    '皇帝',
    '国王',
    '长老',
    '掌门',
    '父亲',
    '母亲',
    '爸爸',
    '妈妈',
    '爷爷',
    '奶奶',
    '师父',
    '师傅',
    '师兄',
    '师姐',
    '师弟',
    '师妹',
    '哥哥',
    '姐姐',
    '弟弟',
    '妹妹',
    '儿子',
    '女儿',
    '未知',
    '未知人',
    '不明人物',
  };

  final ImmersiveStateStore _store;
  final Map<String, Future<void>> _bookCommitSerial = {};
  final DateTime Function() _now;

  IdentityCoordinator(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// 判断名称是否为泛指描述或关系称谓（不能无证据直接合并）
  static bool isGenericNonUniqueLabel(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return true;
    if (nonUniqueGenericLabels.contains(trimmed)) return true;
    // 形如“黑衣人甲”“某男子”“一个老人”也归为非唯一泛称
    if (RegExp(r'^(一个|一名|某|那名|那个|暗处|未知)').hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  /// 校验候选草稿是否满足全部原文覆盖与引用不变量（第 8.4 节）
  static void validateDraftAgainstChunk({
    required Map<String, dynamic> payload,
    required AnalysisChunk chunk,
    required Map<String, SourceUnit> unitById,
    required Set<String> knownCharacterIds,
  }) {
    ImmersiveNativeSchemas.validateChunkAnalysisPayload(payload);

    final targetIds = chunk.targetUnitIds;
    final targetIndexMap = <String, int>{
      for (var i = 0; i < targetIds.length; i++) targetIds[i]: i,
    };
    final allowedEvidenceIds = <String>{
      ...chunk.contextBeforeUnitIds,
      ...chunk.targetUnitIds,
      ...chunk.contextAfterUnitIds,
    };

    // 校验局部新角色声明唯一性
    final proposals = (payload['new_character_proposals'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final declaredLocalRefs = <String>{};
    for (final p in proposals) {
      final lref = p['local_ref'] as String;
      if (!lref.startsWith('local:new_')) {
        throw DraftSemanticValidationException('新角色局部引用必须以 local:new_ 开头：$lref');
      }
      if (!declaredLocalRefs.add(lref)) {
        throw DraftSemanticValidationException('重复声明局部角色引用：$lref');
      }
      for (final ev in (p['evidence_unit_ids'] as List).cast<String>()) {
        if (!allowedEvidenceIds.contains(ev)) {
          throw DraftSemanticValidationException('新角色证据越界：$ev');
        }
      }
    }

    final assignments = (payload['assignments'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final seenTargets = <String>{};
    var expectedNextTargetIdx = 0;
    final reconstructedBuffer = StringBuffer();

    for (var i = 0; i < assignments.length; i++) {
      final a = assignments[i];
      final uIds = (a['source_unit_ids'] as List).cast<String>();
      if (uIds.isEmpty) {
        throw DraftSemanticValidationException('assignments[$i].source_unit_ids 不能为空');
      }
      for (var j = 0; j < uIds.length; j++) {
        final uid = uIds[j];
        final pos = targetIndexMap[uid];
        if (pos == null) {
          throw DraftSemanticValidationException(
            'assignments[$i] 包含非目标单元或只读上下文单元：$uid',
          );
        }
        if (!seenTargets.add(uid)) {
          throw DraftSemanticValidationException('目标单元重复分配：$uid');
        }
        if (pos != expectedNextTargetIdx) {
          throw DraftSemanticValidationException(
            '目标单元乱序、跳段或非连续合并：期望 ${targetIds[expectedNextTargetIdx]}，实际 $uid',
          );
        }
        expectedNextTargetIdx++;
        reconstructedBuffer.write(unitById[uid]?.text ?? '');
      }

      for (final ev in (a['evidence_unit_ids'] as List).cast<String>()) {
        if (!allowedEvidenceIds.contains(ev)) {
          throw DraftSemanticValidationException('assignments[$i] 证据 unit 越界：$ev');
        }
      }

      final kind = a['kind'] as String;
      final speakerRef = a['speaker_ref'] as String?;
      if (AllocationKind.isDirectDialogue(kind)) {
        if (speakerRef != null &&
            speakerRef != 'narrator' &&
            !knownCharacterIds.contains(speakerRef) &&
            !declaredLocalRefs.contains(speakerRef)) {
          throw DraftSemanticValidationException(
            'assignments[$i] 引用了不存在的角色 ID：$speakerRef',
          );
        }
      }
    }

    if (expectedNextTargetIdx != targetIds.length) {
      throw DraftSemanticValidationException(
        '目标单元覆盖不完整：共 ${targetIds.length} 条，实际覆盖 $expectedNextTargetIdx 条',
      );
    }

    // 拼接还原原文必须与目标规范化原文逐字一致
    final expectedText = targetIds.map((id) => unitById[id]?.text ?? '').join();
    if (reconstructedBuffer.toString() != expectedText) {
      throw const DraftSemanticValidationException('分配结果拼回原文与目标规范原文不一致');
    }
  }

  /// 按序尝试消费连续身份前沿之后已就绪的草稿（单书串行，保证并发乱序草稿严格按顺序提交）
  /// 支持 minWindowChunkOrder：空降长书中间章节时最多回溯 5 章，不阻塞在更早未加载章节上
  Future<List<ChunkCommitOutcome>> drainOrderedCommits({
    required String bookId,
    required String bookRevisionId,
    required ImmersiveConfig config,
    IdentityRecheckInvoker? recheckInvoker,
    int minWindowChunkOrder = 0,
  }) async {
    final prev = _bookCommitSerial[bookId] ?? Future<void>.value();
    final completer = Completer<List<ChunkCommitOutcome>>();
    late final Future<void> run;
    run = prev
        .catchError((_) {})
        .then((_) async {
          try {
            final outcomes = await _drainInternal(
              bookId: bookId,
              bookRevisionId: bookRevisionId,
              config: config,
              recheckInvoker: recheckInvoker,
              minWindowChunkOrder: minWindowChunkOrder,
            );
            completer.complete(outcomes);
          } catch (e, s) {
            completer.completeError(e, s);
          }
        })
        .whenComplete(() {
          if (identical(_bookCommitSerial[bookId], run)) {
            _bookCommitSerial.remove(bookId);
          }
        });
    _bookCommitSerial[bookId] = run;
    return completer.future;
  }

  Future<List<ChunkCommitOutcome>> _drainInternal({
    required String bookId,
    required String bookRevisionId,
    required ImmersiveConfig config,
    IdentityRecheckInvoker? recheckInvoker,
    int minWindowChunkOrder = 0,
  }) async {
    final outcomes = <ChunkCommitOutcome>[];
    final chunks = await _store.getAnalysisChunks(bookRevisionId);
    if (chunks.isEmpty) return outcomes;
    final sortedChunks = [...chunks]
      ..sort((a, b) => a.chunkOrder.compareTo(b.chunkOrder));
    final allUnits = await _store.getSourceUnits(bookRevisionId);
    final unitById = {for (final u in allUnits) u.unitId: u};

    while (true) {
      final bookCfg = await _store.getBookAudioConfig(bookId);
      if (bookCfg == null) break;
      final latestCp = await _store.getLatestCheckpoint(bookId, bookRevisionId);
      final currentConfirmedOrder = latestCp?.confirmedChunkOrder ?? -1;
      final floorOrder = math.max(currentConfirmedOrder + 1, minWindowChunkOrder);
      AnalysisChunk? nextChunk;
      for (final c in sortedChunks) {
        if (c.chunkOrder >= floorOrder) {
          nextChunk = c;
          break;
        }
      }
      if (nextChunk == null) break;

      final draft = await _store.getDraftForChunk(
        bookRevisionId,
        nextChunk.chunkId,
        bookCfg.analysisRunRevision,
      );
      if (draft == null || draft.validationStatus != 'valid') {
        break;
      }

      final outcome = await _commitSingleDraft(
        bookId: bookId,
        bookRevisionId: bookRevisionId,
        bookCfg: bookCfg,
        config: config,
        chunk: nextChunk,
        draft: draft,
        latestCp: latestCp,
        unitById: unitById,
        recheckInvoker: recheckInvoker,
      );
      outcomes.add(outcome);
      if (!outcome.committed) break;
    }

    return outcomes;
  }

  Future<ChunkCommitOutcome> _commitSingleDraft({
    required String bookId,
    required String bookRevisionId,
    required BookAudioConfig bookCfg,
    required ImmersiveConfig config,
    required AnalysisChunk chunk,
    required AnalysisDraft draft,
    required MemoryCheckpoint? latestCp,
    required Map<String, SourceUnit> unitById,
    IdentityRecheckInvoker? recheckInvoker,
  }) async {
    final nowMs = _now().millisecondsSinceEpoch;
    final existingChars = await _store.getCharacters(bookId);
    final existingAliases = await _store.getAliasEvidences(bookId);
    final existingBindings = await _store.getVoiceBindings(bookId);

    final activeCharsById = <String, ImmersiveCharacter>{
      for (final c in existingChars) c.characterId: c,
    };
    final bindingByCharId = <String, VoiceBinding>{
      for (final b in existingBindings) b.characterId: b,
    };

    // 跟踪合并重定向：已合并角色解析到目标主角色 ID
    String followRedirect(String charId) {
      var cur = charId;
      final visited = <String>{};
      while (visited.add(cur)) {
        final ch = activeCharsById[cur];
        if (ch != null &&
            ch.status == 'merged' &&
            ch.mergedIntoCharacterId != null) {
          cur = ch.mergedIntoCharacterId!;
        } else {
          break;
        }
      }
      return cur;
    }

    final payload = Map<String, dynamic>.from(
      jsonDecode(draft.payloadJson) as Map,
    );

    // 二次校验原文覆盖与引用完整性
    try {
      validateDraftAgainstChunk(
        payload: payload,
        chunk: chunk,
        unitById: unitById,
        knownCharacterIds: activeCharsById.keys.toSet(),
      );
    } on DraftSemanticValidationException catch (e) {
      await _store.updateDraftStatus(draft.draftId, 'invalid');
      return ChunkCommitOutcome(
        committed: false,
        chunkId: chunk.chunkId,
        confirmedChunkOrder: latestCp?.confirmedChunkOrder ?? -1,
        blockingReason: '草稿校验失败：${e.message}',
      );
    }

    // 检查音色使用统计，用于优先给常同场对话的角色分配不同声音
    final voiceUsageCount = <String, int>{};
    for (final vb in existingBindings) {
      voiceUsageCount[vb.voiceProfileId] =
          (voiceUsageCount[vb.voiceProfileId] ?? 0) + 1;
    }
    final sceneVoiceIds = <String>{
      for (final cid in latestCp?.activeSceneCharacterIds ?? const <String>[])
        if (bindingByCharId[followRedirect(cid)] != null)
          bindingByCharId[followRedirect(cid)]!.voiceProfileId,
    };

    final newOrUpdatedChars = <ImmersiveCharacter>[];
    final newAliases = <AliasEvidence>[];
    final newBindings = <VoiceBinding>[];
    var nextRegistryRev = bookCfg.registryRevision;
    var charCounter = existingChars.length;

    // 映射 local:new_* -> 正式 character_id 或 null(复核后转未确定)
    final localRefToCharId = <String, String?>{};
    final conflictsByCharId = <String, String>{};
    var missingVoiceBlockReason = '';

    final proposals = (payload['new_character_proposals'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    for (final prop in proposals) {
      final localRef = prop['local_ref'] as String;
      final rawName = (prop['display_name'] as String).trim();
      final gender = prop['gender'] as String;
      final suggestedVoice = prop['suggested_voice_profile_id'] as String?;
      final evUnits = (prop['evidence_unit_ids'] as List).cast<String>();

      // 查询全书完整角色与别名索引（避免并发草稿旧快照重复创建同名角色）
      final candidates = _findNameOrAliasCandidates(
        rawName: rawName,
        allCharacters: [...existingChars, ...newOrUpdatedChars],
        allAliases: [...existingAliases, ...newAliases],
      );

      String? matchedExistingId;
      if (candidates.isNotEmpty && !isGenericNonUniqueLabel(rawName)) {
        // 精确同名命中：若仅有 1 个完全同名且非泛称角色，直接归一或由旧快照触发复核
        final exactNameMatches = candidates
            .where((c) => c.canonicalName == rawName && c.status == 'active')
            .toList();
        if (exactNameMatches.length == 1 &&
            draft.snapshotRegistryRevision == bookCfg.registryRevision) {
          matchedExistingId = exactNameMatches.first.characterId;
        } else if (recheckInvoker != null) {
          // 事务外执行局部身份复核（最多 max_identity_rechecks 次）
          final disputedUnits = evUnits
              .map((id) => unitById[id])
              .whereType<SourceUnit>()
              .toList();
          final surrounding = [
            ...chunk.contextBeforeUnitIds,
            ...chunk.targetUnitIds,
          ].map((id) => unitById[id]).whereType<SourceUnit>().toList();

          final decision = await _runBoundedIdentityRecheck(
            config: config,
            bookCfg: bookCfg,
            disputedUnits: disputedUnits.isEmpty
                ? [unitById[chunk.targetUnitIds.first]!]
                : disputedUnits,
            surroundingContext: surrounding,
            candidateCharacters: candidates,
            bindingByCharId: bindingByCharId,
            disputeReason:
                '新提议角色「$rawName」与已有角色索引存在候选匹配（草稿快照版本=${draft.snapshotRegistryRevision}，当前版本=${bookCfg.registryRevision}）',
            recheckInvoker: recheckInvoker,
          );

          if (decision != null) {
            final dType = decision['decision'] as String;
            final resolvedId = decision['resolved_character_id'] as String?;
            if (dType == 'resolved_existing' &&
                resolvedId != null &&
                activeCharsById.containsKey(resolvedId)) {
              matchedExistingId = followRedirect(resolvedId);
            } else if (dType == 'unresolved') {
              localRefToCharId[localRef] = null;
              continue;
            } else if (dType == 'conflict') {
              final targetId =
                  resolvedId != null && activeCharsById.containsKey(resolvedId)
                  ? followRedirect(resolvedId)
                  : candidates.first.characterId;
              conflictsByCharId[targetId] =
                  '复核发现角色身份冲突：${decision['reason'] ?? rawName}';
              matchedExistingId = targetId;
            }
          }
        } else if (exactNameMatches.length == 1) {
          // 离线/无复核回调但旧快照中已有精确同名非泛称角色时，复用既有 ID 防止双角色竞争（I06）
          matchedExistingId = exactNameMatches.first.characterId;
        }
      }

      if (matchedExistingId != null) {
        localRefToCharId[localRef] = matchedExistingId;
        continue;
      }

      // 确属新角色：分配全书永久 character_id，并按策略选择固定音色
      charCounter++;
      final newCharId = 'char_${charCounter.toString().padLeft(4, '0')}';
      final firstSeen = evUnits.isNotEmpty
          ? evUnits.first
          : chunk.targetUnitIds.first;
      final isUnnamed = rawName.isEmpty || isGenericNonUniqueLabel(rawName);
      final displayName = rawName.isEmpty ? '暂存人物#$charCounter' : rawName;

      final voicePick = _selectVoiceForNewCharacter(
        config: config,
        bookCfg: bookCfg,
        characterGender: gender,
        suggestedVoiceProfileId: suggestedVoice,
        voiceUsageCount: voiceUsageCount,
        sceneVoiceIds: sceneVoiceIds,
      );

      final newChar = ImmersiveCharacter(
        characterId: newCharId,
        bookId: bookId,
        canonicalName: displayName,
        gender: gender,
        firstSeenUnitId: firstSeen,
        status: isUnnamed ? 'provisional' : 'active',
        evidenceUnitIds: evUnits.isEmpty ? [firstSeen] : evUnits,
        traitsSummary: '',
        version: 1,
        updatedAtMs: nowMs,
      );
      newOrUpdatedChars.add(newChar);
      activeCharsById[newCharId] = newChar;
      nextRegistryRev++;

      if (voicePick.voiceProfileId != null) {
        final vb = VoiceBinding(
          bookId: bookId,
          characterId: newCharId,
          voiceProfileId: voicePick.voiceProfileId!,
          bindingRevision: 1,
          manualLocked: false,
          updatedAtMs: nowMs,
        );
        newBindings.add(vb);
        bindingByCharId[newCharId] = vb;
        voiceUsageCount[vb.voiceProfileId] =
            (voiceUsageCount[vb.voiceProfileId] ?? 0) + 1;
        sceneVoiceIds.add(vb.voiceProfileId);
      } else if (voicePick.blockingReason != null) {
        missingVoiceBlockReason = voicePick.blockingReason!;
      }

      localRefToCharId[localRef] = newCharId;
    }

    // 处理 identity_link_proposals（同人关联证据：无冲突则建别名/合并，双方异声冲突则暂停受影响范围）
    final linkProposals = (payload['identity_link_proposals'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    for (final link in linkProposals) {
      final fromRaw = link['from_ref'] as String;
      final toRaw = link['to_ref'] as String;
      final evIds = (link['evidence_unit_ids'] as List).cast<String>();
      final fromId = fromRaw.startsWith('local:new_')
          ? localRefToCharId[fromRaw]
          : (activeCharsById.containsKey(fromRaw) ? followRedirect(fromRaw) : null);
      final toId = toRaw.startsWith('local:new_')
          ? localRefToCharId[toRaw]
          : (activeCharsById.containsKey(toRaw) ? followRedirect(toRaw) : null);
      if (fromId == null || toId == null || fromId == toId) continue;

      final vbFrom = bindingByCharId[fromId];
      final vbTo = bindingByCharId[toId];
      if (vbFrom != null &&
          vbTo != null &&
          vbFrom.voiceProfileId != vbTo.voiceProfileId) {
        // 双方异声冲突：按 identity_conflict_policy=pause_affected_range 阻塞，不静默覆盖（I09）
        final note =
            '角色 ${activeCharsById[fromId]?.canonicalName ?? fromId} 与 ${activeCharsById[toId]?.canonicalName ?? toId} '
            '存在同人证据但绑定了不同音色（${vbFrom.voiceProfileId} vs ${vbTo.voiceProfileId}），请手动确认合并音色';
        conflictsByCharId[fromId] = note;
        conflictsByCharId[toId] = note;
      } else if (evIds.isNotEmpty) {
        // 双方同声或仅一方有声：在存在明确原文证据时归并，将别名归属到主角色
        final keepId = vbTo != null ? toId : fromId;
        final dropId = keepId == toId ? fromId : toId;
        final dropChar = activeCharsById[dropId];
        if (dropChar != null && !isGenericNonUniqueLabel(dropChar.canonicalName)) {
          newAliases.add(
            AliasEvidence(
              aliasId: 'al_${bookId}_${dropId}_$nowMs',
              bookId: bookId,
              characterId: keepId,
              aliasText: dropChar.canonicalName,
              scopeType: 'global_name',
              evidenceUnitId: evIds.first,
            ),
          );
        }
        if (dropChar != null) {
          final merged = dropChar.copyWith(
            status: 'merged',
            mergedIntoCharacterId: keepId,
            version: dropChar.version + 1,
            updatedAtMs: nowMs,
          );
          newOrUpdatedChars.add(merged);
          activeCharsById[dropId] = merged;
          nextRegistryRev++;
        }
      }
    }

    // 生成正式 Allocation 列表
    final rawAssignments = (payload['assignments'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final allocations = <Allocation>[];
    final recentTurns = List<Map<String, dynamic>>.from(
      latestCp?.recentDialogueTurns ?? const [],
    );
    final updatedSceneIds = <String>{
      ...?latestCp?.activeSceneCharacterIds,
    };
    var conflictCount = 0;
    var unresolvedCount = 0;
    String? chunkBlockingReason = missingVoiceBlockReason.isNotEmpty
        ? missingVoiceBlockReason
        : null;

    for (var i = 0; i < rawAssignments.length; i++) {
      final a = rawAssignments[i];
      final uIds = (a['source_unit_ids'] as List).cast<String>();
      final kind = a['kind'] as String;
      final rawSpeaker = a['speaker_ref'] as String?;
      final evIds = (a['evidence_unit_ids'] as List).cast<String>();
      final evType = a['evidence_type'] as String;
      final firstUnit = unitById[uIds.first]!;
      final allocId = 'alloc_${chunk.chunkId}_$i';

      // 1. 非直接发言（narration / inner_monologue / quoted_text）固定旁白（停用/缺失时自动按同性别兜底）
      if (!AllocationKind.isDirectDialogue(kind)) {
        final narratorFb = config.resolveVoiceProfileWithFallback(
          preferredVoiceProfileId: bookCfg.narratorVoiceProfileId,
          isNarrator: true,
        );
        final narratorAvailable = narratorFb != null;
        final effectiveNarratorVoiceId =
            narratorFb?.resolution.voice.voiceProfileId;
        allocations.add(
          Allocation(
            allocationId: allocId,
            bookId: bookId,
            bookRevisionId: bookRevisionId,
            chunkId: chunk.chunkId,
            chapterIndex: chunk.chapterIndex,
            orderInBook: firstUnit.globalOrder,
            sourceUnitIds: uIds,
            kind: kind,
            speakerRef: 'narrator',
            originalSpeakerRef: 'narrator',
            allocationStatus: narratorAvailable
                ? AllocationStatus.accepted
                : AllocationStatus.blockedMissingVoice,
            speakerResolution: SpeakerResolution.narrator,
            effectiveVoiceProfileId: effectiveNarratorVoiceId,
            evidenceUnitIds: evIds,
            evidenceType: evType,
            conflictNote: narratorAvailable ? null : '当前无可用启用的旁白音色，请在设置中启用音色',
          ),
        );
        if (!narratorAvailable) {
          chunkBlockingReason ??= '当前无可用启用的旁白音色，等待配置修复';
        }
        continue;
      }

      // 2. 直接对白（dialogue）：解析正式角色 ID
      String? resolvedCharId;
      if (rawSpeaker != null && rawSpeaker.startsWith('local:new_')) {
        resolvedCharId = localRefToCharId[rawSpeaker];
      } else if (rawSpeaker != null &&
          rawSpeaker != 'narrator' &&
          activeCharsById.containsKey(rawSpeaker)) {
        resolvedCharId = followRedirect(rawSpeaker);
      }

      // 若无法确定说话人，尝试最多 max_identity_rechecks 次局部复核
      if (resolvedCharId == null && recheckInvoker != null) {
        final disputed = uIds
            .map((id) => unitById[id])
            .whereType<SourceUnit>()
            .toList();
        final surrounding = [
          ...chunk.contextBeforeUnitIds,
          ...chunk.targetUnitIds,
          ...chunk.contextAfterUnitIds,
        ].map((id) => unitById[id]).whereType<SourceUnit>().toList();
        final sceneCandidates = activeCharsById.values
            .where((c) => c.status == 'active')
            .take(12)
            .toList();
        if (sceneCandidates.isNotEmpty) {
          final decision = await _runBoundedIdentityRecheck(
            config: config,
            bookCfg: bookCfg,
            disputedUnits: disputed,
            surroundingContext: surrounding,
            candidateCharacters: sceneCandidates,
            bindingByCharId: bindingByCharId,
            disputeReason: '直接对白缺少明确说话人，需复核确认是否属于在场角色',
            recheckInvoker: recheckInvoker,
          );
          if (decision != null &&
              decision['decision'] == 'resolved_existing' &&
              decision['resolved_character_id'] is String &&
              activeCharsById.containsKey(decision['resolved_character_id'])) {
            resolvedCharId = followRedirect(
              decision['resolved_character_id'] as String,
            );
          }
        }
      }

      // 2a. 复核后仍未确定说话人：按 unresolved_dialogue_policy=narrator_fallback_after_review 兜底
      // 保留 speaker_resolution=unresolved、speaker_ref=null、kind=dialogue，不创建“未知人”
      if (resolvedCharId == null) {
        unresolvedCount++;
        final narratorRes = config.resolveVoiceProfile(
          bookCfg.narratorVoiceProfileId,
        );
        final ok = narratorRes != null && narratorRes.isEffectivelyEnabled;
        allocations.add(
          Allocation(
            allocationId: allocId,
            bookId: bookId,
            bookRevisionId: bookRevisionId,
            chunkId: chunk.chunkId,
            chapterIndex: chunk.chapterIndex,
            orderInBook: firstUnit.globalOrder,
            sourceUnitIds: uIds,
            kind: AllocationKind.dialogue,
            speakerRef: null,
            originalSpeakerRef: null,
            allocationStatus: ok
                ? AllocationStatus.accepted
                : AllocationStatus.blockedMissingVoice,
            speakerResolution: SpeakerResolution.unresolved,
            effectiveVoiceProfileId: ok ? bookCfg.narratorVoiceProfileId : null,
            fallbackVoiceProfileId: bookCfg.narratorVoiceProfileId,
            evidenceUnitIds: evIds,
            evidenceType: EvidenceType.unresolved,
            conflictNote: ok ? null : '未确定对白兜底旁白音色不可用',
          ),
        );
        continue;
      }

      // 2b. 检查是否处于身份冲突阻塞
      if (conflictsByCharId.containsKey(resolvedCharId)) {
        conflictCount++;
        chunkBlockingReason ??= conflictsByCharId[resolvedCharId];
        allocations.add(
          Allocation(
            allocationId: allocId,
            bookId: bookId,
            bookRevisionId: bookRevisionId,
            chunkId: chunk.chunkId,
            chapterIndex: chunk.chapterIndex,
            orderInBook: firstUnit.globalOrder,
            sourceUnitIds: uIds,
            kind: AllocationKind.dialogue,
            speakerRef: resolvedCharId,
            originalSpeakerRef: resolvedCharId,
            allocationStatus: AllocationStatus.blockedConflict,
            speakerResolution: SpeakerResolution.conflict,
            effectiveVoiceProfileId: bindingByCharId[resolvedCharId]?.voiceProfileId,
            evidenceUnitIds: evIds,
            evidenceType: evType,
            conflictNote: conflictsByCharId[resolvedCharId],
          ),
        );
        continue;
      }

      // 2c. 正常已确认角色：严格复用其唯一固定音色绑定
      final binding = bindingByCharId[resolvedCharId];
      final voiceRes = binding == null
          ? null
          : config.resolveVoiceProfile(binding.voiceProfileId);
      final voiceReady = voiceRes != null && voiceRes.isEffectivelyEnabled;

      allocations.add(
        Allocation(
          allocationId: allocId,
          bookId: bookId,
          bookRevisionId: bookRevisionId,
          chunkId: chunk.chunkId,
          chapterIndex: chunk.chapterIndex,
          orderInBook: firstUnit.globalOrder,
          sourceUnitIds: uIds,
          kind: AllocationKind.dialogue,
          speakerRef: resolvedCharId,
          originalSpeakerRef: resolvedCharId,
          allocationStatus: voiceReady
              ? AllocationStatus.accepted
              : AllocationStatus.blockedMissingVoice,
          speakerResolution: SpeakerResolution.resolved,
          effectiveVoiceProfileId: voiceReady ? binding!.voiceProfileId : null,
          evidenceUnitIds: evIds,
          evidenceType: evType,
          conflictNote: voiceReady
              ? null
              : '角色 ${activeCharsById[resolvedCharId]?.canonicalName ?? resolvedCharId} 缺少有效音色配置，等待修复',
        ),
      );

      if (!voiceReady) {
        chunkBlockingReason ??=
            '角色 ${activeCharsById[resolvedCharId]?.canonicalName ?? resolvedCharId} 的绑定音色不可用或缺失，等待配置修复';
      }

      updatedSceneIds.add(resolvedCharId);
      final excerpt = uIds.map((id) => unitById[id]?.text ?? '').join();
      recentTurns.add({
        'speaker_ref': resolvedCharId,
        'speaker_name': activeCharsById[resolvedCharId]?.canonicalName ?? '',
        'excerpt': excerpt.length > 60 ? excerpt.substring(0, 60) : excerpt,
      });
    }

    // 保留最近 N 轮已确认对白
    final maxTurns = config.analysisPipeline.recentDialogueTurns;
    final trimmedTurns = recentTurns.length > maxTurns
        ? recentTurns.sublist(recentTurns.length - maxTurns)
        : recentTurns;

    final contextHash = sha256
        .convert(
          utf8.encode(
            canonicalJsonEncode({
              'parent': latestCp?.contextHash ?? 'root',
              'chunk_id': chunk.chunkId,
              'registry_revision': nextRegistryRev,
              'scene': updatedSceneIds.toList()..sort(),
              'turns': trimmedTurns,
            }),
          ),
        )
        .toString();

    final newCp = MemoryCheckpoint(
      checkpointId: 'cp_${bookRevisionId}_${chunk.chunkOrder}',
      bookId: bookId,
      bookRevisionId: bookRevisionId,
      confirmedChunkOrder: chunk.chunkOrder,
      confirmedThroughGlobalOrder: chunk.endGlobalOrder,
      parentCheckpointId: latestCp?.checkpointId,
      contextHash: contextHash,
      activeSceneCharacterIds: updatedSceneIds.take(16).toList(),
      recentDialogueTurns: trimmedTurns,
      registryRevision: nextRegistryRev,
      chapterSummary: latestCp?.chapterSummary ?? '',
      createdAtMs: nowMs,
    );

    // 短事务原子提交（若期间前沿或版本被更改，拒绝盲写返回 false 供外层重跑）
    final committed = await _store.commitChunkConfirmationAtomically(
      bookId: bookId,
      bookRevisionId: bookRevisionId,
      expectedConfirmedChunkOrder: latestCp?.confirmedChunkOrder ?? -1,
      expectedRegistryRevision: bookCfg.registryRevision,
      draftId: draft.draftId,
      newOrUpdatedCharacters: newOrUpdatedChars,
      newAliases: newAliases,
      newBindings: newBindings,
      allocations: allocations,
      newCheckpoint: newCp,
      newRegistryRevision: nextRegistryRev,
    );

    return ChunkCommitOutcome(
      committed: committed,
      chunkId: chunk.chunkId,
      confirmedChunkOrder: committed
          ? chunk.chunkOrder
          : (latestCp?.confirmedChunkOrder ?? -1),
      allocations: committed ? allocations : const [],
      conflictsDetected: conflictCount,
      unresolvedCount: unresolvedCount,
      blockingReason: chunkBlockingReason,
    );
  }

  /// 为新角色按本书配音策略挑选合法音色（严禁越界使用未勾选音色或私自调用旁白）
  ({String? voiceProfileId, String? blockingReason}) _selectVoiceForNewCharacter({
    required ImmersiveConfig config,
    required BookAudioConfig bookCfg,
    required String characterGender,
    required String? suggestedVoiceProfileId,
    required Map<String, int> voiceUsageCount,
    required Set<String> sceneVoiceIds,
  }) {
    final candidateIds = bookCfg.selectedVoiceProfileIds.where((id) {
      if (bookCfg.reserveNarratorForNonDialogue &&
          id == bookCfg.narratorVoiceProfileId) {
        return false;
      }
      final res = config.resolveVoiceProfile(id);
      return res != null && res.isEffectivelyEnabled;
    }).toList();

    if (candidateIds.isEmpty) {
      return (voiceProfileId: null, blockingReason: '本书人物候选音色池为空或全部禁用，请先勾选可用音色');
    }

    // 过滤合规性别候选池
    List<String> byGender(String g) => candidateIds
        .where((id) => config.resolveVoiceProfile(id)?.voice.gender == g)
        .toList();

    List<String> allowedPool;
    if (characterGender == 'male' || characterGender == 'female') {
      final exact = byGender(characterGender);
      if (exact.isNotEmpty) {
        allowedPool = exact;
      } else {
        // known_gender_no_match_policy = prefer_neutral_else_require_selection
        // 绝不自动为已明确性别的角色配相反性别声音
        final neutral = byGender('neutral');
        if (neutral.isNotEmpty) {
          allowedPool = neutral;
        } else {
          return (
            voiceProfileId: null,
            blockingReason:
                '人物性别已明确为 $characterGender，但本书未勾选对应性别或中性候选音色，请手动勾选音色或为角色指定声音',
          );
        }
      }
    } else {
      // unknown / neutral: prefer_neutral_then_selected（且角色自身性别仍保留 unknown）
      final neutral = byGender('neutral');
      allowedPool = neutral.isNotEmpty ? neutral : candidateIds;
    }

    // 若不允许复用则进一步排除已使用音色
    var pool = bookCfg.allowVoiceReuse
        ? allowedPool
        : allowedPool.where((id) => (voiceUsageCount[id] ?? 0) == 0).toList();
    if (pool.isEmpty) {
      return (voiceProfileId: null, blockingReason: '当前配置禁止音色复用且可用音色已分配完毕');
    }

    // 优先采用模型在合法候选池内的建议（前提是未与同场角色强碰撞，或池内无其他未碰撞音色）
    if (suggestedVoiceProfileId != null &&
        pool.contains(suggestedVoiceProfileId)) {
      final nonScene = pool.where((id) => !sceneVoiceIds.contains(id)).toList();
      if (nonScene.isEmpty || nonScene.contains(suggestedVoiceProfileId)) {
        return (voiceProfileId: suggestedVoiceProfileId, blockingReason: null);
      }
    }

    // 优先选择未在当前同场对话出现且全书使用次数最少的音色
    pool.sort((a, b) {
      final aScene = sceneVoiceIds.contains(a) ? 1 : 0;
      final bScene = sceneVoiceIds.contains(b) ? 1 : 0;
      if (aScene != bScene) return aScene.compareTo(bScene);
      return (voiceUsageCount[a] ?? 0).compareTo(voiceUsageCount[b] ?? 0);
    });
    return (voiceProfileId: pool.first, blockingReason: null);
  }

  List<ImmersiveCharacter> _findNameOrAliasCandidates({
    required String rawName,
    required List<ImmersiveCharacter> allCharacters,
    required List<AliasEvidence> allAliases,
  }) {
    if (rawName.isEmpty) return const [];
    final baseName = rawName.split(RegExp(r'[（(]')).first.trim();
    final hits = <String, ImmersiveCharacter>{};
    final byId = {for (final c in allCharacters) c.characterId: c};

    for (final c in allCharacters) {
      if (c.status == 'merged') continue;
      final cBase = c.canonicalName.split(RegExp(r'[（(]')).first.trim();
      if (c.canonicalName == rawName ||
          (baseName.isNotEmpty && !isGenericNonUniqueLabel(baseName) && cBase == baseName)) {
        hits[c.characterId] = c;
      }
    }
    for (final a in allAliases) {
      if (a.status != 'active') continue;
      if (a.aliasText == rawName) {
        final ch = byId[a.characterId];
        if (ch != null && ch.status != 'merged') {
          hits[ch.characterId] = ch;
        }
      }
    }
    return hits.values.toList();
  }

  Future<Map<String, dynamic>?> _runBoundedIdentityRecheck({
    required ImmersiveConfig config,
    required BookAudioConfig bookCfg,
    required List<SourceUnit> disputedUnits,
    required List<SourceUnit> surroundingContext,
    required List<ImmersiveCharacter> candidateCharacters,
    required Map<String, VoiceBinding> bindingByCharId,
    required String disputeReason,
    required IdentityRecheckInvoker recheckInvoker,
  }) async {
    final maxChecks = math.max(0, config.analysisPipeline.maxIdentityRechecks);
    if (maxChecks == 0) return null;

    final prompt = ContextBuilder.buildIdentityRecheckPrompt(
      config: config,
      bookConfig: bookCfg,
      disputedUnits: disputedUnits,
      surroundingContext: surroundingContext,
      candidateCharacters: candidateCharacters,
      bindingByCharId: bindingByCharId,
      disputeReason: disputeReason,
    );

    Map<String, dynamic>? last;
    for (var attempt = 0; attempt < maxChecks; attempt++) {
      final resp = await recheckInvoker(
        systemMessage: prompt.systemMessage,
        userMessage: prompt.userMessage,
      );
      if (resp == null) break;
      last = resp.data;
      if (resp.data['decision'] != 'unresolved') {
        return last;
      }
    }
    return last;
  }

  /// 手动修改角色固定音色（递增 binding_revision，不影响无关角色缓存）
  Future<VoiceBinding> setCharacterVoice({
    required String bookId,
    required String characterId,
    required String voiceProfileId,
    bool manualLocked = true,
  }) async {
    final nowMs = _now().millisecondsSinceEpoch;
    final existing = await _store.getVoiceBinding(bookId, characterId);
    final updated = VoiceBinding(
      bookId: bookId,
      characterId: characterId,
      voiceProfileId: voiceProfileId,
      bindingRevision: (existing?.bindingRevision ?? 0) + 1,
      manualLocked: manualLocked,
      updatedAtMs: nowMs,
    );
    await _store.upsertVoiceBinding(updated);

    // 同步更新该角色已存在 Allocation 的有效音色（仅受影响角色）
    final rev = await _store.getLatestBookRevision(bookId);
    if (rev != null) {
      final allocs = await _store.getAllocations(bookId, rev.revisionId);
      final changed = <Allocation>[];
      for (final a in allocs) {
        if (a.speakerRef == characterId) {
          changed.add(
            a.copyWith(
              allocationStatus: AllocationStatus.accepted,
              effectiveVoiceProfileId: voiceProfileId,
              allocationVersion: a.allocationVersion + 1,
              conflictNote: null,
            ),
          );
        }
      }
      if (changed.isNotEmpty) {
        await _store.saveAllocations(changed);
      }
    }
    return updated;
  }

  /// 可逆合并两个角色：保留原角色与 Allocation 原始来源，并记录 IdentityChange 审计日志
  Future<IdentityChange> mergeCharacters({
    required String bookId,
    required String sourceCharacterId,
    required String targetCharacterId,
    required String resolvedVoiceProfileId,
    String operatorType = 'user',
    List<String> evidenceUnitIds = const [],
  }) async {
    if (sourceCharacterId == targetCharacterId) {
      throw ArgumentError('不能将角色合并到自身');
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final chars = await _store.getCharacters(bookId);
    final source = chars.firstWhere((c) => c.characterId == sourceCharacterId);
    final target = chars.firstWhere((c) => c.characterId == targetCharacterId);
    final oldTargetBinding = await _store.getVoiceBinding(
      bookId,
      targetCharacterId,
    );
    final oldSourceBinding = await _store.getVoiceBinding(
      bookId,
      sourceCharacterId,
    );

    // 不硬删除 source，仅标为 merged 并记录重定向
    await _store.saveCharacter(
      source.copyWith(
        status: 'merged',
        mergedIntoCharacterId: targetCharacterId,
        version: source.version + 1,
        updatedAtMs: nowMs,
      ),
    );
    if (!isGenericNonUniqueLabel(source.canonicalName)) {
      await _store.saveAliasEvidence(
        AliasEvidence(
          aliasId: 'al_merge_${sourceCharacterId}_$nowMs',
          bookId: bookId,
          characterId: targetCharacterId,
          aliasText: source.canonicalName,
          scopeType: 'global_name',
          evidenceUnitId: evidenceUnitIds.isNotEmpty
              ? evidenceUnitIds.first
              : source.firstSeenUnitId,
        ),
      );
    }

    final newBinding = VoiceBinding(
      bookId: bookId,
      characterId: targetCharacterId,
      voiceProfileId: resolvedVoiceProfileId,
      bindingRevision: (oldTargetBinding?.bindingRevision ?? 0) + 1,
      manualLocked: operatorType == 'user',
      updatedAtMs: nowMs,
    );
    await _store.upsertVoiceBinding(newBinding);

    final affectedAllocationIds = <String>[];
    final rev = await _store.getLatestBookRevision(bookId);
    if (rev != null) {
      final allocs = await _store.getAllocations(bookId, rev.revisionId);
      final updated = <Allocation>[];
      for (final a in allocs) {
        if (a.speakerRef == sourceCharacterId ||
            a.speakerRef == targetCharacterId) {
          affectedAllocationIds.add(a.allocationId);
          updated.add(
            a.copyWith(
              speakerRef: targetCharacterId,
              originalSpeakerRef: a.originalSpeakerRef ?? a.speakerRef,
              allocationStatus: AllocationStatus.accepted,
              speakerResolution: SpeakerResolution.resolved,
              effectiveVoiceProfileId: resolvedVoiceProfileId,
              allocationVersion: a.allocationVersion + 1,
              conflictNote: null,
            ),
          );
        }
      }
      if (updated.isNotEmpty) {
        await _store.saveAllocations(updated);
      }
    }

    final bookCfg = await _store.getBookAudioConfig(bookId);
    if (bookCfg != null) {
      await _store.saveBookAudioConfig(
        bookCfg.copyWith(
          registryRevision: bookCfg.registryRevision + 1,
          updatedAtMs: nowMs,
        ),
      );
    }

    final change = IdentityChange(
      changeId: 'chg_${bookId}_$nowMs',
      bookId: bookId,
      changeType: 'merge',
      oldMappingJson: jsonEncode({
        'source_character_id': sourceCharacterId,
        'target_character_id': targetCharacterId,
        'source_old_status': source.status,
        'source_old_voice': oldSourceBinding?.voiceProfileId,
        'target_old_voice': oldTargetBinding?.voiceProfileId,
      }),
      newMappingJson: jsonEncode({
        'merged_into': targetCharacterId,
        'target_new_voice': resolvedVoiceProfileId,
      }),
      affectedScopeJson: jsonEncode({
        'allocation_ids': affectedAllocationIds,
        'target_name': target.canonicalName,
      }),
      operatorType: operatorType,
      evidenceUnitIds: evidenceUnitIds,
      undone: false,
      createdAtMs: nowMs,
    );
    await _store.saveIdentityChange(change);
    return change;
  }

  /// 撤销一次身份合并（拆分还原：恢复原角色与受影响 Allocation，不重解析全书）
  Future<bool> undoIdentityChange({
    required String bookId,
    required String changeId,
  }) async {
    final changes = await _store.getIdentityChanges(bookId);
    final idx = changes.indexWhere((c) => c.changeId == changeId);
    if (idx == -1) return false;
    final change = changes[idx];
    if (change.undone || change.changeType != 'merge') return false;

    final nowMs = _now().millisecondsSinceEpoch;
    final oldMap = Map<String, dynamic>.from(
      jsonDecode(change.oldMappingJson) as Map,
    );
    final scopeMap = Map<String, dynamic>.from(
      jsonDecode(change.affectedScopeJson) as Map,
    );

    final sourceId = oldMap['source_character_id'] as String;
    final targetId = oldMap['target_character_id'] as String;
    final sourceOldStatus = oldMap['source_old_status'] as String? ?? 'active';
    final sourceOldVoice = oldMap['source_old_voice'] as String?;
    final targetOldVoice = oldMap['target_old_voice'] as String?;
    final affectedIds = ((scopeMap['allocation_ids'] as List?) ?? const [])
        .cast<String>()
        .toSet();

    final chars = await _store.getCharacters(bookId);
    for (final c in chars) {
      if (c.characterId == sourceId) {
        await _store.saveCharacter(
          c.copyWith(
            status: sourceOldStatus,
            mergedIntoCharacterId: null,
            version: c.version + 1,
            updatedAtMs: nowMs,
          ),
        );
      }
    }

    if (targetOldVoice != null) {
      final curTarget = await _store.getVoiceBinding(bookId, targetId);
      await _store.upsertVoiceBinding(
        VoiceBinding(
          bookId: bookId,
          characterId: targetId,
          voiceProfileId: targetOldVoice,
          bindingRevision: (curTarget?.bindingRevision ?? 0) + 1,
          manualLocked: curTarget?.manualLocked ?? false,
          updatedAtMs: nowMs,
        ),
      );
    }
    if (sourceOldVoice != null) {
      final curSource = await _store.getVoiceBinding(bookId, sourceId);
      await _store.upsertVoiceBinding(
        VoiceBinding(
          bookId: bookId,
          characterId: sourceId,
          voiceProfileId: sourceOldVoice,
          bindingRevision: (curSource?.bindingRevision ?? 0) + 1,
          manualLocked: curSource?.manualLocked ?? false,
          updatedAtMs: nowMs,
        ),
      );
    }

    final rev = await _store.getLatestBookRevision(bookId);
    if (rev != null) {
      final allocs = await _store.getAllocations(bookId, rev.revisionId);
      final restored = <Allocation>[];
      for (final a in allocs) {
        if (affectedIds.contains(a.allocationId) &&
            a.originalSpeakerRef == sourceId) {
          restored.add(
            a.copyWith(
              speakerRef: sourceId,
              effectiveVoiceProfileId: sourceOldVoice,
              allocationVersion: a.allocationVersion + 1,
            ),
          );
        } else if (affectedIds.contains(a.allocationId) &&
            a.originalSpeakerRef == targetId &&
            targetOldVoice != null) {
          restored.add(
            a.copyWith(
              speakerRef: targetId,
              effectiveVoiceProfileId: targetOldVoice,
              allocationVersion: a.allocationVersion + 1,
            ),
          );
        }
      }
      if (restored.isNotEmpty) {
        await _store.saveAllocations(restored);
      }
    }

    await _store.saveIdentityChange(
      IdentityChange(
        changeId: change.changeId,
        bookId: change.bookId,
        changeType: change.changeType,
        oldMappingJson: change.oldMappingJson,
        newMappingJson: change.newMappingJson,
        affectedScopeJson: change.affectedScopeJson,
        operatorType: change.operatorType,
        evidenceUnitIds: change.evidenceUnitIds,
        undone: true,
        createdAtMs: change.createdAtMs,
      ),
    );
    return true;
  }

  /// 手动纠正单条 Allocation 的说话人（例如解决 unresolved 对白）
  Future<Allocation?> correctAllocationSpeaker({
    required String bookId,
    required String bookRevisionId,
    required String allocationId,
    required String newSpeakerRef,
    required ImmersiveConfig config,
  }) async {
    final bookCfg = await _store.getBookAudioConfig(bookId);
    if (bookCfg == null) return null;
    final allocs = await _store.getAllocations(bookId, bookRevisionId);
    final idx = allocs.indexWhere((a) => a.allocationId == allocationId);
    if (idx == -1) return null;
    final old = allocs[idx];

    String? effectiveVoice;
    String resolution;
    if (newSpeakerRef == 'narrator') {
      effectiveVoice = bookCfg.narratorVoiceProfileId;
      resolution = SpeakerResolution.narrator;
    } else {
      final vb = await _store.getVoiceBinding(bookId, newSpeakerRef);
      effectiveVoice = vb?.voiceProfileId;
      resolution = SpeakerResolution.resolved;
    }

    final voiceRes = effectiveVoice == null
        ? null
        : config.resolveVoiceProfile(effectiveVoice);
    final ok = voiceRes != null && voiceRes.isEffectivelyEnabled;

    final updated = old.copyWith(
      speakerRef: newSpeakerRef,
      originalSpeakerRef: old.originalSpeakerRef ?? old.speakerRef,
      allocationStatus: ok
          ? AllocationStatus.accepted
          : AllocationStatus.blockedMissingVoice,
      speakerResolution: resolution,
      effectiveVoiceProfileId: ok ? effectiveVoice : null,
      fallbackVoiceProfileId: null,
      allocationVersion: old.allocationVersion + 1,
      conflictNote: ok ? null : '所选角色音色不可用',
    );
    await _store.saveAllocations([updated]);
    return updated;
  }
}
