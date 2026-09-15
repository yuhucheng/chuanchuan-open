[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'configure_media_sdk.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "FAIL $Name"
    }
}

function New-Fixture([string]$Root, [string]$SdkName = 'share_hub_media_sdk') {
    $project = Join-Path $Root 'open client 空格'
    $sdk = Join-Path $Root 'private sdk 空格'
    New-Item -ItemType Directory -Force (Join-Path $project 'packages/share_hub_media_api') | Out-Null
    New-Item -ItemType Directory -Force $sdk | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $project 'pubspec.yaml'),
        "name: share_hub_open`r`ndependencies:`r`n  flutter:`r`n    sdk: flutter`r`n`r`ndev_dependencies:`r`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Set-Content -LiteralPath (Join-Path $project 'packages/share_hub_media_api/pubspec.yaml') -Encoding utf8 -Value "name: share_hub_media_api`n"
    Set-Content -LiteralPath (Join-Path $sdk 'pubspec.yaml') -Encoding utf8 -Value "name: $SdkName`n"
    return @{ Project = $project; Sdk = $sdk }
}

function Invoke-Tool([hashtable]$Fixture, [switch]$Disable) {
    if ($Disable) {
        & $scriptPath -ProjectPath $Fixture.Project -Disable -SkipPubGet
    }
    else {
        & $scriptPath -ProjectPath $Fixture.Project -SdkPath $Fixture.Sdk -SkipPubGet
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("share-hub-sdk-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    Invoke-Case 'enable creates quoted overrides and SDK entrypoint for paths with spaces' {
        $f = New-Fixture (Join-Path $tempRoot 'shape')
        $originalManifest = [System.IO.File]::ReadAllBytes((Join-Path $f.Project 'pubspec.yaml'))
        Invoke-Tool $f
        $override = Get-Content -Raw -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml')
        $entry = Get-Content -Raw -LiteralPath (Join-Path $f.Project '.local/media-sdk/main.dart')
        $manifest = Get-Content -Raw -LiteralPath (Join-Path $f.Project 'pubspec.yaml')
        Assert-True ($override.Contains('dependency_overrides:')) 'missing dependency_overrides'
        Assert-True ($override.Contains('share_hub_media_sdk:')) 'missing SDK override'
        Assert-True ($override.Contains('share_hub_media_api:')) 'missing API override'
        $quotedSdkPath = ConvertTo-Json -Compress ($f.Sdk.Replace('\', '/'))
        Assert-True ($override.Contains($quotedSdkPath)) 'SDK path is not safely YAML quoted'
        Assert-True ($entry.Contains("import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';")) 'missing SDK import'
        Assert-True ($entry.Contains('WidgetsFlutterBinding.ensureInitialized();')) 'entrypoint does not initialize Flutter bindings'
        Assert-True ($entry.Contains("ShareHubApp(previewEngine: createPreviewEngine(), appTitle: 'Share Hub')")) 'missing configured app entrypoint'
        Assert-True ($manifest.Contains("  share_hub_media_sdk: any`r`n")) 'SDK is not a direct dependency'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/pubspec.yaml.original')) 'missing byte-exact manifest backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/state.json')) 'missing managed state'
    }

    Invoke-Case 'enable twice and disable twice are idempotent' {
        $f = New-Fixture (Join-Path $tempRoot 'idempotent')
        $manifestPath = Join-Path $f.Project 'pubspec.yaml'
        $originalManifest = [System.IO.File]::ReadAllBytes($manifestPath)
        Invoke-Tool $f
        Invoke-Tool $f
        Invoke-Tool $f -Disable
        Invoke-Tool $f -Disable
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml'))) 'override remains after disable'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/main.dart'))) 'entry remains after disable'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/state.json'))) 'state remains after disable'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($originalManifest, [System.IO.File]::ReadAllBytes($manifestPath))) 'disable did not restore pubspec.yaml byte-for-byte'
    }

    Invoke-Case 'existing unmanaged override is preserved and rejected' {
        $f = New-Fixture (Join-Path $tempRoot 'unmanaged')
        $path = Join-Path $f.Project 'pubspec_overrides.yaml'
        Set-Content -LiteralPath $path -Encoding utf8 -Value "dependency_overrides:`n  other: ../other`n"
        $failed = $false
        try { Invoke-Tool $f } catch { $failed = $true }
        Assert-True $failed 'enable accepted an unmanaged override'
        Assert-True ((Get-Content -Raw -LiteralPath $path).Contains('other:')) 'unmanaged override was changed'
        $failed = $false
        try { Invoke-Tool $f -Disable } catch { $failed = $true }
        Assert-True $failed 'disable accepted an unmanaged override'
        Assert-True (Test-Path -LiteralPath $path) 'disable removed unmanaged override'
    }

    Invoke-Case 'manual edits to either managed file prevent enable and disable' {
        foreach ($target in @('pubspec.yaml', 'pubspec_overrides.yaml', '.local/media-sdk/main.dart', '.local/media-sdk/pubspec.yaml.original')) {
            $f = New-Fixture (Join-Path $tempRoot ("edited-" + ($target -replace '[^a-z]', '-')))
            Invoke-Tool $f
            $path = Join-Path $f.Project $target
            Add-Content -LiteralPath $path -Encoding utf8 -Value '// manual edit'
            foreach ($operation in @('enable', 'disable')) {
                $failed = $false
                try {
                    if ($operation -eq 'enable') { Invoke-Tool $f } else { Invoke-Tool $f -Disable }
                }
                catch { $failed = $true }
                Assert-True $failed "$operation accepted edited $target"
                Assert-True ((Get-Content -Raw -LiteralPath $path).Contains('manual edit')) "$operation erased edited $target"
            }
        }
    }

    Invoke-Case 'unmanaged direct SDK dependency is rejected without changing manifest' {
        $f = New-Fixture (Join-Path $tempRoot 'unmanaged-direct-dependency')
        $manifestPath = Join-Path $f.Project 'pubspec.yaml'
        Add-Content -LiteralPath $manifestPath -Encoding utf8 -Value "  share_hub_media_sdk: any"
        $before = [System.IO.File]::ReadAllBytes($manifestPath)
        $failed = $false
        try { Invoke-Tool $f } catch { $failed = $true }
        Assert-True $failed 'unmanaged direct SDK dependency was accepted'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($before, [System.IO.File]::ReadAllBytes($manifestPath))) 'unmanaged manifest was changed'
    }

    Invoke-Case 'orphan manifest backup is preserved and blocks enable' {
        $f = New-Fixture (Join-Path $tempRoot 'orphan-backup')
        $backupPath = Join-Path $f.Project '.local/media-sdk/pubspec.yaml.original'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
        $orphanBytes = [byte[]](0, 255, 17, 42, 99)
        [System.IO.File]::WriteAllBytes($backupPath, $orphanBytes)
        $manifestBefore = [System.IO.File]::ReadAllBytes((Join-Path $f.Project 'pubspec.yaml'))
        $failed = $false
        try { Invoke-Tool $f } catch { $failed = $true }
        Assert-True $failed 'orphan manifest backup was accepted'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($orphanBytes, [System.IO.File]::ReadAllBytes($backupPath))) 'orphan backup bytes were changed'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($manifestBefore, [System.IO.File]::ReadAllBytes((Join-Path $f.Project 'pubspec.yaml')))) 'project manifest was changed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml'))) 'override was created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/main.dart'))) 'entrypoint was created'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/state.json'))) 'managed state was created'
    }

    Invoke-Case 'wrong SDK path and package identity fail before mutation' {
        $missing = New-Fixture (Join-Path $tempRoot 'missing')
        Remove-Item -LiteralPath (Join-Path $missing.Sdk 'pubspec.yaml')
        $failed = $false
        try { Invoke-Tool $missing } catch { $failed = $true }
        Assert-True $failed 'missing SDK manifest was accepted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $missing.Project 'pubspec_overrides.yaml'))) 'missing SDK mutated project'

        $wrong = New-Fixture (Join-Path $tempRoot 'wrong-name') 'some_other_package'
        $failed = $false
        try { Invoke-Tool $wrong } catch { $failed = $true }
        Assert-True $failed 'wrong SDK package name was accepted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $wrong.Project '.local'))) 'wrong SDK mutated project'
    }

    Invoke-Case 'pub get failure retains managed integration for retry or disable' {
        $f = New-Fixture (Join-Path $tempRoot 'pubget-failure')
        $fakeFlutter = Join-Path $tempRoot 'fake flutter.cmd'
        Set-Content -LiteralPath $fakeFlutter -Encoding ascii -Value '@exit /b 23'
        $failed = $false
        $message = ''
        try {
            & $scriptPath -ProjectPath $f.Project -SdkPath $f.Sdk -FlutterCommand $fakeFlutter
        }
        catch {
            $failed = $true
            $message = $_.Exception.Message
        }
        Assert-True $failed 'pub get failure was reported as success'
        Assert-True ($message.Contains('-Disable')) 'failure omitted the disable recovery action'
        Assert-True ($message.Contains('Retry')) 'failure omitted the retry recovery action'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Project 'pubspec_overrides.yaml')) 'failure removed managed override'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Project '.local/media-sdk/state.json')) 'failure removed managed state'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

if ($failures.Count -gt 0) {
    throw ($failures -join [Environment]::NewLine)
}
$global:LASTEXITCODE = 0
Write-Host "All configure_media_sdk tests passed."
