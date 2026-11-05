# macOS 客户端实施与验证记录

- 记录日期：2026-11-05–2026-11-06；基线 `eed103f`，版本保持 `3.3.4+340`。
- 本机：Mac mini / Apple M4 / 24 GB，macOS 27.0.1（26A434），`arm64`。
- 工具链：Flutter 3.47.4 / Dart 3.13.3 / Xcode 27.2（27B52）。
- 当前范围（用户 2026-11-06 调整）：按 [开发计划](MACOS_CLIENT_DEVELOPMENT_PLAN.md) 完成核心阅读适配并先做本地测试；S6 签名／Actions／正式分发和 S7 听书延期。
- 状态：**核心适配代码和本地自动化验证通过，人工验收尚未全部完成。** 本阶段不要求正式签名或云端构建；不能据此宣称已完成整份原计划或已公开发布。

## 1. 已落地的实现

| 阶段 | 实现依据 | 当前证据与尚未完成的出口 |
|---|---|---|
| S0 | `macos/Runner`、Bundle ID `com.fanqie.reader.macos`、原图标、工程级 `arm64`／排除 `x86_64`、12.0 目标、插件注册、双配置沙盒权限 | Debug／Release、项目级 arm64、双配置权限、真实 AOT 可见窗口启动和原生退出通过；S0 阶段出口通过 |
| S1 | `ReaderPlatform`／`ReaderCapabilities`、`AppStorage`、`FileExportService`、Swift `ReaderNativePlatform`／`ReaderFileExporter`、统一事件总线与退出协调 | 实际能力、Application Support、系统保存取消、原子流式复制、隐藏窗口保位、释放常亮、恢复窗口通过自动化；用户手工 Release 另存为外部 Documents 成功、内容一致；真实原生退出回调刷写当前段落并正常退出（最近 720×540 验证保存第 21 段）；Dock／完整文件选择手工体验仍需补齐 |
| S2 | `MainScreen` 侧栏／紧凑侧栏、宽度变化保留 IndexedStack、搜索焦点、导入与设置菜单、书架自适应宫格 | 桌面导航／搜索焦点／窄窗口通过；新增 2 项真实 macOS 业务闭环（发现卡片→目录→正文／下载→离线重建→删除重加）通过；全部弹层真实视觉体验仍需验收 |
| S3 | 阅读正文最大逻辑宽度 840；实际视口分页；键盘／鼠标滚轮／触控板；桌面 SelectableText 原文选区；路由命令；退出前保存参与者 | 五种分页模式、滚动模式、鼠标拖选、键盘优先级、窗口重排有测试；持续缩放中发现锚点漂移，已修复并增加精确字符锚点回归；右键批注、真实中文 IME、全屏和 Retina 手工验收仍需补齐 |
| S4 | Swift 严格流式 UTF-8／UTF-16／GB18030／GBK／Big5；同端导入、备份和恢复保持格式；TTS 能力关闭且入口隐藏 | 六类编码、EPUB 导入／去重／源文件保留／恢复与安全回归通过；新根目录恢复后删除旧根，封面校验和正文插图实际渲染通过；全部业务真实路径仍需逐项验收 |
| S5 | Dart 桌面测试、Swift XCTest、macOS 通道测试、Release smoke、30 分钟 soak；Android 原生回归 | 自动化证据如下；最低系统与完整视觉／无障碍／全屏仍未通过；长时和显式真实接口已通过 |
| S6（延期） | 本地 DMG／SHA-256 和未来正式签名、公证校验脚本；当前不配置 macOS Actions | 内部包已生成并校验；用户确认签名／Actions／正式发布后续再做。本轮不新增 macOS 工作流、不触发云端构建 |
| S7 | macOS 能力返回 TTS／媒体／密钥存储不可用 | 未实施；不得启用系统／网络听书、Keychain 或系统播控入口 |

Android 通道名称、方法、播放事件协议及移动网关参数保持不变。macOS 不拦截物理音量键，不修改全局显示器亮度，不提供无效触感开关。无电池的本机电量返回 `-1`，不伪造百分比。

## 2. 自动化证据

测试数据使用隔离目录及偏好设置。以下是实际命令结果，不代表未测试设备或完整手工体验。

