#Requires -Version 7.0
# Host-side wrapper for the SDK source probe. Native integration tests must run
# from the application project, so this shim imports the SDK probe in place,
# supplies the display probe and the current shell path, and restores the normal
# Debug entry afterwards. It is read-only: the probe captures nothing.
[CmdletBinding()]
param(
    [string]$FlutterCommand = 'flutter',
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'This probe requires an interactive Windows desktop.' }
$project = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $project '.local/media-sdk/package'
$probe = Join-Path $sdk 'integration_test/windows_source_probe_test.dart'
$monitorProbe = Join-Path $sdk 'tool/windows_monitor_probe.ps1'
foreach ($required in @($probe, $monitorProbe)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The configured SDK does not include the source probe: $required"
    }
}
if (!$LogPath) { $LogPath = Join-Path $project 'build/windows-source-probe.log' }
# Flutter classifies integration tests by their path under the host project.
# Passing a test outside integration_test runs it without native plugins.
$directory = Join-Path $project 'integration_test/.sdk-validation'
$entry = Join-Path $directory 'windows_source_probe_test.dart'
foreach ($parent in @($project, (Join-Path $project 'integration_test'), $directory)) {
    $item = Get-Item -LiteralPath $parent -Force -ErrorAction Ignore
    if ($item -and (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Refusing a redirected test entry directory: $parent"
    }
}
if (Test-Path -LiteralPath $entry) { throw "An existing test entry will not be overwritten: $entry" }
$body = @'
import '../../.local/media-sdk/package/integration_test/windows_source_probe_test.dart' as sdk;
void main() => sdk.main();
'@
$shell = (Get-Process -Id $PID).Path
$oldMonitor = $env:SHARE_HUB_MONITOR_PROBE
$oldShell = $env:SHARE_HUB_POWERSHELL
$testExit = 1
$buildExit = 1
New-Item -ItemType Directory -Force -Path $directory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
Set-Content -LiteralPath $entry -Value $body -Encoding utf8NoBOM
Push-Location -LiteralPath $project
try {
    $env:SHARE_HUB_MONITOR_PROBE = (Resolve-Path -LiteralPath $monitorProbe).Path
    $env:SHARE_HUB_POWERSHELL = $shell
    Write-Host "Probe log: $LogPath"
    & $FlutterCommand test integration_test/.sdk-validation/windows_source_probe_test.dart -d windows --no-pub --reporter expanded 2>&1 |
        Tee-Object -FilePath $LogPath
    $testExit = $LASTEXITCODE
} finally {
    $env:SHARE_HUB_MONITOR_PROBE = $oldMonitor
    $env:SHARE_HUB_POWERSHELL = $oldShell
    try {
        # Delete only the owned shim; never recursively delete SDK links/files.
        if ((Get-Content -LiteralPath $entry -Raw).Trim() -eq $body.Trim()) {
            Remove-Item -LiteralPath $entry
        } else {
            Write-Warning "Probe entry changed during validation; retained at $entry"
        }
        # Native integration tests replace the Debug executable's Dart entry.
        # Restore the normal application so the Debug build stays usable.
        & $FlutterCommand build windows --debug --no-pub
        $buildExit = $LASTEXITCODE
    } finally { Pop-Location }
}
if ($buildExit -ne 0) { throw 'Normal Windows application rebuild failed; the Debug executable is not ready.' }
if ($testExit -ne 0) { throw "Source probe failed. Output is retained at $LogPath." }
Write-Host "Source probe finished. Full output: $LogPath"
