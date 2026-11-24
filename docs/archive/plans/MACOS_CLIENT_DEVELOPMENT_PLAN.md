# macOS 客户端开发计划

> - 核查日期：2026-11-05
> - 代码基线：`eed103f`，版本 `3.3.4+340`
> - 文档状态：核心阅读版与 V3、S7 系统／兼容接口听书已落地；2026-11-07 用户追加自用云端 DMG。人工验收仍待补齐，S6 Developer ID／公证正式分发延期；最新证据见 [V3 记录](READING_EXPERIENCE_V3_IMPLEMENTATION.md) 和 [自用打包说明](MACOS_INTERNAL_RELEASE.md)。

本文记录核查基线、平台边界及后续开发路线。**最初的规划文档交付仅包含本文和 README 入口；用户随后要求按计划实施客户端。**以下“当前事实／已有功能”表格仍描述 `eed103f` 基线，不作为当前实现状态；工程、平台接口、桌面布局和 CI 的最新实现与测试证据见 [实施和验证记录](MACOS_CLIENT_VERIFICATION.md)。尚未通过阶段出口和正式分发验收的事项不得写成已完成。

## 当前执行范围（用户于 2026-11-07 再次调整）

1. 用户没有 Apple ID，仅需自用 DMG；现授权推送 V3 并运行 GitHub Actions Release 构建，无需正式签名或公证凭据。
2. 不递增 `3.3.4+340`。macOS 自用预发布使用独立 `macos-internal-*` 标签，明确记录本次源码提交；不改写 Android `v*` 标签、Release 说明或 APK。
3. 新增独立手动 macOS Actions：标准 arm64 runner、固定 Flutter、离线回归、生产 Release 编译、ad-hoc DMG / SHA-256；只使用内置 `GITHUB_TOKEN`。S6 正式分发部分仍属于后续规划。
4. S0 已通过；S1–S5 的完整手工验收、最低系统验证仍按原标准记录未完成。S7 已按用户追加要求实现系统语音和安卓同协议兼容 TTS，完整手工声音／系统播控验收仍单独保留。

## 目录

