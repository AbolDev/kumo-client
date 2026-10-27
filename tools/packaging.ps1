# Writes the package manifests for the stores (winget, Scoop, Chocolatey, Homebrew, AUR, Flatpak,
# Snap) into packaging/, with the addresses and SHA-256 of one release's files.
#
# Usage: pwsh tools/packaging.ps1 -Tag v1.7.0
#        (needs the GitHub CLI, `gh`, logged in: the checksums come from the release)
param([Parameter(Mandatory)][string]$Tag)

$ErrorActionPreference = 'Stop'
$repo = 'AbolDev/kumo-client'
$ver = $Tag.TrimStart('v')
$base = "https://github.com/$repo/releases/download/$Tag"
$root = Split-Path -Parent $PSScriptRoot

$rel = gh api "repos/$repo/releases/tags/$Tag" | ConvertFrom-Json
$date = ([datetime]$rel.published_at).ToString('yyyy-MM-dd')
function Sha($name) {
  $a = $rel.assets | Where-Object { $_.name -eq $name }
  if (-not $a) { throw "the release has no file named $name" }
  if (-not $a.digest) { throw "no checksum is given for $name" }
  return $a.digest -replace '^sha256:', ''
}

$map = @{
  '@@VER@@'          = $ver
  '@@TAG@@'          = $Tag
  '@@DATE@@'         = $date
  '@@BASE@@'         = $base
  '@@SHA_SETUP_X64@@' = Sha 'kumo-windows-x64-setup.exe'
  '@@SHA_SETUP_ARM@@' = Sha 'kumo-windows-arm64-setup.exe'
  '@@SHA_WZIP_X64@@'  = Sha 'kumo-windows-x64-portable.zip'
  '@@SHA_WZIP_ARM@@'  = Sha 'kumo-windows-arm64-portable.zip'
  '@@SHA_DMG@@'       = Sha 'kumo-macos-universal.dmg'
  '@@SHA_TAR_X64@@'   = Sha 'kumo-linux-x64-portable.tar.gz'
  '@@SHA_TAR_ARM@@'   = Sha 'kumo-linux-arm64-portable.tar.gz'
}
$map['@@SHA_SETUP_X64_UP@@'] = $map['@@SHA_SETUP_X64@@'].ToUpper()
$map['@@SHA_SETUP_ARM_UP@@'] = $map['@@SHA_SETUP_ARM@@'].ToUpper()

