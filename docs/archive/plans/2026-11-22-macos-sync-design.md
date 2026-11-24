# macOS 同步优化范围与验收设计

用户于 2026-11-22 确认上一轮跨平台检查清单，并要求新建 worktree、全部依次跟进。本设计落实既有功能，不重复移植共享 Dart 下载、分页、配色及设置保护代码。

## 边界

- 基线提交：`114216f94c646d0191da5df858c58537f3624062`。
- 独立分支：`codex/macos-sync-optimizations`；不修改原 checkout。
- 保持应用版本 `3.3.6+342`、macOS 最低构建目标 `12.0` 和 `arm64`。
- 不升级业务依赖，不改 Android/Windows 默认行为或旧发布资产。
- 保留 macOS 自用 ad-hoc Release 包、main-only 公开预发布限制；隔离分支可以运行 `publish=false` 并产出可下载 DMG。不自行合并或推送 main。
- 真实声音、耳机/蓝牙、媒体键、Retina 物理显示、macOS 12 和安装升级的人工验收与自动化结果分别记录。

## 顺序与设计

1. **验证基线**：对齐 Flutter `3.47.9`；在现有 macOS 工作流接入隔离原生 XCTest，保留既有完整平台集成入口。失败必须阻断生产打包。使用当前 Mac CI 建立原生证据，不能用 Windows 组件测试替代。
2. **下载目录**：桌面下载共用输出目录 UI。Windows 保持 `windows_download_dir` 和既有默认路径。macOS 目录授权、security-scoped bookmark 和文件提交由 Swift 管理；默认用户 Downloads/fanqie 使用仅 Downloads 的沙盒权限，自选目录使用用户选择授权。授权失效必须明确失败，不静默写往另一个目录。后台提交不弹保存框，原子提交不覆盖同名文件，取消保留源/旧目标并清理 staging。
3. **滚轮策略**：Windows 行为不变。macOS 仅在原生事件明确标记非精确滚动时启用连续完整刻度/明确反向；精确滚动及未分类事件保持一次手势一次翻页。原生事件时间戳与 Flutter 指针事件匹配，缓存有界，未知/迟到分类失败关闭；内层滚动和选区继续优先。
4. **回归和性能**：字体预览/正文/标题、五种页效果、缓存保留、配色刷新、Retina 2× 双栏回退均覆盖 Mac 和 Windows。Mac AOT Profile 增加实际双栏、跨章节、超长段落和前台状态记录。前台/物理输入/显示 FPS 不混同于 Dart 命令到提交帧。
5. **发行质量**：校验完整版本与 build、生产入口、运行资源和 native-assets；DMG 最终只读挂载后再验内容。文件名包含 build，拒绝既有输出冲突。来源元数据绑定源码、ref、SDK、run、attempt、版本和附件摘要，发布前独立验证、上传后确认远端标签和附件。不绕过 main-only 或正式签名/公证边界。

## 验收方法

- 本地：锁定依赖、完整 Flutter 离线测试、analyze、Python 验包/来源/脚本边界测试、shell 语法、diff 检查。
- macOS CI：arm64 原生 XCTest、生产 Release 构建、签名/权限/资源/DMG/摘要校验；平台集成与 AOT Profile 结果单独保留。
- 最终提供来源明确的新版 DMG 与 SHA-256，记录实际 Actions 源码 SHA 和全部未实机验证项目。
