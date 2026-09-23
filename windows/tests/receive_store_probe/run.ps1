$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Visual C++ Build Tools are required.' }
$cmake = Join-Path $visualStudio 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$probeBuild = Join-Path $PSScriptRoot 'build'
& $cmake -S $PSScriptRoot -B $probeBuild -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Probe configure failed.' }
& $cmake --build $probeBuild --config Debug
if ($LASTEXITCODE -ne 0) { throw 'Probe build failed.' }
& (Join-Path $probeBuild 'Debug/receive_store_probe.exe')
if ($LASTEXITCODE -ne 0) { throw 'Probe failed.' }