function Put($path, $text) {
  foreach ($k in $map.Keys) { $path = $path.Replace($k, $map[$k]) }
  $full = Join-Path $root $path
  New-Item -ItemType Directory -Force (Split-Path -Parent $full) | Out-Null
  foreach ($k in $map.Keys) { $text = $text.Replace($k, $map[$k]) }
  # LF line ends, no byte order mark
  [IO.File]::WriteAllText($full, ($text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  Write-Host "wrote $path"
}

$short = 'Free VPN client powered by sing-box and Xray'
$long = 'Kumo connects to the servers and subscriptions you choose. It can run as a local proxy (also set as the system proxy) or tunnel the whole computer, and it supports many protocols, subscriptions, routing rules, ad blocking and more.'

# ----------------------------------------------------------------------------------- winget
$wdir = 'packaging/winget/manifests/a/AbolDev/Kumo/@@VER@@'
Put "$wdir/AbolDev.Kumo.yaml" @'
# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: AbolDev.Kumo
PackageVersion: @@VER@@
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
'@
Put "$wdir/AbolDev.Kumo.installer.yaml" @'
# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: AbolDev.Kumo
PackageVersion: @@VER@@
InstallerLocale: en-US
InstallerType: inno
Scope: machine
InstallModes:
- interactive
- silent
- silentWithProgress
InstallerSwitches:
  Silent: /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  SilentWithProgress: /SILENT /SUPPRESSMSGBOXES /NORESTART
UpgradeBehavior: install
ReleaseDate: @@DATE@@
Installers:
- Architecture: x64
  InstallerUrl: @@BASE@@/kumo-windows-x64-setup.exe
  InstallerSha256: @@SHA_SETUP_X64_UP@@
  ProductCode: '{7D2C5E0A-4B1F-4C7A-9E3B-5A6F0D8C1B24}_is1'
- Architecture: arm64
  InstallerUrl: @@BASE@@/kumo-windows-arm64-setup.exe
  InstallerSha256: @@SHA_SETUP_ARM_UP@@
  ProductCode: '{7D2C5E0A-4B1F-4C7A-9E3B-5A6F0D8C1B24}_is1'
ManifestType: installer
ManifestVersion: 1.6.0
'@
Put "$wdir/AbolDev.Kumo.locale.en-US.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: AbolDev.Kumo
PackageVersion: @@VER@@
PackageLocale: en-US
Publisher: AbolDev
PublisherUrl: https://github.com/AbolDev
PublisherSupportUrl: https://github.com/$repo/issues
PackageName: Kumo
PackageUrl: https://github.com/$repo
License: GPL-3.0-only
LicenseUrl: https://github.com/$repo/blob/main/LICENSE
ShortDescription: $short
Description: $long
Moniker: kumo
Tags:
- proxy
- sing-box
- v2ray
- vpn
- xray
ReleaseNotesUrl: https://github.com/$repo/releases/tag/@@TAG@@
ManifestType: defaultLocale
ManifestVersion: 1.6.0
"@

# ----------------------------------------------------------------------------------- Scoop
Put 'packaging/scoop/kumo.json' @"
{
    "version": "@@VER@@",
    "description": "$short",
    "homepage": "https://github.com/$repo",
    "license": "GPL-3.0-only",
    "notes": "Kumo asks for administrator rights when it starts: the tunnel needs them.",
    "architecture": {
        "64bit": {
            "url": "@@BASE@@/kumo-windows-x64-portable.zip",
            "hash": "@@SHA_WZIP_X64@@"
        },
        "arm64": {
            "url": "@@BASE@@/kumo-windows-arm64-portable.zip",
            "hash": "@@SHA_WZIP_ARM@@"
        }
    },
    "shortcuts": [
        [
            "kumo.exe",
            "Kumo"
        ]
    ],
    "persist": "data",
    "checkver": "github",
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "https://github.com/$repo/releases/download/v`$version/kumo-windows-x64-portable.zip"
            },
            "arm64": {
                "url": "https://github.com/$repo/releases/download/v`$version/kumo-windows-arm64-portable.zip"
            }
        }
    }
}
"@

# ----------------------------------------------------------------------------------- Chocolatey
Put 'packaging/chocolatey/kumo.nuspec' @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>kumo</id>
    <version>@@VER@@</version>
    <title>Kumo</title>
    <authors>AbolDev</authors>
    <owners>AbolDev</owners>
    <projectUrl>https://github.com/$repo</projectUrl>
    <projectSourceUrl>https://github.com/$repo</projectSourceUrl>
    <bugTrackerUrl>https://github.com/$repo/issues</bugTrackerUrl>
    <licenseUrl>https://github.com/$repo/blob/main/LICENSE</licenseUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <iconUrl>https://raw.githubusercontent.com/$repo/main/assets/tray_icon.png</iconUrl>
    <tags>vpn proxy sing-box xray v2ray</tags>
    <summary>$short</summary>
    <description>$long</description>
    <releaseNotes>https://github.com/$repo/releases/tag/@@TAG@@</releaseNotes>
  </metadata>
  <files>
    <file src="tools\**" target="tools" />
  </files>
</package>
"@
Put 'packaging/chocolatey/tools/chocolateyinstall.ps1' @'
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
  $packageArgs.url64bit      = '@@BASE@@/kumo-windows-arm64-setup.exe'
  $packageArgs.checksum64    = '@@SHA_SETUP_ARM@@'
} else {
  $packageArgs.url64bit      = '@@BASE@@/kumo-windows-x64-setup.exe'
  $packageArgs.checksum64    = '@@SHA_SETUP_X64@@'
}
Install-ChocolateyPackage @packageArgs
'@
Put 'packaging/chocolatey/tools/chocolateyuninstall.ps1' @'
$ErrorActionPreference = 'Stop'

