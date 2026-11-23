# 2026-11-23 macOS 接手与验证

## 来源与边界

- 从远端 `codex/macos-sync-optimizations` 的 `672686d` 接手；本地原 checkout
  无未提交改动，使用 fast-forward 同步，分支包含当前 `origin/main`。
- 本次实现提交：`2f5d30f633174558fed937aef0ac42d56c46f997`。
  后续验证记录的文档提交不改变这个实现提交中的代码。
- 版本仍为 **3.3.6+342 / arm64 / 最低构建目标 macOS 12.0**。
  没有修改业务代码、依赖、锁文件、Android/Windows 默认行为或其工作流。
- 本机使用单独安装、固定到官方 `3.47.9` 标签的 Flutter SDK，
  Dart **3.13.7**；保留原有 Flutter 3.47.4 安装。测试命令临时设置 PATH/
  FLUTTER/JAVA_HOME，没有改变全局工具链配置。
- 本机环境：macOS **27.0.1 (26A434)**、Xcode **27.2 (27B52)**；
  Python **3.12.14**，已有 JDK **21.0.13**。

## 隐藏窗口 WIP 修复

改动仅在 `integration_test/macos_client_platform_test.dart` 与
`test/macos_hidden_window_lifecycle_test.dart`：

1. 隐藏时只做有界 native/IO 观察，不等待 widget 帧。单阶段仍为 5 秒，
   focused fixture 的独立总期限仍为 500ms，没有增加原期限制造通过。
   使用单调 Stopwatch 计算阶段剩余时间。
2. 保存必须同时满足：原文章节/段落/字符偏移/图片锚点不变；保存意图时间晚于
   旧快照和本次 hide 请求；实际 `onWindowHidden` 保存参与者完成后观测的快照
   与读取的已保存快照属于同一代。
3. 只在基线 flush 后追加只读观察参与者，真实阅读器参与者先执行。
   没有预先保存新的通过记录、替换原生/生产隐藏 handler 或伪造可见状态。
4. finally 始终走 native show + 真实 visibility probe；show 回应失败时仍探测
   恢复。未确认可见就不 pump。验证异常在 runAsync 内捕获，恢复后明确重抛，
   避免 `WidgetTester.runAsync` 报告异常后返回 null 使 helper 表面成功。
5. 文件夹具原子替换自身临时 JSON；失败操作以完成信号同步拥有者 teardown，
   避免在 widget 的 FakeAsync error zone 结束后重新等待其失败 Future。

已单独复现 RED：原 helper 让“runAsync 吞错”“新鲜但在 hide 前保存的记录”
和“没有隐藏保存确认的记录”三种情况错误成功。修复后这些阴性案例均拒绝。
补充真实 `tester.runAsync`、`ReaderPositionService.save/loadSnapshot`、
不同源锚点/代际、阻塞 native/IO、失败恢复回归。

**保存证据边界：** focused 文件夹具使用真实隔离文件；
`ReaderPositionService` 和平台 reader 的偏好使用进程内 mock，避免读写用户的
原生偏好域。这里验证保存完成/代际及真实 native 隐藏通知，不声称完成用户偏好
域的断电持久性或真实 TCC/外部卷验收。

## 已完成的本机验证

| 门禁 | 结果 |
|---|---|
| 隐藏窗口 focused | 25 通过 |
| focused + position + Mac client | 47 通过 |
| `flutter analyze --no-pub` | 无问题 |
| 全量离线 `flutter test --no-pub` | 980 通过 / 11 跳过 |
| stock `/bin/bash` native pipeline fixtures | 19 通过 |
| stock `/bin/bash` AOT lifecycle fixtures | 6 通过 |
| package/provenance filesystem fixtures | 28 通过 |
| shell 语法、diff 检查 | 通过 |
| 完整 macOS 平台集成 | 11 通过 / 2 人工用例跳过 |
| 生产 Debug 主机原生 XCTest | 57 通过 / 0 失败 |
| 七场景 AOT Profile | 7 场景全部通过 |
| 生产入口 Release 构建 | 通过 |
| ad-hoc 签名、生产 bundle/权限/架构门禁 | 通过 |

全量第一轮的两个 Kotlin unit 失败来自未设置本机已有 JDK，配置 JAVA_HOME 后
原样通过；没有跳过它们或修改 Android 实现。云端没有这组 Kotlin 缓存时，
合法跳过计数会与本机不同。

实际隐藏窗口证据：resize 后锚点为 `c / paragraph 76 / offset 0`，
旧代 `2026-11-23T06:02:54.496184Z`，隐藏保存新代
`2026-11-23T06:02:54.510617Z`；隐藏时 `visible=false`、
`displayAssertion=false`，恢复后 native probe 的 `visible=true`。
此会话 `applicationActive=false`、`keyWindow=false`、backing scale **1**，
不能把“可见”写成“前台”或物理 Retina 验收。

