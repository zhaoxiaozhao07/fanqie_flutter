# macOS 开发交接

交接日期：2026-11-23（Asia/Shanghai）。用户要求暂停 Windows 上的开发，仅保存 WIP、编写说明并通过 Git 迁移；本次交接不继续修复、不启动测试或 CI。

> **Mac 续工状态（2026-11-23）：** 隐藏窗口 WIP 已在 `2f5d30f` 修复；
> focused/analyze、全量离线、实际 Mac 平台与 57 项 XCTest 已通过，
> 七场景 AOT、完整 CI 45121742680、最终 DMG 下载/只读挂载复验也已通过。
> 代码与自动化验收完成，物理/人工项目仍单独待验。最新状态及证据见
> [Mac 接手验证记录](MACOS_RESUME_VERIFICATION_2026-11-23.md)。
> 下文保留 Windows 暂停时的历史状态，不代表续工后的当前验收状态。

## 1. 在 Mac 上接手

仓库：[zhaoxiaozhao07/fanqie_flutter](https://github.com/zhaoxiaozhao07/fanqie_flutter)。
分支：`codex/macos-sync-optimizations`。本文和两份未完成改动位于同一个 WIP 交接提交，提交号可用 `git log -1 --oneline` 查看。

```bash
mkdir -p "$HOME/Projects"
git clone --branch codex/macos-sync-optimizations \
  https://github.com/zhaoxiaozhao07/fanqie_flutter.git \
  "$HOME/Projects/fanqie_flutter"
cd "$HOME/Projects/fanqie_flutter"
git status --short
git log -1 --oneline
```

若 Mac 已有该仓库，先保留自己的改动，再 `git fetch origin`、切换该分支，使用 `git pull --ff-only`；不要覆盖本地改动或强制重置。

- 开发目标是 Apple Silicon / arm64，应用版本保持 **3.3.6+342**、最低构建目标 **macOS 12.0**。
- 使用 **Flutter 3.47.9 / Dart 3.13.7**；安装 Xcode 和 Command Line Tools。Python 工具要求 **3.10+**。
- 不复制 Windows 的 worktree、Flutter SDK、构建缓存或本机设置。Git 不携带本次聊天、忽略的 SDD 日志和报告；接手时先读本文。
- 用户在 Mac 上恢复开发后，可执行：

```bash
flutter --version
flutter doctor -v
flutter config --enable-macos-desktop
flutter pub get --enforce-lockfile
```

## 2. 已完成且经过验证的产品代码

最近通过验证的源码提交：**`9deb13a3c5e90d81e88d3c8f18836e6bd60b061c`**。
WIP 交接提交不是已通过 Mac 全部验收的提交。

- **下载目录**：Swift 管理 Downloads 权限、自选目录 security-scoped bookmark、既往目录的精确文件检查；Dart 路径不是授权。后台复制、原子不覆盖提交、取消及已提交成功语义有测试。
- **滚轮**：只有原生明确非精确的 Mac 滚动事件可连续翻页；源时间戳截断至微秒、精确匹配、一次消费、有界缓存。精确/未知/迟到事件失败关闭；Windows 行为保留。
- **字体/阅读**：Mac 与 Windows 独立字体期望、五种页效果、缓存复用、配色刷新、2× DPI 双栏转单栏锚点回归已补充。
- **AOT**：五种单栏效果、真实双栏、真实跨章节，共七场景；核对实际列数、提交地址、原文范围、耗时与内存。
- **发行**：完整版本/build、生产入口、资源、native-assets、权限、签名、完整目录快照和 DMG 只读挂载复验；输出带 build、拒绝覆盖，来源绑定源码/ref/SDK/run/attempt/摘要。扫描错误必须失败关闭。Bash 3.2 下中文相邻变量已显式加花括号。
- 显式手动 `release` 路径保留且要求所有者证书/公证配置，绝非自用 CI 的 fallback；未执行真实 Developer ID 签名/公证。

实际云端证据：

| 运行 | 结果与边界 |
|---|---|
| [45036306625](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/45036306625) | Mac 953 项 Dart 通过 / 13 跳过，57 项 XCTest 通过；完整平台前 7 项通过，在隐藏窗口用例等待帧时达到 15 分钟期限。后续 AOT/打包未运行。 |
| [45040046473](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/45040046473) | 关闭完整平台入口的独立验证；Mac 953/13、57 XCTest、七场景 AOT、生产 Release、签名/权限/快照/挂载/产物来源校验通过；`publish=false`。它不替代完整平台验收。 |

AOT 观测：104,000 UTF-16 单位单段冷分页 377ms；六个大正文场景为 206,340 UTF-16 单位；实际双栏最终页 44，跨章完成 20 次 + 2 次热身、最终 c22；最高 build P95 7.713ms、raster P95 3.265ms、命令到提交帧 P95 30.305ms，进程峰值 232,062,976 bytes。
该 runner **foreground=false、DPR=1**；不是物理 Retina、前台显示 FPS、实际输入延迟或声音验收。

已验证自用包：[Actions 产物](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/45040046473/artifacts/14761503228)，含 DMG、同名 SHA-256 和 build-info。

- 文件：`fanqie-v3.3.6-342-macos-arm64-internal.dmg`
- 大小：28,906,351 bytes
- SHA-256：`ddc8d449830902c656ddeed5e313029d462bb22a9b0195cfdd79b1f3afbe85ed`
- 来源仍是上面的 **9deb13a**，不是 WIP；ad-hoc、未公证，不承诺 Gatekeeper/安装升级验收。

## 3. 交接时 WIP：先完成隐藏窗口测试（历史）

本次只原样保存两份暂停时的文件，没有继续修改其逻辑：

1. `integration_test/macos_client_platform_test.dart`
   - 新增测试专用 `verifyMacHiddenWindowLifecycle`。
   - 移除隐藏后直接等待 `tester.pump` 的依赖；尝试以有界 native/IO 观察确认隐藏、电源断言和保存锚点，再在 finally 恢复真实可见状态后 pump。
2. `test/macos_hidden_window_lifecycle_test.dart`
   - 新增 suppressed-frame、恢复、超时、保存/IO/权限失败的模拟行为测试；有真实隔离临时文件。

**交接时状态：WIP，尚未 GREEN、尚未 analyze、尚未独立复审、尚未实际 Mac 验证。**
暂停前只完成了旧行为的 RED 复现：隐藏帧不可用时触发独立 500ms 期限。刚写入的修复不能当作已通过。

重点：

- 先检查 helper 与实际 `ReaderPositionService` 持久化语义；尤其 `updatedAt` 必须晚于旧快照的条件是否真正验证了隐藏时的新保存。
- 不用预先保存、删除隐藏/电源/锚点断言、伪造可见/前台状态或增大总期限来制造通过。
- 即使隐藏检查失败，也应以有界 native 恢复路径重新显示窗口，再恢复依赖帧的测试；不能再次挂死。

用户在 Mac 恢复开发后的建议顺序：

```bash
flutter test --no-pub test/macos_hidden_window_lifecycle_test.dart
flutter analyze --no-pub
scripts/test_macos_platform.sh \
  --dart-define=MACOS_SAVE_PANEL_TEST=false \
  --dart-define=MACOS_NATIVE_FULLSCREEN_TEST=false
```

完成必要修复与独立复审后再跑全量离线测试，并使用同一最终源码验证七场景 AOT 和生产包：

```bash
scripts/test_macos_reader_performance.sh
```

若使用云端完整验证，先提交/推送已验证的改动，再手动请求该分支；不发布：

```bash
gh workflow run macos-internal.yml --ref codex/macos-sync-optimizations \
  -f version=3.3.6 -f publish=false -f full_platform=true \
  -f reader_aot=true -f require_foreground=false -f live_api=false
```

## 4. 继续工作的约束

- 不自动合并或推送 main；不改 Windows/Android 默认行为、依赖锁文件、旧标签或发布附件。
- 不自动公开预发布，不使用真实用户数据/语音密钥测试；保持自用 ad-hoc 与正式签名/公证边界。
- 真机自选目录/TCC/外部卷、物理鼠标和触控板事件顺序、IME、Retina、音频/媒体键/耳机蓝牙、macOS 12、安装升级仍需单独验收。
- 先前决策：历史下载检查使用原生 bookmark 权限；导入测试按拥有者清理完成同步，而不是固定睡眠；曾限制 formal 接口的决定已撤销并恢复显式 manual route；大 benchmark 主函数抽取延期，不扩大本次修复范围。
- 设计/计划在 `docs/superpowers/specs/2026-11-22-macos-sync-design.md`、`docs/superpowers/plans/2026-11-22-macos-sync-optimizations.md`。执行记录仅本机忽略目录中；本文是可随 Git 迁移的恢复入口。

可粘贴到 Mac 新聊天：

> 请先阅读 docs/MACOS_DEVELOPMENT_HANDOFF.md，继续 codex/macos-sync-optimizations 分支的隐藏窗口 WIP。先做 focused GREEN/analyze 和代码审查，再做实际 Mac 完整平台、七场景 AOT 与最终来源验证。不要删安全/锚点断言或伪造前台结果；不要自动合并 main、公开发布或使用真实用户密钥。
