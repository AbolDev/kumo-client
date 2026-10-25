# Downloads the official sing-box and Xray-core builds for Windows and puts them in windows/core,
# from where the Windows build copies them next to kumo.exe.
#
#   kumo-core.exe  sing-box (TUN, routing, all protocols except XHTTP)
#   kumo-xray.exe  Xray-core (only used for XHTTP configs)
#   wintun.dll     virtual network adapter driver sing-box uses for the TUN device
param(
    [string]$SingBox = "1.13.21",
    [string]$Xray = "v26.10.21",
    [string]$Wintun = "0.14.1",
    [ValidateSet("x64", "arm64")][string]$Arch = "x64"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = Split-Path $PSScriptRoot -Parent
$out = "$root\windows\core"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("kumo-core-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $out, $tmp | Out-Null

function Get-Zip($url, $name) {
    $zip = "$tmp\$name.zip"
    Invoke-WebRequest $url -OutFile $zip
    Expand-Archive $zip "$tmp\$name" -Force
    return "$tmp\$name"
}

$sb = Get-Zip "https://github.com/SagerNet/sing-box/releases/download/v$SingBox/sing-box-$SingBox-windows-$(if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64' }).zip" "singbox"
Copy-Item (Get-ChildItem $sb -Recurse -Filter sing-box.exe | Select-Object -First 1).FullName "$out\kumo-core.exe" -Force

$xr = Get-Zip "https://github.com/XTLS/Xray-core/releases/download/$Xray/Xray-windows-$(if ($Arch -eq 'arm64') { 'arm64-v8a' } else { '64' }).zip" "xray"
Copy-Item "$xr\xray.exe" "$out\kumo-xray.exe" -Force

$wt = Get-Zip "https://www.wintun.net/builds/wintun-$Wintun.zip" "wintun"
Copy-Item "$wt\wintun\bin\$(if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64' })\wintun.dll" "$out\wintun.dll" -Force

Remove-Item $tmp -Recurse -Force
Get-ChildItem $out | Select-Object Name, Length
