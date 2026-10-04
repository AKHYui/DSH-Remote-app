# Checks a built APK before it is handed to anyone.
#
# Motivated by a real escape: the release APK shipped with no INTERNET
# permission, because Flutter's template declares it only in the debug and
# profile manifests. Every network call failed with "network is unreachable",
# while the debug build — the only one ever run during development — worked
# fine. Nothing in the test suite could see this; only the artifact could.
#
# Usage:
#   pwsh -File tool/verify_apk.ps1 -Apk build/app/outputs/flutter-apk/app-release.apk
#
# Exits non-zero when a required permission is missing.

param(
  [Parameter(Mandatory = $true)][string]$Apk,
  [string]$AndroidSdk = 'D:\Android\Sdk'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Apk)) {
  Write-Output "FAIL  APK not found: $Apk"
  exit 2
}

$analyzer = Join-Path $AndroidSdk 'cmdline-tools\latest\bin\apkanalyzer.bat'
if (-not (Test-Path $analyzer)) {
  Write-Output "FAIL  apkanalyzer not found at $analyzer"
  exit 2
}

$apkPath = (Resolve-Path $Apk).Path
$sizeMb = [math]::Round((Get-Item $apkPath).Length / 1MB, 1)
Write-Output "checking $apkPath ($sizeMb MB)"

$failures = @()

# Every build variant is a network client, so this must be present in all of them.
$permissions = & $analyzer manifest permissions $apkPath 2>&1
$required = @('android.permission.INTERNET')
foreach ($permission in $required) {
  if ($permissions -match [regex]::Escape($permission)) {
    Write-Output "  PASS  $permission"
  } else {
    Write-Output "  FAIL  $permission is missing"
    $failures += $permission
  }
}

# A debug-signed release is fine for sideloading but must be a conscious choice.
$signature = & $analyzer manifest print $apkPath 2>&1 | Select-String -Pattern 'debuggable'
if ($signature) {
  Write-Output "  INFO  manifest declares debuggable=$($signature.Line.Trim())"
}

# Which ABIs actually made it in, so a "universal" build that is secretly
# x86_64-only cannot be handed to a phone.
$abis = & $analyzer apk features $apkPath 2>&1
$nativeLibs = (& $analyzer files list $apkPath 2>&1) |
  Select-String -Pattern '^/lib/([^/]+)/' |
  ForEach-Object { ($_ -split '/')[2] } |
  Sort-Object -Unique
if ($nativeLibs) {
  Write-Output "  INFO  native ABIs: $($nativeLibs -join ', ')"
} else {
  Write-Output "  INFO  no native libraries found"
}

if ($failures.Count -gt 0) {
  Write-Output ""
  Write-Output "FAILED: $($failures -join ', ')"
  exit 1
}

Write-Output "ok"
exit 0
