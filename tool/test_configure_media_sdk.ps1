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
    New-Item -ItemType Directory -Force -Path (Join-Path $project 'packages/share_hub_media_api') | Out-Null
    Set-Content -LiteralPath (Join-Path $project 'packages/share_hub_media_api/pubspec.yaml') -Value "name: share_hub_media_api`nversion: 0.4.0"
    Set-Content -LiteralPath (Join-Path $sdk 'pubspec.yaml') -Value "name: share_hub_media_sdk`ndescription: Private Share Hub media SDK development adapter.`nversion: 0.1.0-test.1`npublish_to: none"
    Set-Content -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -Value '// SDK fixture'
    return @{ Project=$project; Sdk=$sdk }
}
function FormalFixture($Name) {
    $f=Fixture $Name
    $architecture=[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $target=if ($IsWindows) { "windows-$architecture" } elseif ($IsMacOS) { 'macos-universal' } else { throw 'Unsupported formal fixture platform' }
    $native=Join-Path $f.Sdk "native/$target"
    New-Item -ItemType Directory -Force -Path (Join-Path $native 'include'),(Join-Path $native 'lib') | Out-Null
    Set-Content -LiteralPath (Join-Path $native 'include/share_hub_media_sdk.h') -Value '/* ABI fixture */'
    Set-Content -LiteralPath (Join-Path $native 'lib/share_hub_media_core.bin') -Value 'binary fixture'
    $m=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../docs/sdk-release-manifest.example.json') -Raw | ConvertFrom-Json -AsHashtable
    $m.sampleOnly=$false
    $m.sdkVersion='0.1.0-test.1'
    foreach ($artifact in $m.artifacts) { $artifact.sha256='0' * 64 }
    foreach ($entry in $m.targets) {
        $entry.minimumOs=if ($entry.id -like 'windows-*') { '10.0' } else { '13.0' }
        $entry.runtimes=@('fixture-runtime')
        $entry.buildIdentity='fixture-build'
    }
    $m.files=@(
        @{ artifact='flutter-plugin'; path='pubspec.yaml'; sha256=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'pubspec.yaml')).Hash.ToLowerInvariant() },
        @{ artifact='flutter-plugin'; path='lib/share_hub_media_sdk.dart'; sha256=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash.ToLowerInvariant() },
        @{ artifact="native:$target"; path='include/share_hub_media_sdk.h'; sha256=(Get-FileHash -LiteralPath (Join-Path $native 'include/share_hub_media_sdk.h')).Hash.ToLowerInvariant() },
        @{ artifact="native:$target"; path='lib/share_hub_media_core.bin'; sha256=(Get-FileHash -LiteralPath (Join-Path $native 'lib/share_hub_media_core.bin')).Hash.ToLowerInvariant() }
    )
    $f.Target=$target
    $f.Manifest=$m
    return $f
}
function SaveFormalManifest($f) {
    $f.Manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $f.Sdk 'sdk-release-manifest.json')
}
function ConfigureFormal($f) {
    $digest=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'sdk-release-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet -ExpectedManifestSha256 $digest
}
function Configure($f) { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet -DevelopmentAdapter }
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
function RejectWith($Action, $Pattern) {
    $message=$null
    try { & $Action } catch { $message=$_.Exception.Message }
    Assert ($message -match $Pattern) "Expected diagnostic matching $Pattern, got: $message"
}
try {
    $f=Fixture 'missing-sdk-path'
    RejectWith { & $tool -ProjectPath $f.Project -SdkPath (Join-Path $tempRoot 'absent-sdk') -SkipPubGet } 'SDK package.*missing'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Missing SDK path mutated project'
    Write-Output 'PASS missing SDK path has actionable diagnostic'

    $f=Fixture 'missing-release-manifest'
    Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Missing release manifest mutated project'
    Write-Output 'PASS formal SDK requires a release manifest before linking'

    $f=Fixture 'sample-manifest'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../docs/sdk-release-manifest.example.json') -Destination (Join-Path $f.Sdk 'sdk-release-manifest.json')
    Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Sample manifest mutated project'
    Write-Output 'PASS example-only release manifest cannot be installed'

    $f=Fixture 'unmarked-development-package'
    Set-Content -LiteralPath (Join-Path $f.Sdk 'pubspec.yaml') -Value 'name: share_hub_media_sdk'
    Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet -DevelopmentAdapter }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unmarked development package mutated project'
    Write-Output 'PASS development exception requires the internal adapter marker'

    $f=FormalFixture 'formal-cannot-use-development-exception'
    SaveFormalManifest $f
    Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet -DevelopmentAdapter }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Formal package bypassed verification'
    Write-Output 'PASS formal package cannot bypass verification with development switch'

    $f=FormalFixture 'formal-bad-api'
    $f.Manifest.publicMediaApi.verifiedVersions=@('0.3.0')
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'public media API'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Incompatible API mutated project'
    Write-Output 'PASS incompatible public API rejected before linking'

    $f=FormalFixture 'formal-missing-manifest-anchor'
    SaveFormalManifest $f
    Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet }
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unanchored manifest mutated project'
    Write-Output 'PASS formal SDK requires an independently obtained manifest digest'

    $f=FormalFixture 'formal-wrong-manifest-digest'
    SaveFormalManifest $f
    RejectWith { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet -ExpectedManifestSha256 ('0' * 64) } 'manifest checksum mismatch'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Wrong trusted digest mutated project'
    Write-Output 'PASS wrong trusted manifest digest rejected before linking'

    $f=FormalFixture 'formal-valid'
    SaveFormalManifest $f
    ConfigureFormal $f | Out-Null
    Assert (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/package/sdk-release-manifest.json')) 'Valid formal package did not link'
    Write-Output 'PASS compatible formal package links at the standard location'

    $f=FormalFixture 'formal-missing-artifact-digest'
    ($f.Manifest.artifacts | Where-Object { $_.target -eq $f.Target }).sha256=$null
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'artifact checksum'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Missing archive checksum mutated project'
    Write-Output 'PASS release artifact digest is required'

    $f=FormalFixture 'formal-sdk-version-mismatch'
    $f.Manifest.sdkVersion='0.1.0-test.2'
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'SDK version'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'SDK version mismatch mutated project'
    Write-Output 'PASS SDK manifest and plugin package versions must agree'

    $f=FormalFixture 'formal-bad-abi'
    $f.Manifest.nativeAbi.major=2
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'native ABI'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Incompatible ABI mutated project'
    Write-Output 'PASS incompatible native ABI rejected before linking'

    $f=FormalFixture 'formal-wrong-platform'
    $f.Manifest.targets=@($f.Manifest.targets | Where-Object { $_.id -ne $f.Target })
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'platform'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unsupported platform mutated project'
    Write-Output 'PASS absent target platform rejected before linking'

    $f=FormalFixture 'formal-unsupported-os'
    ($f.Manifest.targets | Where-Object { $_.id -eq $f.Target }).minimumOs='99.0'
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'minimum OS'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unsupported OS mutated project'
    Write-Output 'PASS minimum OS incompatibility rejected before linking'

    $f=FormalFixture 'formal-bad-checksum'
    SaveFormalManifest $f
    Set-Content -LiteralPath (Join-Path $f.Sdk "native/$($f.Target)/lib/share_hub_media_core.bin") -Value 'tampered'
    RejectWith { ConfigureFormal $f } 'checksum mismatch'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Bad checksum mutated project'
    Write-Output 'PASS signed-byte file checksum mismatch rejected before linking'

    $f=FormalFixture 'formal-missing-native-layout'
    $f.Manifest.files=@($f.Manifest.files | Where-Object { $_.artifact -eq 'flutter-plugin' })
    SaveFormalManifest $f
    RejectWith { ConfigureFormal $f } 'package layout'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unlisted native package mutated project'
    Write-Output 'PASS native ABI header and library must be listed and verified'

    $f=FormalFixture 'formal-unlisted-file'
    SaveFormalManifest $f
    Set-Content -LiteralPath (Join-Path $f.Sdk 'lib/unlisted.dart') -Value '// unverified code'
    RejectWith { ConfigureFormal $f } 'unlisted file'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Unlisted package file mutated project'
    Write-Output 'PASS unlisted plugin file rejected before linking'

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
        Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner -DevelopmentAdapter }
        $linked=Join-Path $f.Project '.local/media-sdk/package'
        Assert (Test-Path -LiteralPath (Join-Path $linked 'lib/share_hub_media_sdk.dart')) 'Failed pub get lost its retryable SDK link'
        Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Failed pub get changed the project manifest'
        Assert ((Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash -eq $sdkBefore) 'Failed pub get changed the SDK'
        Assert ((Get-Location).Path -eq $locationBefore) 'Failed pub get left the shell in the project'
        Set-Content -LiteralPath (Join-Path $f.Project 'flutter-outcome.txt') -Value '0'
        & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner -DevelopmentAdapter | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'SDK setup retry did not complete'
        Assert ((Get-Content -LiteralPath (Join-Path $f.Project 'flutter-calls.txt')).Count -eq 2) 'Pub get was not retried once'
        Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $before) 'Retry changed the project manifest'
        Set-Content -LiteralPath (Join-Path $f.Project 'flutter-outcome.txt') -Value '17'
        Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $runner -DevelopmentAdapter }
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
    Reject { & $tool -ProjectPath $f.Project -SdkPath $other.Sdk -SkipPubGet -DevelopmentAdapter }
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
