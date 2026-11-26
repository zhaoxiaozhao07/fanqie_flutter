import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/immersive_config.dart';
import '../models/immersive_entities.dart';

/// 文本模型调用错误分类（明确区分可重试临时错误与不可重试配置/协议错误）
enum TextModelErrorKind {
  authFailed,
  rateLimited,
  unsupportedStructuredOutput,
  schemaViolation,
  truncated,
  refusal,
  badRequest,
  transientNetwork,
  cancelled,
}

/// 文本模型结构化调用异常
class TextModelException implements Exception {
  final TextModelErrorKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  const TextModelException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
  });

  bool get isRetryable =>
      kind == TextModelErrorKind.rateLimited ||
      kind == TextModelErrorKind.transientNetwork;

  bool get isBlockingConfigOrProtocol =>
      kind == TextModelErrorKind.authFailed ||
      kind == TextModelErrorKind.unsupportedStructuredOutput ||
      kind == TextModelErrorKind.badRequest;

  @override
  String toString() => message;
}

/// 文本模型返回的结构化结果封装
class StructuredModelResponse {
  final Map<String, dynamic> data;
  final int promptTokens;
  final int completionTokens;
  final int reasoningTokens;
  final int latencyMs;
  final String schemaVersion;

  const StructuredModelResponse({
    required this.data,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.reasoningTokens = 0,
    required this.latencyMs,
    required this.schemaVersion,
  });
}

/// 连接测试报告
class AnalysisProviderTestResult {
  final bool success;
  final String message;
  final int latencyMs;
  final String modeUsed;
  final int? reasoningTokens;

  const AnalysisProviderTestResult({
    required this.success,
    required this.message,
    required this.latencyMs,
    required this.modeUsed,
    this.reasoningTokens,
  });
}

/// 独立版本化的原生 JSON Schema 注册表（使用 anyOf 兼容 OpenAI 与 MiniMax 严格模式）
class ImmersiveNativeSchemas {
  static const chunkAnalysisVersion = 'chunk_analysis_v1';
  static const identityRecheckVersion = 'identity_recheck_v1';
  static const summaryUpdateVersion = 'summary_update_v1';

