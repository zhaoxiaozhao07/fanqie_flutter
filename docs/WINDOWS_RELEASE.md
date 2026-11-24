# Windows 正式便携版

Windows 发布独立于 Android / macOS。只使用手动工作流 `Windows 正式便携版`，
不创建 `v*` 标签，不修改任何历史 APK、标签、发布正文或 Android Latest 指向。

## 发布约定

- Windows Server 2022 x64 hosted runner (`windows-2022`)、PowerShell 7 (`pwsh`)。
- 固定 Flutter **3.47.9 stable** / Dart **3.13.7**。
- `pubspec.yaml` 是唯一版本来源；输入 `version` 只校验、不覆盖版本。
- 例如 `3.3.6+342`：
  - 标签：`windows-v3.3.6-342`
  - ZIP：`FanqieReader-3.3.6-342-windows-x64.zip`
  - 同名 `.zip.sha256`
  - `windows-build-info.json`
- 正式、非 prerelease，但 `make_latest=false`，保持 Android 下载链接含义。
- 官方项目分发的 **unsigned portable ZIP**：不是 Authenticode 签名、Store 认证、
  MSI/MSIX 安装包，也没有自动更新承诺。无需增加秘密或使用 Android 签名秘密。

## 维护者流程

1. 保留当前阅读/Windows 修改，合并当前 main，完成字体一致性与回归验证。
2. 主维护代理明确升级版本（本轮批准目标 `3.3.6+342`），更新应用发布说明，
   合并/推送到 main。工作流必须先存在于默认分支。
3. 手动在 main 运行工作流，`publish=true`；非 main 只能 `publish=false` 做验证。
4. build job 仅 `contents:read`，checkout 精确 triggering SHA，禁用持久化 Git 凭据。
   `pub get --enforce-lockfile`，全量离线 `analyze --no-pub` / `test --no-pub`，
   然后脚本仅构建一次 `lib/main.dart` 的 x64 Release (`--no-pub`、明确版本/构建号)。
5. 打包及独立解压检查完成后，仅上传 ZIP、checksum、provenance。
   分离日志 artifact 保留 14 天，分发 artifact 保留 30 天。
6. publish job 仅 main 有 `contents:write`，使用自动 `github.token`。
   校验精确 run/source/SDK/target/runtime、ZIP 内每个文件及附件摘要。
   任何既有同名 tag/release 都拒绝；API 只有明确 release 404 才视为不存在，
   其他错误、非完整上传、digest 缺失、SHA 不一致均失败关闭。
7. 显式创建新 lightweight tag 指向 triggering SHA，再创建新 draft，
   上传三个附件、检查完整 assets/size/digest 和精确 tagSHA，最后才公开；
   draft 和公开阶段均使用 `make_latest=false`。不 force、不 clobber、不复用。
8. 主维护代理等待两个 job 完成，重新下载正式附件，独立核验 checksum/provenance/tagSHA。
   Windows 10/11 干净用户、DPI、阅读/导出/音频与 SmartScreen 实机验收另行记录。

**失败恢复**：失败可留下新 tag、draft、已上传部分附件或本地 stage/ZIP。
不要自动删除、强制移动 tag 或重跑覆盖。检查日志和遗留状态，由维护者显式决定
如何处理；已公开版本采用新 version/build 发布修复版。`publish=false` 可重复新 runner 构建，
不产生远程 mutation。

## 本地打包与检查

在仓库根目录，先使用固定 SDK 完成 `flutter pub get --enforce-lockfile` 和回归检查，
再运行：

```powershell
pwsh -NoProfile -File scripts/package_windows.ps1 -OutputDir dist/windows-local
```

`OutputDir` 只允许仓库 `dist` 或其子目录（默认 `dist`），不能是仓库根、
源码目录、外部绝对路径、UNC、通配符、ADS、junction/symlink/reparse 根。
脚本在任何构建副作用之前解析 output/stage/archive/extract/build 路径；
现有 stage、ZIP、sidecar、provenance、extract 均拒绝覆盖。没有递归删除。
下一次打包选择一个全新的 `dist` 子目录。

必须找到 VS2022 的 `x64/Microsoft.VC143.CRT`，且包含 x64
`msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`。
可以通过 `-RuntimeDir` 显式选择同形状的 runtime 目录；不会回退为依赖用户另装 VC++。
完整 Release 输出被复制，友好 EXE 名仍是 `FanqieReader.exe`，
安装说明仍是 `README-安装说明.txt`（显式 **UTF-8 BOM**）。

脚本同时检查 EXE product/string/numeric version、所有 EXE/DLL 的 x64 PE、
Flutter Windows AOT snapshot 的 x64 ELF64（`app.so` 不是 PE DLL）、
Flutter data、native assets、Windows permission plugin、两组阅读字体/映射/OFL 许可证，
并将字体/许可证 bytes 与源码比对。生产清单使用 Flutter 生成的
`data/flutter_assets/NativeAssetsManifest.json`；测试可能遗留的根目录
`native_assets.json` 不参与校验，也不打入正式包。native manifest 当前只支持 1.0.0 格式、
Windows bundled DLL 的 `["absolute","basename.dll"]` 加载描述（模式名并不表示主机绝对路径）。
不接受主机路径、目录穿越或相对 AOT snapshot 的 `relative` 描述；未来原生依赖改变格式必须先更新验证。
ZIP 根直接包含 EXE/DLL/data（不新增顶层文件夹）；sidecar 是真实 ZIP 的 SHA-256。
再次解压至新 `.verify` 目录，逐文件比对 stage 与 ZIP 摘要。

