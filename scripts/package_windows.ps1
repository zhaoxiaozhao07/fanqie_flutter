# FanqieReader unsigned Windows x64 portable Release. Requires PowerShell 7.
param([string]$OutputDir = 'dist', [string]$RuntimeDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use pwsh (PowerShell 7), not Windows PowerShell 5.1' }
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'verify_windows_package.ps1')

# Resolve every output/stage/archive/build path before any build or mutation.
$root = Resolve-WindowsReleasePath $root $root
$dist = Resolve-WindowsReleasePath 'dist' $root
$output = Resolve-WindowsReleasePath $OutputDir $root
Assert-WindowsWithin $output $dist -AllowParent
$pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'pubspec.yaml version not found' }
$version = $Matches[1]; $build = $Matches[2]; $fullVersion = "$version+$build"
$packageName = "FanqieReader-$version-$build-windows-x64"
$stage = Resolve-WindowsReleasePath (Join-Path $output $packageName) $root
$zipPath = Resolve-WindowsReleasePath (Join-Path $output "$packageName.zip") $root
$checksumPath = Resolve-WindowsReleasePath "$zipPath.sha256" $root
$infoPath = Resolve-WindowsReleasePath (Join-Path $output 'windows-build-info.json') $root
$extract = Resolve-WindowsReleasePath (Join-Path $output "$packageName.verify") $root
$release = Resolve-WindowsReleasePath 'build/windows/x64/runner/Release' $root
foreach ($path in @($stage, $zipPath, $checksumPath, $infoPath, $extract)) {
  Assert-WindowsWithin $path $output
  if (Test-Path -LiteralPath $path) { throw "No overwrite: path already exists (collision): $path" }
}
if (Test-Path -LiteralPath $release) { $null = @(Get-WindowsSafeFiles $release) }

