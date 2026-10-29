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
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.11.0/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = 'f5676f4ced1e132fe07260b867165495f21714ca823b1aef19aa90208281a1a6'
} else {
  $packageArgs.url64bit      = 'https://github.com/AbolDev/kumo-client/releases/download/v1.11.0/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '85f149b1817fb19443a0419795b4cf2200cecede5cb9622b5cd74f0024cb8354'
}
Install-ChocolateyPackage @packageArgs