  static Map<String, dynamic> chunkAnalysisSchema() => {
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'assignments',
      'new_character_proposals',
      'identity_link_proposals',
      'unresolved_items',
    ],
    'properties': {
      'assignments': {
        'type': 'array',
        'description': '按原文顺序恰好覆盖 target_units 全部单元的分配列表',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'source_unit_ids',
            'kind',
            'speaker_ref',
            'evidence_unit_ids',
            'evidence_type',
          ],
          'properties': {
            'source_unit_ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'kind': {
              'type': 'string',
              'enum': ['narration', 'dialogue', 'inner_monologue', 'quoted_text'],
            },
            'speaker_ref': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'null'},
              ],
            },
            'evidence_unit_ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'evidence_type': {
              'type': 'string',
              'enum': [
                'explicit_attribution',
                'confirmed_continuation',
                'context_inference',
                'unresolved',
              ],
            },
          },
        },
      },
      'new_character_proposals': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'local_ref',
            'display_name',
            'gender',
            'suggested_voice_profile_id',
            'evidence_unit_ids',
          ],
          'properties': {
            'local_ref': {'type': 'string'},
            'display_name': {'type': 'string'},
            'gender': {
              'type': 'string',
              'enum': ['male', 'female', 'neutral', 'unknown'],
            },
            'suggested_voice_profile_id': {
              'anyOf': [
                {'type': 'string'},
                {'type': 'null'},
              ],
            },
            'evidence_unit_ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
      },
      'identity_link_proposals': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'from_ref',
            'to_ref',
            'evidence_unit_ids',
            'relation_type',
          ],
          'properties': {
            'from_ref': {'type': 'string'},
            'to_ref': {'type': 'string'},
            'evidence_unit_ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'relation_type': {
              'type': 'string',
              'enum': ['same_person_candidate'],
            },
          },
        },
      },
      'unresolved_items': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'source_unit_ids',
            'candidate_speaker_refs',
            'issue_type',
          ],
          'properties': {
            'source_unit_ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'candidate_speaker_refs': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'issue_type': {'type': 'string'},
          },
        },
      },
    },
  };

  static Map<String, dynamic> identityRecheckSchema() => {
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'decision',
      'resolved_character_id',
      'suggested_name',
      'gender',
      'suggested_voice_profile_id',
      'evidence_unit_ids',
      'reason',
    ],
    'properties': {
      'decision': {
        'type': 'string',
        'enum': ['resolved_existing', 'confirmed_new', 'unresolved', 'conflict'],
      },
      'resolved_character_id': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
      'suggested_name': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
      'gender': {
        'type': 'string',
        'enum': ['male', 'female', 'neutral', 'unknown'],
      },
      'suggested_voice_profile_id': {
        'anyOf': [
          {'type': 'string'},
          {'type': 'null'},
        ],
      },
      'evidence_unit_ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'reason': {'type': 'string'},
    },
  };

  static Map<String, dynamic> summaryUpdateSchema() => {
    'type': 'object',
    'additionalProperties': false,
    'required': ['chapter_summary', 'active_character_ids'],
    'properties': {
      'chapter_summary': {'type': 'string'},
      'active_character_ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
  };

  /// 本地严格校验返回对象是否完全匹配 chunk_analysis_v1 核心契约
  /// 自动补齐省略的可空/空数组字段，清洗模型偶发的多余无关键，但严格校验必填字段、类型与枚举值
  static void validateChunkAnalysisPayload(Map<String, dynamic> data) {
    const rootKeys = {
      'assignments',
      'new_character_proposals',
      'identity_link_proposals',
      'unresolved_items',
    };
    if (!data.containsKey('assignments')) {
      throw const TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: '结构化输出 chunk_analysis 缺少必填字段 assignments',
      );
    }
    for (final listKey in const [
      'new_character_proposals',
      'identity_link_proposals',
      'unresolved_items',
    ]) {
      if (!data.containsKey(listKey) || data[listKey] == null) {
        data[listKey] = <dynamic>[];
      }
    }
    _sanitizeToAllowedKeys(data, rootKeys);
    final assignments = _assertList(data['assignments'], 'assignments');
    final normalizedAssignments = <Map<String, dynamic>>[];
    for (var i = 0; i < assignments.length; i++) {
      final m = _assertMap(assignments[i], 'assignments[$i]');
      if (!m.containsKey('speaker_ref')) {
        m['speaker_ref'] = null;
      }
      if (!m.containsKey('evidence_unit_ids') || m['evidence_unit_ids'] == null) {
        m['evidence_unit_ids'] = <String>[];
      }
      if (!m.containsKey('evidence_type') || m['evidence_type'] == null) {
        m['evidence_type'] = 'explicit';
      }
      const allowedAssignmentKeys = {
        'source_unit_ids',
        'kind',
        'speaker_ref',
        'evidence_unit_ids',
        'evidence_type',
      };
      _sanitizeToAllowedKeys(m, allowedAssignmentKeys);
      _assertRequiredKeys(m, allowedAssignmentKeys, 'assignments[$i]');
      _assertStringList(m['source_unit_ids'], 'assignments[$i].source_unit_ids');
      final kind = m['kind'];
      if (kind is! String || !AllocationKind.values.contains(kind)) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'assignments[$i].kind 值非法：$kind',
        );
      }
      final ref = m['speaker_ref'];
      if (ref != null && ref is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'assignments[$i].speaker_ref 必须为字符串或 null',
        );
      }
      if (ref is String && ref.trim().isEmpty) {
        m['speaker_ref'] = null;
      }
      _assertStringList(
        m['evidence_unit_ids'],
        'assignments[$i].evidence_unit_ids',
      );
      final et = m['evidence_type'];
      if (et is! String || !EvidenceType.values.contains(et)) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'assignments[$i].evidence_type 值非法：$et',
        );
      }
      normalizedAssignments.add(m);
    }
    data['assignments'] = normalizedAssignments;

    final proposals = _assertList(
      data['new_character_proposals'],
      'new_character_proposals',
    );
    final normalizedProposals = <Map<String, dynamic>>[];
    for (var i = 0; i < proposals.length; i++) {
      final m = _assertMap(proposals[i], 'new_character_proposals[$i]');
      if (!m.containsKey('suggested_voice_profile_id')) {
        m['suggested_voice_profile_id'] = null;
      }
      if (!m.containsKey('evidence_unit_ids') || m['evidence_unit_ids'] == null) {
        m['evidence_unit_ids'] = <String>[];
      }
      if (!m.containsKey('gender') || m['gender'] == null) {
        m['gender'] = 'unknown';
      }
      const allowedProposalKeys = {
        'local_ref',
        'display_name',
        'gender',
        'suggested_voice_profile_id',
        'evidence_unit_ids',
      };
      _sanitizeToAllowedKeys(m, allowedProposalKeys);
      _assertRequiredKeys(
        m,
        allowedProposalKeys,
        'new_character_proposals[$i]',
      );
      if (m['local_ref'] is! String || (m['local_ref'] as String).isEmpty) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'new_character_proposals[$i].local_ref 非法',
        );
      }
      if (m['display_name'] is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'new_character_proposals[$i].display_name 非法',
        );
      }
      if (m['gender'] is! String ||
          !const {'male', 'female', 'neutral', 'unknown'}.contains(m['gender'])) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'new_character_proposals[$i].gender 值非法：${m['gender']}',
        );
      }
      final sv = m['suggested_voice_profile_id'];
      if (sv != null && sv is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'new_character_proposals[$i].suggested_voice_profile_id 非法',
        );
      }
      if (sv is String && sv.trim().isEmpty) {
        m['suggested_voice_profile_id'] = null;
      }
      _assertStringList(
        m['evidence_unit_ids'],
        'new_character_proposals[$i].evidence_unit_ids',
      );
      normalizedProposals.add(m);
    }
    data['new_character_proposals'] = normalizedProposals;

    final links = _assertList(
      data['identity_link_proposals'],
      'identity_link_proposals',
    );
    final normalizedLinks = <Map<String, dynamic>>[];
    for (var i = 0; i < links.length; i++) {
      final m = _assertMap(links[i], 'identity_link_proposals[$i]');
      if (!m.containsKey('evidence_unit_ids') || m['evidence_unit_ids'] == null) {
        m['evidence_unit_ids'] = <String>[];
      }
      if (!m.containsKey('relation_type') || m['relation_type'] == null) {
        m['relation_type'] = 'same_person_candidate';
      }
      const allowedLinkKeys = {
        'from_ref',
        'to_ref',
        'evidence_unit_ids',
        'relation_type',
      };
      _sanitizeToAllowedKeys(m, allowedLinkKeys);
      _assertRequiredKeys(m, allowedLinkKeys, 'identity_link_proposals[$i]');
      if (m['from_ref'] is! String || m['to_ref'] is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'identity_link_proposals[$i] 引用字段非法',
        );
      }
      if (m['relation_type'] != 'same_person_candidate') {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'identity_link_proposals[$i].relation_type 必须为 same_person_candidate',
        );
      }
      _assertStringList(
        m['evidence_unit_ids'],
        'identity_link_proposals[$i].evidence_unit_ids',
      );
      normalizedLinks.add(m);
    }
    data['identity_link_proposals'] = normalizedLinks;

    final unresolved = _assertList(data['unresolved_items'], 'unresolved_items');
    final normalizedUnresolved = <Map<String, dynamic>>[];
    for (var i = 0; i < unresolved.length; i++) {
      final m = _assertMap(unresolved[i], 'unresolved_items[$i]');
      if (!m.containsKey('candidate_speaker_refs') ||
          m['candidate_speaker_refs'] == null) {
        m['candidate_speaker_refs'] = <String>[];
      }
      if (!m.containsKey('issue_type') || m['issue_type'] == null) {
        m['issue_type'] = 'ambiguous_speaker';
      }
      const allowedUnresolvedKeys = {
        'source_unit_ids',
        'candidate_speaker_refs',
        'issue_type',
      };
      _sanitizeToAllowedKeys(m, allowedUnresolvedKeys);
      _assertRequiredKeys(m, allowedUnresolvedKeys, 'unresolved_items[$i]');
      _assertStringList(
        m['source_unit_ids'],
        'unresolved_items[$i].source_unit_ids',
      );
      _assertStringList(
        m['candidate_speaker_refs'],
        'unresolved_items[$i].candidate_speaker_refs',
      );
      if (m['issue_type'] is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: 'unresolved_items[$i].issue_type 必须为字符串',
        );
      }
      normalizedUnresolved.add(m);
    }
    data['unresolved_items'] = normalizedUnresolved;
  }

  /// 本地严格校验身份复核结果
  static void validateIdentityRecheckPayload(Map<String, dynamic> data) {
    for (final nullableKey in const [
      'resolved_character_id',
      'suggested_name',
      'suggested_voice_profile_id',
    ]) {
      if (!data.containsKey(nullableKey)) {
        data[nullableKey] = null;
      }
    }
    if (!data.containsKey('evidence_unit_ids') ||
        data['evidence_unit_ids'] == null) {
      data['evidence_unit_ids'] = <String>[];
    }
    if (!data.containsKey('reason') || data['reason'] == null) {
      data['reason'] = '';
    }
    if (!data.containsKey('gender') || data['gender'] == null) {
      data['gender'] = 'unknown';
    }
    const allowedKeys = {
      'decision',
      'resolved_character_id',
      'suggested_name',
      'gender',
      'suggested_voice_profile_id',
      'evidence_unit_ids',
      'reason',
    };
    _sanitizeToAllowedKeys(data, allowedKeys);
    _assertRequiredKeys(data, allowedKeys, 'identity_recheck');
    if (!const {
      'resolved_existing',
      'confirmed_new',
      'unresolved',
      'conflict',
    }.contains(data['decision'])) {
      throw TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: 'identity_recheck.decision 值非法：${data['decision']}',
      );
    }
    if (!const {'male', 'female', 'neutral', 'unknown'}.contains(data['gender'])) {
      throw TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: 'identity_recheck.gender 值非法：${data['gender']}',
      );
    }
    _assertStringList(
      data['evidence_unit_ids'],
      'identity_recheck.evidence_unit_ids',
    );
    if (data['reason'] is! String) {
      throw const TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: 'identity_recheck.reason 必须为字符串',
      );
    }
  }

  /// 本地严格校验摘要更新结果
  static void validateSummaryUpdatePayload(Map<String, dynamic> data) {
    if (!data.containsKey('active_character_ids') ||
        data['active_character_ids'] == null) {
      data['active_character_ids'] = <String>[];
    }
    const allowed = {'chapter_summary', 'active_character_ids'};
    _sanitizeToAllowedKeys(data, allowed);
    _assertRequiredKeys(data, allowed, 'summary_update');
    if (data['chapter_summary'] is! String) {
      throw const TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: 'summary_update.chapter_summary 必须为字符串',
      );
    }
    _assertStringList(
      data['active_character_ids'],
      'summary_update.active_character_ids',
    );
  }

  static void _sanitizeToAllowedKeys(
    Map<String, dynamic> map,
    Set<String> allowed,
  ) {
    final extraKeys = map.keys.where((k) => !allowed.contains(k)).toList();
    for (final k in extraKeys) {
      map.remove(k);
    }
  }

  static void _assertRequiredKeys(
    Map<String, dynamic> map,
    Set<String> expected,
    String path,
  ) {
    for (final k in expected) {
      if (!map.containsKey(k)) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '结构化输出 $path 缺少必填字段 $k',
        );
      }
    }
  }

  static List<dynamic> _assertList(Object? v, String path) {
    if (v is! List) {
      throw TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: '结构化输出 $path 必须为数组',
      );
    }
    return v;
  }

  static Map<String, dynamic> _assertMap(Object? v, String path) {
    if (v is! Map) {
      throw TextModelException(
        kind: TextModelErrorKind.schemaViolation,
        message: '结构化输出 $path 必须为对象',
      );
    }
    return Map<String, dynamic>.from(v);
  }

  static void _assertStringList(Object? v, String path) {
    final list = _assertList(v, path);
    for (final item in list) {
      if (item is! String) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '结构化输出 $path 数组元素必须为字符串',
        );
      }
    }
  }
}

