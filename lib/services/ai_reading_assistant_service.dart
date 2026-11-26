import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../immersive/models/immersive_config.dart';
import '../immersive/models/immersive_entities.dart';
import '../immersive/services/immersive_config_service.dart';
import '../immersive/services/immersive_database.dart';
import '../immersive/services/immersive_playback_coordinator.dart';
import '../models/chapter.dart';
import 'reader_text.dart';

/// AI 前情提要生成结果
class AiRecapResult {
  final String content;
  final int fromChapterIndex;
  final int toChapterIndex;
  final int analyzedChapters;
  final String modelName;
  final int latencyMs;
  final bool fromCache;

  const AiRecapResult({
    required this.content,
    required this.fromChapterIndex,
    required this.toChapterIndex,
    required this.analyzedChapters,
    required this.modelName,
    required this.latencyMs,
    this.fromCache = false,
  });
}

/// AI 防剧透词条与人物速查结果
class AiTermLookupResult {
  final String term;
  final String explanation;
  final List<String> matchedSnippets;
  final ImmersiveCharacter? matchedCharacter;
  final List<String> knownAliases;
  final String modelName;
  final int latencyMs;

  const AiTermLookupResult({
    required this.term,
    required this.explanation,
    required this.matchedSnippets,
    required this.matchedCharacter,
    required this.knownAliases,
    required this.modelName,
    required this.latencyMs,
  });
}

/// 复用沉浸式听书文本大模型通道与本地角色档案的「防剧透 AI 阅读助手」
/// 严格边界：仅允许读取当前章节索引及以前（且当前章截断至当前段落）的正文，杜绝任何后文剧透
class AiReadingAssistantService {
  static final AiReadingAssistantService _instance =
      AiReadingAssistantService._();
  factory AiReadingAssistantService() => _instance;

  AiReadingAssistantService._()
    : _httpClient = http.Client(),
      _configService = ImmersiveConfigService();

  AiReadingAssistantService.forTesting({
    required http.Client httpClient,
    required ImmersiveConfigService configService,
  }) : _httpClient = httpClient,
       _configService = configService;

  final http.Client _httpClient;
  final ImmersiveConfigService _configService;
  final Map<String, AiRecapResult> _recapCache = {};

  /// 读取当前本书在本地已确认的角色名录（只读，无数据库时不创建）
  Future<
    ({List<ImmersiveCharacter> characters, Map<String, List<String>> aliases})
  >
  loadKnownCharacters(String bookId) async {
    try {
      final active = ImmersivePlaybackCoordinator().activeStateStore;
      if (active != null) {
        return await _readCharactersFromStore(active, bookId);
      }
      var paths = _configService.resolvedPaths;
      if (paths == null) {
        final st = await _configService.loadAndValidateConfig(
          autoInitPreset: false,
        );
        paths = st.paths;
      }
      if (paths == null) {
        final cfgFile = await _configService.defaultConfigFile();
        paths = _configService.resolvePaths(cfgFile, const StorageConfig());
      }
      final dbFile = File(paths.databasePath);
      if (!await dbFile.exists()) {
        return (
          characters: const <ImmersiveCharacter>[],
          aliases: const <String, List<String>>{},
        );
      }
      final store = SqliteImmersiveStateStore(paths.databasePath);
      await store.initialize();
      try {
        return await _readCharactersFromStore(store, bookId);
      } finally {
        await store.close();
      }
    } catch (_) {
      return (
        characters: const <ImmersiveCharacter>[],
        aliases: const <String, List<String>>{},
      );
    }
  }

  Future<
    ({List<ImmersiveCharacter> characters, Map<String, List<String>> aliases})
  >
  _readCharactersFromStore(ImmersiveStateStore store, String bookId) async {
    final chars = await store.getCharacters(bookId);
    final aliasList = await store.getAliasEvidences(bookId);
    final aliasMap = <String, List<String>>{};
    for (final a in aliasList) {
      if (a.status != 'active') continue;
      aliasMap.putIfAbsent(a.characterId, () => []).add(a.aliasText);
    }
    return (characters: chars, aliases: aliasMap);
  }

