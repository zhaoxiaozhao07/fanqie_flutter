# GitHub Actions 自用 DMG

用户于 2026-11-07 授权推送代码并进行云端构建；此前“仅本机、不运行 macOS
Actions”的决定由本次授权替代。正式 Developer ID / Apple 公证仍不在范围内。

## 不需要配置新密钥

- 无需 Apple ID、Apple Developer 付费账号、证书或公证密码。
- 当前构建固定 Flutter `3.47.9` / Dart `3.13.7`，版本 `3.3.6+342`，
  最低构建目标 macOS `12.0` / `arm64`，生产入口 `lib/main.dart`，**Release AOT**。
- 打包使用 `scripts/package_macos.sh … internal …`：临时 ad-hoc 签名，
  不是 Debug，也不是 Developer ID 正式签名。当前来源校验打包器仅支持
  `internal`，拒绝 `release`；不提供 Developer ID / 公证回退。
- 只有发布任务声明 `contents: write`，使用 GitHub 自动提供的
  `GITHUB_TOKEN`，不使用仓库里现有的 `TOKEN` 或 Android 签名 secrets。
  构建任务保持只读权限，无需新增 Environment。
- TTS 地址、模型、音色和 API Key 在应用内设置；密钥存入本机 Keychain，
  不配置到构建仓库，也不自动迁移安卓密钥。

## 手动构建

进入 [构建 macOS 自用 DMG](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/workflows/macos-internal.yml)
→ **Run workflow**：

| 参数 | 默认值 / 作用 |
|---|---|
| 分支 | `main` |
| `version` | 留空，使用 `pubspec.yaml`；填写时只做一致性校验，不改版本 |
| `publish` | `true`，创建独立的 macOS 自用预发布版本 |
| `full_platform` | `false`；最终控制端可请求完整平台集成，15 分钟上限 |
| `reader_aot` | `false`；七场景 AOT Profile，12 分钟上限，独立 app/runner 日志 |
| `require_foreground` | `false`；仅影响 AOT；设为 true 时无真实前台即失败 |
| `live_api` | `false`；独立只读真实 API smoke，8 分钟上限，无用户凭据 |

也可以使用已登录的 GitHub CLI：

```bash
gh workflow run macos-internal.yml --ref main -f publish=true
gh run list --workflow macos-internal.yml --limit 5
```

关闭 `publish` 时仅上传 Actions Artifact，保留 30 天；非 `main` 分支只允许
此模式。每次发布创建 `macos-internal-v<version>-<run-id>-<attempt>` 标签，
准确指向本次源码提交，不移动、覆盖或借用旧 Android `v<version>` 标签。
预发布不设为 Latest，不修改现有 Android Release 的说明和附件。
工作流仅手动触发，和 Android 工作流无依赖或共享 concurrency。

最终验证应由控制端在审查最终提交后选择隔离分支、`publish=false`、
`full_platform=true`、`reader_aot=true`；本次 Task 5 不 dispatch 或推送。
人工 `MACOS_SAVE_PANEL_TEST` / `MACOS_NATIVE_FULLSCREEN_TEST` 显式保持 false。
hosted UI / AOT 若失败，会保留诊断并阻止产物上传，不把跳过或失败当成验收。
`require_foreground=false` 的受控 AOT 结果不证明真实前台 FPS。

