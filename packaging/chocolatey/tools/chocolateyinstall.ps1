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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.12.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'd2a1feefd8566187f4dfb2a0101a703c42a5d3d087a924ed523d5e66d7784996'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.12.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '8f83eb6d0a67838d45d7434e68e9a2eaa3b70fc83bf19fc4382a475121fe8660'
}
Install-ChocolateyPackage @packageArgs