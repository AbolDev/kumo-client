$ErrorActionPreference = 'Stop'

$keys = Get-UninstallRegistryKey -SoftwareName 'Kumo*'
foreach ($key in $keys) {
  $file = $key.UninstallString -replace '^"?([^"]+)"?.*$', '$1'
  Uninstall-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType 'exe' `
    -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -File $file -ValidExitCodes @(0)
}