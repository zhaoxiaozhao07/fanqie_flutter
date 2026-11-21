# Controlled Flutter-boundary tests; filesystem guards/copy/ZIP/PE checks stay real.
param(
  [ValidateSet('Guards', 'All', 'Publish', 'Review', 'Bootstrap')][string]$Suite = 'All',
  [string]$LogPath,
  [switch]$OmitDraftValidation
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$fixtureParent = Join-Path $repo '.dart_tool/codex-windows-reading'
$fixtureRoot = Join-Path $fixtureParent ("package-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
if ($LogPath) { Start-Transcript -LiteralPath $LogPath | Out-Null }
$failures = 0
$passes = 0
$savedLocation = Get-Location

function Assert-True($condition, [string]$message) {
  if (-not $condition) { throw "ASSERT: $message" }
}
function Expect-Failure([scriptblock]$action, [string]$pattern) {
  $errorSeen = $null
  try { & $action } catch { $errorSeen = $_.Exception.Message }
  Assert-True ($null -ne $errorSeen) "operation should fail ($pattern)"
  Assert-True ($errorSeen -match $pattern) "wrong failure: $errorSeen (expected $pattern)"
}
function Test-Case([string]$name, [scriptblock]$body) {
  try { & $body; $script:passes++; Write-Host "PASS $name" }
  catch { $script:failures++; Write-Host "FAIL $name : $($_.Exception.Message)" }
}
function New-PeFixture([string]$path, [int]$machine = 0x8664) {
  $bytes = [byte[]]::new(512)
  $bytes[0] = 0x4d; $bytes[1] = 0x5a
  [BitConverter]::GetBytes([int]128).CopyTo($bytes, 60)
  $bytes[128] = 0x50; $bytes[129] = 0x45
  [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes, 132)
  [IO.File]::WriteAllBytes($path, $bytes)
}
function New-Fixture {
  $case = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
  $app = Join-Path $case 'app'
  foreach ($dir in @('scripts', 'assets/fonts', 'seed/data/flutter_assets/assets/fonts', 'runtime/x64/Microsoft.VC143.CRT')) {
    New-Item -ItemType Directory -Path (Join-Path $app $dir) -Force | Out-Null
  }
  Copy-Item -LiteralPath (Join-Path $repo 'scripts/package_windows.ps1') -Destination (Join-Path $app 'scripts')
  # No real Flutter runs in fixtures. Isolate only the mutex name at this boundary,
  # retaining real mutex acquisition/release without blocking the shared coordinator.
  $fixtureScript = Join-Path $app 'scripts/package_windows.ps1'
  $source = [IO.File]::ReadAllText($fixtureScript)
  $fixtureMutex = "Local\FanqieCodexPackageFixture-$([guid]::NewGuid().ToString('N'))"
  $source = $source.Replace('Local\FanqieCodexReaderFlutterChecks', $fixtureMutex)
  [IO.File]::WriteAllText($fixtureScript, $source, [Text.UTF8Encoding]::new($true))
  if (Test-Path -LiteralPath (Join-Path $repo 'scripts/verify_windows_package.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo 'scripts/verify_windows_package.ps1') -Destination (Join-Path $app 'scripts')
  }
  # Use an existing EXE only for real Windows resource inspection, never launch it.
  $exe = Join-Path $repo 'build/windows/x64/runner/Release/fanqie_flutter.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw 'Tests require one existing Windows Release EXE (no Flutter is invoked).' }
  $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
  Assert-True ($v -match '^\d+\.\d+\.\d+\+\d+$') 'fixture EXE must have Flutter version resources'
  Set-Content -LiteralPath (Join-Path $app 'pubspec.yaml') -Value "version: $v" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $app 'pubspec.lock') -Value 'controlled lock' -Encoding utf8
  Copy-Item -LiteralPath $exe -Destination (Join-Path $app 'seed/fanqie_flutter.exe')
  foreach ($dll in @('flutter_windows.dll', 'permission_handler_windows_plugin.dll')) {
    New-PeFixture (Join-Path $app "seed/$dll")
  }
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    New-PeFixture (Join-Path $app "runtime/x64/Microsoft.VC143.CRT/$dll")
  }
  Set-Content -LiteralPath (Join-Path $app 'seed/native_assets.json') -Value '{"format-version":[1,0,0],"native-assets":{}}'
  # Flutter's Windows AOT snapshot is ELF64 x86_64, not a Windows PE DLL.
  $aot = [byte[]]::new(64)
  ([byte[]]@(0x7f, 0x45, 0x4c, 0x46, 2, 1, 1)).CopyTo($aot, 0)
  $aot[16] = 3; $aot[18] = 62
  [IO.File]::WriteAllBytes((Join-Path $app 'seed/data/app.so'), $aot)
  foreach ($file in @('icudtl.dat')) {
    Set-Content -LiteralPath (Join-Path $app "seed/data/$file") -Value 'controlled data'
  }
  $manifest = @(
    @{ family = 'ReaderKaiTi'; fonts = @(@{asset = 'assets/fonts/LXGWWenKaiLite-Regular.ttf'}) },
    @{ family = 'ReaderSongTi'; fonts = @(@{asset = 'assets/fonts/ZCOOLXiaoWei-Regular.ttf'}) }
  )
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $app 'seed/data/flutter_assets/FontManifest.json')
  foreach ($file in @('LXGWWenKaiLite-Regular.ttf', 'ZCOOLXiaoWei-Regular.ttf', 'LXGW-OFL.txt', 'ZCOOL-OFL.txt')) {
    Set-Content -LiteralPath (Join-Path $app "assets/fonts/$file") -Value "controlled $file"
    Copy-Item -LiteralPath (Join-Path $app "assets/fonts/$file") -Destination (Join-Path $app 'seed/data/flutter_assets/assets/fonts')
  }
  $global:FanqiePackageTestState = @{ App = $app; Failure = ''; MutateLock = $false; Suite = $Suite }
  return @{ App = $app; Case = $case; Version = $v; Mutex = $fixtureMutex; Name = "FanqieReader-$($v.Replace('+','-'))-windows-x64" }
}
function global:flutter {
  # Flutter is the sole expensive boundary replaced. Native exit status remains real.
  $arguments = @($args)
  if ($arguments[0] -eq '--version') {
    '{"frameworkVersion":"3.47.9","channel":"stable","dartSdkVersion":"3.13.7","frameworkRevision":"c197ca5199e9ee5661e865596c9c07294dfab51c"}'
  } elseif ($arguments[0] -eq 'build') {
    $global:FanqiePackageTestState.BuildArguments = $arguments -join ' '
    if ($arguments.Count -gt 3) {
      Assert-True (($arguments -join ' ') -match '^build windows --release --no-pub --target lib/main.dart --build-name=\d+\.\d+\.\d+ --build-number=\d+$') 'build must use production target, no-pub and explicit version'
    }
    Set-Content -LiteralPath (Join-Path $global:FanqiePackageTestState.App 'build-called') -Value 'called'
    $release = Join-Path $global:FanqiePackageTestState.App 'build/windows/x64/runner/Release'
    New-Item -ItemType Directory -Path $release -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $global:FanqiePackageTestState.App 'seed') -Force | Copy-Item -Destination $release -Recurse
    if ($global:FanqiePackageTestState.MutateLock) { Add-Content -LiteralPath (Join-Path $global:FanqiePackageTestState.App 'pubspec.lock') -Value 'changed' }
  } else { throw "Unexpected Flutter invocation: $arguments" }
  $code = if ($global:FanqiePackageTestState.Failure -eq $arguments[0]) { 23 } else { 0 }
  & $env:ComSpec /d /c "exit $code"
}
function Invoke-Package($f, [string]$output = 'dist', [switch]$Runtime) {
  $parameters = @{ OutputDir = $output }
  if ($Runtime -and (Test-Path -LiteralPath (Join-Path $f.App 'scripts/verify_windows_package.ps1'))) {
    $parameters.RuntimeDir = Join-Path $f.App 'runtime/x64/Microsoft.VC143.CRT'
  }
  & (Join-Path $f.App 'scripts/package_windows.ps1') @parameters
}
function Get-PublishProgram {
  # Read the actual YAML literal run block. This is execution, not source assertions.
  $lines = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/windows-release.yml')
  $inPublish = $false; $inRun = $false; $program = [Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if ($line -eq '  publish:') { $inPublish = $true }
    if (-not $inPublish) { continue }
    if ($line -eq '        run: |') { $inRun = $true; continue }
    if ($inRun) {
      if ($line -and -not $line.StartsWith('          ')) { break }
      $program.Add($(if ($line) { $line.Substring(10) } else { '' }))
    }
  }
  if (-not $program.Count) { throw 'Publication run block missing' }
  return $program -join "`n"
}
function Test-FlutterBootstrap {
  # Execute the actual build step only through its SDK JSON read, not a copy of
  # the wrapper. The SDK boundary simulates a fresh installation's noisy launch.
  $lines = Get-Content -LiteralPath (Join-Path $repo '.github/workflows/windows-release.yml')
  $selected = $false; $inRun = $false
  $programLines = [Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if ($line -eq '      - name: Enforce lock, offline analyze/test, production build and verified package') {
      $selected = $true
    }
    if (-not $selected) { continue }
    if ($line -eq '        run: |') { $inRun = $true; continue }
    if ($inRun) {
      if ($line -and -not $line.StartsWith('          ')) { break }
      $programLines.Add($(if ($line) { $line.Substring(10) } else { '' }))
    }
  }
  $program = $programLines -join "`n"
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($program, [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw 'Build step parser failure' }
  $read = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
      $node.Left.VariablePath.UserPath -eq 'sdk'
  }, $true))
  if ($read.Count -ne 1) { throw 'Build SDK read boundary not found' }
  $prefix = $program.Substring(0, $read[0].Extent.EndOffset)
  function global:flutter {
    $arguments = @($args)
    Assert-True ($arguments[0] -eq '--version') 'unexpected SDK bootstrap operation'
    $global:FanqieBootstrapTestState.Calls.Add($arguments -join ' ')
    if (-not $global:FanqieBootstrapTestState.Initialized) {
      'Building flutter tool...'
      'Resolving dependencies...'
      [Console]::Error.WriteLine('Running pub upgrade...')
      $global:FanqieBootstrapTestState.Initialized = $true
    }
    if ($arguments -contains '--machine') {
      '{"frameworkVersion":"3.47.9","channel":"stable","dartSdkVersion":"3.13.7"}'
    } else { 'Flutter 3.47.9 stable / Dart 3.13.7' }
    $code = if ($global:FanqieBootstrapTestState.Fail) { 23 } else { 0 }
    & $env:ComSpec /d /c "exit $code"
  }
  foreach ($mode in @('cold', 'warm', 'native-error')) {
    Test-Case "SDK $mode bootstrap preserves strict machine JSON and exit status" {
      $f = New-Fixture
      $global:FanqieBootstrapTestState = @{
        Initialized = ($mode -eq 'warm'); Fail = ($mode -eq 'native-error')
        Calls = [Collections.Generic.List[string]]::new()
      }
      Set-Location -LiteralPath $f.App
      try {
        if ($mode -eq 'native-error') {
          Expect-Failure { . ([scriptblock]::Create($prefix)) } 'exit 23'
          Assert-True ($global:FanqieBootstrapTestState.Calls.Count -eq 1) 'SDK failure was silently retried'
        } else {
          . ([scriptblock]::Create($prefix))
          Assert-True ($sdk.frameworkVersion -ceq '3.47.9' -and $sdk.dartSdkVersion -ceq '3.13.7') 'wrong parsed SDK'
          $json = Get-Content -LiteralPath (Join-Path $f.App 'build/windows/ci-logs/flutter-version.json') -Raw
          Assert-True (($json | ConvertFrom-Json).frameworkVersion -ceq '3.47.9') 'machine log contains bootstrap chatter'
          if ($mode -eq 'cold') {
            $bootstrap = Get-Content -LiteralPath (Join-Path $f.App 'build/windows/ci-logs/flutter-bootstrap.log') -Raw
            Assert-True ($bootstrap.Contains('Building flutter tool...')) 'initialization diagnostics were lost'
          }
        }
      } finally { Set-Location -LiteralPath $savedLocation }
    }
  }
  Remove-Variable FanqieBootstrapTestState -Scope Global -ErrorAction SilentlyContinue
}
function global:Invoke-WebRequest {
  param($Method, $Uri, $Headers, [switch]$SkipHttpErrorCheck, $Body, $ContentType, $InFile)
  # Test-only in-memory GitHub resource store. Never sends a network request.
  $state = $global:FanqieReleaseTestState
  $status = 200; $result = $null
  $path = ([Uri]$Uri).AbsolutePath
  if ($Method -eq 'GET' -and $path -match '/git/matching-refs/tags/') {
    if ($state.Mode -eq 'Api503') { $status = 503; $result = @{message='unavailable'} }
    elseif ($state.Mode -eq 'Api401') { $status = 401; $result = @{message='unauthorized'} }
    elseif ($state.Mode -eq 'ExistingTag') { $result = @(@{ref="refs/tags/$env:TAG"}) }
    else { $result = @() }
  } elseif ($Method -eq 'GET' -and $path -match '/releases/tags/') {
    if ($state.Mode -eq 'ExistingRelease') { $result = @{id=99; tag_name=$env:TAG; draft=$false} }
    else { $status = 404; $result = @{message='Not Found'} }
  } elseif ($Method -eq 'GET' -and $path.EndsWith('/releases')) {
    $result = @()
    if ($state.Mode -eq 'ExistingDraftNoTag') { $result = @(@{id=99; tag_name=$env:TAG; draft=$true}) }
  } elseif ($Method -eq 'POST' -and $path.EndsWith('/git/refs')) {
    $payload = $Body | ConvertFrom-Json -AsHashtable
    if ($payload.ref -cne "refs/tags/$env:TAG" -or $payload.sha -cne $env:GITHUB_SHA) { throw 'Server rejected tag identity' }
    $state.Tag = @{ ref=$payload.ref; object=@{type='commit'; sha=$payload.sha} }
    $result = $state.Tag; $status = 201
  } elseif ($Method -eq 'POST' -and $path.EndsWith('/releases')) {
    $payload = $Body | ConvertFrom-Json -AsHashtable
    if ($payload.make_latest -cne 'false' -or $payload.draft -ne $true -or
        $payload.prerelease -ne $false -or $payload.target_commitish -cne $env:GITHUB_SHA) {
      throw 'Server rejected unsafe release creation'
    }
    $state.Release = @{
      id=77; tag_name=$payload.tag_name; target_commitish=$payload.target_commitish
      draft=$true; prerelease=$false; assets=@(); body=$payload.body
      upload_url='https://uploads.github.com/repos/fixture/repo/releases/77/assets{?name,label}'
      html_url="https://github.com/fixture/repo/releases/tag/$env:TAG"
    }
    $result = $state.Release; $status = 201
  } elseif ($Method -eq 'POST' -and $path.EndsWith('/assets')) {
    if ($state.Mode -eq 'UploadFailure') { $status = 500; $result = @{message='upload failed'} }
    else {
      $name = [Uri]::UnescapeDataString(([Uri]$Uri).Query.Substring(6))
      $asset = @{
        name=$name; size=(Get-Item -LiteralPath $InFile).Length; state='uploaded'
        digest="sha256:$((Get-FileHash -LiteralPath $InFile).Hash.ToLowerInvariant())"
      }
      if ($state.Mode -eq 'BadDigest') { $asset.digest = 'sha256:' + ('0' * 64) }
      if ($state.Mode -eq 'MissingDigest') { $asset.Remove('digest') }
      if ($state.Mode -eq 'MissingAsset' -and $name -eq 'windows-build-info.json') { $asset.state='new' }
      $state.Release.assets += $asset
      $result = $asset; $status = 201
    }
  } elseif ($Method -eq 'GET' -and $path.EndsWith('/releases/77')) {
    $result = $state.Release
  } elseif ($Method -eq 'GET' -and $path -match '/git/ref/tags/') {
    $result = if ($state.Mode -eq 'TagRace') { @{object=@{type='commit';sha=('b' * 40)}} } else { $state.Tag }
  } elseif ($Method -eq 'PATCH' -and $path.EndsWith('/releases/77')) {
    $payload = $Body | ConvertFrom-Json -AsHashtable
    if ($payload.make_latest -cne 'false' -or $payload.draft -ne $false -or $payload.prerelease -ne $false) {
      throw 'Server rejected unsafe publication'
    }
    $state.Release.draft = $false
    $result = $state.Release
  } else { throw "Unexpected API request (no network): $Method $Uri" }
  return @{StatusCode=$status; Content=(ConvertTo-Json -InputObject $result -Depth 25 -Compress)}
}
function Test-Publication {
  $variables = @('GITHUB_SHA','GITHUB_REF','GITHUB_API_URL','GITHUB_SERVER_URL','GITHUB_REPOSITORY',
    'GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','GITHUB_STEP_SUMMARY','GH_TOKEN','VERSION','BUILD_NUMBER','FULL_VERSION','TAG','PACKAGE')
  $saved = @{}
  foreach ($name in $variables) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
  $program = Get-PublishProgram
  if ($OmitDraftValidation) {
    # Mutation check in test utilities only: detect public-before-validation regressions.
    $program = $program.Replace('Confirm-NewRelease $completeDraft $true', '# test mutation: omitted pre-publication validation')
  }
  try {
    $env:GITHUB_SHA = 'a' * 40; $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_API_URL = 'https://api.github.test'; $env:GITHUB_SERVER_URL = 'https://github.com'
    $env:GITHUB_REPOSITORY = 'fixture/repo'; $env:GITHUB_RUN_ID = '123'; $env:GITHUB_RUN_ATTEMPT = '1'
    $env:GH_TOKEN = 'test-only-not-a-secret'
    foreach ($mode in @('Success','ExistingTag','ExistingRelease','ExistingDraftNoTag','Api503','Api401','UploadFailure','BadDigest','MissingDigest','MissingAsset','TagRace','WrongSource')) {
      Test-Case "publication $mode resource state" {
        $f = New-Fixture
        $env:FULL_VERSION = $f.Version
        $env:VERSION, $env:BUILD_NUMBER = $f.Version.Split('+')
        $env:TAG = "windows-v$env:VERSION-$env:BUILD_NUMBER"; $env:PACKAGE = $f.Name
        $env:GITHUB_STEP_SUMMARY = Join-Path $f.App 'summary.md'
        Invoke-Package $f 'dist/package' -Runtime
        $download = Join-Path $f.App 'dist/windows'
        New-Item -ItemType Directory -Path $download | Out-Null
        foreach ($name in @("$($f.Name).zip", "$($f.Name).zip.sha256", 'windows-build-info.json')) {
          Copy-Item -LiteralPath (Join-Path $f.App "dist/package/$name") -Destination $download
        }
        $programPath = Join-Path $f.App 'publish-fixture.ps1'
        [IO.File]::WriteAllText($programPath, $program)
        if ($mode -eq 'WrongSource') {
          $path = Join-Path $f.App 'dist/windows/windows-build-info.json'
          $info = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
          $info.source_commit = 'b' * 40
          $info | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $path
        }
        $global:FanqieReleaseTestState = @{Mode=$mode; Tag=$null; Release=$null}
        $previous = Get-Location
        try {
          Set-Location $f.App
          if ($mode -eq 'Success') {
            & $programPath
            $r = $global:FanqieReleaseTestState.Release
            Assert-True ($r.draft -eq $false -and $r.assets.Count -eq 3) 'complete release did not become public'
            Assert-True ($global:FanqieReleaseTestState.Tag.object.sha -ceq ('a' * 40)) 'public tag source incorrect'
            Assert-True ((Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw) -match '下载 ZIP') 'release link summary missing'
          } else {
            Expect-Failure { & $programPath } 'exists|closed|mismatch|digest|Provenance|property'
            $state = $global:FanqieReleaseTestState
            Assert-True ($null -eq $state.Release -or $state.Release.draft -eq $true) 'failed validation made a public release'
            if ($mode -in @('ExistingTag','ExistingRelease','ExistingDraftNoTag','Api503','Api401','WrongSource')) {
              Assert-True ($null -eq $state.Tag -and $null -eq $state.Release) 'preflight failure changed remote resource state'
            }
          }
        } finally { Set-Location $previous }
      }
    }
  } finally {
    foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Variable FanqieReleaseTestState -Scope Global -ErrorAction SilentlyContinue
  }
}
function Test-ReviewRepairs {
  # All concurrency instrumentation is test-only. Task.Run supplies a different
  # OS thread so Mutex's same-thread reentrancy cannot hide early release.
  if (-not ('FanqieReleaseReviewProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class FanqieArchiveSwapResult {
  public bool Replaced;
  public bool Writable;
  public int MoveError;
  public int WriteError;
}
public static class FanqieReleaseReviewProbe {
  public static bool CanEnter(string name) {
    int callerThread = Environment.CurrentManagedThreadId;
    return Task.Run(() => {
      if (Environment.CurrentManagedThreadId == callerThread) throw new Exception("Mutex probe must use another thread");
      using (var mutex = new Mutex(false, name)) {
        bool owned = false;
        try {
          try { owned = mutex.WaitOne(0); }
          catch (AbandonedMutexException) { owned = true; }
          return owned;
        } finally { if (owned) mutex.ReleaseMutex(); }
      }
    }).GetAwaiter().GetResult();
  }
  public static FanqieArchiveSwapResult SwapArchive(string original, string candidate) {
    return Task.Run(() => {
      if (!File.Exists(original) || !File.Exists(candidate)) throw new Exception("Swap fixture missing");
      var result = new FanqieArchiveSwapResult();
      try { File.Move(candidate, original, true); result.Replaced = true; }
      catch (IOException e) { result.MoveError = e.HResult & 0xffff; }
      catch (UnauthorizedAccessException e) { result.MoveError = e.HResult & 0xffff; }
      try {
        using (var handle = new FileStream(original, FileMode.Open, FileAccess.ReadWrite,
                                           FileShare.ReadWrite | FileShare.Delete)) {
          result.Writable = true;
        }
      } catch (IOException e) { result.WriteError = e.HResult & 0xffff; }
      return result;
    }).GetAwaiter().GetResult();
  }
}
'@
  }
  foreach ($component in @('CON.txt', 'CON', 'PRN.log', 'AUX/child', 'COM1', 'COM9.exe',
      'LPT1.log', 'LPT9', 'NUL.txt', 'com1.data', 'CONIN$.txt', 'LPT².log')) {
    Test-Case "reserved device $component rejected before effects" {
      $f = New-Fixture
      . (Join-Path $f.App 'scripts/verify_windows_package.ps1')
      Expect-Failure {
        $resolved = Resolve-WindowsReleasePath "dist/$component" $f.App
        Assert-WindowsWithin $resolved (Join-Path $f.App 'dist')
      } 'reserved|device'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'device guard invoked build'
    }
  }
  Test-Case 'normal device-prefix filename remains allowed' {
    $f = New-Fixture
    . (Join-Path $f.App 'scripts/verify_windows_package.ps1')
    $resolved = Resolve-WindowsReleasePath 'dist/CONtent/COM10.txt/LPTnotes' $f.App
    Assert-WindowsWithin $resolved (Join-Path $f.App 'dist')
  }
  Test-Case 'competing thread excluded during real Release copy and stage hashes' {
    $f = New-Fixture
    $global:FanqieReviewSnapshot = @{
      Mutex = $f.Mutex; Release = Join-Path $f.App 'build/windows/x64/runner/Release'
      Stage = Join-Path $f.App "dist/$($f.Name)"; Observations = [Collections.Generic.List[bool]]::new()
      Copies = 0
    }
    # Wrap, do not replace, the real copy. The callback observes lock ownership
    # during the source-to-private-stage snapshot and still performs actual copy.
    function global:Copy-Item {
      [CmdletBinding(DefaultParameterSetName='Path')]
      param(
        [Parameter(Position=0, ValueFromPipeline=$true, ParameterSetName='Path')][object[]]$Path,
        [Parameter(ParameterSetName='Literal')][string[]]$LiteralPath,
        [string]$Destination, [switch]$Recurse, [switch]$Force
      )
      process {
        $state = $global:FanqieReviewSnapshot
        $sources = if ($PSCmdlet.ParameterSetName -eq 'Literal') { $LiteralPath } else {
          @($Path | ForEach-Object { if ($_ -is [IO.FileSystemInfo]) { $_.FullName } else { [string]$_ } })
        }
        foreach ($source in $sources) {
          if ($Recurse -and $Destination -eq $state.Stage -and $source.StartsWith($state.Release + '\')) {
            $state.Observations.Add([FanqieReleaseReviewProbe]::CanEnter($state.Mutex))
            $state.Copies++
          }
          Microsoft.PowerShell.Management\Copy-Item -LiteralPath $source -Destination $Destination -Recurse:$Recurse -Force:$Force
        }
      }
    }
    $breakpoint = $null
    try {
      $scriptPath = Join-Path $f.App 'scripts/package_windows.ps1'
      $tokens = $null; $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
      $command = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Get-WindowsFileDigests'
      }, $true)
      if (-not $command) { throw 'Stage hash boundary missing' }
      $breakpoint = Set-PSBreakpoint -Script $scriptPath -Line $command.Extent.StartLineNumber -Action {
        $state = $global:FanqieReviewSnapshot
        $state.Observations.Add([FanqieReleaseReviewProbe]::CanEnter($state.Mutex))
      }
      Invoke-Package $f -Runtime
      Assert-True ($global:FanqieReviewSnapshot.Copies -gt 0 -and $global:FanqieReviewSnapshot.Observations.Count -gt 1) 'real snapshot was not observed'
      Write-Host "Snapshot race: real_copies=$($global:FanqieReviewSnapshot.Copies) competitor_entries=$($global:FanqieReviewSnapshot.Observations -join ',')"
      Assert-True (-not ($global:FanqieReviewSnapshot.Observations -contains $true)) 'competing thread acquired mutex during shared snapshot/stage hashes'
      Assert-True ([FanqieReleaseReviewProbe]::CanEnter($f.Mutex)) 'mutex not released after successful package'
    } finally {
      if ($breakpoint) { Remove-PSBreakpoint -Breakpoint $breakpoint }
      Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
      Remove-Variable FanqieReviewSnapshot -Scope Global -ErrorAction SilentlyContinue
    }
  }
  Test-Case 'stage validation failure releases mutex to competing thread' {
    $f = New-Fixture
    Add-Content -LiteralPath (Join-Path $f.App 'seed/data/flutter_assets/assets/fonts/LXGWWenKaiLite-Regular.ttf') -Value 'wrong bytes'
    Expect-Failure { Invoke-Package $f -Runtime } 'font|digest'
    Assert-True ([FanqieReleaseReviewProbe]::CanEnter($f.Mutex)) 'failed snapshot leaked mutex ownership'
  }
  Test-Case 'standalone ZIP replacement and write blocked at pre-extraction boundary' {
    $f = New-Fixture
    Invoke-Package $f -Runtime
    $archive = Join-Path $f.App "dist/$($f.Name).zip"
    $candidate = Join-Path $f.App 'dist/replacement.zip'
    Copy-Item -LiteralPath $archive -Destination $candidate
    $zip = [IO.Compression.ZipFile]::Open($candidate, 'Update')
    try {
      $zip.GetEntry('data/icudtl.dat').Delete()
      $entry = $zip.CreateEntry('data/icudtl.dat')
      $writer = [IO.StreamWriter]::new($entry.Open())
      try { $writer.Write('replacement attack') } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $global:FanqieReviewZip = @{ Archive = $archive; Candidate = $candidate; Result = $null }
    try {
      # Instrument just the .NET extraction boundary in a fixture copy. Wrap
      # the actual extraction with a deterministic replacement attempt; no
      # debugger sequence-point dependence, production hooks or timing sleeps.
      $scriptPath = Join-Path $f.App 'scripts/standalone-verifier.ps1'
      Copy-Item -LiteralPath (Join-Path $f.App 'scripts/verify_windows_package.ps1') -Destination $scriptPath
      $tokens = $null; $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
      $boundary = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'ExtractToDirectory'
      }, $true)
      if (-not $boundary) { throw 'ZIP extraction boundary missing' }
      $arguments = @($boundary.Arguments | ForEach-Object { $_.Extent.Text })
      $source = [IO.File]::ReadAllText($scriptPath)
      $source = $source.Remove($boundary.Extent.StartOffset, $boundary.Extent.EndOffset - $boundary.Extent.StartOffset).
        Insert($boundary.Extent.StartOffset, "Invoke-FanqieFixtureExtraction ($($arguments[0])) ($($arguments[1]))")
      [IO.File]::WriteAllText($scriptPath, $source, [Text.UTF8Encoding]::new($false))
      function global:Invoke-FanqieFixtureExtraction {
        param([object]$ArchiveOrPath, [string]$Destination)
        $state = $global:FanqieReviewZip
        $state.Result = [FanqieReleaseReviewProbe]::SwapArchive($state.Archive, $state.Candidate)
        if ($ArchiveOrPath -is [IO.Compression.ZipArchive]) {
          [IO.Compression.ZipFileExtensions]::ExtractToDirectory($ArchiveOrPath, $Destination)
        } else {
          [IO.Compression.ZipFile]::ExtractToDirectory([string]$ArchiveOrPath, $Destination)
        }
      }
      $destination = Join-Path $f.App 'dist/standalone-check'
      & $scriptPath -ZipPath $archive -ExtractDir $destination -Version $f.Version
      $result = $global:FanqieReviewZip.Result
      Assert-True ($null -ne $result) 'pre-extraction boundary did not execute'
      Write-Host "Archive race: replaced=$($result.Replaced) writable=$($result.Writable) move_error=$($result.MoveError) write_error=$($result.WriteError)"
      Assert-True (-not $result.Replaced -and -not $result.Writable -and
        $result.MoveError -in @(5, 32) -and $result.WriteError -eq 32) 'checked ZIP could be replaced/written before extraction'
      Assert-True ((Get-Content -LiteralPath (Join-Path $destination 'data/icudtl.dat') -Raw).Trim() -eq 'controlled data') 'extracted payload came from replacement archive'
      # Successful disposal must allow normal access again.
      $handle = [IO.File]::Open($archive, 'Open', 'ReadWrite', 'None'); $handle.Dispose()
    } finally {
      Remove-Item Function:\Invoke-FanqieFixtureExtraction -ErrorAction SilentlyContinue
      Remove-Variable FanqieReviewZip -Scope Global -ErrorAction SilentlyContinue
    }
  }
  Test-Case 'ZIP checksum failure disposes the held read handle' {
    $f = New-Fixture
    Invoke-Package $f -Runtime
    $archive = Join-Path $f.App "dist/$($f.Name).zip"
    Set-Content -LiteralPath "$archive.sha256" -Value "$('0' * 64)  $($f.Name).zip"
    Expect-Failure {
      & (Join-Path $f.App 'scripts/verify_windows_package.ps1') -ZipPath $archive -ExtractDir (Join-Path $f.App 'dist/invalid-check')
    } 'checksum'
    $handle = [IO.File]::Open($archive, 'Open', 'ReadWrite', 'None')
    $handle.Dispose()
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'dist/invalid-check'))) 'bad checksum caused extraction'
  }
}
try {
  if ($Suite -eq 'Publish') { Test-Publication }
  elseif ($Suite -eq 'Review') { Test-ReviewRepairs }
  elseif ($Suite -eq 'Bootstrap') { Test-FlutterBootstrap }
  else {
  Test-Case 'escaped output rejected before build' {
    $f = New-Fixture
    Expect-Failure { Invoke-Package $f '../escaped' } 'output|unsafe|within|dist'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'unsafe output caused a build'
  }
  Test-Case 'workspace root rejected before build' {
    $f = New-Fixture
    Expect-Failure { Invoke-Package $f '.' } 'output|unsafe|within|dist'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'workspace root caused a build'
  }
  Test-Case 'Windows device output rejected before build' {
    $f = New-Fixture
    Expect-Failure { Invoke-Package $f 'dist/NUL' } 'unsafe|device'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'Windows device output caused a build'
  }
  Test-Case 'existing stage preserved before build' {
    $f = New-Fixture
    $stage = Join-Path $f.App "dist/$($f.Name)"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stage 'sentinel') -Value 'preserve me'
    Expect-Failure { Invoke-Package $f } 'exists|overwrite|collision'
    Assert-True ((Get-Content -LiteralPath (Join-Path $stage 'sentinel') -Raw).Trim() -eq 'preserve me') 'stage was deleted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'collision caused a build'
  }
  Test-Case 'existing archive preserved before build' {
    $f = New-Fixture
    New-Item -ItemType Directory -Path (Join-Path $f.App 'dist') | Out-Null
    $archive = Join-Path $f.App "dist/$($f.Name).zip"
    Set-Content -LiteralPath $archive -Value 'preserve zip'
    Expect-Failure { Invoke-Package $f } 'exists|overwrite|collision'
    Assert-True ((Get-Content -LiteralPath $archive -Raw).Trim() -eq 'preserve zip') 'archive was overwritten'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'collision caused a build'
  }
  Test-Case 'junction output rejected without touching target' {
    $f = New-Fixture
    $outside = Join-Path $f.Case 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $f.App 'dist') -Target $outside | Out-Null
    Expect-Failure { Invoke-Package $f } 'reparse|junction|unsafe'
    Assert-True (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'junction target changed'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'junction caused a build'
  }
  Test-Case 'junction build output rejected before build' {
    $f = New-Fixture
    $outside = Join-Path $f.Case 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $f.App 'build/windows/x64/runner') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $f.App 'build/windows/x64/runner/Release') -Target $outside | Out-Null
    Expect-Failure { Invoke-Package $f } 'reparse|junction|unsafe'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'reparse build path caused a build'
    Assert-True (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'build path junction target changed'
  }
  if ($Suite -eq 'All') {
    foreach ($suffix in @('.zip.sha256', '.verify', 'provenance')) {
      Test-Case "existing $suffix preserved before build" {
        $f = New-Fixture
        New-Item -ItemType Directory -Path (Join-Path $f.App 'dist') | Out-Null
        $leaf = if ($suffix -eq 'provenance') { 'windows-build-info.json' } else { $f.Name + $suffix }
        $existing = Join-Path $f.App "dist/$leaf"
        if ($suffix -eq '.verify') { New-Item -ItemType Directory -Path $existing | Out-Null }
        else { Set-Content -LiteralPath $existing -Value 'preserve existing' }
        Expect-Failure { Invoke-Package $f -Runtime } 'exists|collision|overwrite'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'existing sidecar/provenance/extraction caused build'
        Assert-True (Test-Path -LiteralPath $existing) 'existing path removed'
      }
    }
    Test-Case 'self-contained ZIP, sidecar, provenance and BOM README' {
      $f = New-Fixture
      Invoke-Package $f -Runtime
      Assert-True ($global:FanqiePackageTestState.BuildArguments -match '^build windows --release --no-pub --target lib/main.dart --build-name=\d+\.\d+\.\d+ --build-number=\d+$') 'package build omitted production target or explicit version'
      $zip = Join-Path $f.App "dist/$($f.Name).zip"
      $hash = (Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant()
      Assert-True ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -eq "$hash  $($f.Name).zip") 'checksum does not match real ZIP'
      $info = Get-Content -LiteralPath (Join-Path $f.App 'dist/windows-build-info.json') -Raw | ConvertFrom-Json
      Assert-True ($info.version -eq $f.Version -and $info.build_target -eq 'lib/main.dart' -and $info.signing -eq 'unsigned') 'provenance identity incorrect'
      Assert-True ($info.assets."$($f.Name).zip".sha256 -eq $hash) 'provenance ZIP digest incorrect'
      $readme = [IO.File]::ReadAllBytes((Join-Path $f.App "dist/$($f.Name).verify/README-安装说明.txt"))
      Assert-True ($readme[0] -eq 239 -and $readme[1] -eq 187 -and $readme[2] -eq 191) 'README must retain UTF-8 BOM'
      Assert-True (Test-Path -LiteralPath (Join-Path $f.App "dist/$($f.Name).verify/vcruntime140_1.dll")) 'extracted runtime missing'
      # Re-running must never overwrite the completed artifact.
      Expect-Failure { Invoke-Package $f -Runtime } 'exists|collision|overwrite'
    }
    Test-Case 'missing runtime rejected before build' {
      $f = New-Fixture
      Remove-Item -LiteralPath (Join-Path $f.App 'runtime/x64/Microsoft.VC143.CRT/msvcp140.dll')
      Expect-Failure { Invoke-Package $f -Runtime } 'runtime|msvcp140'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'build-called'))) 'missing runtime caused a build'
    }
    foreach ($command in @('--version', 'build')) {
      Test-Case "native $command exit 23 fails closed" {
        $f = New-Fixture; $global:FanqiePackageTestState.Failure = $command
        Expect-Failure { Invoke-Package $f -Runtime } '23|failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App "dist/$($f.Name).zip"))) 'failed native command produced ZIP'
      }
    }
    Test-Case 'dependency lock mutation prevents ZIP' {
      $f = New-Fixture; $global:FanqiePackageTestState.MutateLock = $true
      Expect-Failure { Invoke-Package $f -Runtime } 'lock'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App "dist/$($f.Name).zip"))) 'mutated lock produced ZIP'
    }
    foreach ($missing in @('permission_handler_windows_plugin.dll', 'native_assets.json', 'data/app.so', 'data/flutter_assets/assets/fonts/LXGW-OFL.txt')) {
      Test-Case "missing $missing prevents ZIP" {
        $f = New-Fixture
        Remove-Item -LiteralPath (Join-Path $f.App "seed/$missing")
        Expect-Failure { Invoke-Package $f -Runtime } 'missing|required|native'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App "dist/$($f.Name).zip"))) 'invalid layout produced ZIP'
      }
    }
    Test-Case 'x86 plugin rejected' {
      $f = New-Fixture
      New-PeFixture (Join-Path $f.App 'seed/permission_handler_windows_plugin.dll') 0x14c
      Expect-Failure { Invoke-Package $f -Runtime } 'x64|8664'
    }
    Test-Case 'non-x64 AOT snapshot rejected' {
      $f = New-Fixture
      $path = Join-Path $f.App 'seed/data/app.so'
      $aot = [IO.File]::ReadAllBytes($path); $aot[18] = 183
      [IO.File]::WriteAllBytes($path, $aot)
      Expect-Failure { Invoke-Package $f -Runtime } 'AOT|x64'
    }
    Test-Case 'font bytes differ from source rejected' {
      $f = New-Fixture
      Add-Content -LiteralPath (Join-Path $f.App 'seed/data/flutter_assets/assets/fonts/LXGWWenKaiLite-Regular.ttf') -Value 'wrong font'
      Expect-Failure { Invoke-Package $f -Runtime } 'font|digest'
    }
    Test-Case 'font family mapping mismatch rejected' {
      $f = New-Fixture
      Set-Content -LiteralPath (Join-Path $f.App 'seed/data/flutter_assets/FontManifest.json') -Value '[]'
      Expect-Failure { Invoke-Package $f -Runtime } 'font|ReaderKaiTi'
    }
    Test-Case 'EXE version mismatch rejected' {
      $f = New-Fixture
      Set-Content -LiteralPath (Join-Path $f.App 'pubspec.yaml') -Value 'version: 9.8.7+654'
      Expect-Failure { Invoke-Package $f -Runtime } 'version'
    }
    Test-Case 'ZIP traversal rejected before extraction' {
      $f = New-Fixture
      New-Item -ItemType Directory -Path (Join-Path $f.App 'dist') | Out-Null
      $zip = Join-Path $f.App 'dist/bad.zip'
      $z = [IO.Compression.ZipFile]::Open($zip, 'Create')
      $entry = $z.CreateEntry('../escaped.txt')
      $writer = [IO.StreamWriter]::new($entry.Open()); $writer.Write('bad'); $writer.Dispose(); $z.Dispose()
      "$((Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant())  bad.zip" | Set-Content -LiteralPath "$zip.sha256"
      Expect-Failure { & (Join-Path $f.App 'scripts/verify_windows_package.ps1') -ZipPath $zip -Version $f.Version } 'unsafe|escape|entry'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.App 'dist/escaped.txt'))) 'ZIP traversal escaped'
    }
  }
  }
} finally {
  Set-Location $savedLocation
  Remove-Item Function:\flutter -ErrorAction SilentlyContinue
  Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
  Remove-Item Function:\Copy-Item -ErrorAction SilentlyContinue
  Remove-Variable FanqiePackageTestState -Scope Global -ErrorAction SilentlyContinue
  # Cleanup only the explicitly created fixture root, after absolute containment verification.
  $full = [IO.Path]::GetFullPath($fixtureRoot)
  $parent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
  if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $full) -notmatch '^package-tests-[0-9a-f]{32}$') { throw 'Unsafe fixture cleanup' }
  # Remove junctions themselves first; never recurse through their targets.
  Get-ChildItem -LiteralPath $full -Directory -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  for ($attempt = 0; $attempt -lt 4; $attempt++) {
    try {
      if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
      break
    } catch {
      if ($attempt -eq 3) { throw }
      Start-Sleep -Milliseconds 500
    }
  }
  Write-Host "RESULT passes=$passes failures=$failures"
  if ($LogPath) { Stop-Transcript | Out-Null }
}
if ($failures -gt 0) { exit 1 }
exit 0
