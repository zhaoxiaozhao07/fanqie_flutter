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
- 本轮产物：`dist/FanqieReader-3.3.4-340-windows-x64.zip`，26.2MB，SHA-256 `51579A0E4A92CBF9DD77E5C3A0C91E778829030079C138DCFA07010CEE1158A0`。
- 打包产物从 dist 独立启动/退出验证通过（验证 DLL 自包含性）。

## 未验证与已知限制

1. **Android APK 构建**：本机网络阻断（gradle 发行版/插件仓库超时），无法出包。共享逻辑回归按计划口径以 analyze + 全量 flutter test（447 通过）为准；本轮未改动任何 Android 原生代码，`android/` 目录无 diff。
2. **手工验收门（与 macOS 同样保留）**：真实保存面板交互式往返（`WINDOWS_SAVE_PANEL_TEST=true`）与原生全屏锚点（`WINDOWS_NATIVE_FULLSCREEN_TEST=true`）为可选人工门，默认跳过；自动化已覆盖等价的取消/退出路径。
3. **听书（TTS）、音量键、亮度调节、触感**：按计划与 macOS 同步延后（能力位为 false，入口隐藏）。
4. **正式分发**：未做代码签名（无证书）、SmartScreen 信誉、GitHub Actions Windows 构建——与 macOS 内部构建策略一致，后续再议。
5. **多显示器/DPI 动态切换**：单实例、工作区钳制、每显示器 DPI 已实现并有单元级钩子，但未做多显示器手动矩阵验收。