/// 文本分析模型适配器抽象接口（方便注入可控模拟器测试）
abstract class TextModelAdapter {
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  });

  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  });

  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  });

  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  });

  void cancelAll();
}

/// OpenAI Chat Completions 原生结构化适配器
/// 支持标准 response_format.json_schema 与已注册的 vendor_native(openai_tool_call_schema)
class OpenAiChatTextModelAdapter implements TextModelAdapter {
  final http.Client _client;
  final Set<Completer<void>> _active = {};

  OpenAiChatTextModelAdapter(this._client);

  @override
  void cancelAll() {
    for (final c in _active.toList()) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// 调用 OpenAI 兼容 `/v1/models`（智能兼容 `/models` 与 `/v1/models`）拉取可用模型 ID 列表
  static Future<List<String>> fetchAvailableModels({
    required String baseUrl,
    String apiKey = '',
    Map<String, String> extraHeaders = const {},
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final trimmedUrl = baseUrl.trim();
    if (trimmedUrl.isEmpty) {
      throw const FormatException('请先填写 Base URL 后再获取模型列表');
    }
    if (isExampleReservedEndpoint(trimmedUrl) ||
        isTemplatePlaceholderValue(apiKey)) {
      throw const FormatException('当前接口地址或密钥仍为示例占位值，无法拉取模型列表');
    }

    final parsedBase = Uri.tryParse(trimmedUrl);
    if (parsedBase == null ||
        !parsedBase.hasScheme ||
        (parsedBase.scheme != 'http' && parsedBase.scheme != 'https')) {
      throw const FormatException('Base URL 格式无效，必须以 http:// 或 https:// 开头');
    }

    final headers = <String, String>{'Accept': 'application/json'};
    extraHeaders.forEach((k, v) {
      if (ProtectedProtocolFields.headersLower.contains(k.toLowerCase())) {
        throw FormatException('extra_headers 不允许覆盖受保护请求头 $k');
      }
      headers[k] = v;
    });
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $trimmedKey';
    }

    final normalizedPath = parsedBase.path.replaceAll(RegExp(r'/+$'), '');
    final candidateUris = <Uri>[joinProviderUrl(trimmedUrl, '/models')];
    if (!normalizedPath.endsWith('/v1')) {
      candidateUris.add(joinProviderUrl(trimmedUrl, '/v1/models'));
    }

    final ownClient = client == null;
    final activeClient = client ?? http.Client();
    try {
      String? lastError;
      for (var i = 0; i < candidateUris.length; i++) {
        final uri = candidateUris[i];
        final req = http.Request('GET', uri)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(headers);

        final streamed = await activeClient.send(req).timeout(timeout);
        final bytes = await streamed.stream.toBytes().timeout(timeout);
        final status = streamed.statusCode;
        final bodyStr = utf8.decode(bytes, allowMalformed: true);

        if (status == 401 || status == 403) {
          throw FormatException('模型列表鉴权失败（HTTP $status），请检查 API Key');
        }
        if (status >= 300 && status < 400) {
          throw FormatException('拒绝模型列表接口重定向（HTTP $status），避免转发凭证');
        }
        if ((status == 404 || status == 405) && i + 1 < candidateUris.length) {
          lastError = 'HTTP $status（$uri）';
          continue;
        }
        if (status != 200) {
          final summary = _extractProviderErrorMessage(bodyStr);
          throw FormatException('获取模型列表失败（HTTP $status）：$summary');
        }

        final Object? decoded;
        try {
          decoded = jsonDecode(bodyStr);
        } catch (_) {
          throw const FormatException('模型列表接口返回的内容不是合法 JSON');
        }

        final rawList = decoded is List
            ? decoded
            : (decoded is Map && decoded['data'] is List)
            ? decoded['data'] as List
            : (decoded is Map && decoded['models'] is List)
            ? decoded['models'] as List
            : null;
        if (rawList == null) {
          throw const FormatException('模型列表响应缺少 data 或 models 数组');
        }

        final ids = <String>{};
        for (final item in rawList) {
          String? modelId;
          if (item is String) {
            modelId = item.trim();
          } else if (item is Map) {
            final rawId =
                item['id'] ?? item['model'] ?? item['name'];
            if (rawId != null) {
              modelId = rawId.toString().trim();
              if (item['id'] == null && modelId.startsWith('models/')) {
                modelId = modelId.substring('models/'.length);
              }
            }
          }
          if (modelId != null && modelId.isNotEmpty) {
            ids.add(modelId);
          }
        }

        final sorted = ids.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (sorted.isEmpty) {
          throw const FormatException('接口返回成功，但未发现可用模型');
        }
        return sorted;
      }
      throw FormatException('获取模型列表失败：${lastError ?? '未知错误'}');
    } on TimeoutException {
      throw const FormatException('获取模型列表超时，请检查网络或 Base URL');
    } finally {
      if (ownClient) {
        activeClient.close();
      }
    }
  }

  /// 剥离模型返回中的思考标签（`<think>...</think>` 等）与 Markdown 代码块围栏，
  /// 仅当剥离后的净正文是完整 JSON 对象时返回该 JSON 文本（绝不对闲聊正文做正则兜底抓取）
  static ({String cleaned, bool hadThinkingTag}) stripThinkingAndCodeFence(
    String raw,
  ) {
    var text = raw.replaceFirst('\uFEFF', '').trim();
    text = text
        .replaceAll(RegExp(r'<\|(?:im_end|endoftext|eot_id)\|>'), '')
        .replaceAll('<｜end▁of▁sentence｜>', '')
        .trim();
    var hadThinking = false;
    // 移除成对的 <think>/<thinking>/<reasoning>/<thought> 标签及其内容
    final pairedRegex = RegExp(
      r'<(think|thinking|reasoning|thought)\b[^>]*>[\s\S]*?<\/\1>',
      caseSensitive: false,
    );
    while (pairedRegex.hasMatch(text)) {
      hadThinking = true;
      text = text.replaceAll(pairedRegex, '').trim();
    }
    // 处理仅含闭合标签 </think> 的前缀思考输出
    final closeTagRegex = RegExp(
      r'^[\s\S]*?<\/(think|thinking|reasoning|thought)>',
      caseSensitive: false,
    );
    if (closeTagRegex.hasMatch(text)) {
      hadThinking = true;
      text = text.replaceFirst(closeTagRegex, '').trim();
    }
    // 处理 Markdown ```json ... ``` 围栏包裹
    final fenceMatch = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(text);
    if (fenceMatch != null) {
      text = (fenceMatch.group(1) ?? '').trim();
    }
    return (cleaned: text, hadThinkingTag: hadThinking);
  }

  /// 构建对外请求体（供单测与真实调用复用，保证标准 OpenAI 兼容协议一致）
  static Map<String, dynamic> buildRequestBody({
    required TextAnalysisConfig config,
    required String taskSchemaSuffix,
    required String toolDescription,
    required Map<String, dynamic> schema,
    required String systemMessage,
    required String userMessage,
    String? overrideReasoningEffort,
    bool omitReasoningEffort = false,
    String? overrideStructuredMode,
  }) {
    if (config.structuredOutput.allowPromptOnlyFallback) {
      throw const TextModelException(
        kind: TextModelErrorKind.badRequest,
        message: '严禁启用提示词 JSON 兜底模式',
      );
    }
    for (final k in config.extraBody.keys) {
      if (ProtectedProtocolFields.textBody.contains(k)) {
        throw TextModelException(
          kind: TextModelErrorKind.badRequest,
          message: 'extra_body 不允许覆盖受保护协议字段 $k',
        );
      }
    }

    final schemaName =
        '${config.structuredOutput.schemaNamePrefix}_$taskSchemaSuffix';

    final body = <String, dynamic>{
      ...config.extraBody,
      'model': config.modelId,
      'messages': [
        {'role': 'system', 'content': systemMessage},
        {'role': 'user', 'content': userMessage},
      ],
      'stream': false,
    };

    // 按思考程度设置标准 OpenAI reasoning_effort；auto 默认不强行发送，保持最广兼容性
    if (omitReasoningEffort) {
      body.remove('reasoning_effort');
      body.remove('thinking');
      body.remove('enable_thinking');
    } else if (overrideReasoningEffort != null &&
        overrideReasoningEffort.isNotEmpty) {
      body['reasoning_effort'] = overrideReasoningEffort;
    } else if (!body.containsKey('reasoning_effort')) {
      switch (config.thinkingLevel) {
        case TextThinkingLevel.none:
        case TextThinkingLevel.off:
          body['reasoning_effort'] = 'none';
          break;
        case TextThinkingLevel.minimal:
        case TextThinkingLevel.low:
        case TextThinkingLevel.medium:
        case TextThinkingLevel.high:
        case TextThinkingLevel.max:
          body['reasoning_effort'] = config.thinkingLevel;
          break;
        case TextThinkingLevel.auto:
        default:
          break;
      }
    }

    // 最大输出非空时按配置发送输出上限字段；留空（null）时严格不传入该字段
    if (config.maxOutputTokens != null) {
      body[config.outputLimitParameter] = config.maxOutputTokens;
    }

    // temperature 为 null 时严格省略，不发送 null 字符串
    if (config.temperature != null) {
      body['temperature'] = config.temperature;
    }

    final mode = overrideStructuredMode ?? config.structuredOutput.mode;
    final useVendorToolCall =
        mode == 'vendor_native' &&
        (overrideStructuredMode == 'vendor_native' ||
            config.structuredOutput.vendorAdapterId ==
                'openai_tool_call_schema');
    if (mode == 'json_schema') {
      body['response_format'] = {
        'type': 'json_schema',
        'json_schema': {
          'name': schemaName,
          'strict': config.structuredOutput.strict,
          'schema': schema,
        },
      };
    } else if (useVendorToolCall) {
      // 标准 OpenAI Function Calling 强制严格 Schema 协议（已在 MiniMax / GLM / Qwen 实测通过）
      body['tools'] = [
        {
          'type': 'function',
          'function': {
            'name': schemaName,
            'description': toolDescription,
            'strict': config.structuredOutput.strict,
            'parameters': schema,
          },
        },
      ];
      body['tool_choice'] = {
        'type': 'function',
        'function': {'name': schemaName},
      };
    } else {
      throw TextModelException(
        kind: TextModelErrorKind.unsupportedStructuredOutput,
        message:
            '不支持的结构化输出配置：mode=$mode, vendor_adapter_id=${config.structuredOutput.vendorAdapterId}',
      );
    }

    return body;
  }

  @override
  Future<StructuredModelResponse> analyzeChunk({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    final resp = await _invokeStructured(
      config: config,
      apiKey: apiKey,
      taskSchemaSuffix: ImmersiveNativeSchemas.chunkAnalysisVersion,
      toolDescription: '提交本分析分块的角色与音色结构化分配结果',
      schema: ImmersiveNativeSchemas.chunkAnalysisSchema(),
      systemMessage: systemMessage,
      userMessage: userMessage,
      isCancelled: isCancelled,
    );
    ImmersiveNativeSchemas.validateChunkAnalysisPayload(resp.data);
    return resp;
  }

  @override
  Future<StructuredModelResponse> recheckIdentity({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    final resp = await _invokeStructured(
      config: config,
      apiKey: apiKey,
      taskSchemaSuffix: ImmersiveNativeSchemas.identityRecheckVersion,
      toolDescription: '提交局部角色身份复核裁决结果',
      schema: ImmersiveNativeSchemas.identityRecheckSchema(),
      systemMessage: systemMessage,
      userMessage: userMessage,
      isCancelled: isCancelled,
    );
    ImmersiveNativeSchemas.validateIdentityRecheckPayload(resp.data);
    return resp;
  }

  @override
  Future<StructuredModelResponse> updateSummary({
    required TextAnalysisConfig config,
    required String apiKey,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
  }) async {
    final resp = await _invokeStructured(
      config: config,
      apiKey: apiKey,
      taskSchemaSuffix: ImmersiveNativeSchemas.summaryUpdateVersion,
      toolDescription: '提交当前已确认前沿的剧情摘要更新',
      schema: ImmersiveNativeSchemas.summaryUpdateSchema(),
      systemMessage: systemMessage,
      userMessage: userMessage,
      isCancelled: isCancelled,
    );
    ImmersiveNativeSchemas.validateSummaryUpdatePayload(resp.data);
    return resp;
  }

  @override
  Future<AnalysisProviderTestResult> testProvider({
    required TextAnalysisConfig config,
    required String apiKey,
  }) async {
    final modeDesc = config.structuredOutput.mode == 'vendor_native'
        ? 'vendor_native(${config.structuredOutput.vendorAdapterId})'
        : 'json_schema';
    final sw = Stopwatch()..start();
    try {
      StructuredModelResponse resp;
      try {
        resp = await _runProbeChunk(config, apiKey);
      } on TextModelException catch (e) {
        if (e.kind == TextModelErrorKind.rateLimited) {
          await Future<void>.delayed(
            e.retryAfter ?? const Duration(seconds: 2),
          );
          resp = await _runProbeChunk(config, apiKey);
        } else {
          rethrow;
        }
      }
      sw.stop();
      final assignments = resp.data['assignments'] as List;
      if (assignments.isEmpty) {
        return AnalysisProviderTestResult(
          success: false,
          message: '接口返回了空的 assignments 列表，结构化输出未产生有效内容',
          latencyMs: sw.elapsedMilliseconds,
          modeUsed: modeDesc,
          reasoningTokens: resp.reasoningTokens,
        );
      }
      return AnalysisProviderTestResult(
        success: true,
        message:
            '${config.modelId} JSON 结构化测试通过（${assignments.length} 条分配，耗时 ${sw.elapsedMilliseconds}ms，思考档位=${config.thinkingLevel}，思考 token=${resp.reasoningTokens}）',
        latencyMs: sw.elapsedMilliseconds,
        modeUsed: modeDesc,
        reasoningTokens: resp.reasoningTokens,
      );
    } on TextModelException catch (e) {
      sw.stop();
      return AnalysisProviderTestResult(
        success: false,
        message: '${config.modelId} 测试失败：${e.message}',
        latencyMs: sw.elapsedMilliseconds,
        modeUsed: modeDesc,
      );
    } catch (e) {
      sw.stop();
      return AnalysisProviderTestResult(
        success: false,
        message: '${config.modelId} 连接测试异常：$e',
        latencyMs: sw.elapsedMilliseconds,
        modeUsed: modeDesc,
      );
    }
  }

  Future<StructuredModelResponse> _runProbeChunk(
    TextAnalysisConfig config,
    String apiKey,
  ) {
    return analyzeChunk(
      config: config,
      apiKey: apiKey,
      systemMessage:
          '你是沉浸式听书角色分配分析器。请分析 target_units 的每一条原文单元，'
          '非直接对白（narration/inner_monologue/quoted_text）speaker_ref 为 "narrator"；'
          '已有角色用其 ID；新角色用 "local:new_1" 并在 new_character_proposals 中声明。'
          '候选人物音色：vp_test_male(male), vp_test_female(female)；固定旁白：narrator。',
      userMessage:
          'target_units:\n'
          'u1: 林岚问：\n'
          'u2: “你来了？”\n'
          'u3: 陈舟答道：\n'
          'u4: “刚到。”',
    );
  }

  Future<StructuredModelResponse> _invokeStructured({
    required TextAnalysisConfig config,
    required String apiKey,
    required String taskSchemaSuffix,
    required String toolDescription,
    required Map<String, dynamic> schema,
    required String systemMessage,
    required String userMessage,
    bool Function()? isCancelled,
    String? overrideReasoningEffort,
    bool omitReasoningEffort = false,
    bool allowAdaptiveRetry = true,
    String? overrideStructuredMode,
    bool allowProtocolNegotiation = true,
  }) async {
    final modelTag = config.displayName.trim().isNotEmpty
        ? config.displayName.trim()
        : config.modelId;
    final activeMode = overrideStructuredMode ?? config.structuredOutput.mode;
    final alternateMode = activeMode == 'vendor_native'
        ? 'json_schema'
        : 'vendor_native';

    if (isCancelled?.call() == true) {
      throw TextModelException(
        kind: TextModelErrorKind.cancelled,
        message: '[$modelTag] 文本分析请求已取消',
      );
    }
    if (isExampleReservedEndpoint(config.baseUrl) ||
        isTemplatePlaceholderValue(config.modelId) ||
        isTemplatePlaceholderValue(apiKey)) {
      throw TextModelException(
        kind: TextModelErrorKind.badRequest,
        message: '[$modelTag] 文本分析配置仍包含示例占位值，已阻止发出真实请求',
      );
    }

    final uri = joinProviderUrl(config.baseUrl, config.endpoint);
    final payload = buildRequestBody(
      config: config,
      taskSchemaSuffix: taskSchemaSuffix,
      toolDescription: toolDescription,
      schema: schema,
      systemMessage: systemMessage,
      userMessage: userMessage,
      overrideReasoningEffort: overrideReasoningEffort,
      omitReasoningEffort: omitReasoningEffort,
      overrideStructuredMode: overrideStructuredMode,
    );

    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };
    config.extraHeaders.forEach((k, v) {
      if (ProtectedProtocolFields.headersLower.contains(k.toLowerCase())) {
        throw TextModelException(
          kind: TextModelErrorKind.badRequest,
          message: '[$modelTag] extra_headers 不允许覆盖受保护请求头 $k',
        );
      }
      headers[k] = v;
    });
    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    final abort = Completer<void>();
    _active.add(abort);
    var timedOut = false;
    final sw = Stopwatch()..start();
    final timer = Timer(Duration(milliseconds: config.requestTimeoutMs), () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });

    try {
      final request = http.AbortableRequest('POST', uri, abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers.addAll(headers)
        ..body = jsonEncode(payload);

      final sending = _client.send(request);
      unawaited(
        sending.then<void>((resp) async {
          if (abort.isCompleted) {
            await resp.stream.listen((_) {}).cancel();
          }
        }, onError: (Object _, StackTrace _) {}),
      );

      final streamed = await Future.any<http.StreamedResponse>([
        sending,
        abort.future.then<http.StreamedResponse>((_) {
          if (!timedOut || isCancelled?.call() == true) {
            throw TextModelException(
              kind: TextModelErrorKind.cancelled,
              message: '[$modelTag] 文本分析请求已取消',
            );
          }
          throw TextModelException(
            kind: TextModelErrorKind.transientNetwork,
            message: '[$modelTag] 文本分析请求超时',
          );
        }),
      ]);

      final responseBytes = await Future.any<List<int>>([
        streamed.stream.toBytes(),
        abort.future.then<List<int>>((_) {
          if (!timedOut || isCancelled?.call() == true) {
            throw TextModelException(
              kind: TextModelErrorKind.cancelled,
              message: '[$modelTag] 文本分析请求已取消',
            );
          }
          throw TextModelException(
            kind: TextModelErrorKind.transientNetwork,
            message: '[$modelTag] 文本分析响应读取超时',
          );
        }),
      ]);

      sw.stop();
      final status = streamed.statusCode;
      final bodyStr = utf8.decode(responseBytes, allowMalformed: true);

      if (status == 401 || status == 403) {
        throw TextModelException(
          kind: TextModelErrorKind.authFailed,
          message: '[$modelTag] 文本模型鉴权失败（HTTP $status），请检查 API Key 或权限',
          statusCode: status,
        );
      }
      if (status == 429) {
        final raSec = int.tryParse(streamed.headers['retry-after'] ?? '');
        throw TextModelException(
          kind: TextModelErrorKind.rateLimited,
          message: '[$modelTag] 文本模型触发限流（HTTP 429）',
          statusCode: status,
          retryAfter: raSec == null ? null : Duration(seconds: raSec.clamp(1, 60)),
        );
      }
      if (status >= 500) {
        throw TextModelException(
          kind: TextModelErrorKind.transientNetwork,
          message: '[$modelTag] 文本模型服务端临时错误（HTTP $status）',
          statusCode: status,
        );
      }
      if (status >= 300 && status < 400) {
        throw TextModelException(
          kind: TextModelErrorKind.badRequest,
          message: '[$modelTag] 拒绝文本模型重定向（HTTP $status），避免转发凭证',
          statusCode: status,
        );
      }
      if (status != 200) {
        final errSummary = _extractProviderErrorMessage(bodyStr);
        final lower = errSummary.toLowerCase();
        // 自适应兼容：若服务端拒绝思考控制参数，自动去掉该参数按纯标准 OpenAI 请求重试一次
        if (allowAdaptiveRetry &&
            !omitReasoningEffort &&
            payload.containsKey('reasoning_effort') &&
            (lower.contains('reasoning') ||
                lower.contains('thinking') ||
                lower.contains('思考') ||
                lower.contains('unknown parameter') ||
                lower.contains('unsupported') ||
                lower.contains('invalid') ||
                lower.contains('enum'))) {
          timer.cancel();
          return await _invokeStructured(
            config: config,
            apiKey: apiKey,
            taskSchemaSuffix: taskSchemaSuffix,
            toolDescription: toolDescription,
            schema: schema,
            systemMessage: systemMessage,
            userMessage: userMessage,
            isCancelled: isCancelled,
            omitReasoningEffort: true,
            allowAdaptiveRetry: false,
            overrideStructuredMode: overrideStructuredMode,
            allowProtocolNegotiation: allowProtocolNegotiation,
          );
        }
        if (lower.contains('response_format') ||
            lower.contains('json_schema') ||
            lower.contains('tool_choice') ||
            lower.contains('tools') ||
            lower.contains('structured')) {
          if (allowProtocolNegotiation) {
            timer.cancel();
            return await _invokeStructured(
              config: config,
              apiKey: apiKey,
              taskSchemaSuffix: taskSchemaSuffix,
              toolDescription: toolDescription,
              schema: schema,
              systemMessage: systemMessage,
              userMessage: userMessage,
              isCancelled: isCancelled,
              overrideReasoningEffort: overrideReasoningEffort,
              omitReasoningEffort: omitReasoningEffort,
              allowAdaptiveRetry: allowAdaptiveRetry,
              overrideStructuredMode: alternateMode,
              allowProtocolNegotiation: false,
            );
          }
          throw TextModelException(
            kind: TextModelErrorKind.unsupportedStructuredOutput,
            message: '[$modelTag] 模型不支持当前原生结构化输出协议（HTTP $status）：$errSummary',
            statusCode: status,
          );
        }
        throw TextModelException(
          kind: TextModelErrorKind.badRequest,
          message: '[$modelTag] 文本模型请求被拒绝（HTTP $status）：$errSummary',
          statusCode: status,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(bodyStr);
      } catch (_) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '[$modelTag] 文本模型 HTTP 200 响应体不是有效 JSON',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '[$modelTag] 文本模型响应根节点不是 JSON 对象',
        );
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '[$modelTag] 文本模型响应缺少 choices',
        );
      }
      final choice = Map<String, dynamic>.from(choices.first as Map);
      final finishReason = choice['finish_reason']?.toString() ?? '';
      if (finishReason == 'length') {
        final effectiveEffort =
            overrideReasoningEffort ?? payload['reasoning_effort']?.toString();
        // 若未被显式设为 none 且尚有自适应机会，先尝试关闭思考（none）重试一次以释放输出预算
        if (allowAdaptiveRetry &&
            effectiveEffort != 'none' &&
            config.thinkingLevel != TextThinkingLevel.none &&
            config.thinkingLevel != TextThinkingLevel.off) {
          timer.cancel();
          return await _invokeStructured(
            config: config,
            apiKey: apiKey,
            taskSchemaSuffix: taskSchemaSuffix,
            toolDescription: toolDescription,
            schema: schema,
            systemMessage: systemMessage,
            userMessage: userMessage,
            isCancelled: isCancelled,
            overrideReasoningEffort: 'none',
            allowAdaptiveRetry: false,
            overrideStructuredMode: overrideStructuredMode,
            allowProtocolNegotiation: allowProtocolNegotiation,
          );
        }
        final limitDesc = config.maxOutputTokens == null
            ? '不限'
            : '${config.maxOutputTokens}';
        throw TextModelException(
          kind: TextModelErrorKind.truncated,
          message:
              '[$modelTag] 模型内容被长度上限截断（finish_reason=length，当前最大输出=$limitDesc，思考=${config.thinkingLevel}），请在模型编辑中调大/留空最大输出或将思考程度设为 none',
        );
      }
      if (finishReason == 'content_filter') {
        throw TextModelException(
          kind: TextModelErrorKind.refusal,
          message: '[$modelTag] 文本模型因内容策略拒绝输出（content_filter）',
        );
      }

      final message = choice['message'];
      if (message is! Map) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '[$modelTag] 文本模型响应缺少 message 对象',
        );
      }
      final msgMap = Map<String, dynamic>.from(message);
      if (msgMap['refusal'] != null && msgMap['refusal'].toString().isNotEmpty) {
        throw TextModelException(
          kind: TextModelErrorKind.refusal,
          message: '[$modelTag] 文本模型拒绝响应：${msgMap['refusal']}',
        );
      }