| 命令／测试 | 实际结果 |
|---|---|
| `flutter analyze --no-pub` | 最新无问题 |
| `flutter test --no-pub` | 最终 432 通过／11 跳过（414 项既有回归＋18 项 macOS 测试）；真实网络默认不启用 |
| `flutter test --no-pub test/macos_client_test.dart` | 18 项通过：能力、缺失桥接、目录失败、三种保存结果、路由命令、退出写入失败、导航状态、五种分页模式、鼠标滚轮、拖选／右键菜单、上下文搜索／组合态优先、精确重排锚点、双倍字号页面与设置 |
| `xcodebuild test ... -destination 'platform=macOS,arch=arm64'` | 10 项 XCTest 通过：六类编码、跨块字符、损坏／截断拒绝、128 MB 限制、解码取消、流式复制、原子替换、取消保留目标、链接／悬空链接／目录目标拒绝、电量范围、确认 XCTest 不启动生产 Dart／不访问日常阅读数据 |
| `flutter test integration_test/macos_client_platform_test.dart -d macos --reporter expanded` | 4 通过／2 手工验收测试跳过（保存、全屏）：实际能力、六类编码导入、同端备份恢复、真实 NSSavePanel 取消、窗口重排／隐藏／恢复、常亮释放、同端更换数据根恢复后的封面和正文插图 |
| `scripts/test_macos_release_smoke.sh` | Release AOT 实际启动通过；正式应用与共用初始化器、真实可见窗口、原生能力、Application Support 导入、实际保存取消通过；在真实阅读器滚动后调用原生退出，收到原生回调、刷写当前段落并由 AppKit 正常终止（最近第 21 段）；RSS 最近单次 191,758,336 bytes，仅为样本，不是性能标准 |
| `flutter test integration_test/macos_business_platform_test.dart -d macos --dart-define=FANQIE_LIVE_API=true` | 2 项通过：官方发现的新书与既有书籍，真实卡片／详情／阅读、目录与首章下载、离线零网络重建、删除重加；测试根目录完全隔离；默认不开启真实网络 |
| `scripts/test_android_platform.sh` | 9 项通过：使用 `fanqie_v320_api35` 的只读实例（`emulator-5554`）；原生解码、亮度、Keystore、保存、备份、统计、播放器、关屏前台服务及媒体暂停／恢复回归 |
| `bash -n scripts/*.sh` | 本地脚本语法通过（兼容 macOS Bash 3.2）；之前拟定的 macOS 工作流已按用户决定移除，不使用 Actions 验证 |

### 发现并修复的问题

1. 未完成的 Swift 解码取消实现错误引用导出队列字段，导致编译失败；改为加锁的解码请求集合。
2. Darwin `iconv` 拒绝有效 GB18030 四字节补充平面字符（例如 😀）。改用 CoreFoundation 完整映射，先校验字符边界，64 KiB 读取，保留最多 3 字节跨块尾部，不替换损坏字符、不提交半文件。
3. Big5 与 GB18030 可存在有效但含义不同的字节序列，无法保证“自动”始终识别正确；保留预览与手动编码选择，不伪称通用自动识别。
4. 侧栏从展开切换到紧凑宽度时，Material 3 动画产生水平溢出；只重建导航栏，不重建业务 IndexedStack，紧凑栏采用 80 逻辑像素。
5. 长时缩放在约 229 秒发现保存段落从 169 漂移到 168。修复为重排后闲置时保留原文字符锚点，实际滚动后恢复采样；增加连续 20 次宽高变化的精确锚点回归。30 分钟复验通过：364 个采样，持续滚动及定期缩放保持原文位置，异常／缓存／RSS 趋势检查通过。
6. 内部 ad-hoc 包若开启 Hardened Runtime，Flutter 组件无共同 Team ID，会被 dyld library validation 拒绝。默认内部配置不开启 Runtime；**正式流程对所有组件使用同一 Developer ID 并明确开启 Hardened Runtime，不加入 disable-library-validation 权限。**
7. 切换 AOT 测试入口后，Flutter 增量嵌入可能导致外层签名封存旧 App.framework；内部脚本刷新外层 ad-hoc 签名并严格校验。正式包仍采用独立的嵌套正式签名流程。

### 长时与真实接口现状

