param([switch]$LiveDiscovery, [string]$FlutterSdk)
$ErrorActionPreference = 'Stop'
$client = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$visualStudio) { throw 'Visual C++ Build Tools are required.' }
$cmake = Join-Path $visualStudio 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$ctest = Join-Path (Split-Path $cmake -Parent) 'ctest.exe'
$source = Join-Path $client 'windows/tests'
$build = Join-Path $source 'build'
$receiveWrapper = Join-Path $client 'windows/flutter/ephemeral/cpp_client_wrapper/include'
if ($FlutterSdk) {
  $receiveWrapper = Join-Path $FlutterSdk 'bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper/include'
}
if (!(Test-Path -LiteralPath (Join-Path $receiveWrapper 'flutter/method_result_functions.h'))) {
  throw 'Flutter Windows headers are required for bridge tests. Run flutter build windows, or flutter precache --windows and supply -FlutterSdk <SDK directory>.'
}
$receiveWrapper = $receiveWrapper.Replace('\', '/')
& $cmake -S $source -B $build -G 'Visual Studio 17 2022' -A x64 "-DFLUTTER_CLIENT_WRAPPER_INCLUDE=$receiveWrapper"
if ($LASTEXITCODE -ne 0) { throw 'Native test configure failed.' }
& $cmake --build $build --config Debug
if ($LASTEXITCODE -ne 0) { throw 'Native test build failed.' }
& $ctest --test-dir $build -C Debug --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Native tests failed.' }
if ($LiveDiscovery) {
  & (Join-Path $build 'Debug/discovery_live_test.exe')
  if ($LASTEXITCODE -ne 0) { throw 'Local DNS-SD integration test failed.' }
}
