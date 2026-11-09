# Third-party software

Kumo is released under the GNU General Public License v3.0 (see `LICENSE`). It builds on and
ships the following work. Each part keeps its own license.

## Cores and drivers

| Component | Use | License |
| --- | --- | --- |
| [sing-box](https://github.com/SagerNet/sing-box) (`libbox` on Android, `kumo-core.exe` on Windows) | VPN core, routing, TUN | GPL-3.0-or-later with a name-use clause |
| [Xray-core](https://github.com/XTLS/Xray-core) (`libxray.so`, `kumo-xray.exe`) | XHTTP servers | MPL-2.0 |
| [TAP-Windows6](https://github.com/OpenVPN/tap-windows6) (`tap0901` driver files in `openvpn\driver`, put into Windows by Kumo the first time an OpenVPN server is used) | The network adapter of OpenVPN | GPL-2.0 (driver signed through Microsoft's hardware program) |
| [OpenVPN](https://github.com/OpenVPN/openvpn) (`openvpn.exe` and `tapctl.exe` from the signed official Windows installer, in the `openvpn` folder; run as a separate program, unchanged) | OpenVPN servers | GPL-2.0 with the OpenSSL exception (source: the link on the left) |
| [OpenVPN](https://github.com/OpenVPN/openvpn) 2.6.14 for Android (`libopenvpn.so`, built from the official source by `tools/android_openvpn/build.sh`, unchanged; the app runs it as a separate program and talks to it over its management channel) | OpenVPN servers on Android | GPL-2.0 with the OpenSSL exception (source: the link on the left) |
| [OpenSSL](https://www.openssl.org/) 3.0, [LZO](https://www.oberhumer.com/opensource/lzo/) 2.10 and [LZ4](https://github.com/lz4/lz4) 1.10 (linked into that OpenVPN) | Encryption and compression of OpenVPN | Apache-2.0; GPL-2.0-or-later; BSD-2-Clause (the library) |
| [wintun](https://www.wintun.net/) (`wintun.dll`) | Windows TUN adapter | Prebuilt binary under the WireGuard LLC license that comes with it |
| [sing-box-for-android](https://github.com/SagerNet/sing-box-for-android) | Parts of the Android VPN service | GPL-3.0-or-later |
| [shadowsocks-android](https://github.com/shadowsocks/shadowsocks-android) | `DefaultNetworkListener.kt` (Copyright 2019 Max Lv and Mygod Studio) | GPL-3.0-or-later |

`tools/libbox_patch/` holds Kumo's small addition to libbox (`MeasureDelay`). The sources of the
cores are available from the links above; the exact versions are set in
`.github/workflows/build.yml`.

## Config file formats

`assets/npvs/` holds tables that let Kumo open locked config files exported by other VPN apps
(`.npvt`, `.npvs` and similar), so a user can move their own servers into Kumo. They are included
for interoperability only. Those apps and their formats belong to their authors.

## Flutter and Dart packages

The packages listed in `pubspec.yaml` are used under their own licenses (BSD, MIT or Apache-2.0).
To see the full list with license texts, run the app and open *Licenses*, or run
`flutter pub deps`.

## Vazirmatn

The font of Persian and Arabic text in the app: [Vazirmatn](https://github.com/rastikerdar/vazirmatn) by Saber Rastikerdar, under the SIL Open Font License 1.1 (assets/fonts/OFL.txt).
