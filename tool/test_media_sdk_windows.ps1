#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$FlutterCommand = 'flutter',
    [ValidateSet('preview', 'negotiation', 'video', 'coexistence')][string]$Suite = 'preview',
    [string]$NativePreviewDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'This test requires an interactive Windows desktop.' }
$project = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $project '.local/media-sdk/package'
$testName = switch ($Suite) {
    'preview' { 'windows_preview_test.dart' }
    'negotiation' { 'native_video_negotiation_test.dart' }
    'video' { 'windows_video_link_test.dart' }
    'coexistence' { 'windows_native_preview_coexistence_test.dart' }
}
$test = Join-Path $sdk "integration_test/$testName"
$fixture = Join-Path $sdk 'tool/windows_preview_fixture.ps1'
foreach ($required in @($test, $fixture)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The configured SDK does not include the Windows validation fixture: $required"
    }
}
if ($Suite -eq 'coexistence') {
    if (!$NativePreviewDirectory) { throw 'Coexistence requires an explicitly built native preview probe directory.' }
    $NativePreviewDirectory = (Resolve-Path -LiteralPath $NativePreviewDirectory).Path
    foreach ($name in @('draft_media.dll', 'windows_preview_flutter_probe.dll', 'libwebrtc.dll')) {
        if (!(Test-Path -LiteralPath (Join-Path $NativePreviewDirectory $name) -PathType Leaf)) {
            throw "Native preview probe is missing $name. Build the matching SDK candidate first."
        }
    }
    $identityPath = Join-Path $NativePreviewDirectory 'preview-probe.json'
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ($identity.schemaVersion -ne 1 -or $identity.kind -cne 'internal-native-preview-test' -or
        $identity.architecture -ine [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -or
        $identity.configuration -notin @('Debug', 'Release')) {
        throw 'Native preview test identity is incompatible with this host.'
    }
    foreach ($name in @('draft_media.dll', 'windows_preview_flutter_probe.dll', 'libwebrtc.dll')) {
        $expected = $identity.libraries.$name
        $actual = (Get-FileHash -LiteralPath (Join-Path $NativePreviewDirectory $name) -Algorithm SHA256).Hash
        if ($expected -cnotmatch '^[a-f0-9]{64}$' -or $actual -ine $expected) {
            throw "Native preview test library identity differs: $name"
        }
    }
    $sdkRoot = [IO.Path]::GetFullPath($sdk).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $sourceEntries = @($identity.sources.PSObject.Properties)
    if ($sourceEntries.Count -eq 0) { throw 'Native preview test source identities are missing.' }
    foreach ($source in $sourceEntries) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $sdkRoot $source.Name))
        if ([IO.Path]::IsPathRooted($source.Name) -or $source.Name.Contains(':') -or
            !$sourcePath.StartsWith($sdkRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Native preview test source path must stay inside the configured SDK.'
        }
        $actual = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        if ($source.Value -cnotmatch '^[a-f0-9]{64}$' -or $actual -ine $source.Value) {
            throw "Native preview source changed since its build: $($source.Name)"
        }
    }
}
# Flutter classifies integration tests by their path under the host project.
# Passing a test outside integration_test runs it without native plugins.
$directory = Join-Path $project 'integration_test/.sdk-validation'
$entry = Join-Path $directory $testName
foreach ($parent in @($project, (Join-Path $project 'integration_test'), $directory)) {
    $item = Get-Item -LiteralPath $parent -Force -ErrorAction Ignore
    if ($item -and (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Refusing a redirected test entry directory: $parent"
    }
}
if (Test-Path -LiteralPath $entry) { throw "An existing test entry will not be overwritten: $entry" }
$body = @"
import '../../.local/media-sdk/package/integration_test/$testName' as sdk;
void main() => sdk.main();
"@
$oldFixture = $env:SHARE_HUB_PREVIEW_FIXTURE
$oldNativePreview = $env:SHARE_HUB_NATIVE_PREVIEW
$testExit = 1
$buildExit = 1
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Set-Content -LiteralPath $entry -Value $body -Encoding utf8NoBOM
Push-Location -LiteralPath $project
try {
    $env:SHARE_HUB_PREVIEW_FIXTURE = $fixture
    if ($Suite -eq 'coexistence') { $env:SHARE_HUB_NATIVE_PREVIEW = $NativePreviewDirectory }
    & $FlutterCommand test "integration_test/.sdk-validation/$testName" -d windows --no-pub --reporter expanded
    $testExit = $LASTEXITCODE
} finally {
    $env:SHARE_HUB_PREVIEW_FIXTURE = $oldFixture
    $env:SHARE_HUB_NATIVE_PREVIEW = $oldNativePreview
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
if ($testExit -ne 0) { throw "Windows SDK $Suite validation failed. The normal application has been rebuilt." }
