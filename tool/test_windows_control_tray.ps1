$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$flutter = if ($env:FLUTTER_BIN) {
  $env:FLUTTER_BIN
} else {
  (Get-Command flutter -ErrorAction Stop).Source
}
$reportPath = Join-Path $env:TEMP 'chuan-control-tray-windows.json'

Push-Location $repository
try {
  $output = & $flutter run -d windows -t lib/dev/control_tray_acceptance_main.dart --no-pub 2>&1
  $line = $output | Where-Object { "$_" -like 'TRAY_PROBE_JSON=*' } | Select-Object -Last 1
  if (-not $line) { throw 'Control tray probe did not produce a report.' }
  $json = "${line}" -replace '^TRAY_PROBE_JSON=', ''
  [System.IO.File]::WriteAllText($reportPath, $json)
  $report = $json | ConvertFrom-Json
  if (-not $report.passed) { throw "Control tray probe failed; see $reportPath" }
  Write-Output "Windows control tray probe passed; report: $reportPath"
} finally {
  & $flutter build windows --debug --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Normal Windows client rebuild failed.' }
  Pop-Location
}
