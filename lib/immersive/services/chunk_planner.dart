import 'dart:math' as math;

import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';

/// 语义分块规划器：按章节/段落/完整句切分不重叠 target_units，并附加只读前后文
class ChunkPlanner {
  static const plannerVersion = 'v1';

  /// 保守 token 估算（无精确 tokenizer 时使用保守估算，偏高估计以防超窗）
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final r in text.runes) {
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF00 && r <= 0xFFEF)) {
        cjk++;
      } else {
        other++;
      }
    }
    // 中文保守按 1.15 token/字，英文/ASCII 按 0.4 token/字符，额外预留结构标签开销
    return (cjk * 1.15 + other * 0.4).ceil() + 6;
  }

  /// 计算当前模型和音色目录允许的最大目标块 token 预算
  static int effectiveTargetBudget({
    required TextAnalysisConfig textConfig,
    required AnalysisPipelineConfig pipelineConfig,
    required int systemVoiceCatalogTokens,
    int? overrideMaxTargetTokens,
  }) {
    final effectiveCtx = textConfig.effectiveContextWindowTokens;
    final safety =
        (effectiveCtx * pipelineConfig.contextSafetyMarginRatio).ceil();
    final outputReserve = textConfig.maxOutputTokens ??
        math.min(
          TextAnalysisConfig.defaultMaxOutputTokens,
          (effectiveCtx * 0.25).floor(),
        );
    final reserved =
        outputReserve +
        safety +
        systemVoiceCatalogTokens +
        pipelineConfig.characterContextMaxTokens +
        pipelineConfig.chapterSummaryMaxTokens +
        pipelineConfig.contextBeforeTokens +
        pipelineConfig.contextAfterTokens +
        600; // 系统规则与 JSON 结构提示开销

    final available = effectiveCtx - reserved;
    if (available < 120) {
      throw StateError(
        '文本模型上下文窗口（$effectiveCtx）不足以容纳全部勾选音色目录与安全余量，请减少勾选音色或调大上下文窗口配置',
      );
    }
    final configuredMax = overrideMaxTargetTokens ?? pipelineConfig.maxChunkTokens;
    return math.min(
      math.min(pipelineConfig.targetChunkTokens, configuredMax),
      available,
    );
  }

  /// 为指定章节的有序 SourceUnit 生成分块（支持跨章只读前后文衔接、首块微切分快启及按章稳定编号）
  static List<AnalysisChunk> planChunks({
    required String bookId,
    required String bookRevisionId,
    required List<SourceUnit> allOrderedUnits,
    required AnalysisPipelineConfig pipelineConfig,
    required TextAnalysisConfig textConfig,
    required int systemVoiceCatalogTokens,
    int? maxTargetTokensOverride,
    bool useChapterScopedChunkOrder = false,
    int? fastStartChapterIndex,
  }) {
    final activeUnits = allOrderedUnits.where((u) => u.active).toList(growable: false);
    if (activeUnits.isEmpty) return const [];

    final targetBudget = effectiveTargetBudget(
      textConfig: textConfig,
      pipelineConfig: pipelineConfig,
      systemVoiceCatalogTokens: systemVoiceCatalogTokens,
      overrideMaxTargetTokens: maxTargetTokensOverride,
    );
    final hardMaxBudget = math.min(
      maxTargetTokensOverride ?? pipelineConfig.maxChunkTokens,
      math.max(targetBudget, (targetBudget * 1.25).floor()),
    );

    final chunks = <AnalysisChunk>[];
    var cursor = 0;
    var chunkOrder = 0;
    final perChapterChunkSeq = <int, int>{};

    while (cursor < activeUnits.length) {
      final startIdx = cursor;
      final chapterIndex = activeUnits[startIdx].chapterIndex;
      final chapterId = activeUnits[startIdx].chapterId;
      final isFastStartFirstChunk =
          maxTargetTokensOverride == null &&
          fastStartChapterIndex != null &&
          chapterIndex == fastStartChapterIndex &&
          (perChapterChunkSeq[chapterIndex] ?? 0) == 0 &&
          pipelineConfig.firstChunkTargetTokens > 0 &&
          pipelineConfig.firstChunkTargetTokens < targetBudget;
      final chunkTargetBudget = isFastStartFirstChunk
          ? math.min(targetBudget, pipelineConfig.firstChunkTargetTokens)
          : targetBudget;
      final chunkHardMaxBudget = isFastStartFirstChunk
          ? math.min(hardMaxBudget, (chunkTargetBudget * 1.25).floor())
          : hardMaxBudget;
      var tokSum = 0;
      var endIdx = startIdx;

      while (endIdx < activeUnits.length &&
          activeUnits[endIdx].chapterIndex == chapterIndex) {
        final u = activeUnits[endIdx];
        final uTok = estimateTokens(u.text);
        // 尽量不在同一段落中间切开，除非接近 hardMaxBudget
        final sameParaAsPrev =
            endIdx > startIdx &&
            activeUnits[endIdx - 1].paragraphIndex == u.paragraphIndex;
        if (endIdx > startIdx) {
          if (!sameParaAsPrev && tokSum + uTok > chunkTargetBudget) {
            break;
          }
          if (tokSum + uTok > chunkHardMaxBudget) {
            break;
          }
        }
        tokSum += uTok;
        endIdx++;
      }

      // 保证单块至少推进 1 个 unit，不死循环
      if (endIdx == startIdx) {
        tokSum = estimateTokens(activeUnits[startIdx].text);
        endIdx = startIdx + 1;
      }

      final targetSlice = activeUnits.sublist(startIdx, endIdx);

      // 收集只读前文（可跨上一章末尾，保证跨章对话衔接）
      final beforeIds = <String>[];
      var beforeTok = 0;
      for (var b = startIdx - 1; b >= 0; b--) {
        final t = estimateTokens(activeUnits[b].text);
        if (beforeIds.isNotEmpty &&
            beforeTok + t > pipelineConfig.contextBeforeTokens) {
          break;
        }
        beforeIds.add(activeUnits[b].unitId);
        beforeTok += t;
      }
      final orderedBeforeIds = beforeIds.reversed.toList(growable: false);

      // 收集只读后文（可跨下一章开头，但只读后文不能提前推进确认前沿）
      final afterIds = <String>[];
      var afterTok = 0;
      for (var a = endIdx; a < activeUnits.length; a++) {
        final t = estimateTokens(activeUnits[a].text);
        if (afterIds.isNotEmpty &&
            afterTok + t > pipelineConfig.contextAfterTokens) {
          break;
        }
        afterIds.add(activeUnits[a].unitId);
        afterTok += t;
      }

      final inChapSeq = perChapterChunkSeq[chapterIndex] ?? 0;
      perChapterChunkSeq[chapterIndex] = inChapSeq + 1;
      final assignedOrder = useChapterScopedChunkOrder
          ? chapterIndex * 1000 + inChapSeq
          : chunkOrder;
      final assignedId = useChapterScopedChunkOrder
          ? 'chk_${bookRevisionId}_c${chapterIndex}_$inChapSeq'
          : 'chk_${bookRevisionId}_$chunkOrder';

      chunks.add(
        AnalysisChunk(
          chunkId: assignedId,
          bookRevisionId: bookRevisionId,
          bookId: bookId,
          chapterIndex: chapterIndex,
          chapterId: chapterId,
          chunkOrder: assignedOrder,
          targetUnitIds: targetSlice.map((u) => u.unitId).toList(growable: false),
          contextBeforeUnitIds: orderedBeforeIds,
          contextAfterUnitIds: afterIds,
          startGlobalOrder: targetSlice.first.globalOrder,
          endGlobalOrder: targetSlice.last.globalOrder,
          plannerVersion: plannerVersion,
          estimatedTokens: tokSum,
        ),
      );

      chunkOrder++;
      cursor = endIdx;
    }

    return chunks;
  }

  /// 当模型返回输出截断或超长错误时，将目标块对半缩减为更小的子块（不裁剪目录或原文）
  static List<AnalysisChunk> splitOversizedChunk(
    AnalysisChunk chunk,
    Map<String, SourceUnit> unitById,
  ) {
    if (chunk.targetUnitIds.length < 2) {
      throw StateError('分块 ${chunk.chunkId} 仅含单个原文单元，无法继续缩小');
    }
    final mid = chunk.targetUnitIds.length ~/ 2;
    final leftIds = chunk.targetUnitIds.sublist(0, mid);
    final rightIds = chunk.targetUnitIds.sublist(mid);

    int est(List<String> ids) => ids.fold<int>(
      0,
      (sum, id) => sum + estimateTokens(unitById[id]?.text ?? ''),
    );

    final leftFirst = unitById[leftIds.first]!;
    final leftLast = unitById[leftIds.last]!;
    final rightFirst = unitById[rightIds.first]!;
    final rightLast = unitById[rightIds.last]!;

    return [
      AnalysisChunk(
        chunkId: '${chunk.chunkId}_a',
        bookRevisionId: chunk.bookRevisionId,
        bookId: chunk.bookId,
        chapterIndex: chunk.chapterIndex,
        chapterId: chunk.chapterId,
        chunkOrder: chunk.chunkOrder,
        targetUnitIds: leftIds,
        contextBeforeUnitIds: chunk.contextBeforeUnitIds,
        contextAfterUnitIds: rightIds.take(4).toList(growable: false),
        startGlobalOrder: leftFirst.globalOrder,
        endGlobalOrder: leftLast.globalOrder,
        plannerVersion: chunk.plannerVersion,
        estimatedTokens: est(leftIds),
      ),
      AnalysisChunk(
        chunkId: '${chunk.chunkId}_b',
        bookRevisionId: chunk.bookRevisionId,
        bookId: chunk.bookId,
        chapterIndex: chunk.chapterIndex,
        chapterId: chunk.chapterId,
        chunkOrder: chunk.chunkOrder + 1,
        targetUnitIds: rightIds,
        contextBeforeUnitIds: leftIds
            .skip(math.max(0, leftIds.length - 4))
            .toList(growable: false),
        contextAfterUnitIds: chunk.contextAfterUnitIds,
        startGlobalOrder: rightFirst.globalOrder,
        endGlobalOrder: rightLast.globalOrder,
        plannerVersion: chunk.plannerVersion,
        estimatedTokens: est(rightIds),
      ),
    ];
  }
}
