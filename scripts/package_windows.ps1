#Requires -Version 5.1
<#
.SYNOPSIS
  Build and package the Windows release (with progress).

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
$script:StepCount = 5
$script:StepIndex = 0
$script:ExitCode = 0

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

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

  Write-Step 'Stage files (exclude fool_ai.exe mirror)'
  New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
  $Stage = Join-Path $DistDir ('.stage-{0}' -f $Version)
  if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $Stage | Out-Null
  Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $Stage -Recurse -Force
  if (Test-Path (Join-Path $Stage 'fool_ai.exe')) {
    Remove-Item (Join-Path $Stage 'fool_ai.exe') -Force
    Write-Info 'Removed fool_ai.exe from package'
  }
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
  Write-Host '  Ship the whole zip, not a single exe. Target PCs need WebView2 Runtime.' -ForegroundColor DarkGray
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