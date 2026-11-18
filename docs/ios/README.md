# Kumo for iOS: where it stands

This branch (`feature/ios`) is a trial. What was found, and what is left.

## What works (tried in CI, `.github/workflows/ios-test.yml`)

- **The app builds for iOS without signing.** `flutter build ios --release --no-codesign` makes `Runner.app` (54 MB) with no
  change to the Dart code. The project is in `ios/`, for iOS 15.5 and later (the QR scanner, `mobile_scanner`, asks for it).
  The plugins the app uses for the phone (QR, gallery, share, file) build; the ones only for a computer (`window_manager`,
  `tray_manager`, `desktop_drop`, `dynamic_color`) are left out by Flutter on this system.
- **sing-box builds as a framework for iOS.** `go run ./cmd/internal/build_libbox -target apple -platform ios` (sing-box 1.13.21, the
  tags its own Apple build uses, among them `with_low_memory`) makes `Libbox.xcframework` (the `libbox-ios` file of the run, 86 MB zipped).

## What does not exist yet

Nothing here connects: on iOS the connect button has no code behind it.

1. **The tunnel extension (Swift).** iOS runs a VPN only inside a *Packet Tunnel Provider*, a second target of the app (an app
   extension, its own bundle id, e.g. `app.kumo.vpn.tunnel`) that links `Libbox.xcframework`, implements libbox's platform interface
   (the TUN file descriptor, the network monitor, the protection of sockets) and starts the core with the configuration the app
   gives it. `sing-box-for-apple` is the reference for it. The project has no such target; adding one means editing
   `Runner.xcodeproj` (with the `xcodeproj` gem or by hand) and writing the Swift.
2. **The app side.** `VpnChannel` knows Android and the computers. For iOS: a method channel in `AppDelegate.swift` that keeps a
   `NETunnelProviderManager`, saves the configuration for the extension (shared through an *App Group*), starts and stops the
   tunnel and reports its state.
3. **An Apple Developer account (paid).** The `com.apple.developer.networking.networkextension` entitlement (`packet-tunnel-provider`) and
   an App Group are not given to free accounts, so the extension can be built here (without signing) but neither run on a phone
   nor sideloaded. Apple also asks that VPN apps in the App Store come from an enrolled organisation: check what that means for
   the account to be used.
4. **Cores other than sing-box.** The extension cannot start another program, so what Android and the computers do with a helper
   (Xray, `kumo-awg`, OpenVPN) does not carry over:
   - **AmneziaWG:** its endpoint can be built into libbox (`tools/libbox_patch/apply_amneziawg.sh` on the sing-box tree), as on Android.
   - **Xray-only servers** (XHTTP, mKCP ...): need Xray as a library inside the extension, or are left out on iOS.
   - **OpenVPN:** needs an OpenVPN library (not a program). Left out at first.
5. **The limits of an extension.** A tunnel extension is killed when it uses more than about 50 MB: the configuration (rule lists, the
   ad blocker) must stay small; `with_low_memory` is on for iOS in the framework above.
6. **What has no iOS equivalent:** the widgets and the quick tile (Android), the shortcuts, the system proxy, per-app routing.

## An order of work

1. Decide on the Apple account (item 3). Nothing after it can be run without it.
2. The tunnel extension with a fixed test configuration, to see a TUN come up on a phone.
3. The channel of the app and its state.
4. AmneziaWG in libbox; the lists and settings that fit the memory of the extension.
5. TestFlight, then the App Store.
