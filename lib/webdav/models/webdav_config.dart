// WebDAV 云同步配置、离线书籍元数据与同步结果模型

/// 离线书籍本地与云端对比状态
enum WebDavOfflineBookStatus {
  /// 本地与云端一致
  synced,

  /// 仅存在本地，尚未上传至云端
  localOnly,

  /// 仅存在云端，尚未下载到本地
  remoteOnly,

  /// 本地版本较新或内容已变化，可上传更新
  localNewer,

  /// 云端版本较新，可下载覆盖
  remoteNewer,
}

/// WebDAV 同步模式
enum WebDavSyncMode {
  /// 智能双向合并同步（默认）
  bidirectional,

  /// 强制将本地快照上传覆盖云端
  pushToRemote,

  /// 强制从云端拉取覆盖本地（阅读数据默认保留未冲突记录或按模式覆盖）
  pullFromRemote,
}

/// WebDAV 云同步配置模型
class WebDavConfig {
  /// 内置隐藏根目录名，绝不在界面向用户暴露或允许编辑
  static const String hiddenRootFolder = 'FanQieReader';

  /// 离线书籍归档子目录名（位于隐藏根目录下）
  static const String booksSubFolder = 'books';

  /// 是否启用 WebDAV 同步
  final bool enabled;

  /// 用户填写的 WebDAV 服务器地址（不含内置隐藏目录）
  final String serverUrl;

  /// 登录账号
  final String username;

  /// 登录密码（持久化时转存 Keystore，仅留槽位标记）
  final String password;

  /// 打开应用时是否自动执行一次后台同步
  final bool autoSyncOnStart;

  /// 退出阅读页或切入后台时是否自动执行轻量阅读进度同步（60 秒节流，不传离线大包）
  final bool autoSyncOnBackground;

  /// 是否同步 AI 配置（沉浸式 TTS 多模型/音色/密钥 + 普通 AI 朗读配置与密钥）
  final bool syncAiConfig;

  /// 是否使用端到端 AES-256-GCM 加密云端 AI 配置中的密钥字段
  final bool encryptCloudAiConfig;

  /// 是否同步每本书的沉浸式角色档案、手动音色锁定与本书配音覆盖
  final bool syncImmersiveProfiles;

  /// 是否同步阅读历史、书架书籍信息、阅读进度、书签、笔记与阅读设置
  final bool syncReadingData;

  /// 是否在自动/一键同步时自动上传本地离线书并下载云端离线书
  final bool syncOfflineBooks;

  /// 上次成功同步时间（UTC）
  final DateTime? lastSyncAt;

  /// 上次同步状态摘要
  final String lastSyncSummary;

  /// 上次已同步的 AI 配置摘要哈希（用于判断双向变更方向）
  final String lastSyncedAiHash;

  /// 上次已同步的阅读数据摘要哈希
  final String lastSyncedReadingHash;

  /// 上次已同步的沉浸式角色档案摘要哈希
  final String lastSyncedProfilesHash;

  /// 本机设备标识（仅用于识别多端同步来源）
  final String deviceId;

  const WebDavConfig({
    this.enabled = false,
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.autoSyncOnStart = false,
    this.autoSyncOnBackground = true,
    this.syncAiConfig = true,
    this.encryptCloudAiConfig = true,
    this.syncImmersiveProfiles = true,
    this.syncReadingData = true,
    this.syncOfflineBooks = true,
    this.lastSyncAt,
    this.lastSyncSummary = '',
    this.lastSyncedAiHash = '',
    this.lastSyncedReadingHash = '',
    this.lastSyncedProfilesHash = '',
    this.deviceId = '',
  });

  /// 规范化用户输入的 WebDAV 地址（兼容全角符号、首尾空白与尾部斜杠，自动剥离误填的内置目录名）
  static String normalizeServerUrl(String raw) {
    var value = raw
        .trim()
        .replaceAll('：', ':')
        .replaceAll('／', '/')
        .replaceAll('。', '.');
    if (value.isEmpty) return '';
    if (!value.contains('://')) {
      value = 'https://$value';
    }
    value = value.replaceAll(RegExp(r'/+$'), '');
    final hiddenSuffix = '/$hiddenRootFolder';
    if (value.toLowerCase().endsWith(hiddenSuffix.toLowerCase())) {
      value = value.substring(0, value.length - hiddenSuffix.length);
      value = value.replaceAll(RegExp(r'/+$'), '');
    }
    return value;
  }