# VC143 is mandatory; select a VS2022 x64 CRT directory or an explicit one.
if (-not $RuntimeDir) {
  $candidates = @()
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($base) {
      $candidates += @(Get-Item -Path "$base/Microsoft Visual Studio/2022/*/VC/Redist/MSVC/*/x64/Microsoft.VC143.CRT" -ErrorAction SilentlyContinue)
    }
  }
  $selected = $candidates | Sort-Object FullName -Descending | Select-Object -First 1
  if ($selected) { $RuntimeDir = $selected.FullName }
}
if (-not $RuntimeDir) { throw 'Required app-local VC143 x64 runtime not found' }
$runtime = Resolve-WindowsReleasePath $RuntimeDir $root
if ($runtime -notmatch '[\\/]x64[\\/]Microsoft\.VC143\.CRT$') { throw 'Runtime must be x64/Microsoft.VC143.CRT' }
$runtimeFiles = @(Get-WindowsSafeFiles $runtime | Where-Object Extension -EQ '.dll')
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
  if (-not ($runtimeFiles | Where-Object Name -EQ $required)) { throw "Required runtime DLL missing: $required" }
}
foreach ($file in $runtimeFiles) { Assert-WindowsX64Pe $file.FullName }
$lockPath = Resolve-WindowsReleasePath 'pubspec.lock' $root
$lockHash = (Get-FileHash -LiteralPath $lockPath).Hash
$oldLocation = Get-Location
$mutex = [Threading.Mutex]::new($false, 'Local\FanqieCodexReaderFlutterChecks')
$ownsMutex = $false
try {
  try { $ownsMutex = $mutex.WaitOne([TimeSpan]::FromMinutes(30)) }
  catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
  if (-not $ownsMutex) { throw 'Timed out waiting for Flutter checks mutex' }
  Set-Location $root
  $sdkText = flutter --version --machine
  $nativeExit = $LASTEXITCODE
  if ($nativeExit -ne 0) { throw "flutter --version failed (exit $nativeExit)" }
  $sdk = ($sdkText -join "`n") | ConvertFrom-Json
  if ($sdk.frameworkVersion -ne '3.47.9' -or $sdk.channel -ne 'stable' -or $sdk.dartSdkVersion -ne '3.13.7') {
    throw 'Required SDK: Flutter 3.47.9 stable / Dart 3.13.7'
  }
  Write-Host '==> production Windows Release build (once)'
  flutter build windows --release --no-pub --target lib/main.dart "--build-name=$version" "--build-number=$build"
  $nativeExit = $LASTEXITCODE
  if ($nativeExit -ne 0) { throw "flutter build failed (exit $nativeExit)" }
  if ((Get-FileHash -LiteralPath $lockPath).Hash -ne $lockHash) { throw 'Dependency lock changed during build' }
# Keep shared Release protected until the private snapshot is validated/hashed.
# Revalidate after build and reserve a fresh stage; never recursively delete.
$null = @(Get-WindowsSafeFiles $release)
if (-not (Test-Path -LiteralPath (Join-Path $release 'fanqie_flutter.exe') -PathType Leaf)) { throw 'Release output missing' }
foreach ($path in @($stage, $zipPath, $checksumPath, $infoPath, $extract)) {
  Assert-WindowsNoReparse $path
  if (Test-Path -LiteralPath $path) { throw "No overwrite: path already exists: $path" }
}
New-Item -ItemType Directory -Path $stage | Out-Null
Get-ChildItem -LiteralPath $release -Force | Copy-Item -Destination $stage -Recurse
Rename-Item -LiteralPath (Join-Path $stage 'fanqie_flutter.exe') -NewName 'FanqieReader.exe'
foreach ($dll in $runtimeFiles) { Copy-Item -LiteralPath $dll.FullName -Destination $stage }
# Keep the Chinese filename and explicit UTF-8 BOM on PowerShell 7.
$readme = @"
番茄Reader $version (build $build) — Windows 桌面版

快速开始
1. 解压到任意可写目录（无需安装）。
2. 运行 FanqieReader.exe。

数据位置
阅读数据保存在 %APPDATA%\com.fanqie\FanqieReader；卸载只需删除解压目录与该数据目录。
升级前退出旧实例，解压新版到新目录；不要删除阅读数据目录。

系统要求
Windows 10 1809 及以上 64 位系统。本包已包含 app-local VC143 x64 运行库。
如提示缺少 DLL，请检查解压完整性和 SHA-256；不要从不可信站点下载单个 DLL。

首次运行提示
本包未做代码签名，首次运行可能触发 Windows SmartScreen 提示；
仅在核验下载来源与 SHA-256 后选择“更多信息 → 仍要运行”，无需关闭系统防护。

包校验
下载 ZIP 同目录的 .sha256 文件是 ZIP 的 SHA-256 校验值：
certutil -hashfile $packageName.zip SHA256
"@
[IO.File]::WriteAllText((Join-Path $stage 'README-安装说明.txt'), $readme, [Text.UTF8Encoding]::new($true))
Test-WindowsPackageLayout $stage $fullVersion $root
$fileDigests = Get-WindowsFileDigests $stage
} finally {
  try { Set-Location $oldLocation } finally {
    try { if ($ownsMutex) { $mutex.ReleaseMutex() } } finally { $mutex.Dispose() }
  }
}
# ZIP/provenance now read only the private snapshot; no shared Flutter lock needed.
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, 'Optimal', $false)
$hash = (Get-FileHash -LiteralPath $zipPath).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksumPath, "$hash  $packageName.zip`n", [Text.ASCIIEncoding]::new())
$extracted = Expand-WindowsReleaseZip $zipPath $extract $root
Test-WindowsPackageLayout $extracted $fullVersion $root
$extractedDigests = Get-WindowsFileDigests $extracted
if ($fileDigests.Count -ne $extractedDigests.Count) { throw 'Extracted ZIP file count differs from stage' }
foreach ($name in $fileDigests.Keys) {
  if ($fileDigests[$name] -ne $extractedDigests[$name]) { throw "Extracted ZIP digest mismatch: $name" }
}
$sourceSha = $env:GITHUB_SHA; $sourceRef = $env:GITHUB_REF
if (-not $sourceSha) {
  $sourceSha = git -C $root rev-parse HEAD
  $nativeExit = $LASTEXITCODE
  if ($nativeExit -ne 0) { throw "git source SHA failed (exit $nativeExit)" }
  $sourceRef = git -C $root symbolic-ref -q HEAD
  $nativeExit = $LASTEXITCODE
  if ($nativeExit -eq 1) { $sourceRef = 'detached' }
  elseif ($nativeExit -ne 0) { throw "git source ref failed (exit $nativeExit)" }
}
if ($sourceSha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid source SHA' }
$assets = [ordered]@{}
foreach ($path in @($zipPath, $checksumPath)) {
  $assets[[IO.Path]::GetFileName($path)] = @{
    sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    size = (Get-Item -LiteralPath $path).Length
  }
}
$runtimeDigests = [ordered]@{}
foreach ($file in $runtimeFiles) { $runtimeDigests[$file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() }
$info = [ordered]@{
  schema_version = 1; version = $fullVersion; release_tag = "windows-v$version-$build"
  source_commit = $sourceSha; source_ref = $sourceRef
  workflow_run = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { $null }
  run_id = $env:GITHUB_RUN_ID; run_attempt = $env:GITHUB_RUN_ATTEMPT
  built_at_utc = [DateTime]::UtcNow.ToString('o')
  architecture = 'x64'; build_mode = 'Release'; build_target = 'lib/main.dart'
  signing = 'unsigned'; authenticode_signed = $false; minimum_windows = '10 1809'
  flutter = $sdk; runner_image = $env:ImageOS; runner_image_version = $env:ImageVersion
  runtime = @{ family = 'VC143'; directory = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $runtime)); dll_sha256 = $runtimeDigests }
  lock_sha256 = $lockHash.ToLowerInvariant(); assets = $assets; package_files_sha256 = $fileDigests
}
[IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "==> packaged and independently extracted: $zipPath`n    SHA-256: $hash"
