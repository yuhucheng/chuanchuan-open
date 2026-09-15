#Requires -Version 7.0
<#
.SYNOPSIS
Creates local Flutter plugin junctions without changing Windows Developer Mode.
.DESCRIPTION
Run from any working directory after flutter pub get has generated plugin metadata.
Only windows/flutter/ephemeral/.plugin_symlinks beneath this script's project is
written. Existing files, directories and conflicting links are never replaced.
Flutter can recreate the links when dependencies change. After preparing links,
run flutter pub get again with unchanged dependencies to finish generating plugin
registrants, then use flutter build windows --debug --no-pub.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-NormalPath([string] $Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Assert-PlainDirectoryPath([string] $Path) {
    # Check every existing ancestor so a parent junction cannot redirect writes.
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $entry = Get-Item -LiteralPath $current -Force -ErrorAction Ignore
        if ($entry) {
            if (-not $entry.PSIsContainer) {
                throw "Expected a directory: $current"
            }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a reparse point in the link destination path: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-LinkTarget([string] $LinkPath, [string] $TargetPath) {
    $entry = Get-Item -LiteralPath $LinkPath -Force -ErrorAction Ignore
    if (-not $entry) { return }
    if (-not $entry.PSIsContainer -or $entry.LinkType -notin @('Junction', 'SymbolicLink')) {
        throw "Plugin path conflict; existing entry will not be replaced: $LinkPath"
    }
    $targets = @($entry.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($targets[0])) {
        throw "Plugin link conflict; target cannot be verified: $LinkPath"
    }
    $actualTarget = $targets[0]
    if (-not [IO.Path]::IsPathFullyQualified($actualTarget)) {
        $actualTarget = Join-Path ([IO.Path]::GetDirectoryName($LinkPath)) $actualTarget
    }
    if (-not [string]::Equals((Get-NormalPath $actualTarget), $TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Plugin link target conflict; existing link will not be replaced: $LinkPath"
    }
}

if (-not $IsWindows) { throw 'This script requires Windows.' }
$projectRoot = Get-NormalPath (Join-Path $PSScriptRoot '..')
$linkRoot = Get-NormalPath (Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks')
Assert-PlainDirectoryPath $linkRoot
foreach ($marker in @('pubspec.yaml', 'windows/CMakeLists.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $marker) -PathType Leaf)) {
        throw "Expected a Flutter Windows project beside this script: missing $marker"
    }
}
$metadataPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw 'Plugin metadata is missing. Run flutter pub get first, then rerun this script.'
}
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($null -eq $metadata.plugins -or $null -eq $metadata.plugins.windows) {
    throw 'Plugin metadata does not contain a Windows plugin list.'
}

$prepared = [Collections.Generic.List[object]]::new()
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($plugin in @($metadata.plugins.windows)) {
    if ($plugin.name -isnot [string] -or $plugin.name -cnotmatch '^[a-z_][a-z0-9_]*$' -or
        $plugin.name -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
        throw 'Invalid Windows plugin name in metadata.'
    }
    if (-not $names.Add($plugin.name)) { throw "Duplicate Windows plugin name: $($plugin.name)" }
    if ($plugin.path -isnot [string] -or $plugin.path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Plugin package directory must use an absolute local drive path: $($plugin.name)"
    }
    $targetPath = Get-NormalPath $plugin.path
    if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
        throw "Plugin package directory does not exist: $targetPath"
    }
    $linkPath = Get-NormalPath (Join-Path $linkRoot $plugin.name)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($linkPath), $linkRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Plugin name escapes the link directory: $($plugin.name)"
    }
    Assert-LinkTarget $linkPath $targetPath
    $prepared.Add(@{ Name = $plugin.name; Path = $linkPath; Target = $targetPath })
}

# Validate the whole list before creating any directories or links.
Assert-PlainDirectoryPath $linkRoot
[IO.Directory]::CreateDirectory($linkRoot) | Out-Null
foreach ($plugin in $prepared) {
    Assert-PlainDirectoryPath $linkRoot
    Assert-LinkTarget $plugin.Path $plugin.Target
    if (-not (Get-Item -LiteralPath $plugin.Path -Force -ErrorAction Ignore)) {
        New-Item -ItemType Junction -Path $linkRoot -Name $plugin.Name -Target $plugin.Target | Out-Null
    }
    Write-Output "Ready: $($plugin.Name)"
}
Write-Output 'Plugin links are ready. Run flutter pub get again to finish generating plugin registrants.'
Write-Output 'Keep dependencies unchanged for that retry, then build with flutter build windows --debug --no-pub.'
Write-Output 'If dependency changes make flutter pub get recreate links, rerun this script and retry pub get.'