      // 优先读取标准 tool_calls；若模型将严格 JSON（或带 <think> 思考标签的严格 JSON）放在 content 中也自动剥离思考并解析
      String? rawStructuredJson;
      var hadThinkingTag = false;
      var fromToolCalls = false;
      final toolCalls = msgMap['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        final firstCall = toolCalls.first;
        if (firstCall is! Map || firstCall['function'] is! Map) {
          throw TextModelException(
            kind: TextModelErrorKind.schemaViolation,
            message: '[$modelTag] tool_calls[0] 缺少 function 字段',
          );
        }
        final fn = firstCall['function'] as Map;
        final args = fn['arguments'];
        fromToolCalls = true;
        if (args is String) {
          final stripped = stripThinkingAndCodeFence(args);
          hadThinkingTag = stripped.hadThinkingTag;
          rawStructuredJson = stripped.cleaned;
        } else if (args is Map) {
          rawStructuredJson = jsonEncode(args);
        } else {
          throw TextModelException(
            kind: TextModelErrorKind.schemaViolation,
            message: '[$modelTag] tool_calls[0].function.arguments 类型无效',
          );
        }
      } else {
        final content = msgMap['content'];
        if (content is String && content.trim().isNotEmpty) {
          final stripped = stripThinkingAndCodeFence(content);
          hadThinkingTag = stripped.hadThinkingTag;
          final cleaned = stripped.cleaned;
          // 仅接受剥离思考标签与围栏后本身就是完整 JSON 对象的响应，不从闲聊文本做正则兜底
          if (cleaned.startsWith('{') && cleaned.endsWith('}')) {
            rawStructuredJson = cleaned;
          }
        }
      }