1. [文档交付与项目基线](#一文档交付与项目基线)
2. [现有功能与 Android 独占能力盘点](#二现有功能与-android-独占能力盘点)
3. [技术方案与开发顺序](#三技术方案与开发顺序)
4. [测试与验收标准](#四测试与验收标准)
5. [默认选择、边界与风险](#五默认选择边界与风险)

## 一、文档交付与项目基线

### 1.1 最初的规划文档交付范围

- 计划文档放入现有 `docs/` 目录，与项目既有实施计划和验证记录保持一致。
- [README](../README.md) 增加“macOS 客户端开发计划”入口，保持当前“Android 客户端”的描述准确。
- 内容覆盖功能盘点、Android 独占能力分类、技术方案、开发顺序、验收标准、工作量及风险。
- 文档落地不包含客户端实现、版本调整、发布标签或工作流变更。

### 1.2 已确定的开发目标

1. **仅支持 Apple Silicon，不支持 Intel。**
2. **核心阅读客户端先发布，完整听书后续补齐。**
3. **Android 与 macOS 暂时各端独立，不安排跨端备份互通或云同步。**
4. 最低系统目标采用当前 Flutter 模板要求的 **macOS 12.0**。
5. 桌面化布局及 GitHub DMG 分发采用推荐默认方案。

### 1.3 核查基线

| 项目 | 当前情况 |
|---|---|
| 代码基线 | `eed103f`，`3.3.4+340` |
| 核查日期 | 2026-11-05 |
| 工程结构 | 只有 Android 原生工程，没有 `macos/` |
| 业务架构 | Flutter + 内置 Dart 引擎，无需另行部署后端 |
| 本机工具链 | Flutter 3.47.4、Dart 3.13.3、Xcode 27.2、CocoaPods 1.17.0 |
| 静态分析 | `flutter analyze --no-pub` 通过，无问题 |
| 测试 | `flutter test --no-pub`：414 项通过，11 项跳过；未开启真实接口验证 |
| macOS 原生验证 | 尚未开展 |
| 正式签名 | 本机未发现有效签名身份；不代表已核查仓库的 macOS 签名 secrets |

必须区分“已有代码／测试覆盖”和“目标平台已验证”，不能将现有 Dart 测试结果写成 macOS 已支持。现有 Android 验证记录也不能代替 macOS 原生、文件权限、生命周期或签名验收。

## 二、现有功能与 Android 独占能力盘点

### 2.1 当前已有功能

下表“已实现”均指当前代码基线中的能力；“macOS 安排”是后续实施目标。

| 模块 | 已实现功能 | 主要实现依据 | macOS 安排 |
|---|---|---|---|
| 在线书库、搜索 | 官方频道与分类、高级筛选、分页、去重、失败重试、分类缓存、关键词搜索 | [SearchScreen](../lib/screens/search_screen.dart)、[ApiService](../lib/services/api_service.dart)、[SearchResultsScreen](../lib/screens/search_results_screen.dart) | 首版复用，适配桌面布局 |
| 书籍详情 | 简介、封面、书评、独立章节目录、目录刷新、开始／继续阅读 | [BookDetailScreen](../lib/screens/book_detail_screen.dart) | 首版 |
| 书架 | 收藏与已下载分区、列表／三列宫格、排序、批量管理、续读、稳定保留滚动位置 | [BookshelfScreen](../lib/screens/bookshelf_screen.dart)、[BookshelfService](../lib/services/bookshelf_service.dart) | 首版；宫格改为按窗口宽度适配 |
| 连载更新 | 更新检查、更新标记、手动刷新、30 分钟节流及迟到响应隔离 | [BookshelfService](../lib/services/bookshelf_service.dart) | 首版复用 |
| 历史 | 阅读／下载历史、正文片段、续读、批量删除与清空记录 | [ReadingHistoryService](../lib/services/reading_history_service.dart)、[HistoryService](../lib/services/history_service.dart) | 首版 |
| 下载 | TXT／EPUB、并发任务、进度、取消、管理面板、后续章节下载、插图保留 | [DownloadService](../lib/services/download_service.dart)、[DownloadManagerSheet](../lib/widgets/download_manager_sheet.dart) | 首版；重做桌面文件保存 |
| 阅读连续性 | 章节 ID、段落与字符锚点、版本化快照、续读、布局变化保位 | [ReaderPositionService](../lib/services/reader_position_service.dart)、[ReadingSnapshot](../lib/models/reading_snapshot.dart)、[ReaderScreen](../lib/screens/reader_screen.dart) | 首版重点验收 |
| 阅读模式 | 连续滚动、左右分页、覆盖／仿真／滑动／渐变／无动画 | [ReaderScreen](../lib/screens/reader_screen.dart)、[ReaderPageView](../lib/widgets/reader_page_view.dart)、[ReaderPagination](../lib/services/reader_pagination.dart) | 首版全部保留 |
| 阅读目录与跳转 | 正倒序、分卷折叠、章节名称搜索、书签／笔记跳转、跳转返回 | [ReaderScreen](../lib/screens/reader_screen.dart)、[ReaderNavigationHistory](../lib/services/reader_navigation_history.dart) | 首版 |
| 排版与主题 | 字号、行距、字距、段距、缩进、边距、内置字体、预设、单书覆盖、手动／跟随系统／定时夜间主题 | [ReaderSettings](../lib/models/reader_settings.dart)、[ReaderSettingsRepository](../lib/services/reader_settings_repository.dart)、[ReaderFontService](../lib/services/reader_font_service.dart) | 首版；隐藏不适用设备选项 |
| 阅读辅助 | 纯净模式、点击热区、自动滚屏、状态信息、休息提醒 | [ReaderScreen](../lib/screens/reader_screen.dart)、[ReaderSettingsSheet](../lib/widgets/reader_settings_sheet.dart) | 首版适配键鼠与窗口生命周期 |
| 缓存与离线 | 请求去重、邻近预取、三档策略、仅 Wi-Fi、覆盖范围、容量限制、清理与重试 | [ReaderCacheService](../lib/services/reader_cache_service.dart)、[FanqieBackendEngine](../lib/services/fanqie_backend_engine.dart) | 首版；补齐网络类型识别 |
| 正文搜索 | 本章／已缓存正文搜索、覆盖范围、原文高亮、取消与返回；不为搜索下载全书 | [ReaderSearchService](../lib/services/reader_search_service.dart)、[ReaderSearchSheet](../lib/widgets/reader_search_sheet.dart) | 首版 |
| 本地 TXT | 文件选择、编码与分章预览、确认导入、去重、取消、源文件保留 | [LocalBookService](../lib/services/local_book_service.dart)、[LocalBookParser](../lib/services/local_book_parser.dart)、[LocalBookImportDialog](../lib/widgets/local_book_import_dialog.dart) | 首版；补齐传统中文编码 |
| 本地 EPUB | OPF spine 顺序、NCX／nav、锚点分章、安全资源处理 | [LocalBookParser](../lib/services/local_book_parser.dart)、[SafeZipReader](../lib/services/safe_zip_reader.dart) | 首版 |
| 图片与封面 | 在线／本地正文插图、位图与安全 SVG、缩放、失败重试、旧书补图、封面校验缓存 | [EpubImages](../lib/services/epub_images.dart)、[OnlineIllustrationStore](../lib/services/online_illustration_store.dart)、[CoverCacheService](../lib/services/cover_cache_service.dart)、[ReaderIllustration](../lib/widgets/reader_illustration.dart) | 首版，验证 Retina 与窗口重排 |
| 书签与批注 | 同章多书签、精确选区、划线、颜色、标签、编辑、搜索、引用定位 | [BookmarkService](../lib/services/bookmark_service.dart)、[NoteAnchorResolver](../lib/services/note_anchor_resolver.dart)、[ReaderNotesSheet](../lib/widgets/reader_notes_sheet.dart) | 首版；适配鼠标选区 |
| 导出与备份 | Markdown／JSON 笔记导出；ZIP 备份、可选书籍文件、合并／替换、事务回滚与启动恢复 | [ReaderExportService](../lib/services/reader_export_service.dart)、[ReaderBackupService](../lib/services/reader_backup_service.dart) | 首版，只验收同端恢复 |
| 阅读统计 | 默认关闭、本地统计、看书／听书区分、后台与闲置过滤、剩余时间估计 | [ReadingActivityService](../lib/services/reading_activity_service.dart) | 首版保留看书统计 |
| 评论与讨论 | 书评、段评、章评、新版讨论流、帖子回复与楼中楼、图片与游标分页 | [ApiService](../lib/services/api_service.dart)、[FanqieMobileGateway](../lib/services/fanqie_mobile_gateway.dart)、[ParagraphCommentSheet](../lib/widgets/paragraph_comment_sheet.dart) | 首版保留只读浏览 |
| 听书 | 系统／兼容网络语音、切片、语速、定时停止、淡出、跨章、后台进度与播控 | [TtsService](../lib/services/tts_service.dart)、[ReaderPlaybackService](../android/app/src/main/kotlin/com/fanqie/fanqie_flutter/ReaderPlaybackService.kt) | 后续独立里程碑 |

### 2.2 “Android 独占”分类

不能把“当前只用 Kotlin 实现”直接等同于“产品功能必须 Android 独占”。迁移时分成四类：

1. **共享业务逻辑：**复用 Dart 实现，再验收 macOS 行为。
2. **当前实现仅限 Android：**功能仍需要，补齐 macOS 实现。
3. **Android 保留／macOS 替代：**不适用的设备功能隐藏，使用桌面操作替代。
4. **后续能力：**明确延期，不显示可操作但无法工作的入口。

| 能力 | 当前限制 | 迁移分类 | macOS 处理 |
|---|---|---|---|
| 物理音量键翻页 | Android 按键拦截 | Android 保留／桌面替代 | 用阅读快捷键，不截获系统音量键 |
| 阅读窗口物理亮度 | Android `WindowManager` | Android 保留 | 隐藏该设置，不修改全局显示器亮度 |
| 触感反馈 | 当前依赖移动端体验 | 首版不提供 | 不显示无效开关 |
| 前台媒体服务、通知栏播控 | Android 服务与 `MediaSession` | 后续替代 | 不移植 Android 服务模型；后续接入 macOS 系统媒体中心 |
| 音频焦点、耳机断开处理 | Android 音频系统 | 后续替代 | 以 macOS 音频输出与生命周期机制实现，不宣称一一对应 |
| 语音密钥保存 | Android Keystore | 后续补齐 | 改用 Keychain；不得回退到明文偏好设置 |
| GB18030／GBK／Big5 解码 | Android 原生流式转码；非 Android 当前只有 UTF-8／UTF-16 | 首版补齐 | 增加 macOS 原生流式解码 |
| 下载与导出到公共目录 | Android MediaStore；桌面只有目录／临时路径兜底 | 首版替代 | 实现系统“另存为”与真实保存结果 |
| 电量 | Android BatteryManager | 首版补齐 | 读取电源信息；无电池设备隐藏 |
| 阅读常亮 | Android 窗口标志 | 首版替代 | 用受控电源断言；不阻止主动睡眠或合盖 |
| 网络类型 | Android ConnectivityManager | 首版补齐 | 识别 Wi-Fi、有线、离线和未知状态 |

当前主要系统通道集中在 [ReaderSystemService](../lib/services/reader_system_service.dart) 与 [ReaderRuntime](../android/app/src/main/kotlin/com/fanqie/fanqie_flutter/ReaderRuntime.kt)，通道名称为 `com.fanqie.fanqie_flutter/download`；虽以 `download` 命名，实际承载文件、解码、系统辅助及听书操作。

**特别说明：**[移动网关](../lib/services/fanqie_mobile_gateway.dart)虽然使用 Android 协议参数，但签名、解密与请求逻辑位于 Dart，并不依赖 Android 原生运行环境。迁移时不应因为客户端运行在 macOS 就擅自修改上游协议字段。

### 2.3 当前 macOS 缺口

| 缺口 | 当前事实 | 对应阶段 |
|---|---|---|
| 原生工程与构建 | 没有 macOS Runner、Bundle ID、应用图标或构建配置 | S0 |
| 平台能力识别 | 部分系统服务在非 Android 平台直接返回未知／无操作；听书仍直接调用现有通道 | S1，听书 S7 |
| 桌面文件保存 | 下载仅保存到文档目录兜底；笔记导出仅返回生成文件路径 | S1 |
| 桌面导航与输入 | 主导航为底部导航；阅读交互以触控和长按为主，没有完整桌面快捷键 | S2、S3 |
| 窗口重排 | 现有保位能力需要在可调整窗口、实际正文视口及 Retina 下验证 | S3 |
| 传统中文编码 | [非 Android 解码分支](../lib/services/local_text_encoding.dart)拒绝 GB18030／GBK 与 Big5 | S4 |
| 本地路径与恢复 | 部分本地资源记录含本机绝对路径；尚无 macOS 同端恢复验证 | S1、S4 |
| macOS 原生测试 | 当前端侧脚本与集成测试主要面向 Android | S5 |
| 打包与公开分发 | [现有发布工作流](../.github/workflows/release.yml)只构建 APK；尚无 macOS 签名、公证与 DMG 流程 | S6 |
| 完整听书 | 系统语音、播放器、安全存储及系统播控仅有 Android 原生闭环 | S7 |

### 2.4 不能误记为已有功能的事项

- 当前没有真实榜单入口、账号云同步或 AI 剧情摘要。
- 自定义外部字体出现在旧规划中，当前实际支持的是系统字体和内置字体。
- 评论功能以读取为主，不包含完整发表评论、点赞或发帖能力。
- 作者话题的讨论展开仍未支持；帖子回复与楼中楼已实现，不能混为一谈。
- 下载任务尚无持久化队列与应用退出后的断点续传保证；“后台下载”指应用进程内的异步任务。
- 删除下载历史记录，不等于物理删除书籍文件。
- 当前备份不包含语音密钥，也不应描述为完整应用数据克隆；例如下载历史不在现有备份设置白名单中。
- 沿用同一备份格式不等于承诺跨端互通；Android ↔ macOS 互通不在本次开发验收范围。

## 三、技术方案与开发顺序

### 3.1 工程与平台接口

1. 在现有 Flutter 项目中增加 macOS Runner，保持同一套阅读核心，不另起客户端仓库或后端。
2. 固定 Bundle ID 为 `com.fanqie.reader.macos`；显示名称与图标沿用“番茄Reader”。
3. 在项目级构建配置限制 `arm64`，排除 `x86_64`；不依赖开发者的全局 Flutter 设置。
4. 增加内部平台适配接口及 `ReaderCapabilities`，集中管理系统能力，避免业务页面散布平台判断。
5. 保留现有 Android 通道名称、方法和播放事件协议；能力字段只做增补，事件仍经统一处理总线分发。
6. 首版 macOS 明确返回听书不可用，隐藏听书入口及相关设置，避免启动时调用未实现原生方法。
7. 保持书籍 ID、阅读锚点、设置与备份格式兼容；不新增业务后端 API。

#### 接口变更边界

| 接口／数据 | 后续变更 |
|---|---|
| 平台适配接口与 `ReaderCapabilities` | 新增内部接口，统一提供系统能力及可用性 |
| 数据目录提供接口 | 新增统一入口，供书籍、缓存、导入、封面、评论、备份及恢复使用 |
| 文件导出结果 | 明确区分保存成功、用户取消与保存失败，避免用空路径混淆状态 |
| Android 方法通道 | 保持已有名称、方法及播放事件协议，能力信息只增补 |
| 书籍、进度、书签、笔记与备份 | 不为此次适配改写稳定 ID、原文锚点或现有格式 |
| 业务网络接口 | 不新增后端服务，不因运行平台改变移动网关协议参数 |

### 3.2 数据与文件操作

1. Android 数据目录保持不变；macOS 持久数据使用 `getApplicationSupportDirectory()`。
2. 统一目录提供接口，使书籍、目录、评论、封面、缓存与恢复日志使用一致根目录。
3. 临时资源与永久书籍明确分离；路径获取失败不得静默把永久数据写入系统临时目录。
4. 保留现有缓存策略及清理边界，不删除下载、本地书、进度或批注。
5. 导入继续使用现有文件选择器；确认导入后复制到应用自有目录，不长期依赖外部源文件。
6. 新增文件导出结果，区分**保存成功、用户取消、保存失败**；仅成功时写入下载记录。
7. macOS 使用 `NSSavePanel` 与原生文件协调／流式保存。现有 `FilePicker.saveFile()` 要求完整字节数组，不用于最多 1 GB 的备份导出。
8. 用户取消保存时保留已下载内容，不伪报成功，也不删除已有目标文件。
9. 同端备份恢复保留校验、合并／替换、回滚和启动恢复；本地资源路径按当前数据根目录解析。

沙盒配置同时覆盖 Debug／Profile 和 Release：网络请求具备客户端权限，用户选择文件具备读写权限；不能只验证调试包而遗漏正式包的导入与导出权限。

文件权限与数据完整性检查沿用现有导入／备份限制，不放宽危险路径、链接、压缩资源、损坏文件或加密正文的拒绝策略。

### 3.3 桌面交互

#### 窗口与布局

- 单窗口，默认 `1024×768`、最小 `720×540`；尺寸为逻辑像素，保留标准标题栏、全屏与窗口尺寸恢复。
- 宽窗口使用侧栏，窄窗口使用紧凑导航；保留现有页面状态，不因切换导航重建书架。
- 普通单栏阅读居中、最大宽度 `840`；双页阅读按窗口实际可用宽度均分，不再限制总宽 `1280`，栏间距 `24`，外侧只保留用户的排版边距。分页使用每栏的实际正文视口，而非整个窗口尺寸。
- 桌面栏数提供自动／单栏／双栏。自动模式在窗口宽度至少 `1000` 且每栏文字空间足够时启用双栏；窄窗口或过大字号回退单栏。双栏用于左右翻页，选择双栏时同步切换为分页阅读，滚动模式保持单栏。
- 双栏每次翻一个跨页（两页），奇数末页右栏留空，不重复正文；下章从左栏开始。单双栏与窗口变化不修改原文锚点、书签或笔记。
- 「阅读全屏」是阅读区域的临时沉浸状态：隐藏阅读工具栏、章节信息、页码与底部状态，正文使用完整阅读视口；不调用应用系统全屏，不改变窗口尺寸、窗口样式或桌面空间，也不改写显示偏好。普通单栏的宽度限制在沉浸期间解除，退出后恢复。
- 普通阅读设置入口常驻；阅读全屏时可点击中间或将鼠标移到上边缘唤出菜单，再打开设置或退出。菜单以覆盖层显示，不挤压正文和触发分页重排，不能因文字选区或翻页动画失去操作入口。离开阅读后沉浸状态不影响书架或下一次阅读。
- 窗口缩放、全屏切换、打开侧面板、字体变化均以原文锚点恢复，不能跳到章节开头。
- 阅读目录与正文搜索使用共用侧栏，默认 `304`、可调整 `240–480`；窗口至少 `1060` 时停靠，否则覆盖显示且点外部／`Esc` 可关闭。拖动只预览，松开后以原文锚点重排一次，双击恢复默认；目录开关与偏好宽度独立于排版预设记忆。有效正文宽度扣除停靠栏后重新判断单双栏。
- 搜索／滚动状态跨缩放和关闭重开保持；搜索保留本书的查询、结果与选中项，非模态停靠栏不阻止正文操作。设置、笔记、缓存与书签仍采用居中桌面弹窗，移动端继续使用底部弹层。
- 桌面正文使用 `SelectionArea`／逐段 `SelectionListener`，只为挂载段落分配选区资源；保留一致的 `3px` 测量预留。跨栏选区保持原起点、复制剔除缩进／气泡。V3 追加同章跨段批注，保留起止段落和字符范围，旧单段格式兼容。
- 列表、宫格及弹层按实际可用尺寸布局，保留窄屏和大字可操作性。

#### 键鼠操作

- 支持鼠标滚轮、触控板、拖动选区、复制、右键批注及清晰的悬停反馈。
- 输入框、中文输入法组合态及文本选区优先处理按键，不触发误翻页。
- 鼠标选区沿用原文字符范围和引用定位，不因桌面展示变化改写批注锚点。
- 拖动选择正文时不得同时触发点击热区或翻页手势。
- 正文单击可翻页／开关控制栏，双击选词与拖动选区优先；用于保留双击的待定单击，在打开设置、改变排版或缩放时取消。关闭设置后恢复阅读快捷键焦点。
- 分页滚轮只处理一次滚动操作的首个信号，连续信号和惯性尾声合并，空闲 `180ms` 后接受新操作；翻页中的滚轮不排队补翻。单栏一次翻一页，双页一次翻一组连续页；可滚动的正文子区域、选区和弹层保留输入优先级。
- 原生滚轮优先按事件源时间戳判断 `180ms` 手势间隔，避免繁忙帧延迟分发时误认成新手势；没有有效时间戳的合成事件仍使用原来的空闲定时器。
- 桌面覆盖／滑动／渐变动画调整为 `320ms`，仿真为 `360ms`，仿真释放收尾按同比例放慢；首个滚轮信号立即响应，无动画／系统减少动态效果仍无动画。Android 原有 `260ms`／`300ms` 节奏不变，键盘和点击的有意重复操作仍保留翻页队列。
- 连续滚动中的键盘重复输入累积目标，不再因上一动画尚未结束而丢失；反向键从当前位置立即反向。滚轮与触控板保留原生滚动，不叠加平滑滤波，并暂停自动阅读；减少动态效果时键盘滚动直接跳转。

| 快捷键 | 行为 |
|---|---|
| `⌘O` | 打开本地小说导入 |
| `⌘F` | 上下文搜索：书库页面搜索书籍，阅读页面搜索正文 |
| `⌘G`／`⌘⇧G`、F3／Shift+F3 | 正文搜索下一处／上一处匹配，输入法组合态优先 |
| `⌘[`／`⌘]` | 阅读位置后退／前进，新跳转清除前进分支 |
| `⌘⇧N` | 打开跨书笔记工作台；工作台中 `⌘F` 聚焦笔记搜索 |
| `⌘D` | 阅读页面添加／管理当前位置书签 |
| `⌘,` | 阅读设置 |
| `⌘⇧D` | 开关桌面目录 |
| `⌘J` | 按序号跳章；范围校验、Enter 确认，失败／取消保留原位置 |
| `⌘+`／`⌘−`／`⌘0` | 增大／缩小／重置字号，按当前全局或单书设置范围保存 |
| `F1` | 阅读快捷键帮助 |
| `F11`／`Esc` | 切换／退出阅读沉浸全屏；输入框、选区及弹层优先，长按重复事件不反复切换 |
| `⌃⌘F` | macOS 应用系统全屏，与阅读沉浸按钮独立；绿色窗口按钮仍为系统操作 |
| 左右键 | 分页模式翻页 |
| 上下键 | 连续滚动模式逐行滚动，按实际缩放后的行高计算 |
| Space／Shift+Space | 下一屏／上一屏，双栏一次翻一组 |
| Home／End | 本章开头／结尾，可通过跳转记录返回 |
| Page Up／Page Down | 两种阅读模式的前后阅读操作 |

#### 生命周期

- 关闭窗口隐藏主窗口并保留进程，Dock 点击恢复；`⌘Q` 才完全退出。
- 退出前保存进度与设置；恢复事务进行中阻止普通退出，强制退出后依靠日志恢复。
- 窗口失去活跃阅读状态时停止自动滚屏、更新统计状态并释放阅读常亮，不改变已有内容位置。
- 原首版不要求多窗口、Finder 文件关联或拖拽导入；本次工作空间后续扩展已接入后两项，多窗口仍不在范围。Finder URL 在原生安全范围内按 `64 KiB` 复制至独立暂存，Dart 接收冷启动／运行中消息并串行展示预览，关闭或确认后只释放受控副本。
- 桌面下载队列原子保存为独立 `download_queue_v1.json`，不混入阅读备份或排版设置；重启时中断任务转为暂停，用户明确继续后复用缓存。退出先保存暂停检查点，不等待阻塞 HTTP；保存中的原生导出须完成或取消，已提交的文件优先。损坏队列不覆盖，也不因空队列读取错误阻止阅读器正常退出。
- 跨书笔记工作台是现有 `notes_<bookId>` 的本地派生索引，不另存一套笔记；名称元数据键 `reader_note_books_v1` 随同端备份合并。引用定位验证章节 ID／唯一旧标题与原文范围，取消或歧义不打开迟到的阅读路由。

### 3.4 顺序实施计划

按 `S0 → S1 → S2 → S3 → S4 → S5 → S6` 完成首版；核心阅读正式版发布后进入 `S7`。每阶段按可验证切片提交，阶段出口通过后再推进下一阶段。

| 阶段 | 工作内容 | 阶段出口 | 估算 |
|---|---|---|---|
| S0 工程启动 | 生成 macOS 工程、Bundle ID、图标、arm64 配置、插件注册、沙盒与网络权限 | Debug／Release 可启动，无平台初始化异常 | 2–3 人日 |
| S1 平台与文件基础 | 能力接口、统一目录、文件选择／保存、电量、网络、常亮、窗口生命周期 | 文件结果真实可靠；不调用 Android 专用能力 | 3–5 人日 |
| S2 桌面业务页面 | 侧栏、书库、搜索、详情、书架、历史、下载管理及自适应弹层 | 在线书籍从发现到阅读／下载形成闭环 | 3–5 人日 |
| S3 阅读器适配 | 正文宽度、窗口重排、全部阅读模式、键鼠、选区、图片、目录与往返导航 | 缩放与交互不破坏原文位置 | 5–8 人日 |
| S4 核心能力补齐 | 传统编码、本地导入、缓存、批注、导出、同端备份、统计、评论 | 首版全部非听书功能通过验收 | 4–6 人日 |
| S5 平台验收 | macOS 原生测试、弱网／离线、长时运行、无障碍、Android 回归 | 核心阅读版达到发布标准 | 3–5 人日 |
| S6 打包发布（正式分发延期） | 自用独立 CI／Release／ad-hoc DMG 已纳入；正式签名、公证、安装与覆盖更新待验收 | 首个核心阅读正式版本发布（不作为自用包出口） | 2–4 人日 |
| S7 完整听书 | 系统／网络语音、Keychain、系统播控、后台与睡眠行为、播放可靠性 | 独立听书版本通过真实端验收 | 10–15 人日 |

- 首版估算 **22–36 人日**，听书追加 **10–15 人日**。
- 以一名熟悉 Flutter 与 Swift 的开发者估算，不包含证书申请、外部接口故障和测试设备等待时间。
- 人日不是固定日历排期；签名凭据和测试设备的准备可提前进行，但不能据此跳过验收。
- 发布时继续遵守项目版本与标签约定；计划文档交付不递增当前版本。

#### 开发进度清单

- [x] S0 工程启动：Debug／Release 启动与 arm64 配置通过（2026-11-06，Apple M4 / macOS 27.0.1，证据见实施和验证记录）。
- [ ] S1 平台与文件基础：目录、权限、保存结果及生命周期通过。
- [ ] S2 桌面业务页面：在线发现、详情、书架、历史和下载闭环通过。
- [ ] S3 阅读器适配：所有阅读模式、窗口重排、键鼠与选区通过。
- [ ] S4 核心能力补齐：本地导入、离线、批注、同端恢复和评论通过。
- [ ] S5 平台验收：macOS 原生、长时及 Android 回归通过。
- [ ] S6 打包发布：签名、公证、安装、覆盖升级和正式分发通过。
- [ ] S7 完整听书：真实端系统／网络语音和系统播控通过。

后续完成阶段时，记录验证日期、实际设备／系统、命令、结果及剩余限制；仅代码完成但原生验收未完成时，不勾选整个阶段。

### 3.5 听书方案（V3 已实现，完整手工出口待验收）

1. 复用现有 Dart 播放队列、原文切片、会话／切片标识、错误暂停及缓存上限。
2. 系统语音使用 `AVSpeechSynthesizer` 直接播放；兼容服务合成的 MP3／WAV 使用 `AVAudioPlayer`。不重复应用服务器 `speed`，系统声音缺失时明确提示。
3. Keychain 保存密钥，不进入日志、普通偏好设置或阅读备份。
4. 使用系统 Now Playing 与远程播放命令，保留播放／暂停、上下段及停止操作。
5. 验证隐藏窗口、后台、锁屏、输出设备变化、定时停止及音量淡出。
6. 不承诺系统睡眠或合盖期间继续播放；唤醒后若停止期限已过，应停止而非继续播报。
7. V3 按用户追加要求启用有效能力入口；代码／隔离协议测试不能代替真实系统声音和外部服务验收。

不将 Android 前台服务、锁屏通知界面或音频焦点模型直接移植到 macOS。迟到的播放、合成与网络事件仍必须按当前会话和切片标识隔离，错误不能静默跳过正文。

### 3.6 CI 与分发（自用已纳入，正式分发延期）

> 2026-11-07 用户授权自用云构建，替代此前仅本地的决定。已新增
> [macos-internal.yml](../.github/workflows/macos-internal.yml)，参数和无密钥方案见
> [自用打包说明](MACOS_INTERNAL_RELEASE.md)。以下 Developer ID 方案仍仅为后续正式分发规划。

1. 新增独立 macOS 验证工作流，采用 ARM64 的 `xcode-27` runner，启动时核查实际架构。
2. 固定当前 Flutter 版本；PR 验证和内部构建不依赖正式签名秘密。
3. 正式流程：Developer ID 签名与 Hardened Runtime → 公证并装订票据 → DMG → 分发验证 → SHA-256。
4. 缺少证书或公证凭据时，只能生成明确标注的内部测试产物，不能冒充正式版。
5. 正式发布手动向已存在的 `v<version>` GitHub Release 追加 macOS 附件，不改写 Android 发布正文，也不阻塞现有快速 APK 流程。
6. 产物命名：`fanqie-v<version>-macos-arm64.dmg` 及对应 `.sha256`。

正式发布前必须核查所有嵌套原生组件的签名、目标架构、最低系统版本和 Release 权限。CI 构建成功不代替首次安装、Gatekeeper 或最低系统真实运行验证。

Runner 标签依据核查当日的 [GitHub-hosted runners 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。实施时验证实际系统与架构，避免将 Intel 构建误当作 Apple Silicon 验收。

## 四、测试与验收标准

### 4.1 自动化与原生测试

| 测试方向 | 必须覆盖的场景 | 通过标准 |
|---|---|---|
| 平台接口 | 能力开关、目录隔离、保存取消／失败、缺少原生实现 | 不调用不支持能力；结果与用户操作一致，没有启动异常 |
| 阅读连续性 | 窗口缩放、全屏、字号与模式变化、图片或评论迟到、退出重进 | 原文锚点保持；不闪现错误开头、不遮挡正文、不错误重排 |
| 键鼠 | 滚轮、触控板、分页快捷键、鼠标选区、右键批注、中文输入 | 选区和输入期间不误翻页，批注范围与原文一致 |
| 本地导入 | UTF-8、UTF-16、GB18030／GBK、Big5、EPUB；损坏数据、重复文件、取消、128 MB 限制、危险资源 | 有正文才提交；取消不产生半本书；不覆盖不同内容或放宽安全策略 |
| 数据安全 | 同端备份合并／替换、损坏拒绝、失败回滚、强制退出后的启动恢复 | 校验先于应用；原数据可恢复；缓存清理不删永久数据 |
| 在线能力 | 分类、搜索、目录、正文与图片、完整讨论及回复分页 | 成功数据正确；失败保留已有内容、提供重试、不以预览冒充正文 |
| 系统行为 | 无电池设备、Wi-Fi、有线、离线、未知状态、后台释放常亮 | 不显示错误电量；网络提示准确；不残留阅读电源断言 |
| Android 回归 | 原生解码、亮度、音量键、听书、导出及共享阅读逻辑 | 现有测试继续通过，Android 已有行为不受影响 |

测试使用隔离数据目录或专用账号，不操作日常阅读数据；真实接口验证仍显式开启，不进入默认离线测试。

#### 可复用的当前测试依据

- 连续性与导航：[位置服务](../test/reader_position_service_test.dart)、[阅读导航](../test/reader_navigation_test.dart)、[阅读入口稳定性](../test/reader_entry_stability_test.dart)。
- 排版与交互：[分页](../test/reader_pagination_test.dart)、[选区与分页](../test/reader_selection_and_pagination_test.dart)、[无障碍](../test/reader_accessibility_test.dart)。
- 导入与插图：[本地导入](../test/local_import_v2_test.dart)、[EPUB 插图](../test/epub_illustration_import_test.dart)、[在线阅读](../test/online_reader_test.dart)。
- 缓存与备份：[缓存](../test/reader_cache_service_test.dart)、[备份](../test/reader_backup_service_test.dart)。
- 听书与回复：[听书服务](../test/tts_service_test.dart)、[帖子回复接口](../test/post_replies_gateway_test.dart)、[帖子回复面板](../test/post_replies_sheet_test.dart)。

以上测试是回归基础，不是已经具备的 macOS 原生测试；平台实现后仍须增加真实 macOS 验证。

### 4.2 真实 macOS 验收

- [ ] 在 Apple Silicon 上验证最低系统目标与当前系统；缺少最低系统设备时标记待验证。
- [ ] 覆盖 `720×540`、`1024×768`、大窗口、Retina 和双倍文字缩放。
- [x] 本机固定离线负载连续阅读至少 30 分钟：每次输入前进、段落／字符锚点、跨章、异常、内存趋势与缓存边界均通过；不外推为全部设备／前台帧率验收。
- [ ] DMG 拖入 Applications、首次打开、离线阅读、退出重开、覆盖升级均通过。
- [ ] 校验主程序架构、签名、公证票据、Gatekeeper 和文件摘要。
- [ ] 听书另行验证真实中文音色、系统播控与输出设备变化，不用协议 mock 代替真实端验收。

真实端记录必须注明设备、芯片、系统版本、构建模式和已验证路径。尚未测量的帧率、中文音色质量或最低系统兼容性不能写成已达标。

### 4.3 最初的规划文档交付验收

> 以下仅适用于最初的计划文档提交；后续客户端实现按 4.1、4.2 和各阶段出口验收，不受“仅文档”提交范围限制。

- 功能盘点有实现依据，不把旧规划写成已实现功能。
- Android 独占、可迁移但缺实现、macOS 替代及延期能力明确分开。
- 首版／后续、阶段依赖、出口标准与估算一致。
- Markdown 表格、相对链接及 README 入口有效。
- 文档落地提交仅包含新计划文档和 README 链接，不夹带客户端实现。
- 客户端开发与真实 macOS 验收清单保持未完成，不将本次文档交付误报为客户端开发完成。

## 五、默认选择、边界与风险

### 5.1 已确认与默认选择

| 类型 | 内容 |
|---|---|
| 已确认 | Apple Silicon、各端独立、阅读先发／听书后补 |
| 默认采用 | 桌面化布局、macOS 12.0、单窗口、GitHub DMG 分发 |
| 原核心首版排除 | Intel、iOS、Windows、账号云同步、Android ↔ macOS 备份互通、新增内容形态、多窗口、Finder 文件关联、拖拽导入 |

后续工作空间迭代已单独纳入 Finder 文件关联／拖拽接收、持久化下载队列和跨书笔记工作台；不将它们混写成原首版已完成的必要验收。其余平台、多窗口、云同步与完整听书仍遵循原边界。

### 5.2 主要风险与处理

| 风险 | 影响 | 处理与阶段出口 |
|---|---|---|
| 阅读器窗口重排与选区冲突 | 位置跳变、误翻页、错误批注 | 使用实际正文视口与原文锚点；S3 验证，S5 回归 |
| 沙盒文件访问与导出 | 调试可用但正式包失败、无权限或取消误报 | Debug／Release 权限均验证；真实路径与三类保存结果验收 |
| 传统中文编码 | 中文乱码、解析失败、大文件阻塞 | 首版补齐原生流式解码；验证损坏输入及取消，不发布无正文占位书籍 |
| 本地路径与恢复 | 同端恢复后资源失效、旧数据被覆盖 | 统一根目录解析，先校验后应用，保持日志与回滚 |
| 第三方接口变化 | 分类、正文、图片或评论不可用 | 保留有效缓存并明确错误；不以网页预览冒充完整正文 |
| 后续媒体生命周期 | 迟到事件误推进、后台中断、定时失效 | S7 独立验收会话标识、播放回调、输出变化及睡眠边界 |
| 正式签名凭据缺失 | 无法可靠公开分发 | 作为 S6 前置条件；内部测试包不能冒充正式版 |
| 最低系统设备缺失 | 无法证明 macOS 12.0 真实兼容性 | 明确待验证状态，不用 CI 构建结果代替最低系统验收 |
| Android 回归 | 共享服务适配影响现有客户端 | Android 目录与通道保持兼容；S5 复验既有平台能力 |

正式签名凭据和最低系统测试设备是发布前置条件，不是现阶段已经具备的能力。只有满足验收条件，才可将 README 或发布说明改为“已支持 macOS”。

仅处理有权使用的内容，继续保留项目版权与使用边界说明。

### 5.3 核查依据与维护

- [当前 README](../README.md)：功能概览、工具链、发布方式与已知边界。
- [当前 pubspec](../pubspec.yaml)：版本、依赖及字体资源。
- [v3.2.0 实施与验证记录](V3_2_0_IMPLEMENTATION_STATUS.md)：阅读连续性、缓存、听书、导入、批注、备份与统计。
- [v3.3.0 验证记录](V3_3_0_VERIFICATION.md)：官方分类与正文可靠性。
- [v3.3.1 验证记录](V3_3_1_VERIFICATION.md)：在线插图与封面。
- [v3.3.2 验证记录](V3_3_2_VERIFICATION.md)：独立目录与阅读入口。
- [v3.3.3 验证记录](V3_3_3_VERIFICATION.md)：书架稳定性、阅读保位与章评。
- [v3.3.4 验证记录](V3_3_4_VERIFICATION.md)、[帖子回复验证](POST_REPLIES_VERIFICATION.md)：完整讨论流、帖子回复与楼中楼。

这些历史记录用于说明当前功能来源，其结果以原记录的平台与范围为准。后续开发保持本计划的范围与阶段编号稳定，在相应阶段补充实施／验证记录；功能或发布目标发生变化时单独确认，不通过悄悄勾选清单扩大首版范围。