$keys = Get-UninstallRegistryKey -SoftwareName 'Kumo*'
foreach ($key in $keys) {
  $file = $key.UninstallString -replace '^"?([^"]+)"?.*$', '$1'
  Uninstall-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType 'exe' `
    -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -File $file -ValidExitCodes @(0)
}
'@

# ----------------------------------------------------------------------------------- Homebrew
Put 'packaging/homebrew/Casks/kumo.rb' @"
cask "kumo" do
  version "@@VER@@"
  sha256 "@@SHA_DMG@@"

  url "https://github.com/$repo/releases/download/v#{version}/kumo-macos-universal.dmg"
  name "Kumo"
  desc "$short"
  homepage "https://github.com/$repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Kumo.app"

  # The app is not notarized yet: the quarantine mark would stop it from opening.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Kumo.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Kumo",
    "~/Library/Preferences/app.kumo.vpn.plist",
    "~/Library/Saved Application State/app.kumo.vpn.savedState",
  ]
end
"@

# ----------------------------------------------------------------------------------- AUR
Put 'packaging/aur/kumo-bin/PKGBUILD' @"
# Maintainer: AbolDev <abolfazlbaghery07@gmail.com>
pkgname=kumo-bin
pkgver=@@VER@@
pkgrel=1
pkgdesc="$short"
arch=('x86_64' 'aarch64')
url="https://github.com/$repo"
license=('GPL-3.0-only')
depends=('gtk3' 'libayatana-appindicator' 'polkit')
provides=('kumo')
conflicts=('kumo')
options=('!strip' '!debug')
install=kumo.install
source_x86_64=("kumo-`$pkgver-x86_64.tar.gz::`$url/releases/download/v`$pkgver/kumo-linux-x64-portable.tar.gz")
source_aarch64=("kumo-`$pkgver-aarch64.tar.gz::`$url/releases/download/v`$pkgver/kumo-linux-arm64-portable.tar.gz")
sha256sums_x86_64=('@@SHA_TAR_X64@@')
sha256sums_aarch64=('@@SHA_TAR_ARM@@')

package() {
  install -d "`$pkgdir/opt/kumo"
  cp -a "`$srcdir/kumo/." "`$pkgdir/opt/kumo/"
  # the "portable" marker would keep the data next to the program
  rm -f "`$pkgdir/opt/kumo/portable" "`$pkgdir/opt/kumo/.gitignore"

  install -d "`$pkgdir/usr/bin"
  ln -s /opt/kumo/kumo "`$pkgdir/usr/bin/kumo"
  install -Dm644 "`$pkgdir/opt/kumo/data/kumo.png" "`$pkgdir/usr/share/pixmaps/kumo.png"

  install -Dm644 /dev/stdin "`$pkgdir/usr/share/applications/kumo.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Kumo
Comment=$short
Exec=/opt/kumo/kumo
Icon=kumo
Terminal=false
Categories=Network;
EOF
}
"@
Put 'packaging/aur/kumo-bin/kumo.install' @'
# Lets the VPN core open the tunnel (TUN) without asking for a password every time.
post_install() {
  setcap cap_net_admin,cap_net_bind_service,cap_net_raw+ep /opt/kumo/kumo-core || true
}

post_upgrade() {
  post_install
}
'@
Put 'packaging/aur/kumo-bin/.SRCINFO' @"
pkgbase = kumo-bin
	pkgdesc = $short
	pkgver = @@VER@@
	pkgrel = 1
	url = https://github.com/$repo
	install = kumo.install
	arch = x86_64
	arch = aarch64
	license = GPL-3.0-only
	depends = gtk3
	depends = libayatana-appindicator
	depends = polkit
	provides = kumo
	conflicts = kumo
	options = !strip
	options = !debug
	source_x86_64 = kumo-@@VER@@-x86_64.tar.gz::https://github.com/$repo/releases/download/v@@VER@@/kumo-linux-x64-portable.tar.gz
	sha256sums_x86_64 = @@SHA_TAR_X64@@
	source_aarch64 = kumo-@@VER@@-aarch64.tar.gz::https://github.com/$repo/releases/download/v@@VER@@/kumo-linux-arm64-portable.tar.gz
	sha256sums_aarch64 = @@SHA_TAR_ARM@@

pkgname = kumo-bin
"@

# ----------------------------------------------------------------------------------- Flatpak
Put 'packaging/flatpak/app.kumo.vpn.yml' @"
app-id: app.kumo.vpn
runtime: org.gnome.Platform
runtime-version: '47'
sdk: org.gnome.Sdk
command: kumo
finish-args:
  - --share=network
  - --share=ipc
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
  # the tray icon
  - --talk-name=org.kde.StatusNotifierWatcher
  - --filesystem=xdg-download
modules:
  - name: kumo
    buildsystem: simple
    build-commands:
      - mkdir -p /app/lib/kumo
      - cp -a . /app/lib/kumo/
      - rm -f /app/lib/kumo/portable /app/lib/kumo/.gitignore
      - mkdir -p /app/bin
      - ln -s /app/lib/kumo/kumo /app/bin/kumo
      - install -Dm644 data/kumo.png /app/share/icons/hicolor/512x512/apps/app.kumo.vpn.png
      - install -Dm644 app.kumo.vpn.desktop /app/share/applications/app.kumo.vpn.desktop
      - install -Dm644 app.kumo.vpn.metainfo.xml /app/share/metainfo/app.kumo.vpn.metainfo.xml
    sources:
      - type: archive
        url: @@BASE@@/kumo-linux-x64-portable.tar.gz
        sha256: @@SHA_TAR_X64@@
        only-arches: [x86_64]
      - type: archive
        url: @@BASE@@/kumo-linux-arm64-portable.tar.gz
        sha256: @@SHA_TAR_ARM@@
        only-arches: [aarch64]
      - type: file
        path: app.kumo.vpn.desktop
      - type: file
        path: app.kumo.vpn.metainfo.xml
"@
Put 'packaging/flatpak/app.kumo.vpn.desktop' @"
[Desktop Entry]
Type=Application
Name=Kumo
Comment=$short
Exec=kumo
Icon=app.kumo.vpn
Terminal=false
Categories=Network;
"@
Put 'packaging/flatpak/app.kumo.vpn.metainfo.xml' @"
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>app.kumo.vpn</id>
  <name>Kumo</name>
  <summary>$short</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>GPL-3.0-only</project_license>
  <developer id="io.github.AbolDev"><name>AbolDev</name></developer>
  <description>
    <p>$long</p>
    <p>In this package the tunnel cannot be opened (the sandbox does not allow it): Kumo works as a local proxy.</p>
  </description>
  <launchable type="desktop-id">app.kumo.vpn.desktop</launchable>
  <url type="homepage">https://github.com/$repo</url>
  <url type="bugtracker">https://github.com/$repo/issues</url>
  <screenshots>
    <screenshot type="default">
      <image>https://raw.githubusercontent.com/$repo/main/docs/screenshots/desktop-connected.png</image>
    </screenshot>
  </screenshots>
  <content_rating type="oars-1.1" />
  <releases>
    <release version="@@VER@@" date="@@DATE@@" />
  </releases>
</component>
"@

# ----------------------------------------------------------------------------------- Snap
Put 'packaging/snap/snapcraft.yaml' @"
name: kumo
base: core24
version: '@@VER@@'
summary: $short
description: |
  $long
  In the Snap the tunnel cannot be opened (strict confinement): Kumo works as a local proxy.
grade: stable
confinement: strict
platforms:
  amd64:
  arm64:
apps:
  kumo:
    command: opt/kumo/kumo
    extensions: [gnome]
    plugs:
      - network
      - network-bind
      - home
parts:
  kumo:
    plugin: nil
    build-packages: [curl]
    override-build: |
      case "`$CRAFT_ARCH_BUILD_FOR" in
        amd64) file=kumo-linux-x64-portable.tar.gz; sum=@@SHA_TAR_X64@@ ;;
        arm64) file=kumo-linux-arm64-portable.tar.gz; sum=@@SHA_TAR_ARM@@ ;;
      esac
      curl -fsSL -o /tmp/kumo.tgz "@@BASE@@/`$file"
      echo "`$sum  /tmp/kumo.tgz" | sha256sum -c -
      mkdir -p "`$CRAFT_PART_INSTALL/opt"
      tar -xzf /tmp/kumo.tgz -C "`$CRAFT_PART_INSTALL/opt"
      rm -f "`$CRAFT_PART_INSTALL/opt/kumo/portable" "`$CRAFT_PART_INSTALL/opt/kumo/.gitignore"
    stage-packages:
      - libayatana-appindicator3-1
"@

Write-Host "done for $Tag"