      if (rawStructuredJson == null || rawStructuredJson.isEmpty) {
        if (allowProtocolNegotiation) {
          timer.cancel();
          return await _invokeStructured(
            config: config,
            apiKey: apiKey,
            taskSchemaSuffix: taskSchemaSuffix,
            toolDescription: toolDescription,
            schema: schema,
            systemMessage: systemMessage,
            userMessage: userMessage,
            isCancelled: isCancelled,
            overrideReasoningEffort: overrideReasoningEffort,
            omitReasoningEffort: omitReasoningEffort,
            allowAdaptiveRetry: allowAdaptiveRetry,
            overrideStructuredMode: alternateMode,
            allowProtocolNegotiation: false,
          );
        }
        throw TextModelException(
          kind: TextModelErrorKind.unsupportedStructuredOutput,
          message: '[$modelTag] 模型未返回符合协议的严格 JSON 结构化输出（已拒绝闲聊正文正则兜底）',
        );
      }

      // 部分代理会在 arguments 截断时误报 finish_reason=tool_calls/stop，识别未闭合 JSON 按截断处理
      final looksTruncatedJson =
          fromToolCalls &&
          rawStructuredJson.startsWith('{') &&
          !rawStructuredJson.endsWith('}');
      if (looksTruncatedJson) {
        final effectiveEffort =
            overrideReasoningEffort ?? payload['reasoning_effort']?.toString();
        if (allowAdaptiveRetry &&
            effectiveEffort != 'none' &&
            config.thinkingLevel != TextThinkingLevel.none &&
            config.thinkingLevel != TextThinkingLevel.off) {
          timer.cancel();
          return await _invokeStructured(
            config: config,
            apiKey: apiKey,
            taskSchemaSuffix: taskSchemaSuffix,
            toolDescription: toolDescription,
            schema: schema,
            systemMessage: systemMessage,
            userMessage: userMessage,
            isCancelled: isCancelled,
            overrideReasoningEffort: 'none',
            allowAdaptiveRetry: false,
            overrideStructuredMode: overrideStructuredMode,
            allowProtocolNegotiation: allowProtocolNegotiation,
          );
        }
        final limitDesc = config.maxOutputTokens == null
            ? '不限'
            : '${config.maxOutputTokens}';
        throw TextModelException(
          kind: TextModelErrorKind.truncated,
          message:
              '[$modelTag] 模型返回的 JSON 未闭合，疑似输出被截断（当前最大输出=$limitDesc，思考=${config.thinkingLevel}），请在模型编辑中调大/留空最大输出或将思考程度设为 none',
        );
      }

