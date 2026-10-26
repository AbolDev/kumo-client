<div align="center">

# Kumo

**A free, simple VPN app that finds working servers for you and connects to the fastest one.**

English · [فارسی](README.fa.md)

</div>

---

## What is Kumo?

Kumo is a free VPN app for Android, Windows, Linux and macOS. It collects public servers for you, checks which ones actually work, and connects you to the fastest one with a single tap. You can also add your own servers or subscriptions if you have them.

Kumo is powered by [sing-box](https://github.com/SagerNet/sing-box), a well-known open-source networking engine, and uses [Xray](https://github.com/XTLS/Xray-core) for what sing-box cannot carry (XHTTP, mKCP, TCP with HTTP headers, VLESS encryption). You can also choose Xray as the default core for the servers both can run.

## Features

**Connecting**

- **One-tap connection.** Press the big button and you are connected.
- **Automatic mode.** Kumo uses the server with the lowest ping. If it stops answering, Kumo switches to the next best one. A server you picked yourself is never switched.
- **Whole device or local proxy.** On Android all traffic of the device goes through the VPN by default (*Tunnel whole device*). On Windows Kumo starts as a local proxy (HTTP/SOCKS) that it also sets as the system proxy; turn the tunnel on to send everything through the VPN.
- **Per-app routing.** Choose which apps use the VPN, or which ones skip it.
- **Direct countries.** Pick countries whose sites and addresses skip the VPN. None by default.
- **Your own routing rules.** Send chosen domains or addresses always direct, or always through the VPN.
- **Share the connection** on your local network through a password-protected proxy.
- **Kill switch** to block the internet if the connection drops.
- **DNS, TLS fragment, MUX, MTU, uTLS fingerprint and proxy chain** under *Advanced*.

**Servers**

- **Free public servers.** The list is downloaded for you. You decide when to test it.
- **Add your own.** Paste a config or subscription link, import a file, or read a QR code. On Windows you can also drop files and QR pictures on the window, or read a QR code from an image, the screen or the clipboard.
- **Unlock locked files.** Open locked config files such as `.npvt` and `.npvs`.
- **Subscriptions.** Updated automatically, with the data and time you have left.
- **Speed tests.** Ping and real delay, and an option to remove servers that don't work.
- **Share.** Send any config as a link, a QR code or an image.
- **Backup.** Save your servers and settings to a file, optionally encrypted with a password.

**Monitoring**

- **Live speed** and a notification that shows the speed, the transferred data and the server name, each of which you can turn on or off.
- **Live connections** and **usage statistics** per day and per server.
- **IP, DNS and WebRTC leak check**, with *Strict DNS* (every lookup stays inside the VPN), *Block WebRTC leaks* and *Block ads and trackers* (a ready-made list, also in local proxy mode).
- **Service test and connection check** (the ⋮ menu): see whether ChatGPT, Netflix, YouTube, Telegram and others open through the current connection, or run a quick "why can't I connect?" check.
- **Why it disconnected**, shown on the home screen, and **alerts** when a subscription is nearly out of data or about to expire.
- **Android widgets** (button, icon-size, and a live speed / data widget that shows the server name when it is big enough), each with its own colour, shape and size. A *not connected* notification with a Connect button stays after a disconnect (can be turned off).

**Android extras:** a first-run guide (VPN permission, language, country), Android TV support with a remote control, a Quick Settings tile, a home screen widget, and reconnect after the phone restarts.

**Desktop extras (Windows, Linux, macOS):** a tray icon (closing the window keeps the VPN running), start when you sign in, and a layout made for wide windows.

**Protocols:** VLESS (with Reality, XHTTP and encryption), VMess, Trojan, Shadowsocks (with obfs, v2ray-plugin and ShadowTLS), Hysteria 2 and 1, TUIC, AnyTLS, WireGuard, SOCKS, SSH and NaiveProxy (not on Android), over TCP, WebSocket, gRPC, HTTP Upgrade, HTTP/2, QUIC, mKCP and XHTTP.

**Routing and tuning:** your own rules by domain, keyword, pattern, address or port (direct, through the VPN, or blocked), staying off on trusted Wi-Fi networks (Android), fake IP, DNS over HTTPS, HTTP/3, TLS, QUIC and TCP, TCP Fast Open, MUX protocols, a log level, and your own JSON for sing-box and Xray.

**Everything else:** light and dark themes, an update check against GitHub Releases, and seven languages: English, فارسی, العربية, Русский, Tiếng Việt, 简体中文 and 繁體中文. Kumo follows your device's language, or you can pick one in Settings.
## Download

Get the latest version from the [**Releases**](../../releases) page.

- **Android:** download the `.apk` file and open it. If your phone asks, allow installing apps from this source.
- **Linux (x64 and arm64):** install `kumo-linux-x64.deb` or `kumo-linux-arm64.deb` (`sudo apt install ./kumo-linux-x64.deb`); it also lets the VPN core open the tunnel without a password. Or take `kumo-linux-x64-portable.tar.gz` / `kumo-linux-arm64-portable.tar.gz`, extract it anywhere and run `kumo`: it keeps its data in a `kumo-data` folder next to it. It needs GTK 3, and the tray icon needs AppIndicator (`libayatana-appindicator3-1`).
- **macOS:** `kumo-macos-arm64.dmg` (Apple silicon: M1 and newer), `kumo-macos-x64.dmg` (Intel) or `kumo-macos-universal.dmg` (both). Open the disk image and drag **Kumo** to Applications. For no installation, use the matching `...-portable.zip`: extract it and run `Kumo.app`; it keeps its data in a `kumo-data` folder next to the app. macOS 11 or newer. Apple has not notarized it: open it with a right-click → **Open** the first time, or run `xattr -dr com.apple.quarantine Kumo.app`.
- **Windows:** download `kumo-windows-x64-setup.exe` and run it. It installs Kumo with an uninstaller. Kumo asks for administrator rights because it starts the VPN core and can change the system proxy. (Windows on ARM runs the x64 build through emulation; a native ARM build is not available yet.) Prefer no installation? Download `kumo-windows-x64-portable.zip`, extract it anywhere and run `kumo.exe`; it keeps its data in a `data` folder next to it. The portable version does not update itself: it opens the release page instead.

### Installing on Android

1. Open the downloaded `.apk`. If Android asks, allow your browser or file manager to install apps.
2. Google Play Protect may show **"App scan recommended – Play Protect hasn't seen this app before"**. This happens for every app that is not from Google Play and that Google has not scanned yet. It does not mean Kumo is harmful; the source code is public and the app is built by GitHub Actions.
3. Tap **Install without scanning** (under *More details* on some phones), or tap **Scan app** to let Google check it and then install.
4. After the first install, updates are signed with the same key, so they install over the old version without removing it.

### Linux and macOS

On Linux and macOS Kumo starts as a local proxy and sets it as the system proxy (GNOME, KDE and macOS network services). Turning on *Tunnel whole device* asks for your password once per connection (`pkexec` on Linux, the administrator prompt on macOS); the Linux `.deb` package gives the core the network capability instead, so it never asks.

### Installing on Windows

1. Run `kumo-windows-x64-setup.exe`.
2. Windows SmartScreen may say *"Windows protected your PC"* because the installer is not code-signed. Choose **More info**, then **Run anyway**.
3. Allow the administrator prompt. Kumo needs it to start the VPN core and change the system proxy.

You can check that a file is the one that was built by this repository by comparing its SHA-256 with the list in the release notes. Check for new versions in *Settings → About*.
## How to use

1. Open Kumo.
2. Wait a moment while the server list loads and is tested.
3. Tap the connect button. By default Kumo uses *Automatic*, which picks the fastest server.
4. On Android, allow the VPN permission the first time you connect.

Want a specific server? Tap it in the list before connecting.

### Adding your own servers

Tap **Add** and choose one of:

- **Add from clipboard**: copy a config or subscription link, then tap this.
- **Add from file**: import a file that contains your configs. Locked files such as `.npvt` and `.npvs` are unlocked automatically.
- **Scan QR code** (Android): use the camera or pick an image from your gallery. On Windows use *QR from the screen* (drag a box over the code), or *Add from file* / *Add from clipboard* with a picture of the QR code.

## Good to know

- Public servers are run by unknown people. **Do not use them for banking, private accounts or anything sensitive.** For those, use your own trusted server.
- Free servers can be slow or stop working at any time. Use *Refresh* to get a fresh list.
- With *Tunnel whole device* off, only apps that use Kumo's local proxy are protected. Apps like Telegram need the proxy set inside them.
- Kumo does not collect any data about you. See the [privacy policy](PRIVACY.md) for the few network requests it makes.

## Build from source

Kumo is a Flutter app (Flutter 3.27, Dart 3.6).

```
flutter pub get
flutter test
```

The app runs next to the sing-box and Xray cores, which are not stored in the repository:

- **Linux and macOS:** run `tools/fetch_unix_core.sh linux` (or `macos`) to download them into `linux/core` (`macos/core`), then `flutter build linux --release` (`flutter build macos --release`). The workflow also builds the `.deb` package and signs the macOS app ad hoc.
- **Windows:** run `tools/fetch_windows_core.ps1` to download them into `windows/core`, then `flutter build windows --release`. `installer/kumo.iss` (Inno Setup) builds the installer.
- **Android:** `tools/build_libbox.ps1` builds `libbox.aar` from sing-box and `tools/build_xray.ps1` builds the Xray binaries; the committed copies are for arm64 only. The GitHub Actions workflow (`.github/workflows/build.yml`) shows the full multi-CPU build.
- **Signing (Android):** without a key, release builds are signed with the debug key. To sign with your own key, create `android/key.properties` with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`.

## Help and feedback

Found a bug or have an idea? Please open an [issue](../../issues). Including your device, Android or Windows version and what you did before the problem happened helps a lot.

## Contributing

Contributions are welcome, including translations and bug fixes. Open an issue first if you plan a big change.

## Disclaimer

Kumo is a tool for your own privacy and for reaching the open internet. It does not provide servers, and it does not control the public servers it lists. You are responsible for following the laws where you live. The software is provided as is, without any warranty; see the license.

## License

Kumo is free software released under the **GNU General Public License v3.0**. It includes parts of [sing-box](https://github.com/SagerNet/sing-box) and [sing-box-for-android](https://github.com/SagerNet/sing-box-for-android), which use the same license.
