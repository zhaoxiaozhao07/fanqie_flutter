import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../immersive/models/immersive_config.dart';
import '../models/webdav_config.dart';
import '../services/webdav_sync_service.dart';

/// 顶栏 WebDAV 云同步快捷入口按钮（同步中显示进度动画）
class WebDavSyncActionButton extends StatelessWidget {
  final VoidCallback? onSyncFinished;

  const WebDavSyncActionButton({super.key, this.onSyncFinished});

  @override
  Widget build(BuildContext context) {
    final service = WebDavSyncService();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final syncing = service.isSyncing;
        final configured = service.config.canSync;
        return IconButton(
          tooltip: syncing ? 'WebDAV 同步中...' : 'WebDAV 云同步',
          icon: syncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  configured
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_sync_outlined,
                  color: configured ? AppTheme.primaryColor : null,
                ),
          onPressed: () async {
            await showWebDavSyncSheet(context);
            onSyncFinished?.call();
          },
        );
      },
    );
  }
}

/// 打开 WebDAV 云同步设置与离线书籍同步面板
Future<void> showWebDavSyncSheet(
  BuildContext context, {
  WebDavSyncService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.9,
      child: WebDavSyncSheet(service: service),
    ),
  );
}

/// WebDAV 云同步完整界面（内置目录自动管理，绝不在 UI 中暴露）
class WebDavSyncSheet extends StatefulWidget {
  final WebDavSyncService? service;

  const WebDavSyncSheet({super.key, this.service});

  @override
  State<WebDavSyncSheet> createState() => _WebDavSyncSheetState();
}