      Object? structuredObj;
      try {
        structuredObj = jsonDecode(rawStructuredJson);
        // 兼容部分中转网关对 tool_calls.function.arguments 做了二次 JSON 字符串编码的情况
        if (structuredObj is String) {
          final inner = stripThinkingAndCodeFence(structuredObj).cleaned;
          if (inner.startsWith('{') && inner.endsWith('}')) {
            structuredObj = jsonDecode(inner);
          }
        }
      } catch (_) {
        if (allowProtocolNegotiation) {
          timer.cancel();
          return await _invokeStructured(
            config: config,
            apiKey: apiKey,
            taskSchemaSuffix: taskSchemaSuffix,
            toolDescription: toolDescription,
            schema: schema,
            systemMessage: systemMessage,
            userMessage: userMessage,
            isCancelled: isCancelled,
            overrideReasoningEffort: overrideReasoningEffort,
            omitReasoningEffort: omitReasoningEffort,
            allowAdaptiveRetry: allowAdaptiveRetry,
            overrideStructuredMode: alternateMode,
            allowProtocolNegotiation: false,
          );
        }
        throw TextModelException(
          kind: TextModelErrorKind.unsupportedStructuredOutput,
          message:
              '[$modelTag] 模型输出不是合法 JSON，疑似不支持严格原生结构化输出（已拒绝提示词正则兜底；可尝试切换结构化输出模式或调整最大输出/思考程度）',
        );
      }
      if (structuredObj is! Map) {
        throw TextModelException(
          kind: TextModelErrorKind.schemaViolation,
          message: '[$modelTag] 结构化输出顶层不是 JSON 对象',
        );
      }

