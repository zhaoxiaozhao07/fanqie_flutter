# FanqieReader Windows release packaging.
#
# Builds the release binary, stages a portable directory (exe + DLLs + data +
# app-local VC runtime), compresses it into a ZIP and emits a SHA-256 file.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1
param(
  [string]$OutputDir = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# --- version from pubspec.yaml ------------------------------------------------
$pubspec = Get-Content "pubspec.yaml" -Raw
if ($pubspec -notmatch "(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)") {
  throw "pubspec.yaml version not found"
}
$version = $Matches[1]
$build = $Matches[2]

# --- release build ------------------------------------------------------------
Write-Host "==> flutter build windows --release" -ForegroundColor Cyan
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$releaseDir = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $releaseDir "fanqie_flutter.exe"))) {
  throw "release output missing"
}

# --- stage portable layout ----------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd"
$packageName = "FanqieReader-$version-$build-windows-x64"
$stageDir = Join-Path $root "$OutputDir\$packageName"
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir | Out-Null

Copy-Item (Join-Path $releaseDir "*") -Destination $stageDir -Recurse
# Friendly executable name; the version resource keeps the product identity.
Rename-Item (Join-Path $stageDir "fanqie_flutter.exe") "FanqieReader.exe"

# --- app-local VC runtime (optional but keeps the ZIP self-contained) --------
$vcRedistRoots = @(
  "${env:ProgramFiles}\Microsoft Visual Studio\2022\*\VC\Redist\MSVC",
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\VC\Redist\MSVC",
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\*\VC\Redist\MSVC"
)
$crt = $vcRedistRoots |
  Where-Object { Test-Path $_ } |
  ForEach-Object { Get-Item $_ } |
  Sort-Object FullName -Descending |
  ForEach-Object {
    Get-ChildItem -Recurse -Filter "Microsoft.VC143.CRT" -Directory $_.FullName |
      Where-Object { $_.FullName -match "\\x64\\Microsoft\.VC143\.CRT$" } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
  } |
  Select-Object -First 1
if ($crt) {
  Copy-Item (Join-Path $crt.FullName "*.dll") -Destination $stageDir
  Write-Host "==> bundled app-local VC runtime from $($crt.FullName)"
} else {
  Write-Warning "VC redist not found; the package requires the Microsoft VC++ 2015-2022 x64 runtime"
}

# --- usage note ---------------------------------------------------------------
@"
番茄Reader $version (build $build) — Windows 桌面版

快速开始
1. 解压到任意可写目录（无需安装）。
2. 运行 FanqieReader.exe。

数据位置
阅读数据保存在 %APPDATA%\com.fanqie\FanqieReader；卸载只需删除解压目录与该数据目录。

系统要求
Windows 10 1809 及以上 64 位系统。若提示缺少 VCRUNTIME140.dll，
安装 Microsoft Visual C++ 2015-2022 运行库（x64）后重试。

首次运行提示
本包未做代码签名，首次运行可能触发 Windows SmartScreen 提示；
选择“更多信息 → 仍要运行”即可，无需关闭系统防护。

包校验
同目录 .sha256 文件是 ZIP 的 SHA-256 校验值：
certutil -hashfile $packageName.zip SHA256
"@ | Out-File (Join-Path $stageDir "README-安装说明.txt") -Encoding utf8

# --- compress + checksum ------------------------------------------------------
$zipPath = Join-Path $root "$OutputDir\$packageName.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
"$hash  $packageName.zip" | Out-File "$zipPath.sha256" -Encoding ascii

Write-Host ""
Write-Host "==> packaged: $zipPath" -ForegroundColor Green
Write-Host "    SHA-256 : $hash" -ForegroundColor Green
Write-Host "    size    : $('{0:N1} MB' -f ((Get-Item $zipPath).Length / 1MB))"