- `macos_reader_soak_test.dart` 1800 秒实际完成（30:04），364 个采样；滚动／缩放保位、异常、缓存及 RSS 趋势断言通过。RSS 首样本 392,232,960、末样本 351,502,336 bytes；只代表本机固定工作负载，不是所有设备的性能承诺。
- 最终显式 `--dart-define=FANQIE_LIVE_API=true --concurrency=1` 执行四个真实接口测试文件：14 项全部通过；分类、搜索、目录、正文、实际 CDN 封面／插图、离线重开、章讨论及完整帖子／楼中楼分页均有实际返回证据。
- 帖子／楼中楼的快速分页确实失败；隔离只读诊断确认上游 HTTP 200 / `code=100`，错误信息包含 3–5 秒 ban window，而非 macOS 原生或解析错误。间隔 6 秒可读取帖子完整 24 条（20＋4）及楼中楼首 3／总 14 条。显式 live 测试增加间隔和最多一次重试，保留全部完整性／游标／正文断言；最终全量 14 项通过，其中帖子 24 条／2 页，楼中楼 14 条／5 页，空回复页仍为 0；未跳过或放宽原有断言。生产网关字段与错误／重试语义未改。
- GUI 观察工具对本地构建 app 返回 `cgWindowNotFound`；不能声称已做完整截图／视觉检查。Release smoke 的真实窗口属性及渲染错误检测不是全部手工体验的替代品。


### 手工 Release 保存证据

执行 `MACOS_SAVE_PANEL_TEST=1 scripts/test_macos_release_smoke.sh`，用户选择系统保存位置后日志返回 `FANQIE_RELEASE_SAVE_OK .../Documents/fanqie-release-smoke.txt`；导出内容与源文件一致，未自动删除选定的输出。该文件仅含隔离测试正文，仍保留供检查。GUI 工具仍无法读取该 app 的窗口，因此不将此次保存外推为完整视觉验收。

测试入口不会覆盖正常客户端的窗口尺寸恢复设置；原生 XCTest 不启动生产 Dart，避免触碰日常偏好／恢复日志。


### 全屏与 Retina：仍需真实前台会话

新增 `MACOS_NATIVE_FULLSCREEN_TEST=true` 原生全屏验收，调用真实 `NSWindow.toggleFullScreen`，等待进入／退出通知并核对原文字符锚点，不用简单改窗口尺寸替代全屏。自动会话尝试失败：窗口可见但 `applicationActive=false`、`keyWindow=false`；实际 backing scale 为 1.0，不能写成 Retina 已测。声明窗口为 full-screen primary、使用新系统激活 API（保留 macOS 12 回退）后，这个无前台会话仍不允许切换。

该测试保留为独立手工验收入口，默认本地自动化测试不计为已覆盖：

```bash
flutter test integration_test/macos_client_platform_test.dart -d macos \
  --dart-define=MACOS_NATIVE_FULLSCREEN_TEST=true --reporter expanded
```

必须在可成为前台的真实桌面会话中通过，才能勾选对应 S3／S5；不能用默认测试中的跳过来支持完成声明。

## 3. 内部产物与签名边界

```bash
flutter pub get
scripts/test_macos_platform.sh
scripts/test_macos_release_smoke.sh
scripts/package_macos.sh
scripts/verify_macos_bundle.sh build/macos/Build/Products/Release/FanqieReader.app internal
```

- 产物：`build/macos/distribution/fanqie-v3.3.4-macos-arm64-internal.dmg` 及 `.sha256`。
- 使用临时签名，DMG 内包含 `INTERNAL_TESTING.txt`；不命名成正式版、不承诺 Gatekeeper／公证。
- 校验器拒绝测试入口产物（Info.plist 记录实际 `FLUTTER_TARGET`，交付必须为 `lib/main.dart`），检查所有 Mach-O 的 `arm64`、最低 OS load command ≤12.0、Bundle ID、主包与嵌套签名、网络客户端／用户选择文件读写／沙盒权限；正式模式还检查 Developer ID、Hardened Runtime、公证票据与 Gatekeeper。
- `hdiutil verify` 通过；SHA-256 必须以当前同名 `.sha256` 文件为准，重建后会变化。
- 尚未验证 DMG 拖入 Applications、首次启动、离线数据延续和覆盖升级。内部包不可当作正式安装验收。

## 4. 正式分发配置（后续规划，本阶段不执行）