      final usage = decoded['usage'] is Map
          ? Map<String, dynamic>.from(decoded['usage'] as Map)
          : const <String, dynamic>{};
      final details = usage['completion_tokens_details'] is Map
          ? Map<String, dynamic>.from(usage['completion_tokens_details'] as Map)
          : const <String, dynamic>{};
      var reasoningTokens = (details['reasoning_tokens'] as num?)?.toInt() ?? 0;
      if (reasoningTokens == 0) {
        final rc =
            (msgMap['reasoning_content'] ?? msgMap['reasoning'])?.toString() ??
            '';
        if (rc.isNotEmpty) {
          reasoningTokens = (rc.length / 2).ceil();
        } else if (hadThinkingTag) {
          reasoningTokens = 1;
        }
      }

      return StructuredModelResponse(
        data: Map<String, dynamic>.from(structuredObj),
        promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
        reasoningTokens: reasoningTokens,
        latencyMs: sw.elapsedMilliseconds,
        schemaVersion: taskSchemaSuffix,
      );
    } on TextModelException {
      rethrow;
    } catch (e) {
      if (isCancelled?.call() == true) {
        throw TextModelException(
          kind: TextModelErrorKind.cancelled,
          message: '[$modelTag] 文本分析请求已取消',
        );
      }
      throw TextModelException(
        kind: TextModelErrorKind.transientNetwork,
        message: '[$modelTag] 文本模型网络通信失败：$e',
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _active.remove(abort);
    }
  }

  static String _extractProviderErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final msg = (decoded['error'] as Map)['message']?.toString();
        if (msg != null && msg.isNotEmpty) {
          return msg.length > 240 ? '${msg.substring(0, 240)}...' : msg;
        }
      }
    } catch (_) {}
    final trimmed = body.trim();
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}...' : trimmed;
  }
}
