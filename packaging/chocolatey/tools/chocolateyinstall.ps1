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
  $packageArgs.checksum64    = '522454b021621b2ae0c491597617001c2c309dfcc284da2be2935071d4b460d5'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.9.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '36fac696182713fab409a5d7449641c944538979f102b7a89d98949a09c775e7'
}
Install-ChocolateyPackage @packageArgs