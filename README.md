<div align="center">

<img src="docs/images/banner.png" alt="Kumo: a free, simple VPN for Android, Windows, Linux and macOS" width="100%">

English · [فارسی](README.fa.md)

</div>

## What is Kumo?

Kumo is a free VPN app for Android, Windows, Linux and macOS. It collects public servers, tests which ones work, and connects you to the fastest with one tap. You can also add your own servers or subscriptions. It is powered by [sing-box](https://github.com/SagerNet/sing-box) and [Xray](https://github.com/XTLS/Xray-core).

## Download

<div align="center">

<table>
  <tr><th>System</th><th>Download</th></tr>
  <tr><td>Android</td><td>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-android-universal.apk"><img src="https://img.shields.io/badge/APK-Universal-2e7d32?style=flat&logo=android&logoColor=white&labelColor=555555" alt="APK Universal"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-android-arm64-v8a.apk"><img src="https://img.shields.io/badge/APK-ARM64%20(most%20phones)-388e3c?style=flat&logo=android&logoColor=white&labelColor=555555" alt="APK ARM64 (most phones)"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-android-armeabi-v7a.apk"><img src="https://img.shields.io/badge/APK-ARMv7-43a047?style=flat&logo=android&logoColor=white&labelColor=555555" alt="APK ARMv7"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-android-x86_64.apk"><img src="https://img.shields.io/badge/APK-x64-66bb6a?style=flat&logo=android&logoColor=white&labelColor=555555" alt="APK x64"></a>
  </td></tr>
  <tr><td>Windows</td><td>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-windows-x64-setup.exe"><img src="https://img.shields.io/badge/Setup-x64-1565c0?style=flat&logo=windows11&logoColor=white&labelColor=555555" alt="Setup x64"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-windows-x64-portable.zip"><img src="https://img.shields.io/badge/Portable-x64-1976d2?style=flat&logo=windows11&logoColor=white&labelColor=555555" alt="Portable x64"></a>
  </td></tr>
  <tr><td>macOS</td><td>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-universal.dmg"><img src="https://img.shields.io/badge/DMG-Universal-424242?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="DMG Universal"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-arm64.dmg"><img src="https://img.shields.io/badge/DMG-Apple%20silicon-505050?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="DMG Apple silicon"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-x64.dmg"><img src="https://img.shields.io/badge/DMG-Intel-616161?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="DMG Intel"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-universal-portable.zip"><img src="https://img.shields.io/badge/Portable-Universal-757575?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="Portable Universal"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-arm64-portable.zip"><img src="https://img.shields.io/badge/Portable-Apple%20silicon-808080?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="Portable Apple silicon"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-macos-x64-portable.zip"><img src="https://img.shields.io/badge/Portable-Intel-8a8a8a?style=flat&logo=apple&logoColor=white&labelColor=555555" alt="Portable Intel"></a>
  </td></tr>
  <tr><td>Linux</td><td>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-linux-x64.deb"><img src="https://img.shields.io/badge/DEB-amd64-e65100?style=flat&logo=linux&logoColor=white&labelColor=555555" alt="DEB amd64"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-linux-arm64.deb"><img src="https://img.shields.io/badge/DEB-ARM64-ef6c00?style=flat&logo=linux&logoColor=white&labelColor=555555" alt="DEB ARM64"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-linux-x64-portable.tar.gz"><img src="https://img.shields.io/badge/Portable-amd64-f57c00?style=flat&logo=linux&logoColor=white&labelColor=555555" alt="Portable amd64"></a><br>
      <a href="https://github.com/AbolDev/kumo-client/releases/latest/download/kumo-linux-arm64-portable.tar.gz"><img src="https://img.shields.io/badge/Portable-ARM64-fb8c00?style=flat&logo=linux&logoColor=white&labelColor=555555" alt="Portable ARM64"></a>
  </td></tr>
</table>

</div>

Not sure which Android file? Use **ARM64**, or **Universal** which works everywhere. Portable packages keep their data next to them.

The apps are not code-signed or on Google Play, so Play Protect, SmartScreen or Gatekeeper may warn: tap *More details → Install anyway* (Android), *More info → Run anyway* (Windows), or right-click → *Open* (macOS). Compare a file's SHA-256 with the one GitHub shows next to it in the release.

## Features

- One-tap connect, automatic fastest server, automatic switch when a server stops answering.
- Whole device (Android) or local proxy; per-app routing, direct countries, your own routing rules.
- Free public servers, your own configs and subscriptions (links, QR codes, files; Clash, sing-box, Xray and Surge formats).
- Many protocols: VLESS, VMess, Trojan, Shadowsocks, Hysteria 1 and 2, TUIC, AnyTLS, WireGuard, SOCKS, SSH and more.
- Privacy: kill switch, strict DNS, WebRTC leak block, ad and tracker block, IP and DNS leak tests.
- Speed tests, live speed and usage, widgets, tray icon, Android TV, seven languages.

## How to use

1. Open Kumo and wait for the server list to load.
2. Tap the connect button (*Automatic* picks the fastest server).
3. On Android, allow the VPN permission the first time.

## Good to know

- Public servers are run by unknown people. **Do not use them for banking or anything sensitive.**
- Kumo collects no data about you. See the [privacy policy](PRIVACY.md).

## Build from source

Flutter 3.27 (Dart 3.6): lutter pub get, lutter test. The sing-box and Xray cores are not in the repository: 	ools/fetch_unix_core.sh (Linux, macOS), 	ools/fetch_windows_core.ps1 (Windows), 	ools/build_libbox.ps1 and 	ools/build_xray.ps1 (Android). The workflow in .github/workflows/build.yml shows the full build.

## Feedback

Found a bug or have an idea? Open an [issue](../../issues).

## Disclaimer and license

Kumo does not provide servers and does not control the public servers it lists. You are responsible for following the laws where you live. The software is provided as is. Kumo is free software under the **GNU GPL v3.0** and includes parts of [sing-box](https://github.com/SagerNet/sing-box) and [sing-box-for-android](https://github.com/SagerNet/sing-box-for-android).
