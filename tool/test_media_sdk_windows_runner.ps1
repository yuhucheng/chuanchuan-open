#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'This runner preflight regression requires Windows.' }
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $temporaryRoot ('sharehub-runner-' + [guid]::NewGuid().ToString('N'))
$runner = Join-Path $fixture 'tool/test_media_sdk_windows.ps1'
$sdk = Join-Path $fixture '.local/media-sdk/package'
$candidate = Join-Path $fixture 'candidate'
try {
    foreach ($directory in @((Split-Path $runner), "$sdk/integration_test", "$sdk/tool", $candidate)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'test_media_sdk_windows.ps1') -Destination $runner
    Set-Content -LiteralPath "$sdk/integration_test/windows_native_preview_coexistence_test.dart" -Value 'unused fixture'
    Set-Content -LiteralPath "$sdk/tool/windows_preview_fixture.ps1" -Value 'unused fixture'
    Set-Content -LiteralPath "$sdk/native-input.txt" -Value 'original source'
    $libraries = [ordered]@{}
    foreach ($name in @('draft_media.dll', 'windows_preview_flutter_probe.dll', 'libwebrtc.dll')) {
        Set-Content -LiteralPath (Join-Path $candidate $name) -Value 'not a loadable library'
        $libraries[$name] = (Get-FileHash -LiteralPath (Join-Path $candidate $name)).Hash.ToLowerInvariant()
    }
    $identity = [ordered]@{
        schemaVersion = 1
        kind = 'internal-native-preview-test'
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        configuration = 'Release'
        libraries = $libraries
        sources = [ordered]@{ 'native-input.txt' = (Get-FileHash -LiteralPath "$sdk/native-input.txt").Hash.ToLowerInvariant() }
    }
    function Save-Identity {
        $identity | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$candidate/preview-probe.json" -Encoding utf8NoBOM
    }
    function Expect-Refusal([string]$expected) {
        $result = & pwsh -NoProfile -File $runner -Suite coexistence -NativePreviewDirectory $candidate -FlutterCommand 'must-not-start-flutter' 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or !$result.Contains($expected)) { throw "Unexpected preflight result: $result" }
        if (Test-Path -LiteralPath "$fixture/integration_test/.sdk-validation") { throw 'Rejected candidate created a test shim.' }
    }
    Save-Identity
    Add-Content -LiteralPath "$candidate/draft_media.dll" -Value 'changed bytes'
    Expect-Refusal 'Native preview test library identity differs'
    Set-Content -LiteralPath "$candidate/draft_media.dll" -Value 'not a loadable library'
    Set-Content -LiteralPath "$sdk/native-input.txt" -Value 'changed source'
    Expect-Refusal 'Native preview source changed since its build'
    $identity.sources = [ordered]@{ '../../../../outside.txt' = ('0' * 64) }
    Save-Identity
    Expect-Refusal 'Native preview test source path must stay inside'
    Write-Output 'Runner preflight: changed DLL, changed source and escaping input rejected before Flutter/shim (3/3).'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $prefix = $temporaryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^sharehub-runner-[a-f0-9]{32}$') {
        throw 'Refusing cleanup outside the owned temporary fixture.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
