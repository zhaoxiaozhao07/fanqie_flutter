import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../../models/chapter.dart';
import '../../models/reading_position.dart';
import '../../services/reader_text.dart';
import '../models/immersive_entities.dart';

/// 标准化后的章节正文结构
class NormalizedChapter {
  final int chapterIndex;
  final String chapterId;
  final String title;
  final List<String> paragraphs;
  final String canonicalText;
  final List<SourceUnit> units;

  const NormalizedChapter({
    required this.chapterIndex,
    required this.chapterId,
    required this.title,
    required this.paragraphs,
    required this.canonicalText,
    required this.units,
  });
}

/// 标准化后的书籍版本与原文单元集合
class NormalizedBookSnapshot {
  final BookRevision revision;
  final List<NormalizedChapter> chapters;
  final List<SourceUnit> allUnits;

  const NormalizedBookSnapshot({
    required this.revision,
    required this.chapters,
    required this.allUnits,
  });
}

/// 混合对白子单元拆分锚点建议
class UnitSplitProposal {
  final String parentUnitId;
  final List<String> exactFragments;

  const UnitSplitProposal({
    required this.parentUnitId,
    required this.exactFragments,
  });
}

/// 原文标准化与稳定定位器（复用 ReaderText，严格保持不可变原文与双向映射）
class SourceNormalizer {
  static const parserVersion = 'v1';

  /// 为单本书生成独立于窗口加载范围的稳定 BookRevision ID，避免长书跳章或增量加载导致编排缓存失效
  static String stableRevisionIdForBook(String bookId) {
    final hash = sha256
        .convert(utf8.encode('$bookId|stable|$parserVersion'))
        .toString()
        .substring(0, 16);
    return 'rev_book_$hash';
  }

  /// 计算按章分区的确定性 globalOrder（每章预留 100,000 个原文单元槽位，任意跳章天然严格递增）
  static int chapterScopedGlobalOrder(int chapterIndex, int inChapterIndex) =>
      chapterIndex * 100000 + inChapterIndex;

  /// 为已知章节正文列表构建固定 BookRevision 与细粒度 SourceUnit
  static NormalizedBookSnapshot normalizeChapters({
    required String bookId,
    required List<Chapter> chapters,
    required Map<String, String> chapterRawTexts,
    String? sourceFileHash,
    String? fixedRevisionId,
    bool useChapterScopedGlobalOrder = false,
    int? nowMs,
  }) {
    final hashBuffer = StringBuffer();
    final normalizedChapters = <NormalizedChapter>[];
    final allUnits = <SourceUnit>[];
    var globalOrder = 0;

    // 第一遍计算确定性正文哈希以生成 book_revision
    final parsedParagraphs = <int, List<String>>{};
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final raw = chapterRawTexts[ch.itemId] ?? ch.content ?? '';
      final paras = ReaderText.paragraphs(raw, chapterTitle: ch.title)
          .where((p) => p.isNotEmpty && p != ReaderText.imageOnlyMarker)
          .toList(growable: false);
      parsedParagraphs[i] = paras;
      hashBuffer
        ..write(ch.itemId)
        ..write('\u001F')
        ..write(paras.join('\n\n'))
        ..write('\u001E');
    }

    final normalizedHash = sha256
        .convert(utf8.encode(hashBuffer.toString()))
        .toString();
    final srcHash = sourceFileHash ?? normalizedHash;
    final revisionId =
        fixedRevisionId ??
        'rev_${sha256.convert(utf8.encode('$bookId|$srcHash|$normalizedHash|$parserVersion')).toString().substring(0, 16)}';

    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final paras = parsedParagraphs[i] ?? const <String>[];
      final canonical = paras.join('\n\n');
      final chUnits = <SourceUnit>[];
      var inChapterOrder = 0;

      for (var pIdx = 0; pIdx < paras.length; pIdx++) {
        final paraText = paras[pIdx];
        final spans = splitParagraphIntoSpans(paraText);
        for (var sIdx = 0; sIdx < spans.length; sIdx++) {
          final span = spans[sIdx];
          // 位置唯一 ID：包含版本、章节索引、段落索引与段内序号，绝不按文本哈希去重
          final unitId = 'u_${revisionId}_c${i}_p${pIdx}_s$sIdx';
          final order = useChapterScopedGlobalOrder
              ? chapterScopedGlobalOrder(i, inChapterOrder++)
              : globalOrder++;
          final unit = SourceUnit(
            unitId: unitId,
            bookRevisionId: revisionId,
            bookId: bookId,
            chapterIndex: i,
            chapterId: ch.itemId,
            paragraphIndex: pIdx,
            globalOrder: order,
            startOffset: span.start,
            endOffset: span.end,
            text: span.text,
          );
          chUnits.add(unit);
          allUnits.add(unit);
        }
      }