[GitHub hosted runners 官方说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 当前包含 ARM64 `xcode-27`。未来引入工作流时应再次检查 `uname -m`；当前不安装 macOS 工作流或专用 actionlint 配置。

未来正式工作流计划使用 `macos-release` environment，届时建议配置必需审核人；需要以下 secrets（不写入仓库／偏好设置／阅读备份）：

- `MACOS_CERTIFICATE_P12_BASE64`、`MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGN_IDENTITY`（`Developer ID Application: ...`）
- `MACOS_NOTARY_APPLE_ID`、`MACOS_NOTARY_PASSWORD`（应用专用密码）
- `MACOS_TEAM_ID`

本机 `security find-identity -v -p codesigning` 为 **0 valid identities**。2026-11-06 只读核查 GitHub：仓库 secrets 名称没有 `MACOS_*`；`macos-release` environment secrets API 返回 404；远端当前仅有 APK 工作流。未读取任何秘密值，也未创建环境或推送工作流。没有凭据时只能运行内部流程。

正式流程：所有叶子 Mach-O 与嵌套组件签名 → 主 app Hardened Runtime／Release 权限 → app ZIP 公证／装订 → app Gatekeeper → DMG → DMG 签名／公证／装订／Gatekeeper → SHA-256。缺少任何凭据或校验失败即失败，不回退临时签名。

手动发布要求指定 `version` 的 `v<version>` 标签和非草稿 Release **已存在，且该标签包含 macOS 实现**，版本与 `pubspec.yaml` 一致。`publish=true` 只追加 DMG 和摘要，不覆盖 Android 正文或阻塞 Android 工作流，不自动创建新 Release。

## 5. 剩余验收（不得提前勾选完整阶段）

- 已通过本轮 analyze、432 项 Dart、10 项 Swift、4 项 macOS 通道、Release 启动／原生退出、30 分钟阅读及 9 项 Android 通道；新编辑后仍须重跑相应测试。
- 真实弱网／离线全业务闭环、全部资源及覆盖升级；30 分钟自动阅读与变根恢复插图已通过。
- Release 用户另存为 Documents 成功、内容已核对；覆盖目标／完整 Debug 与 Release 文件选择交互仍需补齐。
- 720×540、1024×768、大窗口、Retina、双倍字号；鼠标右键批注／复制、中文输入法组合态、全屏、无障碍。
- Dock 恢复、⌘Q 数据保存、恢复期间拒绝普通退出、强制退出后日志恢复。
- 在线完整 UI 闭环；生产 UI 在真实限流情形下的完整手工体验；显式 live 接口测试已全部通过。
- macOS 12.0 真实设备；当前系统不能替代最低系统验收。
- S6 的远端 CI、Developer ID、公证、装订、Gatekeeper 及正式分发已按用户决定延期；本地安装／覆盖更新体验仍可后续人工验收。

S7 听书不属于本次核心阅读首版的完成条件，但其清单必须继续保持延期、入口关闭。

## 6. 原正式交付阻塞（已按用户决定延期）

此前按完整正式发布范围核查时，以下外部条件未具备。用户已于 2026-11-06 明确改为先本地测试，签名与 Actions 后续再安排；证书和发布环境不再阻塞当前检查点提交：

- 本机签名身份仍为 0；仓库没有 `MACOS_*` secrets；GitHub `macos-release` 环境查询仍返回 404。不能执行 Developer ID 签名、公证、Gatekeeper 或正式附件发布。
- 唯一本机为 Apple M4 / macOS 27.0.1；没有 macOS 12.0 实机，不能以 deployment target 或当前系统运行代替最低系统验收。
- 图形控制仍无法获取 app 窗口；原生全屏尝试中窗口可见，但进程未成为前台／key window。需要可交互的前台桌面会话完成全屏、Retina、Dock 和其他手工验收。

已实现的代码、内部 DMG、SHA-256 及自动化结果保持有效；再次核查内部包入口、架构、签名封装和摘要均通过。当前没有进行中的构建或测试任务。整体目标尚未完成，不勾选 S1–S6 的完整阶段。

继续完整正式交付时才需要配置签名／公证凭据和发布环境。当前用户已授权提交并推送开发检查点；不创建发布标签、不公开分发签名产物、不触发 Actions。最低系统与前台人工验收继续保留为待验证项，不伪造通过结果。


## 7. 当前开发检查点与后续功能

- 应用版本继续为 `3.3.4+340`；本次提交的是 macOS 本地开发检查点，不是新正式版本。
- 本地可用：Apple Silicon 工程、桌面导航／快捷键、阅读器限宽与保位、传统中文编码导入、系统另存为、平台能力隔离、生命周期保存、同端恢复及插图。
- 尚不能称为全部完成：全屏／Retina／真实 IME／VoiceOver 等人工验收、最低系统验证、完整安装更新体验；完整 macOS 听书（S7）还未实现。
- 当前不新增或启用 macOS Actions，保留既有 Android 流程；本次提交带 `[skip ci]`，仅在云端保存源代码。
- 可选后续功能：S7 完整听书；持久化下载队列与退出后续传；Finder 文件关联／拖拽导入；跨书笔记索引和独立笔记工作台；外部字体管理。
- 上述新增能力是候选项，不是已实现功能；跨端同步／云同步／AI 内容功能仍不在当前范围。
