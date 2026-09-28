#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdkPath,
    [string]$ProjectPath = (Split-Path -Parent $PSScriptRoot),
    [string]$FlutterCommand = 'flutter',
    [switch]$SkipPubGet,
    [switch]$DevelopmentAdapter,
    [string]$ExpectedManifestSha256
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
    throw "SDK package path is missing or is not a directory: $SdkPath"
}
$sdk = (Resolve-Path -LiteralPath $SdkPath).Path
Assert-Package $project 'share_hub_open'
Assert-Package $sdk 'share_hub_media_sdk'
if (!(Test-Path -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -PathType Leaf)) {
    throw 'SDK entry library is missing.'
}
if ($DevelopmentAdapter) {
    if (Test-Path -LiteralPath (Join-Path $sdk 'sdk-release-manifest.json')) {
        throw 'Formal SDK package cannot use the development adapter exception.'
    }
    $developmentPubspec = Get-Content -LiteralPath (Join-Path $sdk 'pubspec.yaml') -Raw
    if ($developmentPubspec -notmatch '(?m)^description:\s*Private Share Hub media SDK development adapter\.\s*$' -or
        $developmentPubspec -notmatch '(?m)^publish_to:\s*none\s*$') {
        throw 'Development adapter exception is only for the marked internal source package.'
    }
}
if (!$DevelopmentAdapter) {
    $releaseManifestPath = Join-Path $sdk 'sdk-release-manifest.json'
    if (!(Test-Path -LiteralPath $releaseManifestPath -PathType Leaf)) {
        throw 'Formal SDK release manifest is missing. Use a verified release package, or pass -DevelopmentAdapter for the internal source adapter.'
    }
    if ($ExpectedManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Formal SDK requires a trusted lowercase SHA-256 digest of sdk-release-manifest.json.'
    }
    $manifestDigest = (Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifestDigest -cne $ExpectedManifestSha256) {
        throw 'SDK release manifest checksum mismatch.'
    }
    try {
        $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        throw 'Formal SDK release manifest is malformed JSON.'
    }
    if ($releaseManifest['formatVersion'] -ne 1 -or $releaseManifest['sampleOnly'] -ne $false) {
        throw 'Formal SDK release manifest has an unsupported format or is example-only.'
    }
    $sdkVersionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $sdk 'pubspec.yaml') -Raw), '(?m)^version:\s*([^\s#]+)')
    if (!$sdkVersionMatch.Success -or $releaseManifest['sdkVersion'] -cne $sdkVersionMatch.Groups[1].Value) {
        throw 'SDK version in release manifest does not match the plugin package.'
    }
    $apiPath = Join-Path $project 'packages/share_hub_media_api/pubspec.yaml'
    if (!(Test-Path -LiteralPath $apiPath -PathType Leaf)) {
        throw 'Client public media API package is missing.'
    }
    $apiMatch = [regex]::Match((Get-Content -LiteralPath $apiPath -Raw), '(?m)^version:\s*([^\s#]+)')
    if (!$apiMatch.Success) { throw 'Client public media API version is missing.' }
    $api = $releaseManifest['publicMediaApi']
    if ($api -isnot [System.Collections.IDictionary] -or $api['package'] -ne 'share_hub_media_api' -or
        @($api['verifiedVersions']) -notcontains $apiMatch.Groups[1].Value) {
        throw "SDK public media API is incompatible with client version $($apiMatch.Groups[1].Value)."
    }
    $abi = $releaseManifest['nativeAbi']
    if ($abi -isnot [System.Collections.IDictionary] -or $abi['major'] -ne 1 -or $abi['minor'] -lt 0 -or
        $abi['callingConvention'] -ne 'cdecl') {
        throw 'SDK native ABI is incompatible with the client requirement 1.0 cdecl.'
    }
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $targetId = if ($IsWindows -and $architecture -in @('x64', 'arm64')) {
        "windows-$architecture"
    } elseif ($IsMacOS -and $architecture -in @('x64', 'arm64')) {
        'macos-universal'
    } else {
        throw "SDK platform is unsupported: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) $architecture."
    }
    $targets = @($releaseManifest['targets'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] -eq $targetId })
    $artifacts = @($releaseManifest['artifacts'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['kind'] -eq 'native' -and $_['target'] -eq $targetId })
    $pluginArtifacts = @($releaseManifest['artifacts'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['kind'] -eq 'flutter-plugin' })
    if ($targets.Count -ne 1 -or $artifacts.Count -ne 1) {
        throw "SDK platform $targetId is absent or duplicated in the release manifest."
    }
    if ($pluginArtifacts.Count -ne 1 -or
        @($releaseManifest['artifacts'] | Where-Object { $_ -isnot [System.Collections.IDictionary] -or $_['sha256'] -cnotmatch '^[0-9a-f]{64}$' }).Count -gt 0) {
        throw 'SDK release artifact checksum metadata is missing or malformed.'
    }
    if ([string]::IsNullOrWhiteSpace($targets[0]['minimumOs']) -or
        [string]::IsNullOrWhiteSpace($targets[0]['buildIdentity']) -or
        @($targets[0]['runtimes']).Count -eq 0) {
        throw "SDK platform $targetId lacks minimum OS, runtime, or build identity metadata."
    }
    try {
        $minimumOs = [version]$targets[0]['minimumOs']
        $currentOs = if ($IsMacOS) {
            [version]((& /usr/bin/sw_vers -productVersion).Trim())
        } else {
            [Environment]::OSVersion.Version
        }
    } catch {
        throw "SDK platform $targetId has invalid minimum OS metadata."
    }
    if ($currentOs -lt $minimumOs) {
        throw "SDK platform $targetId requires minimum OS $minimumOs; current OS is $currentOs."
    }
    if ($targetId -eq 'macos-universal' -and
        (@($artifacts[0]['slices']) -notcontains 'arm64' -or @($artifacts[0]['slices']) -notcontains 'x86_64')) {
        throw 'SDK macOS universal artifact is missing an architecture slice declaration.'
    }
    $verifiedFiles = @($releaseManifest['files'] | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_['artifact'] -in @('flutter-plugin', "native:$targetId")
    })
    if ($verifiedFiles.Count -eq 0) { throw "SDK package layout for $targetId has no verified files." }
    $pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $verifiedPaths = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $nativeFiles = @($verifiedFiles | Where-Object { $_['artifact'] -eq "native:$targetId" })
    if ([string]::IsNullOrWhiteSpace($abi['header']) -or
        @($nativeFiles | Where-Object { $_['path'] -eq $abi['header'] }).Count -ne 1 -or
        @($nativeFiles | Where-Object { $_['path'] -like 'lib/*' }).Count -eq 0) {
        throw "SDK package layout for $targetId lacks a verified ABI header or native library."
    }
    foreach ($file in $verifiedFiles) {
        $relative = $file['path']
        $expected = $file['sha256']
        if ($relative -isnot [string] -or [IO.Path]::IsPathRooted($relative) -or
            $relative.Contains('\') -or @($relative.Split('/')).Where({ $_ -in @('', '.', '..') }).Count -gt 0 -or
            $expected -isnot [string] -or $expected -cnotmatch '^[0-9a-f]{64}$') {
            throw 'SDK release manifest has an unsafe path or invalid SHA-256 digest.'
        }
        $base = if ($file['artifact'] -eq 'flutter-plugin') { $sdk } else { Join-Path $sdk "native/$targetId" }
        $basePrefix = [IO.Path]::GetFullPath($base).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $fullPath = [IO.Path]::GetFullPath((Join-Path $base $relative))
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (!$fullPath.StartsWith($basePrefix, $comparison)) { throw 'SDK release manifest path escapes its artifact.' }
        if (!$verifiedPaths.Add("$($file['artifact'])/$relative")) { throw 'SDK release manifest lists a duplicate file.' }
        if (!(Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "SDK package layout is missing $($file['artifact'])/$relative." }
        $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "SDK checksum mismatch for $($file['artifact'])/$relative." }
    }
    foreach ($entry in Get-ChildItem -LiteralPath $sdk -Recurse -Force) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "SDK package contains a redirected path: $($entry.FullName)"
        }
        if ($entry.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($sdk, $entry.FullName).Replace('\', '/')
        if ($relative -eq 'sdk-release-manifest.json') { continue }
        $prefix = "native/$targetId/"
        $key = if ($relative.StartsWith($prefix, $comparison)) {
            "native:$targetId/$($relative.Substring($prefix.Length))"
        } elseif ($relative.StartsWith('native/', $comparison)) {
            throw "SDK package includes an unexpected platform file: $relative"
        } else {
            "flutter-plugin/$relative"
        }
        if (!$verifiedPaths.Contains($key)) { throw "SDK package contains an unlisted file: $relative" }
    }
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
