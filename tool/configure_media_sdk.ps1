#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdkPath,
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$FlutterCommand = 'flutter',
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
$sdk = (Resolve-Path -LiteralPath $SdkPath).Path
Assert-Package $project 'share_hub_open'
Assert-Package $sdk 'share_hub_media_sdk'
if (!(Test-Path -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -PathType Leaf)) {
    throw 'SDK entry library is missing.'
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