独立重新核验到全新目录：

```powershell
pwsh -NoProfile -File scripts/verify_windows_package.ps1 `
  -ZipPath dist/windows-local/FanqieReader-3.3.6-342-windows-x64.zip `
  -ExtractDir dist/windows-independent-check -Version 3.3.6+342
```

provenance 包含 source commit/ref、run URL/id/attempt、SDK、runner、VC143 DLL 摘要、
锁文件、unsigned/x64/Release/production target、ZIP/checksum 摘要和 ZIP 内逐文件摘要。
本地 dirty checkout 的 commit 不等于未提交工作内容，因此本地包不是正式源代码来源证明；
正式发布以工作流 checkout 的精确 SHA 为准。

## 脚本行为测试

```powershell
pwsh -NoProfile -File scripts/test_windows_package.ps1 -Suite All
pwsh -NoProfile -File scripts/test_windows_package.ps1 -Suite Publish
pwsh -NoProfile -File scripts/test_windows_package.ps1 -Suite Review
pwsh -NoProfile -File scripts/test_windows_package.ps1 -Suite Bootstrap
```

无需调用真实 Flutter，但需要仓库已经存在一个 Windows Release EXE 用于真实
Windows version-resource 检查。仅 Flutter 边界由测试桩替换，copy、ZIP、hash、
路径/reparse guards、PE/resource/font/license 验证均真实执行。
fixture 根显式创建于 `.dart_tool/codex-windows-reading/package-tests-<guid>`，
清理先验证绝对路径边界并先移除 junction 本身，不删除其他目录。
`Publish` 执行工作流的实际发布 run block，但 HTTP 边界由本地 GitHub resource-store
测试桩接管，验证 draft/public 状态转换、既有 tag/release、API 故障、附件 digest/state、
source/tagSHA 故障；绝不发出远程请求。测试专用 `-OmitDraftValidation` mutation
应当失败，用于证明测试会抓到“先公开再校验”的回归，不能用于正常验证。
fixture utility 将复制的脚本中的 mutex 名改为 fixture 私有名称，保留真实 acquire/release，
避免纯测试桩等待维护者的 Flutter 检查；仓库生产脚本及真实 Flutter 仍使用下面的共享名称。

`Bootstrap` 执行真实工作流的 SDK 初始化及 JSON 读取部分，以冷/热 SDK 和原生命令失败
作为边界夹具。首次普通 `--version` 单独保留工具初始化日志，随后才读取严格机器 JSON，
不从混合日志猜测 JSON；任何命令非零退出仍使构建失败。

`Review` 对 reserved device components（含扩展名）做参数化拒绝检查，
并用不同线程的 C# Task 在真实 Release copy/hash 边界竞争 mutex；
在 fixture 中仅包装实际 .NET extraction 调用，确定性尝试替换/写入已校验 ZIP，
仍执行真实解压，不靠 sleep/时序猜测，也不添加生产测试 hook。

共享 Flutter mutex 一直持有到 Release 完整复制至私有 stage 并完成 stage 校验/逐文件摘要，
所有成功/异常路径由外层 finally 释放；之后 ZIP/provenance/publication 不占用该锁。
ZIP helper 使用同一个 `FileStream`（`FileAccess.Read` / `FileShare.Read`，禁止 write/delete sharing）
完成 SHA-256、entry 校验和同一个 `ZipArchive` 的解压，最后 finally 关闭两者；
不再关闭已检查的 ZIP 后按路径重开。

任何真实 Flutter 命令都必须持有 named mutex
`Local\FanqieCodexReaderFlutterChecks`；`AbandonedMutexException` 表示已取得所有权。
工作流和打包脚本均遵循该约定，避免共享 Windows checkout 同时运行 Flutter。

## 已发布：3.3.6+342（2026-11-22）

- 正式发行：[windows-v3.3.6-342](https://github.com/zhaoxiaozhao07/fanqie_flutter/releases/tag/windows-v3.3.6-342)，非草稿、非 prerelease、未签名 x64 便携版。
- 成功的 build/publish：[Actions 44934821500](https://github.com/zhaoxiaozhao07/fanqie_flutter/actions/runs/44934821500)。
- 发行源码与标签：`08fa58a0ba3a74cb5079f045c3ab2f289ad3dbee`。后续文档提交不改变此发行标签。
- ZIP：`FanqieReader-3.3.6-342-windows-x64.zip`，`28,270,825` bytes。
- SHA-256：`ac8cce77a79107a4834076d55ee15f7bb4d62d5cc61f5f1e0a3b621d3a35d165`。
- 重新下载三个正式附件后，独立验证服务器附件摘要、ZIP sidecar、构建来源/目标/SDK、源码标签和 33 个包内文件的摘要；解压后 x64 EXE/DLL/ELF、版本资源、VC143、字体/OFL 与正式 native manifest 检查通过，没有旧测试清单。
- 本地源码回归 781 通过/11 跳过；云端 779 通过/13 环境相关跳过；脚本回归 65 项通过。原生 Windows 9 项及真实字体 1 项通过，交互式另存为 1 项未执行；更多实机/DPI/前台验收边界仍见 `docs/archive/verifications/WINDOWS_CLIENT_VERIFICATION.md`。
- Android Latest 的发行 ID、标签及原附件摘要/大小保持不变，仍为 `v3.3.5`；没有覆盖原 APK 或 macOS 自用版本。

前两次云构建先后暴露冷 SDK 初始化输出混入 JSON、误用旧测试清单位置的问题，
均在公开发行前修复并补回归；它们没有创建 Windows 发行标签或发布半包。
