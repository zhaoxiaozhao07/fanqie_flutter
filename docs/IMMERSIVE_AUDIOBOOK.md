# 沉浸式多角色听书与 WebDAV 云同步说明

## 1. 架构与集成总览

本功能在原有阅读器（EPUB / TXT 解析、目录定位、单音色听书、Android 前台媒体服务 `ReaderPlaybackService` 与 macOS 原生播放组件 `ReaderPlayback`）基础上独立扩展，代码主要位于 `lib/immersive/` 与 `lib/webdav/`：

- **配置与校验**：`lib/immersive/models/immersive_config.dart`、`lib/immersive/services/immersive_config_service.dart`、`lib/immersive/services/immersive_preset_config.dart`、`docs/config.schema.json`、`docs/config.example.json`
- **持久化状态库**：`lib/immersive/services/immersive_database.dart`（Android 与 macOS 双端使用 `sqflite` SQLite WAL + `COLLATE BINARY` 大小写敏感事务存储；支持全书角色档案与手动音色锁定导入/导出供跨设备同步；单元测试提供等价事务内存实现）
- **原文定位与语义分块**：`lib/immersive/services/source_normalizer.dart`、`lib/immersive/services/chunk_planner.dart`（支持锚点章首块微切分快启，默认 `first_chunk_target_tokens = 550`）
- **协议适配器**：
  - 文本分析：`lib/immersive/services/text_model_adapter.dart`（支持标准 `response_format.json_schema` 与注册的 `vendor_native: openai_tool_call_schema` 强制 Function Calling 严格 Schema，自动剥离 `<think>`/`reasoning_content`，严禁提示词正则兜底）
  - 语音合成：`lib/immersive/services/tts_provider_adapter.dart`（精确区分 `model_id`/`voice_id` 大小写，校验二进制音频完整性与原生时长）
- **角色记忆与有序确认**：`lib/immersive/services/context_builder.dart`、`lib/immersive/services/identity_coordinator.dart`
- **统一调度、原子缓存与无缝播放**：
  - `lib/immersive/services/immersive_job_scheduler.dart`（多文本模型独立并发、主备故障转移与分级思考加速）
  - `lib/immersive/services/audio_cache_manager.dart`、`lib/immersive/services/manifest_builder.dart`
  - `lib/immersive/services/immersive_audio_player_bridge.dart`、`lib/immersive/services/immersive_playback_coordinator.dart`
  - Android 原生：`android/app/src/main/kotlin/com/fanqie/fanqie_flutter/ReaderPlaybackService.kt`（双 `MediaPlayer` 异步预装 `preloadNextAudio` / `clearPreloadedAudio`、段间自然呼吸停顿与 `onAudioTransition` 无缝切段）
  - macOS 原生：`macos/Runner/ReaderPlayback.swift` 与 `macos/Runner/MainFlutterWindow.swift`（双 `AVAudioPlayer` 后台预热无缝切段、段间呼吸停顿、实时变速、音频时长探测 `probeAudioDuration`、磁盘空间查询 `getFreeDiskBytes` 与钥匙串命名密钥存储 `readNamedSecret`/`writeNamedSecret`）
- **模块化 UI**：`lib/immersive/widgets/immersive_settings_sheet.dart`、`lib/immersive/widgets/immersive_settings_dialogs.dart`、`lib/immersive/widgets/immersive_pipeline_tab.dart`、`lib/immersive/widgets/immersive_player_panel.dart`、`lib/immersive/widgets/immersive_characters_sheet.dart`（全面适配移动端底栏与 macOS 桌面工具栏、固定高度桌面控制条及居中对话框）
- **WebDAV 云同步与端到端加密**：`lib/webdav/models/webdav_config.dart`、`lib/webdav/services/webdav_crypto.dart`、`lib/webdav/services/webdav_client.dart`、`lib/webdav/services/webdav_sync_service.dart`、`lib/webdav/widgets/webdav_sync_sheet.dart`

## 2. 应用内可视化配置与安全设计

