#Requires -Version 5.1
<#
.SYNOPSIS
  Build and package the Windows release (with progress).
  Bundles VC++ runtime DLLs + WebView2 bootstrapper + Chinese readme.

.PARAMETER SkipBuild
  Skip flutter build; only re-zip an existing Release output.

.PARAMETER NoPause
  Do not wait for Enter at the end (useful in CI / automation).
#>
[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$script:StartedAt = Get-Date
$script:StepCount = 6
$script:StepIndex = 0
$script:ExitCode = 0

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$VcDllNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$WebView2BootstrapUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
$CacheDir = Join-Path $Root 'scripts\cache'

function Format-Elapsed([datetime]$from = $script:StartedAt) {
  $ts = (Get-Date) - $from
  if ($ts.TotalHours -ge 1) {
    return '{0:hh\:mm\:ss}' -f $ts
  }
  return '{0:mm\:ss}' -f $ts
}

function Write-Step([string]$Message) {
  $script:StepIndex++
  $prefix = '[{0}/{1}]' -f $script:StepIndex, $script:StepCount
  Write-Host ''
  Write-Host ("{0} {1}  (elapsed {2})" -f $prefix, $Message, (Format-Elapsed)) -ForegroundColor Cyan
}

function Write-Info([string]$Message) {
  Write-Host ("       {0}" -f $Message) -ForegroundColor DarkGray
}

function Read-PubspecVersion {
  $line = Get-Content (Join-Path $Root 'pubspec.yaml') -Encoding UTF8 |
    Where-Object { $_ -match '^\s*version:\s*' } |
    Select-Object -First 1
  if (-not $line) { throw 'Cannot find version in pubspec.yaml' }
  $raw = ($line -replace '^\s*version:\s*', '').Trim().Trim('"').Trim("'")
  return ($raw -split '\+', 2)[0]
}

function Read-AppOutputName {
  $cmake = Join-Path $Root 'windows\CMakeLists.txt'
  $line = Get-Content $cmake -Encoding UTF8 |
    Where-Object { $_ -match 'set\(APP_OUTPUT_NAME\s+"([^"]+)"\)' } |
    Select-Object -First 1
  if ($line -match 'set\(APP_OUTPUT_NAME\s+"([^"]+)"\)') {
    return $Matches[1]
  }
  return ([string]([char]0x667A) + [char]0x6167 + [char]0x997C)
}

function Find-VcRedistDirectory {
  $searchRoots = @(
    'F:\VisualStudio',
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022'),
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2019'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2019')
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($root in $searchRoots) {
    $hit = Get-ChildItem -Path $root -Recurse -Filter 'msvcp140.dll' -ErrorAction SilentlyContinue |
      Where-Object {
        $_.FullName -match '\\x64\\' -and
        $_.FullName -match 'Microsoft\.VC\d+\.CRT'
      } |
      Select-Object -First 1
    if ($hit) {
      return $hit.Directory.FullName
    }
  }

  $sys = Join-Path $env:SystemRoot 'System32'
  $ok = $true
  foreach ($n in $VcDllNames) {
    if (-not (Test-Path (Join-Path $sys $n))) { $ok = $false }
  }
  if ($ok) { return $sys }
  return $null
}

function Copy-VcRedistDlls([string]$StageDir) {
  $dir = Find-VcRedistDirectory
  if (-not $dir) {
    throw 'Cannot find VC++ x64 runtime DLLs (msvcp140 / vcruntime140). Install VS Build Tools or VC++ Redistributable on the build PC.'
  }
  Write-Info ("VC++ DLL source: {0}" -f $dir)
  foreach ($n in $VcDllNames) {
    $src = Join-Path $dir $n
    if (-not (Test-Path $src)) {
      throw "Missing $n under $dir"
    }
    Copy-Item $src (Join-Path $StageDir $n) -Force
    Write-Info ("Bundled {0}" -f $n)
  }
}

function Get-WebView2Bootstrapper([string]$StageDir) {
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  $cached = Join-Path $CacheDir 'MicrosoftEdgeWebView2Setup.exe'
  if (-not (Test-Path $cached) -or ((Get-Item $cached).Length -lt 100KB)) {
    Write-Info 'Downloading WebView2 Evergreen Bootstrapper...'
    Write-Info $WebView2BootstrapUrl
    try {
      Invoke-WebRequest -Uri $WebView2BootstrapUrl -OutFile $cached -UseBasicParsing
    } catch {
      # Fallback for older PowerShell / TLS issues
      $wc = New-Object System.Net.WebClient
      $wc.DownloadFile($WebView2BootstrapUrl, $cached)
    }
  } else {
    Write-Info 'Using cached WebView2 bootstrapper'
  }
  if (-not (Test-Path $cached) -or ((Get-Item $cached).Length -lt 100KB)) {
    throw 'Failed to download WebView2 bootstrapper. Check network and retry.'
  }
  $dest = Join-Path $StageDir 'MicrosoftEdgeWebView2Setup.exe'
  Copy-Item $cached $dest -Force
  Write-Info ('Bundled MicrosoftEdgeWebView2Setup.exe ({0:N1} KB)' -f ((Get-Item $dest).Length / 1KB))
}

function Write-PackageHelpers([string]$StageDir, [string]$AppName, [string]$Version) {
  $assets = Join-Path $Root 'scripts\package_assets'
  $utf8Bom = New-Object System.Text.UTF8Encoding $true

  $readmeSrc = Join-Path $assets 'README.zh-CN.txt'
  if (-not (Test-Path $readmeSrc)) {
    throw "Missing package asset: $readmeSrc"
  }
  $readmeText = [System.IO.File]::ReadAllText($readmeSrc, $utf8Bom)
  $readmeText = $readmeText.Replace('{{VERSION}}', $Version)
  $readmeDest = Join-Path $StageDir ([string]([char]0x4F7F) + [char]0x7528 + [char]0x8BF4 + [char]0x660E + '.txt')
  [System.IO.File]::WriteAllText($readmeDest, $readmeText, $utf8Bom)
  Write-Info ('Wrote {0}' -f (Split-Path $readmeDest -Leaf))

  $batSrc = Get-ChildItem $assets -Filter '*.bat' | Select-Object -First 1
  if (-not $batSrc) {
    throw "Missing install-deps .bat under $assets"
  }
  $batDest = Join-Path $StageDir $batSrc.Name
  Copy-Item $batSrc.FullName $batDest -Force
  Write-Info ('Wrote {0}' -f $batSrc.Name)
}

function Invoke-FlutterBuildRelease {
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $flutter) {
    throw 'flutter not found in PATH. Install Flutter and reopen the terminal.'
  }

  Write-Info 'Building... first run after clean may take several minutes.'
  Write-Info 'Flutter logs will stream below. Please wait until SUCCESS appears.'
  Write-Host ''

  $buildStarted = Get-Date
  & flutter build windows --release
  $code = $LASTEXITCODE

  if ($null -eq $code) { $code = 0 }
  if ($code -ne 0) {
    throw ('flutter build failed, exit code {0} (step elapsed {1})' -f $code, (Format-Elapsed $buildStarted))
  }

  Write-Info ('Build finished, step elapsed {0}' -f (Format-Elapsed $buildStarted))
}

