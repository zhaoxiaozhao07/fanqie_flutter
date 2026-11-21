# Windows 客户端实施与验证记录

依据 [WINDOWS_CLIENT_DEVELOPMENT_PLAN.md](WINDOWS_CLIENT_DEVELOPMENT_PLAN.md)（W0–W6）执行。
基线：`eed103f`（v3.3.4 构建 340）之上叠加 macOS 检查点 `4c3ea14` 的共享桌面适配。
分支：`feat/windows-client`。

## 结论摘要

| 阶段 | 状态 | 关键证据 |
| --- | --- | --- |
| W0 环境 | 完成 | Flutter 3.47.9（升级自 3.38.5，锁文件要求 Dart ≥3.11）+ VS2022 Pro 17.12.5 + Win11 26H2 |
| W1 工程与原生模块 | 完成 | `windows/` runner 生成并重构；通道协议全量实现；Debug/Release 构建通过 |
| W1 资源身份 | 完成 | CompanyName=com.fanqie、ProductName=FanqieReader、图标、版本资源 3.3.4.340 |
| W2 数据与文件可靠性 | 完成 | 数据根=`%APPDATA%\com.fanqie\FanqieReader`；关闭握手实测；缓存路径分隔符修复 |
| W3 本地书与导出 | 完成 | 五编码转码（含 GB18030 增补平面😀）、自动回退、取消、备份恢复、下载提交编号，全部真机验证 |
| W4 桌面阅读体验 | 完成 | 侧导航断点、840px 限宽、PgUp/PgDn、Ctrl+←/→ 换章、F11 全屏、Esc 链、鼠标拖选/右键 |
| W5 回归与验收 | 完成 | analyze 0 issues；单元测试 447 通过（新增 15 项 Windows）；集成测试 6/6（2 手工门跳过）；真机启动/单实例/退出握手冒烟通过 |
| W6 Release 打包 | 完成 | `dist/FanqieReader-3.3.4-340-windows-x64.zip`（26.2MB，含 VC 运行库 app-local DLL），SHA-256 生成；打包产物独立运行验证通过 |

## 架构决定（与计划早期草案的差异）

计划早期建议引入 `window_manager`/`file_selector` 插件。实际实现跟随 macOS 检查点（`4c3ea14`）建立的原生桥接模式：**不新增插件依赖**，Windows 用纯 C++ Win32 实现同一通道 `com.fanqie.fanqie_flutter/download` 的桌面子集，理由：

- 与 Android/macOS 保持同一 wire contract，Dart 侧零分叉；
- 退出握手（`onAppQuitRequested`）需要嵌入层配合，插件层难以可靠实现；
- 避免三个插件各自的窗口生命周期/事件循环与自研单实例、全屏、保存面板互相干扰。

## 各阶段实施与验证

### W0 环境与基线

- 本机 Flutter 3.38.5 无法解析锁文件（flutter_svg 2.3.2 需 Dart ≥3.11），升级 stable 至 3.47.9/Dart 3.13.7 后 `pub get` 成功。
- 分支 `feat/windows-client`。

### W1 Windows 工程

- `flutter create --platforms=windows --org=com.fanqie` 生成 runner；分析排除 `windows/**` 已由工具自动加入。
- **原生模块**（`windows/runner/`）：
  - `reader_platform_bridge.cpp`：能力协商（`getReaderCapabilities` 返回 windows/x64/architecture）、`getNetworkType`（INetworkListManager + 适配器类型）、`getBatteryLevel`（SYSTEM_POWER_STATUS，无电池返回 -1→能力 false）、`setKeepScreenOn`（Power Request，仅前台+非最小化时持有，最小化/失焦自动释放）、`showMainWindow`、`setReaderCommandsEnabled`、`requestQuit`、`toggleFullScreen`/`isFullScreen`（无边框全屏，退出恢复原布局）、Debug 测试钩子（`setTestWindowSize` 按 AdjustWindowRect 对齐客户区、`getTestWindowState`、`setTestFullScreen`、`hideTestWindow`=最小化）。
  - `reader_text_decoder.cpp`：后台线程流式转码，BOM 检测→UTF-8→GB18030(54936)→Big5(950)（显式编码含 GBK=936）；`MultiByteToWideChar(MB_ERR_INVALID_CHARS)` 严格校验 + 跨块多字节保留（≤3 字节尾巴）；UTF-16 代理对跨块处理；取消永不发布半文件；128MB 上限；非符号链接/非目录校验。
  - `reader_file_exporter.cpp`：`IFileSaveDialog` 另存为（序列化队列，`cancelExport` 通过 `EnumThreadWindows` 关闭 #32770 模态框）；提交采用同目录 staging + `ReplaceFileW`（已存在）/`MoveFileExW`（新建）原子替换；`commitDownloadFile` 直接提交到目录并自动编号（`name (2).txt`，绝不覆盖邻居）；`pickDownloadDirectory` 原生目录选择。
  - `win32_window.cpp/h`：最小客户区 720×520（`WM_GETMINMAXINFO`）、`Create(placement)` 恢复上次会话几何（`%APPDATA%\com.fanqie\FanqieReader\window-state.txt`，脱离显示器则回退默认）、全屏切换。
  - `main.cpp`：命名事件单实例（第二实例唤起首实例窗口后退出）、窗口状态恢复。