  String get normalizedServerUrl => normalizeServerUrl(serverUrl);

  bool get hasCredentials =>
      normalizedServerUrl.isNotEmpty &&
      username.trim().isNotEmpty &&
      password.isNotEmpty;

  bool get canSync => enabled && hasCredentials;

  WebDavConfig copyWith({
    bool? enabled,
    String? serverUrl,
    String? username,
    String? password,
    bool? autoSyncOnStart,
    bool? autoSyncOnBackground,
    bool? syncAiConfig,
    bool? encryptCloudAiConfig,
    bool? syncImmersiveProfiles,
    bool? syncReadingData,
    bool? syncOfflineBooks,
    DateTime? lastSyncAt,
    bool clearLastSyncAt = false,
    String? lastSyncSummary,
    String? lastSyncedAiHash,
    String? lastSyncedReadingHash,
    String? lastSyncedProfilesHash,
    String? deviceId,
  }) {
    return WebDavConfig(
      enabled: enabled ?? this.enabled,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      autoSyncOnStart: autoSyncOnStart ?? this.autoSyncOnStart,
      autoSyncOnBackground: autoSyncOnBackground ?? this.autoSyncOnBackground,
      syncAiConfig: syncAiConfig ?? this.syncAiConfig,
      encryptCloudAiConfig: encryptCloudAiConfig ?? this.encryptCloudAiConfig,
      syncImmersiveProfiles:
          syncImmersiveProfiles ?? this.syncImmersiveProfiles,
      syncReadingData: syncReadingData ?? this.syncReadingData,
      syncOfflineBooks: syncOfflineBooks ?? this.syncOfflineBooks,
      lastSyncAt: clearLastSyncAt ? null : (lastSyncAt ?? this.lastSyncAt),
      lastSyncSummary: lastSyncSummary ?? this.lastSyncSummary,
      lastSyncedAiHash: lastSyncedAiHash ?? this.lastSyncedAiHash,
      lastSyncedReadingHash:
          lastSyncedReadingHash ?? this.lastSyncedReadingHash,
      lastSyncedProfilesHash:
          lastSyncedProfilesHash ?? this.lastSyncedProfilesHash,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  Map<String, dynamic> toJson({bool includePassword = false}) => {
    'version': 1,
    'enabled': enabled,
    'server_url': normalizedServerUrl,
    'username': username.trim(),
    if (includePassword) 'password': password,
    'auto_sync_on_start': autoSyncOnStart,
    'auto_sync_on_background': autoSyncOnBackground,
    'sync_ai_config': syncAiConfig,
    'encrypt_cloud_ai_config': encryptCloudAiConfig,
    'sync_immersive_profiles': syncImmersiveProfiles,
    'sync_reading_data': syncReadingData,
    'sync_offline_books': syncOfflineBooks,
    'last_sync_at': lastSyncAt?.toUtc().toIso8601String(),
    'last_sync_summary': lastSyncSummary,
    'last_synced_ai_hash': lastSyncedAiHash,
    'last_synced_reading_hash': lastSyncedReadingHash,
    'last_synced_profiles_hash': lastSyncedProfilesHash,
    'device_id': deviceId,
  };

  factory WebDavConfig.fromJson(
    Map<String, dynamic> json, {
    String? hydratedPassword,
  }) {
    return WebDavConfig(
      enabled: json['enabled'] == true,
      serverUrl: normalizeServerUrl(json['server_url']?.toString() ?? ''),
      username: (json['username']?.toString() ?? '').trim(),
      password: hydratedPassword ?? json['password']?.toString() ?? '',
      autoSyncOnStart: json['auto_sync_on_start'] == true,
      autoSyncOnBackground: json['auto_sync_on_background'] != false,
      syncAiConfig: json['sync_ai_config'] != false,
      encryptCloudAiConfig: json['encrypt_cloud_ai_config'] != false,
      syncImmersiveProfiles: json['sync_immersive_profiles'] != false,
      syncReadingData: json['sync_reading_data'] != false,
      syncOfflineBooks: json['sync_offline_books'] != false,
      lastSyncAt: json['last_sync_at'] == null
          ? null
          : DateTime.tryParse(json['last_sync_at'].toString()),
      lastSyncSummary: json['last_sync_summary']?.toString() ?? '',
      lastSyncedAiHash: json['last_synced_ai_hash']?.toString() ?? '',
      lastSyncedReadingHash: json['last_synced_reading_hash']?.toString() ?? '',
      lastSyncedProfilesHash:
          json['last_synced_profiles_hash']?.toString() ?? '',
      deviceId: json['device_id']?.toString() ?? '',
    );
  }
}

/// 离线书籍同步清单项（仅用于已离线的书籍）
class WebDavOfflineBookMeta {
  final String bookId;
  final String bookName;
  final String author;
  final String? thumbUrl;
  final bool isLocalImport;
  final int chapterCount;
  final int totalBytes;
  final String contentHash;
  final DateTime updatedAt;

  const WebDavOfflineBookMeta({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.thumbUrl,
    required this.isLocalImport,
    required this.chapterCount,
    required this.totalBytes,
    required this.contentHash,
    required this.updatedAt,
  });

  String get formattedSize {
    if (totalBytes >= 1024 * 1024) {
      return '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (totalBytes >= 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$totalBytes B';
  }

  Map<String, dynamic> toJson() => {
    'book_id': bookId,
    'book_name': bookName,
    'author': author,
    'thumb_url': thumbUrl,
    'is_local_import': isLocalImport,
    'chapter_count': chapterCount,
    'total_bytes': totalBytes,
    'content_hash': contentHash,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory WebDavOfflineBookMeta.fromJson(Map<String, dynamic> json) {
    return WebDavOfflineBookMeta(
      bookId: json['book_id']?.toString() ?? '',
      bookName: json['book_name']?.toString() ?? '未知书名',
      author: json['author']?.toString() ?? '未知作者',
      thumbUrl: json['thumb_url']?.toString(),
      isLocalImport: json['is_local_import'] == true,
      chapterCount: (json['chapter_count'] as num?)?.toInt() ?? 0,
      totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
      contentHash: json['content_hash']?.toString() ?? '',
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// 本地与云端离线书籍比对条目（供界面展示与单本上传/下载）
class WebDavOfflineBookItem {
  final String bookId;
  final String bookName;
  final String author;
  final WebDavOfflineBookMeta? localMeta;
  final WebDavOfflineBookMeta? remoteMeta;
  final WebDavOfflineBookStatus status;

  const WebDavOfflineBookItem({
    required this.bookId,
    required this.bookName,
    required this.author,
    this.localMeta,
    this.remoteMeta,
    required this.status,
  });

  int get displayBytes =>
      localMeta?.totalBytes ?? remoteMeta?.totalBytes ?? 0;

  String get formattedSize {
    final bytes = displayBytes;
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

/// WebDAV 云端同步索引文件（sync_index.json）
class WebDavSyncIndex {
  final int version;
  final DateTime updatedAt;
  final String updatedByDeviceId;
  final String aiConfigHash;
  final DateTime? aiConfigUpdatedAt;
  final String readingDataHash;
  final DateTime? readingDataUpdatedAt;
  final String immersiveProfilesHash;
  final DateTime? immersiveProfilesUpdatedAt;
  final Map<String, WebDavOfflineBookMeta> offlineBooks;

  const WebDavSyncIndex({
    this.version = 1,
    required this.updatedAt,
    this.updatedByDeviceId = '',
    this.aiConfigHash = '',
    this.aiConfigUpdatedAt,
    this.readingDataHash = '',
    this.readingDataUpdatedAt,
    this.immersiveProfilesHash = '',
    this.immersiveProfilesUpdatedAt,
    this.offlineBooks = const {},
  });

  WebDavSyncIndex copyWith({
    DateTime? updatedAt,
    String? updatedByDeviceId,
    String? aiConfigHash,
    DateTime? aiConfigUpdatedAt,
    String? readingDataHash,
    DateTime? readingDataUpdatedAt,
    String? immersiveProfilesHash,
    DateTime? immersiveProfilesUpdatedAt,
    Map<String, WebDavOfflineBookMeta>? offlineBooks,
  }) {
    return WebDavSyncIndex(
      version: version,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedByDeviceId: updatedByDeviceId ?? this.updatedByDeviceId,
      aiConfigHash: aiConfigHash ?? this.aiConfigHash,
      aiConfigUpdatedAt: aiConfigUpdatedAt ?? this.aiConfigUpdatedAt,
      readingDataHash: readingDataHash ?? this.readingDataHash,
      readingDataUpdatedAt: readingDataUpdatedAt ?? this.readingDataUpdatedAt,
      immersiveProfilesHash:
          immersiveProfilesHash ?? this.immersiveProfilesHash,
      immersiveProfilesUpdatedAt:
          immersiveProfilesUpdatedAt ?? this.immersiveProfilesUpdatedAt,
      offlineBooks: offlineBooks ?? this.offlineBooks,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'updated_by_device_id': updatedByDeviceId,
    'ai_config_hash': aiConfigHash,
    'ai_config_updated_at': aiConfigUpdatedAt?.toUtc().toIso8601String(),
    'reading_data_hash': readingDataHash,
    'reading_data_updated_at': readingDataUpdatedAt?.toUtc().toIso8601String(),
    'immersive_profiles_hash': immersiveProfilesHash,
    'immersive_profiles_updated_at':
        immersiveProfilesUpdatedAt?.toUtc().toIso8601String(),
    'offline_books': {
      for (final e in offlineBooks.entries) e.key: e.value.toJson(),
    },
  };

  factory WebDavSyncIndex.fromJson(Map<String, dynamic> json) {
    final rawBooks = json['offline_books'];
    final books = <String, WebDavOfflineBookMeta>{};
    if (rawBooks is Map) {
      for (final entry in rawBooks.entries) {
        if (entry.value is Map) {
          final meta = WebDavOfflineBookMeta.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          if (meta.bookId.isNotEmpty) {
            books[meta.bookId] = meta;
          }
        }
      }
    }
    return WebDavSyncIndex(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedByDeviceId: json['updated_by_device_id']?.toString() ?? '',
      aiConfigHash: json['ai_config_hash']?.toString() ?? '',
      aiConfigUpdatedAt: json['ai_config_updated_at'] == null
          ? null
          : DateTime.tryParse(json['ai_config_updated_at'].toString()),
      readingDataHash: json['reading_data_hash']?.toString() ?? '',
      readingDataUpdatedAt: json['reading_data_updated_at'] == null
          ? null
          : DateTime.tryParse(json['reading_data_updated_at'].toString()),
      immersiveProfilesHash: json['immersive_profiles_hash']?.toString() ?? '',
      immersiveProfilesUpdatedAt: json['immersive_profiles_updated_at'] == null
          ? null
          : DateTime.tryParse(json['immersive_profiles_updated_at'].toString()),
      offlineBooks: books,
    );
  }
}

/// WebDAV 单次同步执行报告
class WebDavSyncReport {
  final bool success;
  final String message;
  final String aiConfigAction;
  final String readingDataAction;
  final String profilesAction;
  final List<String> uploadedBookIds;
  final List<String> downloadedBookIds;
  final List<String> warnings;
  final int durationMs;

  const WebDavSyncReport({
    required this.success,
    required this.message,
    this.aiConfigAction = '未启用',
    this.readingDataAction = '未启用',
    this.profilesAction = '未启用',
    this.uploadedBookIds = const [],
    this.downloadedBookIds = const [],
    this.warnings = const [],
    this.durationMs = 0,
  });

  String get conciseSummary {
    if (!success) return message;
    final parts = <String>[];
    if (aiConfigAction != '未启用') parts.add('AI配置:$aiConfigAction');
    if (readingDataAction != '未启用') parts.add('阅读数据:$readingDataAction');
    if (profilesAction != '未启用' && profilesAction != '暂无档案') {
      parts.add('角色档案:$profilesAction');
    }
    if (uploadedBookIds.isNotEmpty) {
      parts.add('上传离线书 ${uploadedBookIds.length} 本');
    }
    if (downloadedBookIds.isNotEmpty) {
      parts.add('下载离线书 ${downloadedBookIds.length} 本');
    }
    if (parts.isEmpty) return message;
    return parts.join(' · ');
  }
}

/// WebDAV 连接测试结果
class WebDavConnectionTestResult {
  final bool success;
  final String message;
  final int? statusCode;
  final int durationMs;

  const WebDavConnectionTestResult({
    required this.success,
    required this.message,
    this.statusCode,
    required this.durationMs,
  });
}