class _WebDavSyncSheetState extends State<WebDavSyncSheet>
    with SingleTickerProviderStateMixin {
  late final WebDavSyncService _service = widget.service ?? WebDavSyncService();
  late final TabController _tabs;

  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  bool _loaded = false;
  bool _obscurePassword = true;
  bool _enabled = false;
  bool _autoSyncOnStart = false;
  bool _autoSyncOnBackground = true;
  bool _syncAiConfig = true;
  bool _encryptCloudAiConfig = true;
  bool _syncImmersiveProfiles = true;
  bool _syncReadingData = true;
  bool _syncOfflineBooks = true;

  bool _testing = false;
  bool _busyBooks = false;
  String? _activeBookId;
  String? _notice;
  bool _noticeIsError = false;
  List<WebDavOfflineBookItem> _offlineBooks = const [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (_tabs.index == 1 && !_tabs.indexIsChanging) {
        unawaited(_refreshOfflineBooks());
      }
    });
    _service.addListener(_onServiceChanged);
    unawaited(_init());
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _tabs.dispose();
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    await _service.initialize();
    final cfg = _service.config;
    if (!mounted) return;
    setState(() {
      _urlCtrl.text = cfg.serverUrl;
      _userCtrl.text = cfg.username;
      _passCtrl.text = cfg.password;
      _enabled = cfg.enabled;
      _autoSyncOnStart = cfg.autoSyncOnStart;
      _autoSyncOnBackground = cfg.autoSyncOnBackground;
      _syncAiConfig = cfg.syncAiConfig;
      _encryptCloudAiConfig = cfg.encryptCloudAiConfig;
      _syncImmersiveProfiles = cfg.syncImmersiveProfiles;
      _syncReadingData = cfg.syncReadingData;
      _syncOfflineBooks = cfg.syncOfflineBooks;
      _loaded = true;
    });
    unawaited(_refreshOfflineBooks());
  }

  WebDavConfig _buildDraftConfig() {
    return _service.config.copyWith(
      enabled: _enabled,
      serverUrl: WebDavConfig.normalizeServerUrl(_urlCtrl.text),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
      autoSyncOnStart: _autoSyncOnStart,
      autoSyncOnBackground: _autoSyncOnBackground,
      syncAiConfig: _syncAiConfig,
      encryptCloudAiConfig: _encryptCloudAiConfig,
      syncImmersiveProfiles: _syncImmersiveProfiles,
      syncReadingData: _syncReadingData,
      syncOfflineBooks: _syncOfflineBooks,
    );
  }

  void _setNotice(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _notice = msg;
      _noticeIsError = isError;
    });
  }

  Future<bool> _saveDraft({bool silent = false}) async {
    final draft = _buildDraftConfig();
    if (draft.enabled && !draft.hasCredentials) {
      _setNotice('请填写完整的 WebDAV 服务器地址、账号和密码', isError: true);
      return false;
    }
    _urlCtrl.text = draft.normalizedServerUrl;
    await _service.saveConfig(draft);
    if (!silent) {
      _setNotice('WebDAV 配置已安全保存');
    }
    return true;
  }

  Future<void> _testConnection() async {
    final draft = _buildDraftConfig();
    if (!draft.hasCredentials) {
      _setNotice('请先填写服务器地址、账号与密码后再测试', isError: true);
      return;
    }
    setState(() {
      _testing = true;
      _notice = '正在测试 WebDAV 连接与鉴权...';
      _noticeIsError = false;
    });
    try {
      final result = await _service.testConnection(draft);
      if (result.success) {
        // 测试通过后顺便规范化输入框中的地址
        _urlCtrl.text = draft.normalizedServerUrl;
        _setNotice(result.message, isError: false);
      } else {
        _setNotice(result.message, isError: true);
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _triggerSync(WebDavSyncMode mode) async {
    // 若用户刚填写完账号直接点同步，先自动保存并开启启用开关
    if (!_enabled && _buildDraftConfig().hasCredentials) {
      setState(() => _enabled = true);
    }
    final saved = await _saveDraft(silent: true);
    if (!saved || !mounted) return;

    if (mode == WebDavSyncMode.pullFromRemote) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认从云端拉取覆盖？'),
          content: const Text(
            '将使用 WebDAV 云端备份恢复已勾选的 AI 配置、阅读历史与书籍信息，'
            '并下载云端离线书籍到本地。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认拉取'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    _setNotice('正在执行同步，请稍候...');
    final report = await _service.syncNow(mode: mode);
    if (!mounted) return;
    _setNotice(
      report.success ? report.conciseSummary : report.message,
      isError: !report.success,
    );
    unawaited(_refreshOfflineBooks());
  }

  Future<void> _refreshOfflineBooks() async {
    if (!mounted) return;
    setState(() => _busyBooks = true);
    try {
      final list = await _service.listOfflineBooksStatus();
      if (mounted) {
        setState(() => _offlineBooks = list);
      }
    } catch (e) {
      _setNotice('读取离线书籍云端状态失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busyBooks = false);
    }
  }

  Future<void> _uploadSingleBook(WebDavOfflineBookItem item) async {
    final saved = await _saveDraft(silent: true);
    if (!saved || !mounted) return;
    setState(() {
      _activeBookId = item.bookId;
      _notice = '正在上传离线书籍《${item.bookName}》...';
      _noticeIsError = false;
    });
    try {
      await _service.uploadOfflineBook(item.bookId);
      _setNotice('已上传离线书籍《${item.bookName}》');
      await _refreshOfflineBooks();
    } catch (e) {
      _setNotice('上传《${item.bookName}》失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _activeBookId = null);
    }
  }

  Future<void> _downloadSingleBook(WebDavOfflineBookItem item) async {
    final saved = await _saveDraft(silent: true);
    if (!saved || !mounted) return;
    setState(() {
      _activeBookId = item.bookId;
      _notice = '正在下载离线书籍《${item.bookName}》...';
      _noticeIsError = false;
    });
    try {
      await _service.downloadOfflineBook(item.bookId);
      _setNotice('已下载并恢复离线书籍《${item.bookName}》');
      await _refreshOfflineBooks();
    } catch (e) {
      _setNotice('下载《${item.bookName}》失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _activeBookId = null);
    }
  }

  String _formatDateTime(DateTime? dt) {
    if (dt == null) return '尚未同步';
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final syncing = _service.isSyncing;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
          child: Row(
            children: [
              const Icon(Icons.cloud_sync_rounded, color: AppTheme.primaryColor),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'WebDAV 云同步与备份',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: syncing ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        if (_notice != null || syncing)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _noticeIsError
                  ? Colors.red.shade50
                  : AppTheme.primaryColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                if (syncing || _testing) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    syncing
                        ? (_service.statusMessage.isNotEmpty
                              ? _service.statusMessage
                              : '同步进行中...')
                        : (_notice ?? ''),
                    style: TextStyle(
                      fontSize: 12,
                      color: _noticeIsError
                          ? Colors.red.shade800
                          : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),
        TabBar(
          controller: _tabs,
          labelColor: AppTheme.primaryColor,
          tabs: const [
            Tab(text: '同步设置与操作'),
            Tab(text: '离线书籍管理'),
          ],
        ),
        Expanded(
          child: !_loaded
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _buildSettingsTab(syncing),
                    _buildOfflineBooksTab(syncing),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSettingsTab(bool syncing) {
    final cfg = _service.config;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用 WebDAV 云同步'),
          subtitle: Text(
            cfg.lastSyncAt == null
                ? '密码通过系统安全存储加密保存，同步目录由应用自动管理'
                : '上次同步：${_formatDateTime(cfg.lastSyncAt)}'
                      '${cfg.lastSyncSummary.isNotEmpty ? '\n${cfg.lastSyncSummary}' : ''}',
          ),
          value: _enabled,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _enabled = v);
                  if (!v || _buildDraftConfig().hasCredentials) {
                    await _saveDraft(silent: true);
                  }
                },
        ),
        const Divider(),
        const Text(
          '服务器凭据',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('webdav-url-field'),
          controller: _urlCtrl,
          enabled: !syncing,
          keyboardType: TextInputType.url,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'WebDAV 服务器地址',
            hintText: '例如 https://dav.example.com',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (isInsecureRemoteHttpUrl(
          WebDavConfig.normalizeServerUrl(_urlCtrl.text),
        ))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '安全提示：当前地址使用明文 HTTP 协议，公共网络下存在凭据被窃听风险，建议改用 HTTPS。',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('webdav-user-field'),
          controller: _userCtrl,
          enabled: !syncing,
          decoration: const InputDecoration(
            labelText: '账号',
            hintText: '填写 WebDAV 登录用户名或邮箱',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('webdav-pass-field'),
          controller: _passCtrl,
          enabled: !syncing,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: '密码 / 应用专用密码',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('webdav-save-btn'),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('保存配置'),
              onPressed: syncing || _testing ? null : () => _saveDraft(),
            ),
            OutlinedButton.icon(
              key: const ValueKey('webdav-test-btn'),
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: const Text('测试连接'),
              onPressed: syncing || _testing ? null : _testConnection,
            ),
          ],
        ),
        const Divider(height: 28),
        const Text(
          '同步策略与范围',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        SwitchListTile(
          key: const ValueKey('webdav-autosync-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('打开应用时自动同步'),
          subtitle: const Text('启动后在后台自动执行一次双向同步，不阻塞阅读界面'),
          value: _autoSyncOnStart,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _autoSyncOnStart = v);
                  await _saveDraft(silent: true);
                },
        ),
        SwitchListTile(
          key: const ValueKey('webdav-bgsync-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('退出阅读或切后台自动同步进度'),
          subtitle: const Text('带 60 秒节流防抖，仅上传轻量阅读进度与角色档案，后台不传大离线书'),
          value: _autoSyncOnBackground,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _autoSyncOnBackground = v);
                  await _saveDraft(silent: true);
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('同步 AI 朗读与沉浸式配置'),
          subtitle: const Text('包含沉浸式多角色文本模型、TTS 音色与密钥，以及正常 AI 朗读配置'),
          value: _syncAiConfig,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _syncAiConfig = v);
                  await _saveDraft(silent: true);
                },
        ),
        if (_syncAiConfig)
          SwitchListTile(
            key: const ValueKey('webdav-encrypt-ai-switch'),
            contentPadding: const EdgeInsets.only(left: 12),
            title: const Text('云端端到端加密保护 AI 密钥 (AES-256-GCM)'),
            subtitle: const Text('上传前经 PBKDF2 派生密钥加密，确保远端存储零明文 API Key'),
            value: _encryptCloudAiConfig,
            onChanged: syncing
                ? null
                : (v) async {
                    setState(() => _encryptCloudAiConfig = v);
                    await _saveDraft(silent: true);
                  },
          ),
        SwitchListTile(
          key: const ValueKey('webdav-profiles-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('同步每本书的沉浸式角色与音色锁定'),
          subtitle: const Text('跨设备续听时保留角色档案、手动锁定音色、合并记录与本书配音覆盖'),
          value: _syncImmersiveProfiles,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _syncImmersiveProfiles = v);
                  await _saveDraft(silent: true);
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('同步阅读历史与书籍信息'),
          subtitle: const Text(
            '同步书架全部书籍元数据、阅读历史、阅读进度、书签与笔记（未离线书籍仅同步书籍信息）',
          ),
          value: _syncReadingData,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _syncReadingData = v);
                  await _saveDraft(silent: true);
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动同步已离线书籍文件'),
          subtitle: const Text('一键同步或启动同步时自动上传本地离线书并下载云端新增离线书'),
          value: _syncOfflineBooks,
          onChanged: syncing
              ? null
              : (v) async {
                  setState(() => _syncOfflineBooks = v);
                  await _saveDraft(silent: true);
                },
        ),
        const Divider(height: 24),
        FilledButton.icon(
          key: const ValueKey('webdav-sync-now-btn'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          icon: const Icon(Icons.sync_rounded),
          label: const Text('立即双向同步'),
          onPressed: syncing || _testing
              ? null
              : () => _triggerSync(WebDavSyncMode.bidirectional),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('webdav-push-btn'),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: const Text('上传覆盖云端'),
                onPressed: syncing || _testing
                    ? null
                    : () => _triggerSync(WebDavSyncMode.pushToRemote),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('webdav-pull-btn'),
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('从云端拉取恢复'),
                onPressed: syncing || _testing
                    ? null
                    : () => _triggerSync(WebDavSyncMode.pullFromRemote),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOfflineBooksTab(bool syncing) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '仅展示已离线书籍（本地导入或已离线下载）；未离线在线书籍仅同步书架信息与进度。',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              TextButton.icon(
                icon: _busyBooks
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
                onPressed: syncing || _busyBooks ? null : _refreshOfflineBooks,
              ),
            ],
          ),
        ),
        Expanded(
          child: _offlineBooks.isEmpty
              ? const Center(
                  child: Text(
                    '暂无本地或云端离线书籍',
                    style: TextStyle(color: Colors.black45),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: _offlineBooks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = _offlineBooks[index];
                    final isItemBusy = _activeBookId == item.bookId;
                    final (label, color) = switch (item.status) {
                      WebDavOfflineBookStatus.synced => (
                        '已同步',
                        Colors.green.shade700,
                      ),
                      WebDavOfflineBookStatus.localOnly => (
                        '仅本地',
                        Colors.orange.shade800,
                      ),
                      WebDavOfflineBookStatus.remoteOnly => (
                        '仅云端',
                        Colors.blue.shade700,
                      ),
                      WebDavOfflineBookStatus.localNewer => (
                        '本地较新',
                        Colors.orange.shade800,
                      ),
                      WebDavOfflineBookStatus.remoteNewer => (
                        '云端较新',
                        Colors.blue.shade700,
                      ),
                    };
                    final chapters =
                        item.localMeta?.chapterCount ??
                        item.remoteMeta?.chapterCount ??
                        0;
                    return Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          item.bookName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          label,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: color,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item.author} · $chapters 章 · ${item.formattedSize}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (isItemBusy)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              Wrap(
                                spacing: 6,
                                children: [
                                  if (item.localMeta != null)
                                    OutlinedButton(
                                      onPressed: syncing
                                          ? null
                                          : () => _uploadSingleBook(item),
                                      child: const Text('上传'),
                                    ),
                                  if (item.remoteMeta != null)
                                    FilledButton.tonal(
                                      onPressed: syncing
                                          ? null
                                          : () => _downloadSingleBook(item),
                                      child: const Text('下载'),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
