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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.13.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'd5d727c1b56f1a3b6e68c621de736546190ff939703045e311711e99ecb08b7b'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.13.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = 'c904998cc9022ba3eefcfda972e95ba95da85d7259b783ca2891b8ea7c8e4715'
}
Install-ChocolateyPackage @packageArgs