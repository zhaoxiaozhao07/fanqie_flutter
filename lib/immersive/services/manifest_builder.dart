import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';
import 'source_normalizer.dart';
import 'tts_provider_adapter.dart';

/// 播放清单规划器：从已确认 Allocation 按原文顺序生成 AudioSegment
/// 严格执行：不跨角色 ID 合并、不跨章节合并、双限制独立检查、支持播放中原文边界平滑切换
class ManifestBuilder {
  /// 从有序已确认 Allocation 生成完整或切换点之后的 AudioSegment 列表
  /// 当已编排音色被停用、删除或运行时失效时，自动按性别寻找可用兜底音色（男对男、女对女）
  static List<AudioSegment> buildSegments({
    required String bookId,
    required String bookRevisionId,
    required int manifestRevision,
    required ImmersiveConfig config,
    required List<Allocation> orderedAllocations,
    required Map<String, SourceUnit> unitById,
    required Map<String, ImmersiveCharacter> characterById,
    required Map<String, VoiceBinding> bindingByCharId,
    required Map<String, AudioAsset> existingAssetsByRequestKey,
    int? startupAnchorGlobalOrder,
    List<AudioSegment> lockedPrefixSegments = const [],
    Iterable<String> preferredPoolIds = const [],
    Set<String> failedVoiceProfileIds = const {},
    void Function(String notice)? onVoiceFallback,
  }) {
    final result = <AudioSegment>[...lockedPrefixSegments];
    final lockedBoundaryOrder = lockedPrefixSegments.isEmpty
        ? -1
        : lockedPrefixSegments.last.endGlobalOrder;
    // 针对同一书籍同一次清单构建，缓存“失效音色+性别 -> 同性兜底音色”映射，保持同角色音色全程稳定一致
    final fallbackCache = <String, VoiceFallbackResolution?>{};
    final reportedFallbacks = <String>{};

    VoiceFallbackResolution? resolveEffectiveVoice(Allocation alloc) {
      final rawId = alloc.effectiveVoiceProfileId ?? '';
      final isNarrator =
          alloc.speakerRef == null ||
          alloc.speakerRef == 'narrator' ||
          !AllocationKind.isDirectDialogue(alloc.kind);
      final charGender =
          (alloc.speakerRef != null && alloc.speakerRef != 'narrator')
          ? (characterById[alloc.speakerRef!]?.gender ?? 'unknown')
          : 'unknown';
      final cacheKey = '$rawId|$charGender|$isNarrator';
      return fallbackCache.putIfAbsent(cacheKey, () {
        final fb = config.resolveVoiceProfileWithFallback(
          preferredVoiceProfileId: rawId,
          gender: charGender,
          preferredPoolIds: preferredPoolIds,
          excludeProfileIds: failedVoiceProfileIds,
          isNarrator: isNarrator,
        );
        if (fb != null &&
            fb.didFallback &&
            fb.fallbackReason != null &&
            reportedFallbacks.add(cacheKey)) {
          onVoiceFallback?.call(fb.fallbackReason!);
        }
        return fb;
      });
    }

    // 仅处理切换点之后的 Allocation，禁止新合成单元跨越切换点（满足 A22）
    final pendingAllocs = orderedAllocations.where((a) {
      if (a.sourceUnitIds.isEmpty) return false;
      final firstOrder = unitById[a.sourceUnitIds.first]?.globalOrder ?? -1;
      return firstOrder > lockedBoundaryOrder;
    }).toList();

    var segOrder = result.length;
    var i = 0;
    var isFirstAfterAnchor = startupAnchorGlobalOrder != null;

    while (i < pendingAllocs.length) {
      final first = pendingAllocs[i];

      // 遇到阻塞或未接受的 Allocation：仍产出占位 blocked 段以保证播放器不跳过缺失台词
      if (!first.isReadyForTts) {
        final units = first.sourceUnitIds
            .map((id) => unitById[id])
            .whereType<SourceUnit>()
            .toList();
        if (units.isNotEmpty) {
          final text = SourceNormalizer.normalizeForSpeech(
            units.map((u) => u.text).join(),
          );
          result.add(
            AudioSegment(
              segmentId:
                  'seg_${bookRevisionId}_m${manifestRevision}_$segOrder',
              bookId: bookId,
              bookRevisionId: bookRevisionId,
              manifestRevision: manifestRevision,
              chapterIndex: first.chapterIndex,
              chapterId: units.first.chapterId,
              segmentOrder: segOrder++,
              sourceUnitIds: units.map((u) => u.unitId).toList(),
              startGlobalOrder: units.first.globalOrder,
              endGlobalOrder: units.last.globalOrder,
              startParagraphIndex: units.first.paragraphIndex,
              startCharOffset: units.first.startOffset,
              endParagraphIndex: units.last.paragraphIndex,
              endCharOffset: units.last.endOffset,
              spokenText: text,
              kind: first.kind,
              speakerRef: first.speakerRef,
              speakerDisplayName: _speakerDisplayName(first, characterById),
              voiceProfileId: first.effectiveVoiceProfileId ?? '',
              bindingRevision: _bindingRev(first, bindingByCharId),
              renderSpecHash: 'blocked',
              requestKey: 'blocked_${first.allocationId}',
              status: AudioSegmentStatus.blocked,
              errorMessage: first.conflictNote ?? '等待身份或音色配置修复',
            ),
          );
        }
        i++;
        continue;
      }

      final unitsFirst = first.sourceUnitIds
          .map((id) => unitById[id])
          .whereType<SourceUnit>()
          .toList();
      if (unitsFirst.isEmpty) {
        i++;
        continue;
      }

      final fallbackRes = resolveEffectiveVoice(first);
      final resolution = fallbackRes?.resolution;
      final voiceProfileId =
          resolution?.voice.voiceProfileId ??
          (first.effectiveVoiceProfileId ?? '');

      // 仅当全局已无任何可用的启用音色时，才回退为 blocked
      if (resolution == null || !resolution.isEffectivelyEnabled) {
        final rawText = SourceNormalizer.normalizeForSpeech(
          unitsFirst.map((u) => u.text).join(),
        );
        result.add(
          AudioSegment(
            segmentId: 'seg_${bookRevisionId}_m${manifestRevision}_$segOrder',
            bookId: bookId,
            bookRevisionId: bookRevisionId,
            manifestRevision: manifestRevision,
            chapterIndex: first.chapterIndex,
            chapterId: unitsFirst.first.chapterId,
            segmentOrder: segOrder++,
            sourceUnitIds: unitsFirst.map((u) => u.unitId).toList(),
            startGlobalOrder: unitsFirst.first.globalOrder,
            endGlobalOrder: unitsFirst.last.globalOrder,
            startParagraphIndex: unitsFirst.first.paragraphIndex,
            startCharOffset: unitsFirst.first.startOffset,
            endParagraphIndex: unitsFirst.last.paragraphIndex,
            endCharOffset: unitsFirst.last.endOffset,
            spokenText: rawText,
            kind: first.kind,
            speakerRef: first.speakerRef,
            speakerDisplayName: _speakerDisplayName(first, characterById),
            voiceProfileId: voiceProfileId,
            bindingRevision: _bindingRev(first, bindingByCharId),
            renderSpecHash: 'missing_voice',
            requestKey: 'missing_${first.allocationId}',
            status: AudioSegmentStatus.blocked,
            errorMessage: '当前没有已启用的可用 TTS 音色，请在设置中启用至少一个音色',
          ),
        );
        i++;
        continue;
      }

      // 确定目标字符预算（首播锚点附近使用更小的 startup_target_characters 以加速首播）
      final nearStartup =
          isFirstAfterAnchor &&
          startupAnchorGlobalOrder != null &&
          unitsFirst.first.globalOrder >= startupAnchorGlobalOrder;
      final targetChars = nearStartup
          ? config.audioGeneration.startupTargetCharacters
          : config.audioGeneration.targetCharacters;
      final maxAppChars = config.audioGeneration.maxCharacters;
      if (nearStartup) isFirstAfterAnchor = false;

      // 收集可合并的连续同章、同角色 ID、同最终生效音色、同兼容类别的 Allocation
      final mergedUnits = <SourceUnit>[...unitsFirst];
      var mergedText = _joinUnitsText(mergedUnits);
      var j = i + 1;

      while (j < pendingAllocs.length) {
        final next = pendingAllocs[j];
        if (!next.isReadyForTts) break;
        // 禁止跨章节合并
        if (next.chapterIndex != first.chapterIndex) break;
        // 禁止跨角色 ID 合并（即使两个人共用同一个音色！）
        if (next.speakerRef != first.speakerRef) break;
        // 实际生效音色必须一致（含同性兜底后音色）
        final nextVoiceId =
            resolveEffectiveVoice(next)?.resolution.voice.voiceProfileId ?? '';
        if (nextVoiceId != voiceProfileId) break;
        // 类别兼容性：直接对白不与非直接对白合并
        if (AllocationKind.isDirectDialogue(next.kind) !=
            AllocationKind.isDirectDialogue(first.kind)) {
          break;
        }
        // 未确定对白兜底单独分段，便于在 UI 精确高亮与定位修正
        if (first.speakerResolution == SpeakerResolution.unresolved ||
            next.speakerResolution == SpeakerResolution.unresolved) {
          break;
        }

        final nextUnits = next.sourceUnitIds
            .map((id) => unitById[id])
            .whereType<SourceUnit>()
            .toList();
        if (nextUnits.isEmpty) {
          j++;
          continue;
        }
        final candidateUnits = [...mergedUnits, ...nextUnits];
        final candidateText = _joinUnitsText(candidateUnits);

        // 超过目标字符数且当前已非空则停止合并；同时检查应用码点上限与供应商真实输入上限
        if (SourceNormalizer.countCodePoints(candidateText) > targetChars) {
          break;
        }
        if (!_fitsBothLimits(candidateText, maxAppChars, resolution.model.capabilities)) {
          break;
        }
        mergedUnits.addAll(nextUnits);
        mergedText = candidateText;
        j++;
      }

      // 若单个段本身超出应用或供应商上限，按完整句子/停顿拆分成多个合法子段
      final pieces = _splitIfExceedsLimits(
        text: mergedText,
        maxAppCodePoints: maxAppChars,
        capabilities: resolution.model.capabilities,
      );

      for (var pIdx = 0; pIdx < pieces.length; pIdx++) {
        final pieceText = SourceNormalizer.normalizeForSpeech(pieces[pIdx]);
        if (pieceText.isEmpty) continue;
        final spec = RenderSpec.fromResolution(
          resolution: resolution,
          inputText: pieceText,
        );
        final cached = existingAssetsByRequestKey[spec.requestKey];
        final segId =
            'seg_${bookRevisionId}_m${manifestRevision}_${segOrder}_${sha256.convert(utf8.encode('${mergedUnits.first.unitId}|$pIdx|${spec.requestKey}')).toString().substring(0, 6)}';

        result.add(
          AudioSegment(
            segmentId: segId,
            bookId: bookId,
            bookRevisionId: bookRevisionId,
            manifestRevision: manifestRevision,
            chapterIndex: first.chapterIndex,
            chapterId: mergedUnits.first.chapterId,
            segmentOrder: segOrder++,
            sourceUnitIds: mergedUnits.map((u) => u.unitId).toList(),
            startGlobalOrder: mergedUnits.first.globalOrder,
            endGlobalOrder: mergedUnits.last.globalOrder,
            startParagraphIndex: mergedUnits.first.paragraphIndex,
            startCharOffset: mergedUnits.first.startOffset,
            endParagraphIndex: mergedUnits.last.paragraphIndex,
            endCharOffset: mergedUnits.last.endOffset,
            spokenText: pieceText,
            kind: first.kind,
            speakerRef: first.speakerRef,
            speakerDisplayName: _speakerDisplayName(first, characterById),
            voiceProfileId: voiceProfileId,
            bindingRevision: _bindingRev(first, bindingByCharId),
            renderSpecHash: spec.renderSpecHash,
            requestKey: spec.requestKey,
            status: cached != null
                ? AudioSegmentStatus.ready
                : AudioSegmentStatus.pending,
          ),
        );
      }

      i = j;
    }

    return result;
  }