function Wait-BeforeExit {
  if ($NoPause) { return }
  Write-Host ''
  Write-Host 'Done. Press Enter to close this window...' -ForegroundColor White
  try {
    $null = [Console]::ReadLine()
  } catch {
    Read-Host 'Press Enter to close'
  }
}

if (-not $env:ProgramFiles) { $env:ProgramFiles = 'C:\Program Files' }
if (-not ${env:ProgramFiles(x86)}) {
  ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'
}

try {
  $Version = Read-PubspecVersion
  $AppName = Read-AppOutputName
  $ReleaseDir = Join-Path $Root 'build\windows\x64\runner\Release'
  $DistDir = Join-Path $Root 'dist'
  $ZipVersioned = Join-Path $DistDir ('{0}-windows-x64-v{1}.zip' -f $AppName, $Version)
  $ZipLatest = Join-Path $DistDir ('{0}-windows-x64.zip' -f $AppName)

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Host ('  {0}  Windows package' -f $AppName) -ForegroundColor Cyan
  Write-Host ('  Version: {0}' -f $Version) -ForegroundColor Cyan
  Write-Host ('  Start:   {0}' -f $script:StartedAt.ToString('HH:mm:ss')) -ForegroundColor Cyan
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Info $Root

  Write-Step 'Prepare'
  Write-Info ('SkipBuild = {0}' -f [bool]$SkipBuild)

  if (-not $SkipBuild) {
    Write-Step 'Build Release (flutter build windows --release)'
    Invoke-FlutterBuildRelease
  } else {
    Write-Step 'Skip build, use existing Release output'
  }

  Write-Step 'Verify output'
  $DisplayExe = Join-Path $ReleaseDir ('{0}.exe' -f $AppName)
  $MirrorExe = Join-Path $ReleaseDir 'fool_ai.exe'
  if (-not (Test-Path $DisplayExe)) {
    throw "Missing display exe: $DisplayExe (build failed or APP_OUTPUT_NAME mismatch)"
  }
  if (-not (Test-Path (Join-Path $ReleaseDir 'data'))) {
    throw 'Missing data/ under Release. Install step may have failed; rebuild without -SkipBuild.'
  }
  $releaseSize = [math]::Round(
    ((Get-ChildItem $ReleaseDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
  Write-Info ('Found {0}  (Release ~ {1} MB)' -f (Split-Path $DisplayExe -Leaf), $releaseSize)

  Write-Step 'Stage app files'
  New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
  $Stage = Join-Path $DistDir ('.stage-{0}' -f $Version)
  if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Stage | Out-Null
  Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $Stage -Recurse -Force
  if (Test-Path (Join-Path $Stage 'fool_ai.exe')) {
    Remove-Item (Join-Path $Stage 'fool_ai.exe') -Force
    Write-Info 'Removed fool_ai.exe from package'
  }

  Write-Step 'Bundle VC++ runtime DLLs + WebView2 installer + readme'
  Copy-VcRedistDlls -StageDir $Stage
  Get-WebView2Bootstrapper -StageDir $Stage
  Write-PackageHelpers -StageDir $Stage -AppName $AppName -Version $Version
  $stageFiles = (Get-ChildItem $Stage -Recurse -File).Count
  Write-Info ('Staged files: {0}' -f $stageFiles)

  Write-Step 'Compress zip'
  foreach ($zip in @($ZipVersioned, $ZipLatest)) {
    if (Test-Path $zip) { Remove-Item $zip -Force }
  }
  Write-Info ('Writing {0}' -f $ZipVersioned)
  Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $ZipVersioned -Force
  Copy-Item $ZipVersioned $ZipLatest -Force
  Remove-Item $Stage -Recurse -Force

  $sizeMb = [math]::Round((Get-Item $ZipVersioned).Length / 1MB, 2)
  $total = Format-Elapsed

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Green
  Write-Host '  SUCCESS' -ForegroundColor Green
  Write-Host '========================================' -ForegroundColor Green
  Write-Host ('  Elapsed:     {0}' -f $total)
  Write-Host ('  Local exe:   {0}' -f $DisplayExe)
  if (Test-Path $MirrorExe) {
    Write-Host ('  Dev exe:     {0}  (flutter run only; not in zip)' -f $MirrorExe)
  }
  Write-Host ('  Version zip: {0}  ({1} MB)' -f $ZipVersioned, $sizeMb)
  Write-Host ('  Latest zip:  {0}' -f $ZipLatest)
  Write-Host ''
  Write-Host '  Package includes: VC++ DLLs, WebView2 setup, readme, install-deps bat.' -ForegroundColor DarkGray
  Write-Host ''
}
catch {
  $script:ExitCode = 1
  Write-Host ''
  Write-Host '========================================' -ForegroundColor Red
  Write-Host '  FAILED' -ForegroundColor Red
  Write-Host '========================================' -ForegroundColor Red
  Write-Host ('  Elapsed: {0}' -f (Format-Elapsed)) -ForegroundColor Red
  Write-Host ('  Error:   {0}' -f $_.Exception.Message) -ForegroundColor Red
  Write-Host ''
}
finally {
  Wait-BeforeExit
  exit $script:ExitCode
}