# GitHub Actions 自用 DMG

用户于 2026-11-07 授权推送代码并进行云端构建；此前“仅本机、不运行 macOS
Actions”的决定由本次授权替代。正式 Developer ID / Apple 公证仍不在范围内。

## 不需要配置新密钥

- 无需 Apple ID、Apple Developer 付费账号、证书或公证密码。
- 构建使用现有 Flutter `3.47.4`，生产入口 `lib/main.dart`，**Release AOT**。
- 打包使用 `scripts/package_macos.sh … internal …`：临时 ad-hoc 签名，
  不是 Debug，也不是 Developer ID 正式签名。脚本的 `release` 模式指正式签名
  / 公证流程，自用工作流不调用该模式。
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

必须通过静态分析、默认离线单元 / 组件测试及生产 Release 编译；失败不发布。
不会在 CI 配置用户密钥或运行默认跳过的真实小说 / TTS 网络测试。

打包器检查生产入口、Bundle ID、全部 Mach-O 的 arm64 / 最低系统目标、
内部签名封装及沙盒 / 网络 / 用户选择文件权限；检查 DMG 完整性和 SHA-256。
这些检查不等于真实安装、声音听辨、Retina、Gatekeeper 或 macOS 12 实机验收。

附件：

- `fanqie-v<version>-macos-arm64-internal.dmg`
- 同名 `.dmg.sha256`
- `build-info.json`：源码提交、构建链接、SDK、架构、Release 模式、
  ad-hoc 签名 / 未公证状态及 DMG 摘要。

验证日志另存 Actions Artifact，保留 14 天。仓库公开，因此 GitHub Release
附件也公开；只上传构建产物，不包含本机的阅读数据、字体导入、Keychain
或其他个人配置。

## 首次安装

1. 从本次 macOS 预发布下载 DMG 和同名 `.sha256` 到同一个目录，核对：

   ```bash
   shasum -a 256 -c fanqie-v3.3.4-macos-arm64-internal.dmg.sha256
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
