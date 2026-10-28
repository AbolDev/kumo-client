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

# Every download is checked against the hash pinned in tools\core_sha256.txt before it is used.
function Test-Pinned($file, $pinnedName) {
    $line = Get-Content "$PSScriptRoot\core_sha256.txt" | Where-Object { $_ -match "^[0-9a-f]{64}\s+" + [regex]::Escape($pinnedName) + "$" } | Select-Object -First 1
    if (-not $line) { throw "no pinned hash for $pinnedName in tools\core_sha256.txt" }
    $want = ($line -split '\s+')[0]
    $got = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { throw "checksum mismatch for ${pinnedName}: got $got, expected $want" }
}

function Get-Zip($url, $name, $pinnedName) {
    $zip = "$tmp\$name.zip"
    Invoke-WebRequest $url -OutFile $zip
    Test-Pinned $zip $pinnedName
    Expand-Archive $zip "$tmp\$name" -Force
    return "$tmp\$name"
}

$sbArch = if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64' }
$sb = Get-Zip "https://github.com/SagerNet/sing-box/releases/download/v$SingBox/sing-box-$SingBox-windows-$sbArch.zip" "singbox" "sing-box-$SingBox-windows-$sbArch.zip"
Copy-Item (Get-ChildItem $sb -Recurse -Filter sing-box.exe | Select-Object -First 1).FullName "$out\kumo-core.exe" -Force
# NaiveProxy servers need Chromium's network stack, which sing-box loads from this library.
$cronet = Get-ChildItem $sb -Recurse -Filter libcronet.dll | Select-Object -First 1
if ($cronet) { Copy-Item $cronet.FullName "$out\libcronet.dll" -Force }

$xrArch = if ($Arch -eq 'arm64') { 'arm64-v8a' } else { '64' }
$xr = Get-Zip "https://github.com/XTLS/Xray-core/releases/download/$Xray/Xray-windows-$xrArch.zip" "xray" "Xray-$Xray-windows-$xrArch.zip"
Copy-Item "$xr\xray.exe" "$out\kumo-xray.exe" -Force

$wt = Get-Zip "https://www.wintun.net/builds/wintun-$Wintun.zip" "wintun" "wintun-$Wintun.zip"
Copy-Item "$wt\wintun\bin\$(if ($Arch -eq 'arm64') { 'arm64' } else { 'amd64' })\wintun.dll" "$out\wintun.dll" -Force

Remove-Item $tmp -Recurse -Force
Get-ChildItem $out | Select-Object Name, Length