  /// 同时独立校验应用 Unicode 码点上限和供应商输入单位上限（不跨单位混比）
  static bool _fitsBothLimits(
    String text,
    int maxAppCodePoints,
    TtsModelCapabilities caps,
  ) {
    if (SourceNormalizer.countCodePoints(text) > maxAppCodePoints) {
      return false;
    }
    if (caps.inputLengthUnit == 'utf8_bytes') {
      return SourceNormalizer.countUtf8Bytes(text) <= caps.maxInputLength;
    }
    return SourceNormalizer.countCodePoints(text) <= caps.maxInputLength;
  }

  static List<String> _splitIfExceedsLimits({
    required String text,
    required int maxAppCodePoints,
    required TtsModelCapabilities capabilities,
  }) {
    if (_fitsBothLimits(text, maxAppCodePoints, capabilities)) {
      return [text];
    }
    final pieces = <String>[];
    final buf = StringBuffer();
    final punct = RegExp(r'[。！？!?；;，,、\n]');

    // 按完整字素迭代，绝不拆断 emoji/代理对/组合字符
    final chars = text.characters.toList();
    var lastPunctBufLen = -1;
    for (var idx = 0; idx < chars.length; idx++) {
      final ch = chars[idx];
      final candidate = '$buf$ch';
      if (buf.isNotEmpty &&
          !_fitsBothLimits(candidate, maxAppCodePoints, capabilities)) {
        final curStr = buf.toString();
        if (lastPunctBufLen > 0 && lastPunctBufLen < curStr.length) {
          pieces.add(curStr.substring(0, lastPunctBufLen));
          final remainder = curStr.substring(lastPunctBufLen);
          buf
            ..clear()
            ..write(remainder)
            ..write(ch);
        } else {
          pieces.add(curStr);
          buf
            ..clear()
            ..write(ch);
        }
        lastPunctBufLen = -1;
      } else {
        buf.write(ch);
        if (punct.hasMatch(ch)) {
          lastPunctBufLen = buf.length;
        }
      }
    }
    if (buf.isNotEmpty) pieces.add(buf.toString());
    return pieces;
  }

  static String _joinUnitsText(List<SourceUnit> units) {
    final buf = StringBuffer();
    for (var i = 0; i < units.length; i++) {
      if (i > 0 && units[i].paragraphIndex != units[i - 1].paragraphIndex) {
        buf.write('\n');
      }
      buf.write(units[i].text);
    }
    return SourceNormalizer.normalizeForSpeech(buf.toString());
  }

  static String _speakerDisplayName(
    Allocation alloc,
    Map<String, ImmersiveCharacter> characterById,
  ) {
    if (alloc.speakerResolution == SpeakerResolution.unresolved) {
      return '待确认对白（旁白代读）';
    }
    if (alloc.speakerRef == null || alloc.speakerRef == 'narrator') {
      return '旁白';
    }
    return characterById[alloc.speakerRef!]?.canonicalName ?? alloc.speakerRef!;
  }

  static int _bindingRev(
    Allocation alloc,
    Map<String, VoiceBinding> bindingByCharId,
  ) {
    if (alloc.speakerRef == null || alloc.speakerRef == 'narrator') return 1;
    return bindingByCharId[alloc.speakerRef!]?.bindingRevision ?? 1;
  }
}
