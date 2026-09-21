#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot 'configure_media_sdk.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('share-hub-required-sdk-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
function Assert($Condition, $Message) { if (!$Condition) { throw $Message } }
function Fixture($Name) {
    # Cover non-ASCII and space characters in both the project and SDK paths.
    $project = Join-Path $tempRoot "$Name/客户端 空格"
    $sdk = Join-Path $tempRoot "$Name/媒体SDK 空格"
    New-Item -ItemType Directory -Force -Path $project,(Join-Path $sdk 'lib') | Out-Null
    Set-Content -LiteralPath (Join-Path $project 'pubspec.yaml') -Value "name: share_hub_open`ndependencies:`n  share_hub_media_sdk:`n    path: .local/media-sdk/package"
    Set-Content -LiteralPath (Join-Path $sdk 'pubspec.yaml') -Value 'name: share_hub_media_sdk'
    Set-Content -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -Value '// SDK fixture'
    return @{ Project=$project; Sdk=$sdk }
}
function Configure($f) { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet }
function Reject($Action) {
    $rejected = $false
    try { & $Action } catch { $rejected=$true }
    Assert $rejected 'Expected setup to reject the input'
}
try {
    $f=Fixture 'valid'
    $manifest=Join-Path $f.Project 'pubspec.yaml'
    $before=(Get-FileHash -LiteralPath $manifest).Hash
    Configure $f
    Configure $f
    Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Manifest was modified'
    Assert (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/package/lib/share_hub_media_sdk.dart')) 'Linked SDK missing'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/main.dart'))) 'Unexpected alternate entry'
    Write-Output 'PASS SDK linking is idempotent, handles non-ASCII and space paths, preserves manifest and normal entry'

    $f=Fixture 'invalid'
    Set-Content -LiteralPath (Join-Path $f.Sdk 'pubspec.yaml') -Value 'name: wrong_sdk'
    Reject { Configure $f }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Invalid SDK mutated project'
    Write-Output 'PASS invalid package rejected before mutation'

    $f=Fixture 'directory'
    $destination=Join-Path $f.Project '.local/media-sdk/package'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'keep.txt') -Value 'keep'
    Reject { Configure $f }
    Assert (Test-Path -LiteralPath (Join-Path $destination 'keep.txt')) 'Existing SDK was overwritten'
    Write-Output 'PASS existing unpacked SDK preserved'

    $f=Fixture 'conflict'
    Configure $f
    $other=Fixture 'other'
    Reject { & $tool -ProjectPath $f.Project -SdkPath $other.Sdk -SkipPubGet }
    Write-Output 'PASS conflicting SDK link preserved'

    $f=Fixture 'legacy'
    Set-Content -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml') -Value '# keep local config'
    Reject { Configure $f }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Legacy configuration was overwritten'
    Write-Output 'PASS existing local configuration preserved'

    $f=Fixture 'redirect'
    $external=Join-Path $tempRoot 'redirect-target'
    New-Item -ItemType Directory -Path $external | Out-Null
    $type=if ($IsWindows) {'Junction'} else {'SymbolicLink'}
    New-Item -ItemType $type -Path (Join-Path $f.Project '.local') -Target $external | Out-Null
    Reject { Configure $f }
    Assert (!(Test-Path -LiteralPath (Join-Path $external 'media-sdk'))) 'Redirected parent was written'
    Write-Output 'PASS redirected destination rejected'
} finally {
    $resolved=(Resolve-Path -LiteralPath $tempRoot).Path
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $resolved -Leaf).StartsWith('share-hub-required-sdk-')) { throw 'Unexpected test cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