- **资源身份**：Runner.rc 覆盖 FileDescription=番茄Reader、ProductName=FanqieReader；`flutter_launcher_icons` windows 生成图标（顺带改动的 Android 资源已回滚）。

### W1/W4 Dart 共享代码桌面化

- `ReaderPlatform`：`isWindows`/`isDesktop`/`requiresNativeBridge`；能力协商泛化（battery/keepAwake/networkType/textDecoder/fileExport 对桌面开放；tts/音量键/亮度/触感仍仅 Android）；原生初始化失败在 Windows 同样抛错并显示重试页。
- 全部行为性 `ReaderPlatform.isMacOS` → `isDesktop`（15 处文件），Android 分支不动。
- `DesktopShortcuts`：macOS 保留 Cmd 键位（菜单），Windows 注册 Ctrl+O/F/,/B；F11 全局全屏。
- 阅读器键盘：新增 Ctrl+←/→ 章节切换（边界禁止）、F11、Esc 链（全屏→控制栏→返回）；Shift 修饰忽略；Ctrl+C 保留原生复制。
- `ReaderSystemService`：桌面全屏镜像状态 + `toggleFullScreen`/`exitFullScreenIfActive`。
- 下载：`DesktopDownloadOutput`（默认“下载/fanqie”，偏好记忆，原生目录选择器，`commitDownloadFile` 提交）；`DownloadDialog` Windows 目录行（显示当前目录+更改）。

### W2 数据与文件可靠性

- `AppStorage`（桌面走 Application Support）→ 实测数据根为 `%APPDATA%\com.fanqie\FanqieReader`（由 exe 版本资源决定，与安装位置无关）。
- 修复 `ReaderCacheService`：缓存文件匹配与 pinned 前缀比较改为分隔符归一（Windows 反斜杠路径首次跑测试即暴露误删 pinned 书问题）。
- 关闭握手实测：`WM_CLOSE` → `onAppQuitRequested` → Dart 落盘 → 保存窗口几何 → 进程干净退出（含 8 秒兜底定时器路径存在性验证于代码审查；落盘超时弹“暂时无法退出”）。

### W5 回归与验收

- `flutter analyze`：0 issues。
- `flutter test`：447 通过（含新增 `test/windows_client_test.dart` 15 项：能力/初始化失败/存储失败不静默/导出四态/下载目录默认与记忆/commit 不弹保存面板/命令分发/退出参与者/导航栏状态保持/840px+键控翻页+锚点/Ctrl 换章/F11+Esc/拖选不翻页/设置隐藏无效项）。
- 集成测试（`integration_test/windows_reader_platform_test.dart -d windows`，真实原生通道）：6 通过 + 2 手工门跳过——能力与五编码字节级夹具（GB18030 含😀增补平面、UTF-16 代理对）、auto 回退顺序、重复导入去重、同平台备份恢复、EPUB 插图恢复、下载提交编号与不覆盖 guard 文件、真实保存面板取消（源文件保留）、窗口缩放锚点保持、最小化电源释放、恢复窗口。
- 打包产物独立运行：dist 目录直接启动 → 单实例（第二实例退出码 0）→ WM_CLOSE 干净退出。

### W6 Release 打包

