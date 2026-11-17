# Copies the Visual C++ runtime (vcruntime140.dll, msvcp140.dll ...) of the Visual Studio that built the app into the
# Windows release folder, next to kumo.exe. A Flutter app for Windows needs it, and a Windows that never had another
# program put it there (a fresh install, a virtual machine) refuses to start the app without it
# ("VCRUNTIME140_1.dll was not found"). Microsoft allows the files of the Redist folder of Visual Studio to be
# shipped next to the program (app-local deployment).
#
#   ./tools/bundle_vc_runtime.ps1 -Arch x64      (or arm64)
#
# When the files cannot be found the build goes on, with a warning in the log: the app then needs the runtime
# to be installed, as it did before.
param(
  [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Arch
)

$ErrorActionPreference = 'Stop'
$release = Join-Path (Get-Location) "build\windows\$Arch\runner\Release"
if (-not (Test-Path (Join-Path $release 'kumo.exe'))) {
  # The ARM64 job finds the folder itself, so a build made somewhere else is looked for.
  $exe = Get-ChildItem build\windows -Recurse -Filter kumo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { throw "kumo.exe was not found under build\windows" }
  $release = $exe.Directory.FullName
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$crt = $null
if (Test-Path $vswhere) {
  foreach ($root in (& $vswhere -all -products * -property installationPath)) {
    $redist = Join-Path $root 'VC\Redist\MSVC'
    if (-not (Test-Path $redist)) { continue }
    # The newest version folder (14.xx.yyyy) first; "v143" and the like hold the installers, not the files.
    $found = Get-ChildItem $redist -Directory |
      Where-Object { $_.Name -match '^\d' } |
      Sort-Object { [version]$_.Name } -Descending |
      ForEach-Object { Get-ChildItem (Join-Path $_.FullName $Arch) -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
      Select-Object -First 1
    if ($found) { $crt = $found; break }
  }
}

if (-not $crt) {
  Write-Host "::warning::The Visual C++ runtime ($Arch) was not found on this machine; it is not shipped with the app."
  exit 0
}

Write-Host "Visual C++ runtime from $($crt.FullName)"
foreach ($dll in Get-ChildItem $crt.FullName -Filter *.dll) {
  $target = Join-Path $release $dll.Name
  if (Test-Path $target) { continue }
  Copy-Item $dll.FullName $target
  Write-Host "  + $($dll.Name)"
}
