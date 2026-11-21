# Independent layout/PE/font/ZIP verification. Dot-source for packaging helpers.
param([string]$PackageDir, [string]$ZipPath, [string]$Version, [string]$ExtractDir)
$ErrorActionPreference = 'Stop'

function Resolve-WindowsReleasePath([string]$Path, [string]$Root) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[*?\[\]]|^\\\\|^[^:]+::' -or
      $Path -match ':(?![\\/])') { throw "Unsafe path: $Path" }
  foreach ($part in ($Path -split '[\\/]')) {
    if ($part -notin @('', '.', '..') -and $part -match '[. ]$') { throw "Unsafe path component: $part" }
    if ($part -match '^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(\.|$)') {
      throw "Unsafe reserved Windows device component: $part"
    }
  }
  $full = [IO.Path]::GetFullPath($Path, $Root)
  Assert-WindowsNoReparse $full
  return $full
}
function Assert-WindowsWithin([string]$Path, [string]$Parent, [switch]$AllowParent) {
  $prefix = $Parent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (($AllowParent -and $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) -or
      $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return }
  throw "Unsafe output/path must stay within $Parent : $Path"
}
function Assert-WindowsNoReparse([string]$Path) {
  $current = $Path
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe reparse/junction path: $current" }
    }
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
  }
}
function Get-WindowsSafeFiles([string]$Directory) {
  Assert-WindowsNoReparse $Directory
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "Required directory missing: $Directory" }
  $queue = [Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($Directory)
  while ($queue.Count) {
    foreach ($item in (Get-ChildItem -LiteralPath $queue.Dequeue() -Force)) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unsafe reparse package entry: $($item.FullName)" }
      if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) } else { $item }
    }
  }
}
function Assert-WindowsX64Pe([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid PE file: $Path" }
    $stream.Position = 60
    $offset = $reader.ReadInt32()
    if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE offset: $Path" }
    $stream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
      throw "Required x64 PE (8664) missing: $Path"
    }
  } finally { $reader.Dispose() }
}
function Get-WindowsFileDigests([string]$Directory) {
  $result = [ordered]@{}
  foreach ($file in (Get-WindowsSafeFiles $Directory | Sort-Object FullName)) {
    $relative = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/')
    $result[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $result
}
function Assert-WindowsX64Aot([string]$Path) {
  # Flutter loads an ELF AOT snapshot on Windows; it is not a PE DLL.
  $stream = [IO.File]::OpenRead($Path)
  try {
    $header = [byte[]]::new(20)
    if ($stream.Read($header, 0, 20) -ne 20 -or
        [BitConverter]::ToUInt32($header, 0) -ne 0x464c457f -or
        $header[4] -ne 2 -or $header[5] -ne 1 -or
        [BitConverter]::ToUInt16($header, 18) -ne 62) { throw "Required x64 ELF64 AOT snapshot: $Path" }
  } finally { $stream.Dispose() }
}
function Test-WindowsPackageLayout([string]$Directory, [string]$FullVersion, [string]$SourceRoot) {
  if ($FullVersion -notmatch '^(\d+)\.(\d+)\.(\d+)\+(\d+)$') { throw 'Invalid package version' }
  $numeric = @($Matches[1], $Matches[2], $Matches[3], $Matches[4]) -join '.'
  $files = @(Get-WindowsSafeFiles $Directory)
  foreach ($relative in @(
      'FanqieReader.exe', 'flutter_windows.dll', 'permission_handler_windows_plugin.dll',
      'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
      'data/flutter_assets/NativeAssetsManifest.json', 'data/app.so', 'data/icudtl.dat',
      'data/flutter_assets/FontManifest.json', 'README-安装说明.txt',
      'data/flutter_assets/assets/fonts/LXGWWenKaiLite-Regular.ttf',
      'data/flutter_assets/assets/fonts/ZCOOLXiaoWei-Regular.ttf',
      'data/flutter_assets/assets/fonts/LXGW-OFL.txt',
      'data/flutter_assets/assets/fonts/ZCOOL-OFL.txt')) {
    $path = Join-Path $Directory $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
      throw "Required package file missing/empty: $relative"
    }
  }
  if (Test-Path -LiteralPath (Join-Path $Directory 'fanqie_flutter.exe')) { throw 'Unrenamed package EXE' }
  foreach ($file in $files) {
    if ($file.Extension -in @('.dll', '.exe')) { Assert-WindowsX64Pe $file.FullName }
  }
  Assert-WindowsX64Aot (Join-Path $Directory 'data/app.so')
  $v = (Get-Item -LiteralPath (Join-Path $Directory 'FanqieReader.exe')).VersionInfo
  $actualNumeric = @($v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart) -join '.'
  if ($v.ProductName -ne 'FanqieReader' -or $v.ProductVersion -ne $FullVersion -or
      $v.FileVersion -ne $FullVersion -or $actualNumeric -ne $numeric) {
    throw "EXE product/version mismatch: $($v.ProductName) $($v.ProductVersion) / $actualNumeric; expected $FullVersion"
  }
  $assets = Join-Path $Directory 'data/flutter_assets'
  $fonts = @(Get-Content -LiteralPath (Join-Path $assets 'FontManifest.json') -Raw | ConvertFrom-Json)
  foreach ($mapping in @(
      @{Family = 'ReaderKaiTi'; Asset = 'assets/fonts/LXGWWenKaiLite-Regular.ttf'},
      @{Family = 'ReaderSongTi'; Asset = 'assets/fonts/ZCOOLXiaoWei-Regular.ttf'})) {
    $entries = @($fonts | Where-Object family -EQ $mapping.Family)
    if ($entries.Count -ne 1 -or @($entries[0].fonts).Count -ne 1 -or
        $entries[0].fonts[0].asset -ne $mapping.Asset) { throw "Font family mapping mismatch: $($mapping.Family)" }
  }
  foreach ($font in $fonts) {
    foreach ($entry in $font.fonts) {
      $path = Resolve-WindowsReleasePath $entry.asset $assets
      Assert-WindowsWithin $path $assets
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required font missing: $($entry.asset)" }
    }
  }
  foreach ($file in @('LXGWWenKaiLite-Regular.ttf', 'ZCOOLXiaoWei-Regular.ttf', 'LXGW-OFL.txt', 'ZCOOL-OFL.txt')) {
    $source = Join-Path $SourceRoot "assets/fonts/$file"
    $packaged = Join-Path $assets "assets/fonts/$file"
    if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $packaged).Hash) {
      throw "Font/license digest differs from source: $file"
    }
  }
  $native = Get-Content -LiteralPath (Join-Path $assets 'NativeAssetsManifest.json') -Raw | ConvertFrom-Json -AsHashtable
  if (($native['format-version'] -join '.') -ne '1.0.0' -or -not $native.ContainsKey('native-assets')) { throw 'Unsupported native assets manifest' }
  foreach ($platform in $native['native-assets'].Values) {
    foreach ($asset in $platform.Values) {
      # Windows uses the "absolute" loading mode with a bundled DLL basename.
      # "relative" means relative to app.so, not to the executable directory.
      if ($asset.Count -ne 2 -or $asset[0] -cne 'absolute' -or
          $asset[1] -isnot [string] -or [string]::IsNullOrWhiteSpace($asset[1]) -or
          $asset[1] -match '[\\/]' -or [IO.Path]::GetFileName($asset[1]) -cne $asset[1]) {
        throw 'Non-portable native asset'
      }
      $path = Resolve-WindowsReleasePath $asset[1] $Directory
      Assert-WindowsWithin $path $Directory
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Native asset missing: $path" }
      Assert-WindowsX64Pe $path
    }
  }
  Write-Host "Verified layout/fonts/licenses/native/plugins/x64/EXE $FullVersion : $Directory"
}
function Expand-WindowsReleaseZip([string]$Archive, [string]$Destination, [string]$Root) {
  $archivePath = Resolve-WindowsReleasePath $Archive $Root
  $destinationPath = Resolve-WindowsReleasePath $Destination $Root
  $dist = Resolve-WindowsReleasePath 'dist' $Root
  Assert-WindowsWithin $archivePath $dist
  Assert-WindowsWithin $destinationPath $dist
  if (Test-Path -LiteralPath $destinationPath) { throw "Extraction destination already exists: $destinationPath" }
  $sidecar = Get-Content -LiteralPath "$archivePath.sha256" -Raw
  $name = [IO.Path]::GetFileName($archivePath)
  # One held read handle denies writers/deletion from checksum through extraction.
  # Never close the checked archive and reopen its potentially replaced path.
  $stream = [IO.File]::Open($archivePath, 'Open', 'Read', 'Read')
  $zip = $null
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($sidecar.Trim() -cne "$hash  $name") { throw 'ZIP checksum/filename mismatch' }
    $stream.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
      $entryName = $entry.FullName.Replace('\', '/')
      if ($entryName -match '^/|:|(^|/)\.\.(/|$)' -or
          (($entry.ExternalAttributes -shr 16) -band 0xf000) -eq 0xa000) { throw "Unsafe ZIP entry: $entryName" }
      $target = Resolve-WindowsReleasePath $entryName $destinationPath
      Assert-WindowsWithin $target $destinationPath
      if (-not $seen.Add($target)) { throw "Duplicate ZIP entry: $entryName" }
    }
    [IO.Compression.ZipFileExtensions]::ExtractToDirectory($zip, $destinationPath)
  } finally {
    try { if ($zip) { $zip.Dispose() } } finally { $stream.Dispose() }
  }
  return $destinationPath
}

if ($MyInvocation.InvocationName -ne '.') {
  $root = Split-Path -Parent $PSScriptRoot
  if (-not $Version) {
    $text = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
    if ($text -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$') { throw 'pubspec version missing' }
    $Version = $Matches[1]
  }
  if ($ZipPath) {
    if (-not $ExtractDir) { $ExtractDir = [IO.Path]::ChangeExtension((Resolve-WindowsReleasePath $ZipPath $root), '.verify') }
    $PackageDir = Expand-WindowsReleaseZip $ZipPath $ExtractDir $root
  }
  if (-not $PackageDir) { throw 'Supply PackageDir or ZipPath' }
  $directory = Resolve-WindowsReleasePath $PackageDir $root
  Assert-WindowsWithin $directory (Join-Path $root 'dist')
  Test-WindowsPackageLayout $directory $Version $root
}