  /// 构建防剧透前情提要（仅采集 [currentChapterIndex - windowChapters + 1 .. currentChapterIndex] 已读正文）
  Future<AiRecapResult> generateRecap({
    required String bookId,
    required String bookName,
    required List<Chapter> chapters,
    required int currentChapterIndex,
    required int currentParagraphIndex,
    required Future<String?> Function(int chapterIndex) chapterLoader,
    int windowChapters = 5,
    bool forceRefresh = false,
  }) async {
    final safeIdx = currentChapterIndex.clamp(0, chapters.length - 1);
    final safeWindow = windowChapters.clamp(1, 15);
    final fromIdx = (safeIdx - safeWindow + 1).clamp(0, safeIdx);
    final cacheKey = '$bookId:$fromIdx:$safeIdx:$currentParagraphIndex';
    if (!forceRefresh && _recapCache.containsKey(cacheKey)) {
      final cached = _recapCache[cacheKey]!;
      return AiRecapResult(
        content: cached.content,
        fromChapterIndex: cached.fromChapterIndex,
        toChapterIndex: cached.toChapterIndex,
        analyzedChapters: cached.analyzedChapters,
        modelName: cached.modelName,
        latencyMs: 0,
        fromCache: true,
      );
    }

    final excerptBuffer = StringBuffer();
    var analyzed = 0;
    const maxTotalChars = 14000;

    for (var i = fromIdx; i <= safeIdx; i++) {
      final raw = await chapterLoader(i);
      if (raw == null || raw.trim().isEmpty) continue;
      final chapter = chapters[i];
      String chapterBody = raw;
      // 严格防剧透：当前阅读章节仅截取至当前已读段落（含当前段），绝不传入未读段落
      if (i == safeIdx && currentParagraphIndex >= 0) {
        final paras = ReaderText.paragraphs(raw, chapterTitle: chapter.title);
        if (paras.isNotEmpty) {
          final takeCount = (currentParagraphIndex + 1).clamp(1, paras.length);
          chapterBody = paras.take(takeCount).join('\n');
        }
      }
      final trimmed = chapterBody.trim();
      if (trimmed.isEmpty) continue;
      final remain = maxTotalChars - excerptBuffer.length;
      if (remain <= 200) break;
      final slice = trimmed.length > remain
          ? '${trimmed.substring(0, remain)}…'
          : trimmed;
      excerptBuffer.writeln('【第 ${i + 1} 章：${chapter.title}】');
      excerptBuffer.writeln(slice);
      excerptBuffer.writeln();
      analyzed++;
    }

    if (analyzed == 0) {
      throw const FormatException('未读取到可分析的前文章节正文，请先加载当前或前文章节');
    }

    final known = await loadKnownCharacters(bookId);
    final charHint = known.characters.isEmpty
        ? ''
        : '已知角色档案（供称谓对齐）：${known.characters.take(24).map((c) {
            final al = known.aliases[c.characterId] ?? const [];
            return al.isEmpty ? c.canonicalName : '${c.canonicalName}(别名:${al.join('/')})';
          }).join('、')}\n';

    final systemPrompt =
        '你是专业的小说防剧透阅读助手。严格遵守：只能依据用户提供的已读章节原文进行总结，'
        '严禁补充你记忆中的后续剧情、结局或未在原文出现的剧透信息。'
        '请使用清晰简洁的简体中文纯文本条列输出（不要使用 Markdown 的井号标题或双星号加粗符号），分三部分：\n'
        '一、核心剧情脉络（按时间线列出 3-5 条关键进展）\n'
        '二、关键人物与关系动态（列出本段活跃人物的立场与状态）\n'
        '三、当前悬念与未解伏笔（列出截至当前阅读点的待解问题）';

    final userPrompt =
        '书名：《$bookName》\n'
        '当前阅读位置：第 ${safeIdx + 1} 章《${chapters[safeIdx].title}》（前文范围：第 ${fromIdx + 1} 至 ${safeIdx + 1} 章）\n'
        '$charHint'
        '以下为截至当前进度的已读原文：\n\n'
        '${excerptBuffer.toString()}';

    final reply = await _chatWithFailover(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );

    final result = AiRecapResult(
      content: reply.content,
      fromChapterIndex: fromIdx,
      toChapterIndex: safeIdx,
      analyzedChapters: analyzed,
      modelName: reply.modelName,
      latencyMs: reply.latencyMs,
      fromCache: false,
    );
    _recapCache[cacheKey] = result;
    return result;
  }

  /// 防剧透选中词条 / 人物与设定速查（严格只扫描当前及更早章节）
  Future<AiTermLookupResult> lookupTerm({
    required String bookId,
    required String bookName,
    required String term,
    required List<Chapter> chapters,
    required int currentChapterIndex,
    required int currentParagraphIndex,
    required Future<String?> Function(int chapterIndex) chapterLoader,
    int scanBackChapters = 15,
  }) async {
    final cleanTerm = term.trim();
    if (cleanTerm.isEmpty) {
      throw const FormatException('请输入或选中要查询的人物或设定名称');
    }
    final safeIdx = currentChapterIndex.clamp(0, chapters.length - 1);
    final known = await loadKnownCharacters(bookId);

    ImmersiveCharacter? matchedChar;
    List<String> matchedAliases = const [];
    for (final c in known.characters) {
      final aliases = known.aliases[c.characterId] ?? const <String>[];
      if (c.canonicalName == cleanTerm ||
          c.canonicalName.contains(cleanTerm) ||
          aliases.any((a) => a == cleanTerm || a.contains(cleanTerm))) {
        matchedChar = c;
        matchedAliases = aliases;
        break;
      }
    }

    // 仅向前回溯搜索包含该词条的已读段落片段，绝不读取 safeIdx 之后的章节
    final snippets = <String>[];
    final fromIdx = (safeIdx - scanBackChapters + 1).clamp(0, safeIdx);
    final keywords = <String>{
      cleanTerm,
      if (matchedChar != null) matchedChar.canonicalName,
      ...matchedAliases.take(3),
    }.where((k) => k.length >= 2 || k == cleanTerm).toList();

    for (var i = safeIdx; i >= fromIdx && snippets.length < 10; i--) {
      final raw = await chapterLoader(i);
      if (raw == null || raw.isEmpty) continue;
      final chapter = chapters[i];
      var paras = ReaderText.paragraphs(raw, chapterTitle: chapter.title);
      if (i == safeIdx && currentParagraphIndex >= 0 && paras.isNotEmpty) {
        final takeCount = (currentParagraphIndex + 1).clamp(1, paras.length);
        paras = paras.take(takeCount).toList();
      }
      for (final p in paras.reversed) {
        if (keywords.any((k) => p.contains(k))) {
          final clipped = p.length > 260 ? '${p.substring(0, 260)}…' : p;
          snippets.add('【第 ${i + 1} 章 ${chapter.title}】$clipped');
          if (snippets.length >= 10) break;
        }
      }
    }

    final systemPrompt =
        '你是严格防剧透的小说人物与设定速查助手。'
        '规则：必须仅依据提供的角色档案和已读原文证据进行归纳回答；'
        '如果证据不足，请直接说明“截至当前已读章节暂未出现更多线索”，严禁编造或剧透后续情节。'
        '请使用简体中文分点给出：身份/定义、与主角或他人的关系、截至当前的最新状态。';

    final archiveSummary = matchedChar == null
        ? '本地角色库：暂无精确匹配记录\n'
        : '本地角色库：标准名「${matchedChar.canonicalName}」，性别：${matchedChar.gender}，'
              '已知别名：${matchedAliases.isEmpty ? '无' : matchedAliases.join('、')}\n';

    final evidenceText = snippets.isEmpty
        ? '最近 ${safeIdx - fromIdx + 1} 章已读正文中未检索到直接包含“$cleanTerm”的段落。'
        : snippets.reversed.join('\n\n');

    final userPrompt =
        '书名：《$bookName》\n'
        '查询词条：「$cleanTerm」\n'
        '当前进度：第 ${safeIdx + 1} 章《${chapters[safeIdx].title}》\n'
        '$archiveSummary\n'
        '截至当前进度的已读原文证据：\n$evidenceText';

    final reply = await _chatWithFailover(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
    );

    return AiTermLookupResult(
      term: cleanTerm,
      explanation: reply.content,
      matchedSnippets: snippets.reversed.toList(),
      matchedCharacter: matchedChar,
      knownAliases: matchedAliases,
      modelName: reply.modelName,
      latencyMs: reply.latencyMs,
    );
  }

  /// 调用已配置的主文本模型（连续失败自动降级至兜底文本模型）
  Future<({String content, String modelName, int latencyMs})> _chatWithFailover({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final status = await _configService.loadAndValidateConfig(
      autoInitPreset: true,
    );
    final cfg = status.config;
    if (cfg == null) {
      throw const FormatException('尚未配置 AI 文本模型，请先在「沉浸式听书设置」或 WebDAV 中同步配置');
    }

    final candidates = <TextAnalysisConfig>[];
    final primary = cfg.primaryTextModel;
    if (primary.enabled &&
        primary.baseUrl.trim().isNotEmpty &&
        primary.modelId.trim().isNotEmpty &&
        !primary.baseUrl.contains('example.invalid')) {
      candidates.add(primary);
    }
    final fallback = cfg.fallbackTextModel;
    if (fallback != null &&
        fallback.enabled &&
        fallback.effectiveId != primary.effectiveId &&
        fallback.baseUrl.trim().isNotEmpty &&
        fallback.modelId.trim().isNotEmpty &&
        !fallback.baseUrl.contains('example.invalid')) {
      candidates.add(fallback);
    }
    if (candidates.isEmpty) {
      throw const FormatException('未找到可用的文本模型配置，请先填写 API 地址、模型名与 API Key');
    }

    Object? lastError;
    for (final modelCfg in candidates) {
      final apiKey = _configService.resolveTextModelApiKey(modelCfg).trim();
      final isLocalLoopback =
          modelCfg.baseUrl.contains('127.0.0.1') ||
          modelCfg.baseUrl.contains('localhost');
      if (apiKey.isEmpty && !isLocalLoopback) {
        lastError = const FormatException(
          '当前文本模型未配置 API Key，请先在「沉浸式听书设置」中填写或通过 WebDAV 拉取云端配置',
        );
        continue;
      }
      try {
        return await _sendChatRequest(
          modelCfg: modelCfg,
          apiKey: apiKey,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const FormatException('AI 请求失败，请检查网络或模型配置');
  }

  Future<({String content, String modelName, int latencyMs})> _sendChatRequest({
    required TextAnalysisConfig modelCfg,
    required String apiKey,
    required String systemPrompt,
    required String userPrompt,
  }) async {
    final sw = Stopwatch()..start();
    final endpoint = _joinUrl(modelCfg.baseUrl, modelCfg.endpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final body = <String, dynamic>{
      'model': modelCfg.modelId,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'stream': false,
    };
    if (modelCfg.maxOutputTokens != null) {
      body[modelCfg.outputLimitParameter] =
          modelCfg.maxOutputTokens! < 1200 ? modelCfg.maxOutputTokens! : 1200;
    }
    if (modelCfg.temperature != null) {
      body['temperature'] = modelCfg.temperature;
    }

    final resp = await _httpClient
        .post(endpoint, headers: headers, body: jsonEncode(body))
        .timeout(
          Duration(milliseconds: modelCfg.requestTimeoutMs.clamp(15000, 90000)),
        );
    sw.stop();

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final preview = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final short = preview.length > 160 ? preview.substring(0, 160) : preview;
      throw FormatException('模型接口返回 HTTP ${resp.statusCode}：$short');
    }

    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('模型响应格式异常');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('模型未返回有效回复内容');
    }
    final message = (choices.first as Map)['message'];
    final rawContent = message is Map ? (message['content']?.toString() ?? '') : '';
    final cleaned = stripThinkingTags(rawContent).trim();
    if (cleaned.isEmpty) {
      throw const FormatException('模型返回正文为空');
    }
    return (
      content: cleaned,
      modelName: modelCfg.displayName.isNotEmpty
          ? modelCfg.displayName
          : modelCfg.modelId,
      latencyMs: sw.elapsedMilliseconds,
    );
  }

  /// 剥离推理模型可能夹带的 `<think>...</think>` 思考段
  static String stripThinkingTags(String input) {
    return input
        .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
        .trim();
  }

  static Uri _joinUrl(String baseUrl, String endpointPath) {
    final trimmedBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final trimmedPath = endpointPath.trim().replaceAll(RegExp(r'^/+'), '');
    return Uri.parse('$trimmedBase/$trimmedPath');
  }
}