- `scripts/package_windows.ps1`：Release 构建 → 便携目录（FanqieReader.exe + flutter_windows.dll + 插件 DLL + data/ + **x64 VC 运行库 app-local** + 安装说明）→ ZIP + SHA-256。
- 本轮产物：`dist/FanqieReader-3.3.4-340-windows-x64.zip`，26.2MB，SHA-256 `6C051F866AF37A89EBAB56A57CF56964894C5F71F1E973FF304EBB7C183D18C6`。
- 打包产物从 dist 独立启动/退出验证通过（验证 DLL 自包含性）。
- 安装说明含 SmartScreen 提示说明（计划 5.3：不签名可以，但必须说明且不要求关闭防护）；脚本以 UTF-8 BOM 保存，PowerShell 5.1 中文文件名/内容不再乱码。

### 对照计划审计补强（第二轮）

- **文件名净化（计划 3.3）**：原生 `SanitizeFileName` 拒绝 ADS 冒号、设备保留名（CON/NUL/COM1-9/LPT1-9）、非法字符与尾点/尾空格，另存为对话框默认名与下载提交名统一过毒；集成测试用真实文件验证（`书名:流.txt`→`书名_流.txt`、`CON`→`_CON`、`书名...`去尾点）。
- **关闭竞态加固**：decoder/exporter 改为 `shared_ptr` + `enable_shared_from_this`，工作线程持有自引用；平台线程投递只捕获 HWND（窗口销毁后投递被丢弃），窗口中途销毁不再触碰已释放状态。
- **目录穿越**：下载/导出文件名在 Dart 与原生两侧均不可携带 `/`、`\\`（原生净化替换），目录参数仅来自应用自身偏好或原生对话框，不接受任意外部字符串。

## 与计划条目的有意偏差

1. **不新增 `window_manager`/`file_selector` 插件**：跟随 macOS 检查点（`4c3ea14`）的原生桥接模式，用 runner 内纯 C++ 实现同一通道，保持三端 wire contract 一致（见开头架构决定）。
2. **侧导航断点**：计划 3.4 写“主界面宽 900 用侧导航”，共享代码（macOS 检查点已定型）在任意桌面宽度始终用 NavigationRail，≥1000 展开标签；断点切换不重建页面状态已验证。为保持与 macOS 一致未改断点值。
3. **能力入口**：计划建议“可注入的 ReaderPlatformCapabilities”，实际采用与 Android/macOS 同源的能力协商（通道返回 + `resetForTesting`），未另建注入层。

## 未验证与已知限制

1. **Android APK 构建**：本机网络阻断（gradle 发行版/插件仓库超时），无法出包。共享逻辑回归按计划口径以 analyze + 全量 flutter test（447 通过）为准；本轮未改动任何 Android 原生代码，`android/` 目录无 diff。
2. **手工验收门（与 macOS 同样保留）**：真实保存面板交互式往返（`WINDOWS_SAVE_PANEL_TEST=true`）与原生全屏锚点（`WINDOWS_NATIVE_FULLSCREEN_TEST=true`）为可选人工门，默认跳过；自动化已覆盖等价的取消/退出路径。
3. **听书（TTS）、音量键、亮度调节、触感**：按计划与 macOS 同步延后（能力位为 false，入口隐藏）。
4. **正式分发**：未做代码签名（无证书）、SmartScreen 信誉、GitHub Actions Windows 构建——与 macOS 内部构建策略一致，后续再议。
5. **多显示器/DPI 动态切换**：单实例、工作区钳制、每显示器 DPI 已实现并有单元级钩子，但未做多显示器手动矩阵验收。

## 第二轮：实测反馈修复（阅读交互五项）

真机使用反馈的问题与修复（分支同 `feat/windows-client`，本轮提交）：