      normalizedChapters.add(
        NormalizedChapter(
          chapterIndex: i,
          chapterId: ch.itemId,
          title: ch.title,
          paragraphs: paras,
          canonicalText: canonical,
          units: chUnits,
        ),
      );
    }

    final revision = BookRevision(
      revisionId: revisionId,
      bookId: bookId,
      sourceFileHash: srcHash,
      normalizedTextHash: normalizedHash,
      parserVersion: parserVersion,
      chapterCount: chapters.length,
      createdAtMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );

    return NormalizedBookSnapshot(
      revision: revision,
      chapters: normalizedChapters,
      allUnits: allUnits,
    );
  }

  /// 为单个章节追加生成 SourceUnit（用于按需懒加载在线/离线章节正文）
  static List<SourceUnit> normalizeSingleChapter({
    required String bookId,
    required String bookRevisionId,
    required int chapterIndex,
    required Chapter chapter,
    required String rawText,
    required int startingGlobalOrder,
  }) {
    final paras = ReaderText.paragraphs(rawText, chapterTitle: chapter.title)
        .where((p) => p.isNotEmpty && p != ReaderText.imageOnlyMarker)
        .toList(growable: false);
    final units = <SourceUnit>[];
    var order = startingGlobalOrder;
    for (var pIdx = 0; pIdx < paras.length; pIdx++) {
      final spans = splitParagraphIntoSpans(paras[pIdx]);
      for (var sIdx = 0; sIdx < spans.length; sIdx++) {
        final span = spans[sIdx];
        units.add(
          SourceUnit(
            unitId: 'u_${bookRevisionId}_c${chapterIndex}_p${pIdx}_s$sIdx',
            bookRevisionId: bookRevisionId,
            bookId: bookId,
            chapterIndex: chapterIndex,
            chapterId: chapter.itemId,
            paragraphIndex: pIdx,
            globalOrder: order++,
            startOffset: span.start,
            endOffset: span.end,
            text: span.text,
          ),
        );
      }
    }
    return units;
  }

  /// 按引号、叙述插入和句末边界将段落切分为精确、可完全拼接还原的原文切片
  static List<({int start, int end, String text})> splitParagraphIntoSpans(
    String paragraph,
  ) {
    if (paragraph.isEmpty) return const [];
    final spans = <({int start, int end, String text})>[];

    // 第一步：优先按成对引号边界分离引号段与叙述段（不丢失任意标点与空白）
    final quoteSegments = _splitByQuotes(paragraph);

    // 第二步：对较长的非引号叙述段按句末标点再切细，避免长段混杂多句
    for (final seg in quoteSegments) {
      if (seg.isQuoted || seg.text.runes.length <= 100) {
        spans.add((start: seg.start, end: seg.end, text: seg.text));
      } else {
        spans.addAll(_splitBySentences(seg.text, seg.start));
      }
    }

    // 强不变量自检：拼接后必须与原段落逐字完全一致
    final reconstructed = spans.map((s) => s.text).join();
    if (reconstructed != paragraph) {
      return [(start: 0, end: paragraph.length, text: paragraph)];
    }
    return spans;
  }

  /// 按原文锚点对混合说话人的单个 SourceUnit 拆分子单元（不依赖整章字符偏移）
  static List<SourceUnit> splitUnitWithAnchors(
    SourceUnit parent,
    List<String> exactFragments,
  ) {
    if (exactFragments.length < 2) {
      throw const FormatException('拆分建议至少包含两个片段');
    }
    if (exactFragments.any((f) => f.isEmpty)) {
      throw const FormatException('拆分片段不能为空');
    }
    final joined = exactFragments.join();
    if (joined != parent.text) {
      throw const FormatException('拆分片段拼接结果与父原文单元不完全一致，拒绝拆分');
    }
    final out = <SourceUnit>[];
    var cursor = parent.startOffset;
    for (var i = 0; i < exactFragments.length; i++) {
      final frag = exactFragments[i];
      out.add(
        SourceUnit(
          unitId: '${parent.unitId}_sub$i',
          bookRevisionId: parent.bookRevisionId,
          bookId: parent.bookId,
          chapterIndex: parent.chapterIndex,
          chapterId: parent.chapterId,
          paragraphIndex: parent.paragraphIndex,
          globalOrder: parent.globalOrder,
          startOffset: cursor,
          endOffset: cursor + frag.length,
          text: frag,
          parentUnitId: parent.unitId,
          active: true,
        ),
      );
      cursor += frag.length;
    }
    return out;
  }

  /// 将 SourceUnit 映射回阅读器 ReadingPosition
  static ReadingPosition positionForUnit(SourceUnit unit) => ReadingPosition(
    chapterId: unit.chapterId,
    paragraphIndex: unit.paragraphIndex,
    characterOffset: unit.startOffset,
  );

  /// 将阅读器 ReadingPosition 定位到对应的 SourceUnit（或同章最接近的下一单元）
  static SourceUnit? unitForPosition(
    List<SourceUnit> units,
    ReadingPosition position,
  ) {
    SourceUnit? fallbackInChapter;
    for (final u in units) {
      if (!u.active || u.chapterId != position.chapterId) continue;
      fallbackInChapter ??= u;
      if (u.paragraphIndex > position.paragraphIndex) {
        return u;
      }
      if (u.paragraphIndex == position.paragraphIndex) {
        if (position.characterOffset < u.endOffset) {
          return u;
        }
        fallbackInChapter = u;
      }
    }
    return fallbackInChapter;
  }

  /// Unicode 码点计数（非 UTF-16 code unit）
  static int countCodePoints(String text) => text.runes.length;

  /// UTF-8 字节计数
  static int countUtf8Bytes(String text) => utf8.encode(text).length;

  /// 朗读文本清理规则（可逆：仅移除无须发声的不可见控制符，保留标点停顿）
  static String normalizeForSpeech(String rawText) {
    return rawText.replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '').trim();
  }

  static List<({int start, int end, String text, bool isQuoted})>
  _splitByQuotes(String text) {
    const openToClose = <String, String>{
      '“': '”',
      '「': '」',
      '『': '』',
      '"': '"',
    };
    final result = <({int start, int end, String text, bool isQuoted})>[];
    final chars = text.characters.toList();
    final charOffsets = <int>[];
    var off = 0;
    for (final ch in chars) {
      charOffsets.add(off);
      off += ch.length;
    }
    charOffsets.add(text.length);

    var segStart = 0;
    var i = 0;
    while (i < chars.length) {
      final ch = chars[i];
      final expectedClose = openToClose[ch];
      if (expectedClose != null) {
        // 寻找配对闭合引号
        var closeIdx = -1;
        for (var j = i + 1; j < chars.length; j++) {
          if (chars[j] == expectedClose) {
            closeIdx = j;
            break;
          }
          // 遇到新的中文开引号则放弃当前未闭合匹配
          if (ch != '"' && openToClose.containsKey(chars[j]) && chars[j] != '"') {
            break;
          }
        }
        if (closeIdx != -1) {
          if (charOffsets[i] > segStart) {
            result.add((
              start: segStart,
              end: charOffsets[i],
              text: text.substring(segStart, charOffsets[i]),
              isQuoted: false,
            ));
          }
          final qEnd = charOffsets[closeIdx + 1];
          result.add((
            start: charOffsets[i],
            end: qEnd,
            text: text.substring(charOffsets[i], qEnd),
            isQuoted: true,
          ));
          segStart = qEnd;
          i = closeIdx + 1;
          continue;
        }
      }
      i++;
    }
    if (segStart < text.length) {
      result.add((
        start: segStart,
        end: text.length,
        text: text.substring(segStart),
        isQuoted: false,
      ));
    }
    return result;
  }

  static List<({int start, int end, String text})> _splitBySentences(
    String text,
    int baseOffset,
  ) {
    final result = <({int start, int end, String text})>[];
    final punct = RegExp(r'[。！？!?；;]');
    var start = 0;
    var pos = 0;
    var codePoints = 0;
    for (final ch in text.characters) {
      pos += ch.length;
      codePoints += ch.runes.length;
      if (punct.hasMatch(ch) && codePoints >= 15) {
        result.add((
          start: baseOffset + start,
          end: baseOffset + pos,
          text: text.substring(start, pos),
        ));
        start = pos;
        codePoints = 0;
      }
    }
    if (start < text.length) {
      result.add((
        start: baseOffset + start,
        end: baseOffset + text.length,
        text: text.substring(start),
      ));
    }
    return result;
  }
}
