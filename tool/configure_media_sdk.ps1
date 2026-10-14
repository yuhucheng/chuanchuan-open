#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdkPath,
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$FlutterCommand = 'flutter',
    [ValidateSet('windows', 'macos')][string]$TargetPlatform,
    [string]$CandidateManifestSha256,
    [string]$CandidateConsumerPolicy,
    [string]$PythonCommand = 'python3',
    [switch]$SkipPubGet
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Package([string]$Path, [string]$Name) {
    $manifest = Join-Path $Path 'pubspec.yaml'
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf) -or
        (Get-Content -LiteralPath $manifest -Raw) -notmatch ('(?m)^name:\s*' + [regex]::Escape($Name) + '\s*$')) {
        throw "Expected package $Name at $Path"
    }
}
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
if (!(Test-Path -LiteralPath $SdkPath -PathType Container)) {
    throw "SDK package directory is missing: $SdkPath"
}
$sdk = (Resolve-Path -LiteralPath $SdkPath).Path
Assert-Package $project 'share_hub_open'
try { Assert-Package $sdk 'share_hub_media_sdk' }
catch { throw "SDK package layout is invalid: $($_.Exception.Message)" }
if (!(Test-Path -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -PathType Leaf)) {
    throw 'SDK package layout is invalid: entry library is missing.'
}
# This is a development-link layout check, not a native ABI/signature check.
# Resolve the target before creating destination directories or changing links.
$target = if ($TargetPlatform) { $TargetPlatform.ToLowerInvariant() }
          elseif ($IsWindows) { 'windows' }
          elseif ($IsMacOS) { 'macos' }
          else { throw 'Specify -TargetPlatform windows or macos on this host.' }
$hooks = if ($target -eq 'windows') { @('windows/CMakeLists.txt') }
         else { @('macos/share_hub_media_sdk.podspec', 'macos/share_hub_media_sdk/Package.swift') }
$hasHook = $false
foreach ($hook in $hooks) {
    if (Test-Path -LiteralPath (Join-Path $sdk $hook) -PathType Leaf) { $hasHook = $true }
}
if (!$hasHook) {
    throw "SDK target layout is unavailable for ${target}: expected $($hooks -join ' or ')."
}
# Explicit internal-candidate preflight uses the caller's pinned identity and
# policy. All checks precede link creation or reuse and never load SDK binaries.
if ([bool]$CandidateManifestSha256 -ne [bool]$CandidateConsumerPolicy) {
    throw 'Candidate preflight requires both -CandidateManifestSha256 and -CandidateConsumerPolicy.'
}
if ($CandidateManifestSha256) {
    if ($CandidateManifestSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Candidate manifest checksum must be a lowercase SHA256 digest.'
    }
    $preflightTool = Join-Path $PSScriptRoot 'sdk_candidate_preflight.py'
    try {
        $preflightOutput = & $PythonCommand $preflightTool $sdk $CandidateConsumerPolicy $project `
            --target $target --expected-manifest-sha256 $CandidateManifestSha256
        if ($LASTEXITCODE -ne 0) { throw "Rejected candidate: $($preflightOutput -join ' ')" }
        $preflight = ($preflightOutput -join "`n") | ConvertFrom-Json
        if (!$preflight.ok -or $preflight.installable) { throw 'Invalid candidate preflight response.' }
    } catch {
        throw "SDK candidate preflight failed before link configuration. Use Python with tool/sdk_schema_requirements.txt installed. $($_.Exception.Message)"
    }
    Write-Output 'Internal candidate declarations and inventory checked; publisher trust, runtime and release readiness remain unverified.'
}
$localRoot = Join-Path $project '.local'
$sdkRoot = Join-Path $localRoot 'media-sdk'
# Keep link creation inside the real project, not redirected parent directories.
foreach ($parent in @($project, $localRoot, $sdkRoot)) {
    $entry = Get-Item -LiteralPath $parent -Force -ErrorAction Ignore
    if ($entry -and (!$entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Refusing a redirected or non-directory SDK destination parent: $parent"
    }
}
foreach ($oldFile in @('pubspec_overrides.yaml', '.local/media-sdk/state.json', '.local/media-sdk/main.dart', '.local/media-sdk/pubspec.yaml.original')) {
    if (Test-Path -LiteralPath (Join-Path $project $oldFile)) {
        throw "Existing local SDK configuration requires migration; it will not be overwritten: $oldFile"
    }
}
$linkPath = Join-Path $sdkRoot 'package'
$existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction Ignore
if ($existing) {
    if ($existing.LinkType -notin @('Junction', 'SymbolicLink')) {
        throw "SDK destination already exists and will not be replaced: $linkPath"
    }
    $targets = @($existing.Target)
    if ($targets.Count -ne 1) { throw 'Cannot verify existing SDK link.' }
    $target = $targets[0]
    if (![IO.Path]::IsPathFullyQualified($target)) { $target = Join-Path $sdkRoot $target }
    if ([IO.Path]::GetFullPath($target).TrimEnd('\','/') -ne $sdk.TrimEnd('\','/')) {
        throw 'Existing SDK link points elsewhere; it will not be replaced.'
    }
} else {
    New-Item -ItemType Directory -Force -Path $sdkRoot | Out-Null
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $linkPath -Target $sdk | Out-Null
}
if (!$SkipPubGet) {
    Push-Location -LiteralPath $project
    try {
        & $FlutterCommand pub get
        if ($LASTEXITCODE -ne 0) { throw 'SDK linked but pub get failed. Resolve the error and rerun; the SDK link is retained.' }
    } finally { Pop-Location }
}
Write-Output 'SDK configured. Use the normal flutter run/build entrypoint (lib/main.dart).'