| # | 反馈 | 根因 | 修复与验证 |
| --- | --- | --- | --- |
| 1 | 需要双栏阅读 | 分页器仅单栏 | `ReaderLayout.columns/columnGap` + 分页按"栏"装配（`columnSpans`）；渲染端 Row 双栏、窄屏(<672px)自动回退单栏；设置面板新增"双栏阅读"（桌面显示）。分页单元测试（两栏占满、片断连续、锚点定位）+ 组件测试（1400×900 双栏、缩至 560 回退单栏且锚点保持） |
| 2 | 翻页模式无法点击翻页，只能滚轮 | 桌面段落是 SelectableText，赢下手势竞技场，页面级热区 onTapUp 收不到 | 段落 onTap 在桌面转发 `_handleDesktopTextTap`：用 Scaffold 级 Listener 记录的鼠标位置重放热区判定（左/右翻页、中部菜单）；仿真翻页同样暴露 `handleExternalTap`。鼠标手势测试：点段落右侧→下页、左侧→上页 |
| 3 | 字体有些粗有些细 | 桌面默认 `Roboto` 不存在，未指定字体族按字形回退：中文与拉丁/数字取自不同系统字体，视觉粗细混杂 | 当时正文/章节标题/分页度量统一回退到打包的 `ReaderKaiTi`，非阻塞预载 + 载入后一次重排；当前统一规则见下方 2026-11-22 记录，不宣称任意字体覆盖全部 Unicode 字符 |
| 4 | 点击无法展开上下栏 | 同 #2（中部热区被 SelectableText 吞掉） | 同 #2；滚动模式点击段落中部=切换控制栏（测试验证返回按钮出现） |
| 5 | 阅读无法返回主页 | 控制栏根本无法展开（#4），返回按钮在其中 | 修复后中部点击展开上下栏→左上角"返回"可用；widget 测试从 pushed route 点返回按钮确认退出阅读 |

Android 回归：按用户提供的代理（127.0.0.1:7890，`JAVA_TOOL_OPTIONS` 注入 JVM 代理参数）完成 `flutter build apk --debug`（此前网络阻断项补齐），输出 `build/app/outputs/flutter-apk/app-debug.apk`。

本轮回归：`flutter analyze` 0 issues；`flutter test` 451 通过（+4：点击翻页×1、滚动点击×1、双栏组件×1、双栏分页×1）；Windows 集成 6 通过 + 2 手工门。重新打包 `dist/FanqieReader-3.3.4-340-windows-x64.zip`（SHA-256 `926CDDE64BF0CC4D12F1DB818B6B04D840419684F6CB64E9B2F0F8CEE7481753`），打包产物独立启动/退出冒烟通过。

## 2026-11-22：字体一致性与原生回归

以上为历史检查点；本节记录此次修复，正式发布流程另见 `WINDOWS_RELEASE.md`。

- 复现同一默认设置下正文使用 `Microsoft YaHei`、预览继承 `Segoe UI`，标题又没有相同的字体回退及中文 locale。并非文章被随机设置粗体，而是不同渲染入口选择了不同字体。
- `ReaderFontService.bodyStyle` 统一正文、预览、字体管理预览的常规字重、字体族、回退顺序、locale、基线及行距。标题从同一规则派生，保留有意的粗体层级；测量与实际渲染一致。
- Windows 默认、黑体和缺失字体回退到微软雅黑；楷体、宋体和可用导入字体保留用户选择。宋体自身横细竖粗、不同字体的笔画设计以及未覆盖字符的回退不能当成随机加粗，也不保证所有 Unicode 字符均来自同一字库。
- 全局设置先注册所选字体再显示预览，避免只读索引却没有加载导入字体。导入字体预览显式使用主题前景色，修复暗色背景黑字问题；丢失字体保留原偏好而不改写。
- 字体相关回归及邻接回归共 **60 项通过**，包含分页/滚动四种字体、加载前占位、已有导入字体、缺失字体保留以及明暗预览可读性。红/绿测试和独立审查均保留在 `.dart_tool/codex-windows-reading/`。
- `windows_reader_platform_test.dart` 本次真实 Windows 集成 **9 通过、1 手工另存为跳过**，包含取消、窗口/全屏锚点、文件恢复、导入和真实 loopback 音频播放。
- 新增 `windows_reader_font_smoke.dart` 使用原生 Windows 字库而非 Ahem，四种字体的正文/预览混合中英数字测量一致，并生成合成书籍截图供视觉检查。该烟测 **1 项通过**；这是 Debug 原生字体验收，不冒充 Release 性能测试。
- 物理显示倍率本次为 1.0；更多物理 DPI、多显示器、完整前台性能与手工覆盖保存仍不宣称已通过。
- 主线整合审查发现旧缓存非法 UTF-8 被 `readAsString` 包装为磁盘异常，导致联网及末尾补漏被阻断。改用严格字节解码，保留旧缓存并继续恢复；真实离线写入失败仍报告磁盘错误并禁止自动重试。
- 加入上述修复后的整合全量回归 **781 通过、11 跳过、0 失败**，静态分析 0 issues；保留主线 Android 10+ MediaStore 无存储权限保存优化，Android Debug SDK 编译通过。原生设备权限/MediaStore 验收不由编译替代。
