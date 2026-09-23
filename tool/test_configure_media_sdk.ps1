#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
    Set-Content -LiteralPath (Join-Path $sdk 'lib/share_hub_media_sdk.dart') -Value "// SDK fixture: $Name"
    return @{ Project=$project; Sdk=$sdk }
}
function Configure($f) { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -SkipPubGet }
function Reject($Action, [string]$Expected = '') {
    $rejected = $false
    try { & $Action } catch {
        if ($Expected -and $_.Exception.Message -notmatch $Expected) { throw }
        $rejected=$true
    }
    Assert $rejected 'Expected setup to reject the input'
}
function FlutterStub($f, [string]$Mode) {
    $directory = Join-Path (Split-Path $f.Project -Parent) 'Flutter 模拟 [工具]'
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Set-Content -LiteralPath (Join-Path $directory 'mode.txt') -Value $Mode
    $path = Join-Path $directory 'flutter stub.ps1'
    Set-Content -LiteralPath $path -Value @'
$ErrorActionPreference = 'Stop'
@{ arguments = @($args); cwd = (Get-Location).Path; pid = $PID } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'called.json')
$mode = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim()
if ($mode -eq 'failure') { exit 37 }
if ($mode -eq 'wait') { Start-Sleep -Seconds 120 }
exit 0
'@
    return $path
}
function Assert-Preserved($f, [string]$ManifestHash, [string]$SdkHash) {
    Assert ((Get-FileHash -LiteralPath (Join-Path $f.Project 'pubspec.yaml')).Hash -eq $ManifestHash) 'Manifest changed during failure/cancellation'
    $entry = Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart'
    Assert ((Get-FileHash -LiteralPath $entry).Hash -eq $SdkHash) 'SDK content changed during failure/cancellation'
    Assert ((Get-FileHash -LiteralPath (Join-Path $f.Project '.local/media-sdk/package/lib/share_hub_media_sdk.dart')).Hash -eq $SdkHash) 'Original SDK link was lost or replaced'
    $link=Get-Item -LiteralPath (Join-Path $f.Project '.local/media-sdk/package') -Force
    Assert ($link.LinkType -in @('Junction','SymbolicLink')) 'SDK link was replaced by another type'
    $targets=@($link.Target)
    Assert ($targets.Count -eq 1) 'SDK target is ambiguous'
    Assert ([IO.Path]::GetFullPath($targets[0]) -eq [IO.Path]::GetFullPath($f.Sdk)) 'SDK link points to a different package'
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

    $f=Fixture 'missing-sdk'
    $missing=Join-Path (Split-Path $f.Sdk -Parent) 'not-installed'
    Reject { & $tool -ProjectPath $f.Project -SdkPath $missing -SkipPubGet } 'SDK package directory is missing'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Missing SDK mutated project'
    Write-Output 'PASS missing SDK has a distinct diagnostic before mutation'

    $f=Fixture 'invalid'
    Set-Content -LiteralPath (Join-Path $f.Sdk 'pubspec.yaml') -Value 'name: wrong_sdk'
    Reject { Configure $f } 'Expected package share_hub_media_sdk'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Invalid SDK mutated project'
    Write-Output 'PASS invalid package rejected before mutation'

    $f=Fixture 'missing-entry'
    Remove-Item -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')
    Reject { Configure $f } 'SDK package layout is invalid: entry library is missing'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Missing SDK entry mutated project'
    Write-Output 'PASS missing SDK entry has a distinct layout diagnostic before mutation'

    $f=Fixture 'directory'
    $destination=Join-Path $f.Project '.local/media-sdk/package'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Set-Content -LiteralPath (Join-Path $destination 'keep.txt') -Value 'keep'
    Reject { Configure $f } 'SDK destination already exists'
    Assert (Test-Path -LiteralPath (Join-Path $destination 'keep.txt')) 'Existing SDK was overwritten'
    Write-Output 'PASS existing unpacked SDK preserved'

    $f=Fixture 'conflict'
    Configure $f
    $manifestHash=(Get-FileHash -LiteralPath (Join-Path $f.Project 'pubspec.yaml')).Hash
    $sdkHash=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash
    $other=Fixture 'other'
    Reject { & $tool -ProjectPath $f.Project -SdkPath $other.Sdk -SkipPubGet } 'Existing SDK link points elsewhere'
    Assert-Preserved $f $manifestHash $sdkHash
    Write-Output 'PASS conflicting SDK link preserved'

    $f=Fixture 'legacy'
    Set-Content -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml') -Value '# keep local config'
    Reject { Configure $f } 'Existing local SDK configuration requires migration'
    Assert (!(Test-Path -LiteralPath (Join-Path $f.Project '.local'))) 'Legacy configuration was overwritten'
    Write-Output 'PASS existing local configuration preserved'

    $f=Fixture 'redirect'
    $external=Join-Path $tempRoot 'redirect-target'
    New-Item -ItemType Directory -Path $external | Out-Null
    $type=if ($IsWindows) {'Junction'} else {'SymbolicLink'}
    New-Item -ItemType $type -Path (Join-Path $f.Project '.local') -Target $external | Out-Null
    Reject { Configure $f } 'Refusing a redirected or non-directory SDK destination parent'
    Assert (!(Test-Path -LiteralPath (Join-Path $external 'media-sdk'))) 'Redirected parent was written'
    Write-Output 'PASS redirected destination rejected'

    foreach ($existing in @($false, $true)) {
        $f=Fixture "pubget-failure-$existing"
        if ($existing) { Configure $f }
        $manifestHash=(Get-FileHash -LiteralPath (Join-Path $f.Project 'pubspec.yaml')).Hash
        $sdkHash=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash
        $stub=FlutterStub $f 'failure'
        $location=(Get-Location).Path
        Reject { & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $stub } 'pub get failed'
        Assert ((Get-Location).Path -eq $location) 'Failed pub get did not restore the caller location'
        Assert-Preserved $f $manifestHash $sdkHash
        $call=Get-Content -LiteralPath (Join-Path (Split-Path $stub -Parent) 'called.json') -Raw | ConvertFrom-Json
        Assert (($call.arguments -join ',') -eq 'pub,get') 'Wrong Flutter command'
        Assert ($call.cwd -eq $f.Project) 'pub get ran outside the target project'
        $stub=FlutterStub $f 'success'
        & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $stub
        Assert-Preserved $f $manifestHash $sdkHash
        Write-Output "PASS pub get failure preserves SDK and supports retry (preexisting=$existing)"
    }

    # Terminate only our child while it is executing the bounded waiting stub.
    # This models interruption without terminating the test runner or touching
    # the real Flutter process, user SDK, or workspace configuration.
    foreach ($existing in @($false, $true)) {
        $f=Fixture "cancel-$existing"
        if ($existing) { Configure $f }
        $manifestHash=(Get-FileHash -LiteralPath (Join-Path $f.Project 'pubspec.yaml')).Hash
        $sdkHash=(Get-FileHash -LiteralPath (Join-Path $f.Sdk 'lib/share_hub_media_sdk.dart')).Hash
        $stub=FlutterStub $f 'wait'
        $marker=Join-Path (Split-Path $stub -Parent) 'called.json'
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=(Get-Process -Id $PID).Path
        $info.UseShellExecute=$false
        $info.RedirectStandardOutput=$true
        $info.RedirectStandardError=$true
        foreach ($argument in @('-NoLogo','-NoProfile','-File',$tool,'-ProjectPath',$f.Project,'-SdkPath',$f.Sdk,'-FlutterCommand',$stub)) {
            $info.ArgumentList.Add($argument)
        }
        $child=[Diagnostics.Process]::Start($info)
        try {
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while (!(Test-Path -LiteralPath $marker) -and !$child.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            Assert (Test-Path -LiteralPath $marker) 'Child did not enter simulated pub get'
            Assert (!$child.HasExited) 'Child exited before cancellation'
            $child.Kill($true)
            Assert ($child.WaitForExit(5000)) 'Cancelled child did not terminate'
            Assert-Preserved $f $manifestHash $sdkHash
        } finally {
            if (!$child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
        }
        $stub=FlutterStub $f 'success'
        & $tool -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $stub
        Assert-Preserved $f $manifestHash $sdkHash
        Write-Output "PASS interrupted configuration preserves SDK and supports retry (preexisting=$existing)"
    }
} finally {
    $resolved=(Resolve-Path -LiteralPath $tempRoot).Path
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $resolved -Leaf).StartsWith('share-hub-required-sdk-')) { throw 'Unexpected test cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
