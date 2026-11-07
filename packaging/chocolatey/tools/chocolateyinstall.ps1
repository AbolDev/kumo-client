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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.12.1/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = '483d7c62b78272e1957ec3e1a73f3c3fd290e75e647a16219ca11c8459fe57ad'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.12.1/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '31e848f958d84cd5a46bcffae97fc9a05f04b2c732adf94d53cd5fc93987fe93'
}
Install-ChocolateyPackage @packageArgs