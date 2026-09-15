[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Enable')]
    [string]$SdkPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Disable')]
    [switch]$Disable,

    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$FlutterCommand = 'flutter',
    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'
$expectedProjectName = 'share_hub_open'
$expectedSdkName = 'share_hub_media_sdk'
$expectedApiName = 'share_hub_media_api'

function Get-PackageName([string]$ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Package manifest not found: $ManifestPath"
    }
    $match = [regex]::Match(
        (Get-Content -Raw -LiteralPath $ManifestPath),
        '(?m)^\s*name\s*:\s*[''\"]?([A-Za-z0-9_]+)[''\"]?\s*(?:#.*)?$'
    )
    if (-not $match.Success) { throw "Package name not found in: $ManifestPath" }
    return $match.Groups[1].Value
}

function Assert-Package([string]$Directory, [string]$ExpectedName, [string]$Label) {
    $manifest = Join-Path $Directory 'pubspec.yaml'
    $actualName = Get-PackageName $manifest
    if ($actualName -ne $ExpectedName) {
        throw "$Label must be package '$ExpectedName', but '$manifest' declares '$actualName'."
    }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8File([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Test-HasSdkDependency([string]$ManifestPath) {
    return [regex]::IsMatch(
        (Get-Content -Raw -LiteralPath $ManifestPath),
        '(?m)^\s+share_hub_media_sdk\s*:'
    )
}

function Add-SdkDependency([string]$ManifestPath) {
    $bytes = [System.IO.File]::ReadAllBytes($ManifestPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    $match = [regex]::Match($text, '(?m)^(dependencies\s*:[^\r\n]*)(\r?\n)')
    if (-not $match.Success) {
        throw "Project manifest has no top-level dependencies section: $ManifestPath"
    }
    $newline = $match.Groups[2].Value
    $managedText = $text.Insert($match.Index + $match.Length, "  share_hub_media_sdk: any$newline")
    [System.IO.File]::WriteAllText($ManifestPath, $managedText, [System.Text.UTF8Encoding]::new($hasBom))
}

function Assert-ManagedFilesUnchanged(
    [string]$StatePath,
    [string]$ManifestPath,
    [string]$BackupPath,
    [string]$OverridePath,
    [string]$EntryPath
) {
    try { $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json }
    catch { throw "Managed SDK state is unreadable; refusing to change files: $StatePath" }

    foreach ($item in @(
        @{ Path = $ManifestPath; Hash = [string]$state.managedManifestSha256; Label = 'pubspec.yaml' },
        @{ Path = $BackupPath; Hash = [string]$state.originalManifestSha256; Label = '.local/media-sdk/pubspec.yaml.original' },
        @{ Path = $OverridePath; Hash = [string]$state.overrideSha256; Label = 'pubspec_overrides.yaml' },
        @{ Path = $EntryPath; Hash = [string]$state.entrySha256; Label = '.local/media-sdk/main.dart' }
    )) {
        if (-not $item.Hash -or -not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            throw "Managed $($item.Label) is missing; refusing to erase or replace developer files."
        }
        if ((Get-Hash $item.Path) -ne $item.Hash) {
            throw "Managed $($item.Label) was edited; refusing to erase or replace it: $($item.Path)"
        }
    }
    return $state
}

function Invoke-PubGet([string]$ProjectDirectory, [string]$FailureHint) {
    if ($SkipPubGet) { return }
    Push-Location -LiteralPath $ProjectDirectory
    try {
        & $FlutterCommand pub get
        if ($LASTEXITCODE -ne 0) { throw "Flutter pub get exited with code $LASTEXITCODE." }
    }
    catch {
        throw "$($_.Exception.Message) $FailureHint"
    }
    finally { Pop-Location }
}

$project = (Resolve-Path -LiteralPath $ProjectPath).Path
Assert-Package $project $expectedProjectName 'ProjectPath'
$api = Join-Path $project 'packages/share_hub_media_api'
Assert-Package $api $expectedApiName 'Public media API path'

$overridePath = Join-Path $project 'pubspec_overrides.yaml'
$manifestPath = Join-Path $project 'pubspec.yaml'
$localDirectory = Join-Path $project '.local/media-sdk'
$entryPath = Join-Path $localDirectory 'main.dart'
$statePath = Join-Path $localDirectory 'state.json'
$backupPath = Join-Path $localDirectory 'pubspec.yaml.original'
$hasState = Test-Path -LiteralPath $statePath -PathType Leaf

if (-not $hasState) {
    $unmanaged = @($overridePath, $entryPath, $backupPath) | Where-Object { Test-Path -LiteralPath $_ }
    if ($unmanaged.Count -gt 0) {
        throw "Refusing to change unmanaged SDK integration file(s): $($unmanaged -join ', ')"
    }
    if (Test-HasSdkDependency $manifestPath) {
        throw "Refusing to change an unmanaged share_hub_media_sdk dependency in: $manifestPath"
    }
}
else {
    $null = Assert-ManagedFilesUnchanged $statePath $manifestPath $backupPath $overridePath $entryPath
}

if ($Disable) {
    if (-not $hasState) {
        Write-Host 'Media SDK integration is already disabled.'
        Invoke-PubGet $project "The integration remains disabled; retry '$FlutterCommand pub get' in '$project'."
        return
    }

    [System.IO.File]::WriteAllBytes($manifestPath, [System.IO.File]::ReadAllBytes($backupPath))
    Remove-Item -LiteralPath $overridePath
    Remove-Item -LiteralPath $entryPath
    Remove-Item -LiteralPath $backupPath
    Remove-Item -LiteralPath $statePath
    if ((Test-Path -LiteralPath $localDirectory) -and -not (Get-ChildItem -LiteralPath $localDirectory -Force)) {
        Remove-Item -LiteralPath $localDirectory
    }
    $localRoot = Join-Path $project '.local'
    if ((Test-Path -LiteralPath $localRoot) -and -not (Get-ChildItem -LiteralPath $localRoot -Force)) {
        Remove-Item -LiteralPath $localRoot
    }
    Invoke-PubGet $project "The generated files were removed; retry '$FlutterCommand pub get' in '$project'."
    Write-Host 'Media SDK integration disabled.'
    Write-Host 'Run flutter clean before the next native build if it may contain stale plugin registration artifacts.'
    return
}

$sdk = (Resolve-Path -LiteralPath $SdkPath).Path
Assert-Package $sdk $expectedSdkName 'SdkPath'

$yamlSdkPath = ConvertTo-Json -Compress ($sdk.Replace('\', '/'))
$yamlApiPath = ConvertTo-Json -Compress ($api.Replace('\', '/'))
$overrideContent = @"
# Generated by tool/configure_media_sdk.ps1. Do not edit.
dependency_overrides:
  share_hub_media_sdk:
    path: $yamlSdkPath
  share_hub_media_api:
    path: $yamlApiPath
"@
$entryContent = @"
// Generated by tool/configure_media_sdk.ps1. Do not edit.
import 'package:flutter/material.dart';
import 'package:share_hub_open/ui/client_app.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareHubApp(previewEngine: createPreviewEngine(), appTitle: 'Share Hub'));
}
"@

if (-not $hasState) {
    New-Item -ItemType Directory -Force -Path $localDirectory | Out-Null
    [System.IO.File]::WriteAllBytes($backupPath, [System.IO.File]::ReadAllBytes($manifestPath))
    Add-SdkDependency $manifestPath
}
Write-Utf8File $overridePath $overrideContent
Write-Utf8File $entryPath $entryContent
$state = [ordered]@{
    formatVersion = 2
    generator = 'tool/configure_media_sdk.ps1'
    sdkPath = $sdk
    originalManifestSha256 = Get-Hash $backupPath
    managedManifestSha256 = Get-Hash $manifestPath
    overrideSha256 = Get-Hash $overridePath
    entrySha256 = Get-Hash $entryPath
}
Write-Utf8File $statePath (($state | ConvertTo-Json) + "`n")

Invoke-PubGet $project "Generated integration files remain managed. Retry this command or run the script with -Disable."
Write-Host "Media SDK integration enabled from '$sdk'."
Write-Host 'Run flutter clean before the next native build if it may contain stale plugin registration artifacts.'
