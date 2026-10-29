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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.10.1/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'abefd666f5a1d1c52d2f6f0dabc0746679a8bcaf8d9766be041ea817f842f757'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.10.1/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '5e55104b50c578a489427c744650f1b68f3272482dfa219233d205ed098b4124'
}
Install-ChocolateyPackage @packageArgs