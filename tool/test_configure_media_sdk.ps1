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
function FakeFlutter($f) {
    $runner=Join-Path $f.Project '假 flutter.ps1'
    Set-Content -LiteralPath $runner -Value @'
param($Verb, $Subcommand)
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'flutter-calls.txt') -Value "$Verb $Subcommand"
$outcome=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'flutter-outcome.txt') -Raw).Trim()
if ($outcome -eq 'cancel') { throw [OperationCanceledException]::new('fixture cancellation') }
$global:LASTEXITCODE=[int]$outcome
'@
    return $runner
}
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

    foreach ($outcome in @('17', 'cancel')) {
        $f=Fixture "pub-$outcome"
        $runner=FakeFlutter $f
        $manifest=Join-Path $f.Project 'pubspec.yaml'
        $before=(Get-FileHash -LiteralPath $manifest).Hash
        $sdkBefore=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash
        $locationBefore=(Get-Location).Path
        Set-Content -LiteralPath (Join-Path $f.Project 'flutter-outcome.txt') -Value $outcome
        Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner }
        $linked=Join-Path $f.Project '.local/media-sdk/package'
        Assert (Test-Path -LiteralPath (Join-Path $linked 'lib/share_hub_media_sdk.dart')) 'Failed pub get lost its retryable SDK link'
        Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Failed pub get changed the project manifest'
        Assert ((Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash -eq $sdkBefore) 'Failed pub get changed the SDK'
        Assert ((Get-Location).Path -eq $locationBefore) 'Failed pub get left the shell in the project'
        Set-Content -LiteralPath (Join-Path $f.Project 'flutter-outcome.txt') -Value '0'
        & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'SDK setup retry did not complete'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Project 'flutter-calls.txt')).Count -eq 2) 'Pub get was not retried once'
        Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Retry changed the project manifest'
        Set-Content -LiteralPath (Join-Path $f.Project 'flutter-outcome.txt') -Value '17'
        Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner }
        $existing=Get-Item -LiteralPath $linked -Force
        Assert ($existing.LinkType -in @('Junction', 'SymbolicLink')) 'Existing SDK link was replaced'
        Assert ((Get-FileHash -LiteralPath (Join-Path $linked 'lib/share_hub_media_sdk.dart')).Hash -eq $sdkBefore) 'Existing SDK content was overwritten'
        Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Existing project manifest was overwritten'
        Write-Output "PASS pub get $outcome preserves the SDK and recovers on retry"
    }

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
