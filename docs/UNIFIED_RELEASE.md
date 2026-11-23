# Android / Windows / macOS 统一 Release

## 唯一的标准发布入口

`.github/workflows/release.yml` 负责标准 `v<version>` Release，版本/build
只从提交的 `pubspec.yaml` 读取。当前版本为 **3.3.7+343**，三平台固定使用
**Flutter 3.47.9 / Dart 3.13.7**、锁定业务依赖和 `lib/main.dart` 生产入口。

- push main：只做共享质量检查，不创建 Release，不重复构建三套生产包。
- push `v<pubspec version>` 标签：三端构建并统一发布。标签必须指向 main
  可达的同一源码提交；支持普通/annotated 标签，拒绝版本不匹配。
- 手动 workflow_dispatch：`version` 留空使用 pubspec，`publish=true` 只允许
  main；全部通过后创建同版本新标签与一个完整公开 Release。
- 开发分支验证：明确使用 `publish=false`，仍执行真实三平台生产构建、
  汇总和来源校验，仅上传 Actions artifacts，不创建公开 Release。

示例：

```bash
# 先在开发分支验证
gh workflow run release.yml --ref codex/reader-footer-unified-release \
  -f version=3.3.7 -f publish=false

# 合并到 main 后，只有明确要公开发布时才执行
gh workflow run release.yml --ref main -f version=3.3.7 -f publish=true
```

独立 Windows/macOS workflows 继续提供历史 namespace 的手工兼容入口；
标准 `v*` 发布只由统一 workflow 负责。统一入口只调用
`windows-build.yml` / `macos-build.yml` 的只读构建工作流，不调用含写权限
publish job 的控制器；即使 skipped publish job 也不能突破 caller 权限上限。
只读 builder 与独立控制器使用不同 concurrency group，防止父/子互相等待。

## 门禁与“同时公开”

1. 冻结实际 triggering SHA、ref、完整 version/build 和 run/attempt；
   对外发布时校验 main 可达性，不从其他分支静默发布。
2. 共享静态分析、完整离线 Flutter 回归、发布行为/真实文件系统/源范围测试。
3. 并行构建：
   - Android：Java 21、真实 Release APK、原始发布证书匹配、aapt
     applicationId/versionCode/versionName、真实三 ABI AOT 内容及 Kotlin 导出回归。
   - Windows：复用实际 Windows 生产构建、PE/DLL/字体/运行库/ZIP/SHA/原始
     文件快照及五组包装/发布阴性测试。
   - macOS：复用必需生产 Debug XCTest、完整 Mac 平台集成、七场景 AOT、
     最终 Release、ad-hoc 签名、权限、资源、完整目录快照与只读 DMG 挂载复验。
4. 全部成功后再下载三端产物，独立核对每一平台的源码/ref/run/attempt/SDK、
   version/build、外层摘要、完整 ZIP/APK 路径/内容，生成统一 manifest。
5. 唯一 publish job 再次核对汇总产物，创建新 draft、上传全部 10 个附件，
   校验远端每个附件名称/大小/SHA-256 及标签真实 commit，最后一次性公开。

“同时”指完整 draft 从私有状态一次性变为公开，不是三个编译器同一时刻完成。
任一构建/校验失败都阻止后续公开；不会沿用另外一次运行的旧客户端补齐。
已存在的 Release/draft 不覆盖、不删除、不重用。失败发布的草稿/新标签保留
供人工检查；确认清理自己这次未公开的残留后才重试，不能强制移动历史标签。

## 发布附件

每个标准 Release 共 10 个附件：

| 客户端 | 包 | 校验/来源 |
|---|---|---|
| Android 通用 APK | `fanqie-v<version>.apk` | 同名 `.sha256`、`android-build-info.json` |
| Windows x64 便携 | `FanqieReader-<version>-<build>-windows-x64.zip` | 同名 `.sha256`、`windows-build-info.json` |
| macOS arm64 自用 | `fanqie-v<version>-<build>-macos-arm64-internal.dmg` | 同名 `.sha256`、`macos-build-info.json` |
| 三端共同来源 | `release-manifest.json` | 绑定 9 个平台附件的大小/摘要及三种签名事实 |

Mac 原始 Actions artifacts 内继续使用 `build-info.json`；
统一公开附件重命名为 `macos-build-info.json`，校验逻辑及原始内容不变。

## 签名、升级与安全边界

- Android 只使用已有 `KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_PASSWORD`、
  `KEY_ALIAS`；不创建新密钥、不读取到开发机、不上传 keystore/密码。正式构建
  缺少配置失败关闭；输出证书必须与该 keystore 的公钥证书 SHA-256 一致，
  不允许 debug 签名伪装成正式包。私钥文件由 always 步骤清理。
- Windows 是项目分发的**未 Authenticode 签名**便携版，不是 Store/MSI/MSIX。
- Mac 仍为 **ad-hoc、未公证**的自用 Release，不冒用正式 Apple 分发签名。
  需要 Developer ID/公证的人工路径仍独立且必须提供所有者的证书/公证配置，
  统一 workflow 不会自动 fallback 成“已公证”。
- 沿用阅读数据目录；这里不宣称物理 DPI/Retina、鼠标/触控板/IME、声音/媒体键、
  最低系统版本、Gatekeeper/SmartScreen、覆盖升级等人工验收已完成。
- 旧 Android `v*`、独立 Windows/macOS 标签、附件及发布正文不修改。

## 本地检查

```bash
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
python3 scripts/test_unified_release.py
python3 -m pip install PyYAML==6.0.2  # 仅验证工具依赖，不是客户端依赖
python3 scripts/test_unified_workflow.py
python3 scripts/test_macos_package.py
```

发布验证工具要求 Python 3.11+（CI 固定 3.12）。发布 API 只允许 GitHub 官方
API/upload 域，不将 token 跟随重定向发送到其他位置。
