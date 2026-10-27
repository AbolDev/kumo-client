# Prints the HTML table of download badges used in the README and in the release notes.
#
# Usage: tools/download_table.ps1                 links to the latest release (README)
#        tools/download_table.ps1 -Tag v1.3.3     links to the files of one release
#        tools/download_table.ps1 -Lang fa        Persian column titles
param(
  [string]$Tag = 'latest',
  [string]$Lang = 'en'
)

$repo = 'AbolDev/kumo-client'
$base = if ($Tag -eq 'latest') { "https://github.com/$repo/releases/latest/download" } else { "https://github.com/$repo/releases/download/$Tag" }

function Badge($label, $message, $color, $logo, $file) {
  $l = [uri]::EscapeDataString($label).Replace('-', '--')
  $m = [uri]::EscapeDataString($message).Replace('-', '--')
  $img = "https://img.shields.io/badge/$l-$m-$color`?style=flat&logo=$logo&logoColor=white&labelColor=555555"
  return "<a href=`"$base/$file`"><img src=`"$img`" alt=`"$label $message`"></a>"
}

$android = @(
  (Badge 'APK' 'Universal' '2e7d32' 'android' 'kumo-android-universal.apk'),
  (Badge 'APK' 'ARM64 (most phones)' '388e3c' 'android' 'kumo-android-arm64-v8a.apk'),
  (Badge 'APK' 'ARMv7' '43a047' 'android' 'kumo-android-armeabi-v7a.apk'),
  (Badge 'APK' 'x64' '66bb6a' 'android' 'kumo-android-x86_64.apk')
) -join "<br>`n      "
$windows = @(
  (Badge 'Setup' 'x64' '1565c0' 'windows11' 'kumo-windows-x64-setup.exe'),
  (Badge 'Portable' 'x64' '1976d2' 'windows11' 'kumo-windows-x64-portable.zip')
) -join "<br>`n      "
$macos = @(
  (Badge 'DMG' 'Universal' '424242' 'apple' 'kumo-macos-universal.dmg'),
  (Badge 'DMG' 'Apple silicon' '505050' 'apple' 'kumo-macos-arm64.dmg'),
  (Badge 'DMG' 'Intel' '616161' 'apple' 'kumo-macos-x64.dmg'),
  (Badge 'Portable' 'Universal' '757575' 'apple' 'kumo-macos-universal-portable.zip'),
  (Badge 'Portable' 'Apple silicon' '808080' 'apple' 'kumo-macos-arm64-portable.zip'),
  (Badge 'Portable' 'Intel' '8a8a8a' 'apple' 'kumo-macos-x64-portable.zip')
) -join "<br>`n      "
$linux = @(
  (Badge 'AppImage' 'amd64' 'e65100' 'linux' 'kumo-linux-x64.AppImage'),
  (Badge 'DEB' 'amd64' 'ea5a00' 'linux' 'kumo-linux-x64.deb'),
  (Badge 'RPM' 'amd64' 'ef6c00' 'linux' 'kumo-linux-x64.rpm'),
  (Badge 'Portable' 'amd64' 'f57c00' 'linux' 'kumo-linux-x64-portable.tar.gz'),
  (Badge 'AppImage' 'ARM64' 'f68a1f' 'linux' 'kumo-linux-arm64.AppImage'),
  (Badge 'DEB' 'ARM64' 'f89a3a' 'linux' 'kumo-linux-arm64.deb'),
  (Badge 'RPM' 'ARM64' 'fa9f48' 'linux' 'kumo-linux-arm64.rpm'),
  (Badge 'Portable' 'ARM64' 'fba85a' 'linux' 'kumo-linux-arm64-portable.tar.gz')
) -join "<br>`n      "

$system = if ($Lang -eq 'fa') { [regex]::Unescape('\u0633\u06cc\u0633\u062a\u0645') } else { 'System' }
$download = if ($Lang -eq 'fa') { [regex]::Unescape('\u062f\u0627\u0646\u0644\u0648\u062f') } else { 'Download' }

@"
<table>
  <tr><th>$system</th><th>$download</th></tr>
  <tr><td>Android</td><td>
      $android
  </td></tr>
  <tr><td>Windows</td><td>
      $windows
  </td></tr>
  <tr><td>macOS</td><td>
      $macos
  </td></tr>
  <tr><td>Linux</td><td>
      $linux
  </td></tr>
</table>
"@
