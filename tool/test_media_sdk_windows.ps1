#Requires -Version 7.0
[CmdletBinding()]
param([string]$FlutterCommand = 'flutter')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'This test requires an interactive Windows desktop.' }
$project = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $project '.local/media-sdk/package'
$test = Join-Path $sdk 'integration_test/windows_preview_test.dart'
$fixture = Join-Path $sdk 'tool/windows_preview_fixture.ps1'
foreach ($required in @($test, $fixture)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The configured SDK does not include the Windows validation fixture: $required"
    }
}
# Flutter classifies integration tests by their path under the host project.
# Passing a test outside integration_test runs it without native plugins.
$directory = Join-Path $project 'integration_test/.sdk-validation'
$entry = Join-Path $directory 'windows_preview_test.dart'
foreach ($parent in @($project, (Join-Path $project 'integration_test'), $directory)) {
    $item = Get-Item -LiteralPath $parent -Force -ErrorAction Ignore
    if ($item -and (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Refusing a redirected test entry directory: $parent"
    }
}
if (Test-Path -LiteralPath $entry) { throw "An existing test entry will not be overwritten: $entry" }
$body = @'
import '../../.local/media-sdk/package/integration_test/windows_preview_test.dart' as sdk;
void main() => sdk.main();
'@
$oldFixture = $env:SHARE_HUB_PREVIEW_FIXTURE
$testExit = 1
$buildExit = 1
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Set-Content -LiteralPath $entry -Value $body -Encoding utf8NoBOM
Push-Location -LiteralPath $project
try {
    $env:SHARE_HUB_PREVIEW_FIXTURE = $fixture
    & $FlutterCommand test integration_test/.sdk-validation/windows_preview_test.dart -d windows --no-pub --reporter expanded
    $testExit = $LASTEXITCODE
} finally {
    $env:SHARE_HUB_PREVIEW_FIXTURE = $oldFixture
    try {
        # Delete only the owned shim; never recursively delete SDK links/files.
        if ((Get-Content -LiteralPath $entry -Raw).Trim() -eq $body.Trim()) {
            Remove-Item -LiteralPath $entry
        } else {
            Write-Warning "Test entry changed during validation; retained at $entry"
        }
        # Native integration tests replace the Debug executable's Dart entry.
        # Restore the normal application even if the capture assertions fail.
        & $FlutterCommand build windows --debug --no-pub
        $buildExit = $LASTEXITCODE
    } finally { Pop-Location }
}
if ($buildExit -ne 0) { throw 'Normal Windows application rebuild failed; the Debug executable is not ready.' }
if ($testExit -ne 0) { throw 'Windows SDK capture validation failed. The normal application has been rebuilt.' }
