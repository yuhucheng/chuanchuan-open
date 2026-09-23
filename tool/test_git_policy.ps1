#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$hooks = (Join-Path $repoRoot '.githooks').Replace('\', '/')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('share-hub-git-policy-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$checks = 0

function Invoke-FixtureGit {
    param([string[]]$Arguments, [switch]$ExpectFailure)
    $output = & git -C $fixture -c "core.hooksPath=$hooks" -c commit.gpgsign=false @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($ExpectFailure) {
        if ($code -eq 0) { throw "Expected rejection: git $($Arguments -join ' ')" }
        if (($output -join "`n") -notmatch 'Version policy:') { throw "Unexpected failure: $output" }
    } elseif ($code -ne 0) {
        throw "Git fixture failed ($code): $output"
    }
}

try {
    Invoke-FixtureGit -Arguments @('init', '--initial-branch=main')
    Invoke-FixtureGit -Arguments @('config', 'user.name', 'Policy Fixture')
    Invoke-FixtureGit -Arguments @('config', 'user.email', 'policy-fixture@example.invalid')
    Set-Content -LiteralPath (Join-Path $fixture 'VERSION') -Value '0.1.0' -Encoding utf8NoBOM
    Invoke-FixtureGit -Arguments @('add', 'VERSION')
    Invoke-FixtureGit -Arguments @('commit', '-m', 'chore(v0.1.0): initialize fixture'); $checks++
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.2.0): wrong version') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix: no target version') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): ') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('checkout', '-b', 'release/v0.1.0')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): approved existing release branch'); $checks++
    Invoke-FixtureGit -Arguments @('checkout', '-b', 'release/v0.2.0')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): approved next release branch'); $checks++
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.2.0): branch version does not override staged VERSION') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('checkout', '-b', 'release/v0.3.0')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): unapproved release branch') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('checkout', '-b', 'codex/unplanned-fixture')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): unplanned branch') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('checkout', '--detach')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'fix(v0.1.0): detached commit') -ExpectFailure; $checks++
    Invoke-FixtureGit -Arguments @('checkout', 'main')
    Invoke-FixtureGit -Arguments @('rm', '--cached', 'VERSION')
    Invoke-FixtureGit -Arguments @('commit', '-m', 'chore(v0.1.0): missing version') -ExpectFailure; $checks++
    Set-Content -LiteralPath (Join-Path $fixture 'VERSION') -Value 'invalid' -Encoding utf8NoBOM
    Invoke-FixtureGit -Arguments @('add', 'VERSION')
    Invoke-FixtureGit -Arguments @('commit', '-m', 'chore(v0.1.0): invalid version') -ExpectFailure; $checks++
    Set-Content -LiteralPath (Join-Path $fixture 'VERSION') -Value '0.1.0' -Encoding utf8NoBOM
    Invoke-FixtureGit -Arguments @('add', 'VERSION')
    Invoke-FixtureGit -Arguments @('commit', '--allow-empty', '-m', 'merge(v0.1.0): valid merge title'); $checks++
    Write-Output "$checks Git policy checks passed."
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolvedFixture -Leaf) -notlike 'share-hub-git-policy-*') {
        throw 'Refusing cleanup outside the policy fixture temp directory.'
    }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
