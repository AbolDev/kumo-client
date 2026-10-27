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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.9.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = '0c10e7fd255f521d94c8c89ecd265d13be51d3c288830f9e7453fd79796812e7'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.9.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '061f5889a59aa71f069046648d4bd768dbb1e5a043d6c9ae76008f01a5fc2c39'
}
Install-ChocolateyPackage @packageArgs