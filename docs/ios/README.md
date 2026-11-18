# Kumo for iOS: where it stands

This branch (`feature/ios`) is a trial. What was found, what was written, and what is left.

## What builds (tried in CI, `.github/workflows/ios-test.yml`)

- **The whole app builds for iOS without signing:** `flutter build ios --release --no-codesign` makes `Runner.app` (about 114 MB) with
  the tunnel extension `KumoTunnel.appex` in its `PlugIns`. There is no change to the Dart code that the build needed. The project is
  in `ios/`, for iOS 15.5 and later (the QR scanner, `mobile_scanner`, asks for it).
- **sing-box as a framework for iOS.** `go run ./cmd/internal/build_libbox -target apple -platform ios` (sing-box 1.13.21, the tags its own
  Apple build uses, among them `with_low_memory`) makes `Libbox.xcframework` (about 90 MB zipped; the job `libbox` keeps it as the file
  `libbox-ios` of the run). It is not in the repository: the job `ios` fetches it into `ios/Libbox/`.
- **AmneziaWG is in that framework.** `tools/libbox_patch/apply_amneziawg.sh` is run on the sing-box tree before the build, so the core of
  the phone has the endpoint of type `amneziawg` there as on Android. The app counts it as carried by the core on iOS (`amneziaInCore`
  in `lib/core/awg.dart`).

## What was written

- **The tunnel extension** (`ios/KumoTunnel`, Swift): `PacketTunnelProvider.swift` starts sing-box with the configuration the app hands over
  (and keeps it in the App Group folder for a start by the system alone), `KumoPlatformInterface.swift` answers what the core asks of the
  system (the tunnel settings and its file descriptor, the network monitor, the fixed answers of iOS). It is written against the API of the
  framework (the header it makes), not copied from another version; parts of the logic are adapted from `sing-box-for-apple` (GPL-3.0).
- **The app side** (`ios/Runner/KumoVpn.swift`): the same channels `VpnChannel` uses on Android (`kumo/control`, `kumo/status`,
  `kumo/traffic`): `prepare` (saves the VPN configuration, which is what makes iOS ask for the permission), `start`, `stop`, the state, and the small
  file store. What only Android has is answered with nothing.
- **`tools/ios_add_tunnel.rb`** added the target of the extension to `Runner.xcodeproj` (the result is kept in the repository, so the script
  says "already in the project"): bundle ids `app.kumo.vpn` and `app.kumo.vpn.tunnel`, the App Group `group.app.kumo.vpn`, the entitlements,
  `Libbox.xcframework`, `UIKit` and `NetworkExtension` (the Go library of sing-box names `UIApplication`).

## What has never been run

**None of it has run on a phone.** The build proves that it compiles and links, not that a tunnel comes up.

1. **An Apple Developer account (paid).** The `com.apple.developer.networking.networkextension` entitlement (`packet-tunnel-provider`) and an App Group
   are not given to free accounts, so the extension can be built here (without signing) but neither run on a phone nor sideloaded. Apple also
   asks that VPN apps in the App Store come from an enrolled organisation: check what that means for the account to be used. In the account:
   the two App IDs, the App Group, and a provisioning profile for each.
2. **A try on a phone,** first with a fixed small configuration, to see a TUN come up and the first connection go through.
3. **The limits of an extension.** A tunnel extension is ended when it uses more than about 50 MB: the rule lists, the ad blocker, a big
   configuration must stay small; `with_low_memory` is on in the framework. This needs measuring on a phone.
4. **What does not carry over from Android and the computers:**
   - **Xray-only servers** (XHTTP, mKCP ...) and **OpenVPN** need a program of their own, and iOS lets no program start another. They would need
     a library inside the extension (Xray, in the same Go framework as sing-box: two Go frameworks in one process do not work) or a second
     tunnel (OpenVPN), and are left out on iOS for now.
   - **The widgets, the quick tile, the shortcuts, the system proxy, per-app routing,** and the tests of a server with a temporary core (real
     delay, speed, safety check) are Android's or the computers'; on iOS the app answers them with nothing.
   - **The speeds and the data used** are not sent to the app from the extension yet (`kumo/traffic` is silent).
5. **TestFlight, then the App Store.**
