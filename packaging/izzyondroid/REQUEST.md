# IzzyOnDroid: request for inclusion

Post this as a new issue in https://gitlab.com/IzzyOnDroid/repo/-/issues (template "Inclusion request"),
or follow the current instructions at https://gitlab.com/IzzyOnDroid/repo/-/blob/master/README.md.

- App: Kumo (`app.kumo.vpn`)
- Source: https://github.com/AbolDev/kumo-client
- License: GPL-3.0
- Releases: https://github.com/AbolDev/kumo-client/releases (signed APKs for arm64-v8a, armeabi-v7a,
  x86_64 and a universal one, named `kumo-android-*.apk`)
- Short description: Free VPN client powered by sing-box and Xray.
- Anti-features: none known. The app contains no ads and no trackers. It connects only to the servers
  and subscription links the user adds, and to GitHub (update check) and public IP/DNS test services
  when the user opens those tools.
- Notes: the native cores (sing-box libbox and Xray) are built from source in the repository's CI
  (`.github/workflows/build.yml`), not downloaded as binaries.
- Fastlane metadata is in the repository under `fastlane/metadata/android`.