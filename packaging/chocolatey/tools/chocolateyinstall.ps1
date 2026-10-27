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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.8.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = '707e37dbe7192e7038266dfcd6516d1e64557295edadabf98435d273f5054227'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.8.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '7fcea3fc21d8ec8d5b6517a33dbccfd62c2cf526ebc46d747716279ae6bfd6e9'
}
Install-ChocolateyPackage @packageArgs