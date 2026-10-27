$ErrorActionPreference = 'Stop'

$arm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'exe'
  silentArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
  validExitCodes = @(0)
  checksumType64 = 'sha256'
}
if ($arm) {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.7.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'c4921e99a44a2e87a92c6919ed3a490fd21e39ea6ef1250c6fc1a676e31a58fd'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.7.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = 'c27fa0acfd887d68e218ac829d74da314e029f008c82570d0b11741f8945f26c'
}
Install-ChocolateyPackage @packageArgs