本机日志位于忽略目录 `build/macos/local-verification/`。

本机 AOT 的五个单栏效果、真实双栏（最终 page 44）和真实跨章节
（20 次完成 + 2 次热身，最终 `c22`）全部通过。104,000 UTF-16 单位单段
冷分页 **109ms**；六个大正文场景各 206,340 单位。各场景最大 build P95
**17.337ms**、raster P95 **3.475ms**、命令到提交帧 P95 **202.111ms**；
进程峰值 **308,314,112 bytes**，本地搜索就绪 245ms、5000 笔记就绪 431ms、
挂载 7 张笔记卡。所有场景实际 `foreground=false / DPR=1`，这些值不是
物理输入延迟或真实前台显示 FPS。

生产 Release 已恢复 `lib/main.dart` 入口；原生门禁独立验证 3 个 Mach-O
组件的 arm64/minimum target、ad-hoc 签名和生产权限。未启动生产应用读写
日常阅读数据。最终交付 DMG 使用下方 CI 产物并独立下载复验，不冒用 CI run
身份给本机产物编造来源。

## 最终 CI：通过

[完整 CI 45121742680 / attempt 1](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/45121742680)
于 **2026-11-23 14:25:36（Asia/Shanghai）** 成功结束，源码为上述
**2f5d30f633174558fed937aef0ac42d56c46f997**。实际 runner 为 macOS
**26.7.2 (25G332)**、Xcode **26.6 (17F113)**，SDK 为 Flutter 3.47.9 /
Dart 3.13.7。

| CI 门禁 | 结果 |
|---|---|
| 三组 Python/Bash fixtures、analyze | 通过 |
| 全量离线 Dart | 978 通过 / 13 跳过（无本机 Kotlin 缓存的两个 JVM 用例跳过） |
| 必需生产 Debug 主机 XCTest | 57 通过 / 0 失败 |
| 完整 Mac 平台集成 | 11 通过 / 2 人工用例跳过；随后再次 57 XCTest 通过 |
| 七场景 AOT Profile | 全部通过，真实双栏和跨章节完成数量成立 |
| 最终生产 Release / 签名 / 权限 / 资源 / 快照 / 只读 DMG | 通过 |
| 产物及日志上传 | 通过 |
| 公开预发布任务、真实 API smoke | 按显式参数跳过 |

CI AOT：104k 单段冷分页 338ms，最大 build P95 4.688ms、raster P95
2.876ms、命令到提交帧 P95 28.345ms，进程峰值 228,573,184 bytes；
所有场景仍为 **foreground=false / DPR=1**，不是物理前台性能验收。

dispatch 参数为 `version=3.3.6`、`publish=false`、`full_platform=true`、
`reader_aot=true`、`require_foreground=false`、`live_api=false`。
未合并或推送 main，未创建公开 Release/预发布，未变更旧标签/附件，
未使用真实用户阅读数据、语音密钥或真实 API。

## 已下载且本机独立复验的 DMG

[Actions 产物 14795006960](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/45121742680/artifacts/14795006960)，
名称 `fanqie-macos-arm64-3.3.6-45121742680-1`；包含：

- `fanqie-v3.3.6-342-macos-arm64-internal.dmg`
- 同名 `.dmg.sha256`
- `build-info.json`

DMG 大小 **28,908,527 bytes**；SHA-256：

```text
a16bed22e5c249e6e86d129c509ff8811371287c3cac572cfad71e70847e33cd
```

本机保存于 `dist/macos/verified-45121742680/`（忽略目录，Flutter clean 不删除）。
通过独立 GitHub run 元数据核对 SHA/ref/run/attempt/SDK、包及校验文件摘要/大小；
下载的 native-xctest.log 摘要与 build-info 中证据相符。再次校验镜像、只读挂载、
验证生产 app 签名/权限/资源/arm64/minimum target，并逐项比较 pre-image
bundle snapshot，全部通过，挂载已卸载。验证日志在
`build/macos/local-verification/downloaded-artifact-verification.log`。

**这是来源明确的 ad-hoc 自用 Release，不是 Developer ID 签名/Apple 公证包，
不承诺 Gatekeeper、安装或覆盖升级验收。** 没有启动下载的生产 app、
安装到 Applications 或覆盖用户旧应用。

## 单独待验收

物理鼠标/触控板原生事件顺序、自选目录/TCC/外部卷、中文 IME、物理 Retina、
真实前台显示 FPS/输入延迟、实际声音/媒体键/耳机蓝牙、macOS 12、
安装与覆盖升级、Developer ID/公证/Gatekeeper 不由这些自动化结果代替。
