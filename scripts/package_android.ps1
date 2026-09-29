#Requires -Version 5.1
<#
.SYNOPSIS
  Build a release APK and copy it to dist with the Android version in the filename.

.PARAMETER SkipBuild
  Skip flutter build; only copy an existing app-release.apk.

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
$script:StepCount = 4
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

function Read-AndroidVersion {
  $gradle = Join-Path $Root 'android\app\build.gradle.kts'
  $nameLine = Get-Content $gradle -Encoding UTF8 |
    Where-Object { $_ -match '^\s*versionName\s*=' } |
    Select-Object -First 1
  $codeLine = Get-Content $gradle -Encoding UTF8 |
    Where-Object { $_ -match '^\s*versionCode\s*=' } |
    Select-Object -First 1
  if (-not $nameLine) { throw 'Cannot find versionName in android/app/build.gradle.kts' }
  if ($nameLine -notmatch 'versionName\s*=\s*"([^"]+)"') {
    throw "Cannot parse versionName from: $nameLine"
  }
  $versionName = $Matches[1]
  $versionCode = 1
  if ($codeLine -and $codeLine -match 'versionCode\s*=\s*(\d+)') {
    $versionCode = [int]$Matches[1]
  }
  return @{ Name = $versionName; Code = $versionCode }
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

function Invoke-FlutterBuildApk([string]$VersionName, [int]$VersionCode) {
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $flutter) {
    throw 'flutter not found in PATH. Install Flutter and reopen the terminal.'
  }

  $symbolDir = Join-Path $Root 'build\symbols\android'
  New-Item -ItemType Directory -Force -Path $symbolDir | Out-Null

  Write-Info 'Building obfuscated APK... first run after clean may take several minutes.'
  Write-Info 'Dart symbols are written outside the APK. Do not publish that folder.'
  Write-Info 'Flutter logs will stream below. Please wait until SUCCESS appears.'
  Write-Host ''

  $buildStarted = Get-Date
  & flutter build apk --release --obfuscate "--split-debug-info=$symbolDir" "--build-name=$VersionName" "--build-number=$VersionCode"
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  if ($code -ne 0) {
    throw ('flutter build apk failed, exit code {0} (step elapsed {1})' -f $code, (Format-Elapsed $buildStarted))
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

try {
  $ver = Read-AndroidVersion
  $Version = $ver.Name
  $VersionCode = $ver.Code
  $AppName = Read-AppOutputName
  $ApkSrc = Join-Path $Root 'build\app\outputs\flutter-apk\app-release.apk'
  $DistDir = Join-Path $Root 'dist'
  $ApkVersioned = Join-Path $DistDir ('{0}-android-v{1}.apk' -f $AppName, $Version)
  $ApkLatest = Join-Path $DistDir ('{0}-android.apk' -f $AppName)

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Host ('  {0}  Android APK' -f $AppName) -ForegroundColor Cyan
  Write-Host ('  Version: {0}  (versionCode {1})' -f $Version, $VersionCode) -ForegroundColor Cyan
  Write-Host ('  Start:   {0}' -f $script:StartedAt.ToString('HH:mm:ss')) -ForegroundColor Cyan
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Info $Root

  Write-Step 'Prepare'
  Write-Info ('SkipBuild = {0}' -f [bool]$SkipBuild)

  if (-not $SkipBuild) {
    Write-Step 'Build obfuscated Release APK'
    Invoke-FlutterBuildApk -VersionName $Version -VersionCode $VersionCode
  } else {
    Write-Step 'Skip build, use existing app-release.apk'
  }

  Write-Step 'Verify APK'
  if (-not (Test-Path $ApkSrc)) {
    throw "Missing APK: $ApkSrc"
  }
  $srcMb = [math]::Round((Get-Item $ApkSrc).Length / 1MB, 2)
  Write-Info ('Found app-release.apk  (~ {0} MB)' -f $srcMb)

  Write-Step 'Copy to dist'
  New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
  Copy-Item $ApkSrc $ApkVersioned -Force
  Copy-Item $ApkSrc $ApkLatest -Force
  $symbolSrc = Join-Path $Root 'build\symbols\android'
  $symbolDest = Join-Path $DistDir ('symbols\android-v{0}' -f $Version)
  if (Test-Path $symbolSrc) {
    if (Test-Path $symbolDest) { Remove-Item $symbolDest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $symbolDest) | Out-Null
    Copy-Item $symbolSrc $symbolDest -Recurse -Force
    Write-Info ('Dart symbols: {0}' -f $symbolDest)
  }
  $mappingSrc = Join-Path $Root 'build\app\outputs\mapping\release\mapping.txt'
  if (Test-Path $mappingSrc) {
    $mappingDest = Join-Path $symbolDest 'mapping.txt'
    New-Item -ItemType Directory -Force -Path $symbolDest | Out-Null
    Copy-Item $mappingSrc $mappingDest -Force
    Write-Info ('R8 mapping: {0}' -f $mappingDest)
  }
  $outMb = [math]::Round((Get-Item $ApkVersioned).Length / 1MB, 2)

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Green
  Write-Host '  SUCCESS' -ForegroundColor Green
  Write-Host '========================================' -ForegroundColor Green
  Write-Host ('  Elapsed:     {0}' -f (Format-Elapsed))
  Write-Host ('  Version APK: {0}  ({1} MB)' -f $ApkVersioned, $outMb)
  Write-Host ('  Latest APK:  {0}' -f $ApkLatest)
  Write-Host ('  Symbols:     {0}' -f (Join-Path $DistDir ('symbols\android-v{0}' -f $Version)))
  Write-Host '  Keep the symbols folder private. It is not inside the APK.' -ForegroundColor DarkGray
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
