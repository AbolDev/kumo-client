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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.10.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'c43b07033dd3158b34c18b685696d1a67f6f1aca5f9b7a15efaaa98397c0e557'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.10.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '23b879f238c2a809a28853dd86a346d8ad1013db85ae6ca26398970401e7618b'
}
Install-ChocolateyPackage @packageArgs