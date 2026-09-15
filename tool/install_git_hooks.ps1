#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$existing = & git -C $repoRoot config --local --get core.hooksPath
if ($LASTEXITCODE -notin @(0, 1)) { throw 'Cannot read local Git hooks configuration.' }
if ($existing -and $existing -ne '.githooks') {
    throw "Existing core.hooksPath '$existing' requires manual integration; it was not replaced."
}
& git -C $repoRoot config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Cannot install repository Git hooks.' }
Write-Output 'Version policy hooks enabled for this checkout (.githooks).'