- **源码零硬编码密钥**：代码仓库与默认预置骨架中不硬编码任何真实 API Key 或 WebDAV 密码。首次安装未填密钥时默认关闭沉浸式开关，用户可直接在「沉浸式听书设置」中填写或通过 WebDAV 一键拉取恢复；开发联调可通过 `--dart-define` 注入密钥。
- **本地与传输安全**：
  - 所有文本模型 API Key、TTS 供应商 API Key、普通 AI 朗读 API Key 与 WebDAV 密码在 Android 端存入系统 Keystore（`ReaderSecrets`），在 macOS 端存入系统钥匙串（`ReaderKeychain`），本地配置文件与偏好仅存槽位占位符；
  - 对非本地回环的明文 `http://` 网关或 WebDAV 地址，设置界面会展示「明文 HTTP」标识与安全风险提示。
- **多文本分析模型与分级思考加速**：
  - 支持新增、编辑、删除与独立启停多个 OpenAI 兼容文本模型，按模型独立配置并发数与思考程度（默认 `auto`），支持设置 1 个主模型 + 1 个兜底模型并在连续失败达到阈值时自动切换；
  - 默认开启「分级思考加速」（`tiered_thinking = true`）：模型设为 `auto` 时常规分块降档至 `minimal` 加速降耗，跨块身份冲突复核与单模型测试保留原档位。
- **TTS 供应商、瘦身 MP3 试听与同性别兜底**：
  - 内置 13 个 128kbps MP3 试听样本（位于 `assets/TTS-Example/*.mp3`，较原始无损 WAV 缩减 66.4% 包体积），旧版配置里的 `.wav` 样本路径会在加载时自动平滑迁移为 `.mp3`；
  - 音色 ID 默认自动去除 `_female` / `_male` 后缀并精确保留大小写（如 `DeepSeek_female` -> `DeepSeek`），默认旁白为 `Anthropic_male`；
  - 已编排数据使用的 TTS 音色若后续被停用、删除或运行期失效，自动按性别匹配可用音色兜底（男性对男性、女性对女性）。

## 3. 首句快启、无缝播放与重建编排

1. **首块微切分快启**：首次起播或空降到目标章时，目标章第 0 块按较小粒度（默认 `550 Token`，可在「管线与重建」中 `300~1500` 调节）切分，显著压缩冷启动首句出声等待时间，后续分块自动恢复大块吞吐。
2. **原生双缓冲无缝播放与呼吸停顿**：当前段播放期间自动异步预热下一已就绪音频段并按说话人关系插入自然换气停顿（默认：同角色 `120ms`、切换角色 `260ms`、跨章节 `480ms`，均可在「管线与重建」页微调），播放结束由原生无缝切入下一段并通过 `onAudioTransition` 同步 UI 高亮，消除切段 IPC 卡顿。
3. **5 章空降回溯与重建编排**：从长篇小说中间章节空降起听时，最多自动回溯往前 5 章（可调 `0~10` 章）建立角色档案，不拉取更早无关章节；已确认章节持久化复用不重复分析。可在「管线与重建」页一键触发「重建本书编排」，并保留现有 API Key 一键恢复预置模型列表。

## 4. WebDAV 云同步与备份

- **同步范围**：
  - **AI 语音配置**（沉浸式多模型/TTS 音色配置 + 普通 AI 朗读配置）：默认使用 `PBKDF2-HMAC-SHA256`（50,000 次迭代）+ `AES-256-GCM` 基于用户口令端到端加密上传，云端零明文 API Key；兼容读取旧版明文备份并在同步时原地平滑升级为加密信封。
  - **阅读数据**：双向合并书架列表、阅读历史、最新阅读章节进度与搜索历史（未离线在线书仅同步书目与阅读进度元数据，不上传临时缓存正文）。
  - **沉浸式书籍角色档案与音色锁定**：跨设备双向增量同步每本书的配音方案、角色名录、别名证据、身份变更与音色绑定（人工 `manualLocked = true` 锁定优先于自动分配）。
  - **离线书籍正文**：自动识别本地真实离线书籍并打包 ZIP 上传/下载，过滤仅含封面缓存的目录；支持在列表里单本手动上传或下载。
- **同步可靠性与自动化**：
  - 所有 JSON 状态文件采用「`HEAD` 校验 `ETag` 乐观锁 + `PUT .tmp` + `MOVE Overwrite: T` 原子替换」（服务端不支持 `MOVE` 时自动降级带 `If-Match` 直写），遇到并发冲突自动重拉远端最新版本重合并再提交；
  - 支持「打开应用时自动同步」与「退出阅读或切入后台自动轻量同步」（内置 60 秒节流防抖与本地哈希比对，无变化零网络请求，后台不传大离线书 ZIP）。