标准 ARM64 `macos-26` runner 的标签已对照
[官方镜像清单](https://github.com/actions/runner-images#available-images)
核查；不使用付费 larger runner。工作流仍断言实际 `uname -m == arm64`。

## 已发布的自用包（2026-11-07）

- [下载 DMG / SHA-256 / build-info.json](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases/tag/macos-internal-v3.3.4-42376204027-1)
- [成功的 Actions 构建](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/42376204027)
- 源码提交 `1eb74762adabc8375bc5902ea0677f179a768581`，版本 `3.3.4+340`，
  Flutter `3.47.4` / Dart `3.13.3` / Xcode `26.6`。
- 云端静态分析、606 项离线测试（11 项 opt-in 网络跳过）、生产 Release
  编译、签名封装 / 架构 / 镜像校验通过；下载后再验证摘要、镜像及
  3 个 Mach-O / 生产入口 / 权限通过。未运行云端声音听辨或人工安装验收。
- DMG 大小 `28,816,117` bytes，SHA-256：
  `82980d468f876e227fe28711787cf2c725af4106d5c471fba991477e270e2331`。

## 验证与产物

必须通过 portable 原生流水线、Bash 3.2 生命周期、打包/来源回归、静态分析、
默认离线单元 / 组件测试、Task 1 原生 XCTest 及生产 Release 编译；失败不发布。
不会在 CI 配置用户密钥；真实 API 仅由独立 opt-in 请求，TTS 不在此门禁内。

打包器检查生产入口、Bundle ID、全部 Mach-O 的 arm64 / 最低系统目标、
内部签名封装及严格的生产沙盒 / 网络客户端 / 用户文件与书签权限（拒绝
Debug JIT / 网络服务器等额外权限）。核对完整 plist 版本与 build、
versioned App.framework 中的资源、字体映射、AssetManifest.bin、
NativeAssetsManifest.json 和 FlutterMacOS 的 ICU。原生清单允许真实空 mapping；
非空 mapping 仅接受 Mac framework、system、executable、process 加载规则。
`charset.json` 的非空根为 list，其余三个数据 JSON 为非空 dict。
签名后保存全包文件大小/摘要/权限与内部链接快照；私有 DMG 不使用 `-ov`，
只读挂载重新跑原生和资源门禁，并与成像前快照精确比较，才允许发布本地输出。
这些检查不等于真实安装、声音听辨、Retina、Gatekeeper 或 macOS 12 实机验收。

附件：

- `fanqie-v3.3.6-342-macos-arm64-internal.dmg`
- 同名 `.dmg.sha256`
- `build-info.json`：完整版本/build、源码 SHA/ref、run ID/attempt/URL、
  bootstrap 后 SDK machine JSON、Xcode、Task 1 日志摘要/大小、全包快照和摘要、
  架构/最低目标/生产入口/Release/ad-hoc/未公证状态及 DMG/校验文件摘要/大小。

本地打包要求 `MACOS_RELEASE_CONTEXT` 指向来源上下文；CI 用
`macos_release_validation.py context --sdk … --native-log … --output …` 从实际
`GITHUB_*` 身份、SDK 与原生日志生成，`MACOS_XCODE_VERSION` 记录实际 Xcode。
缺上下文即失败，不猜测来源。输出已有任何同名附件即失败，旧包不覆盖；
重跑应使用新的隔离输出目录。

Linux 发布端先独立校验下载附件的精确文件集合、摘要、大小和 trigger 身份，
再拒绝已存在的独立 tag；仍 `--prerelease --latest=false`、仅 main 可公开发布。
上传后重新读取远端 tag SHA、附件大小/digest，并下载全部附件核对实际 bytes。
校验失败不会宣称发布成功，也不删除/改写远端已有资源。

验证日志另存 Actions Artifact，保留 14 天。仓库公开，因此 GitHub Release
附件也公开；只上传构建产物，不包含本机的阅读数据、字体导入、Keychain
或其他个人配置。

## 首次安装

1. 从本次 macOS 预发布下载 DMG 和同名 `.sha256` 到同一个目录，核对：

   ```bash
   shasum -a 256 -c fanqie-v3.3.6-342-macos-arm64-internal.dmg.sha256
   ```

2. 退出旧应用实例，打开 DMG，将 `番茄Reader.app` 拖到 Applications；
   不删除原阅读数据。
3. 未公证应用可能被 Gatekeeper 阻止。确认来源与摘要后，在系统设置
   **隐私与安全性 → 仍要打开**，只允许本应用。

若系统将可信的自用 ad-hoc 包提示为“已损坏”，先确认摘要正确；仅对此
应用移除下载隔离属性后重试：

```bash
xattr -dr com.apple.quarantine "/Applications/番茄Reader.app"
```

不关闭全局 Gatekeeper，不对其他目录递归修改权限或隔离属性。
