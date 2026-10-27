# F-Droid

A draft of what the F-Droid maintainers need in https://gitlab.com/fdroid/fdroiddata :

- `metadata/app.kumo.vpn.yml` goes to `metadata/` there.
- `srclibs/sing-box.yml` and `srclibs/xray-core.yml` go to `srclibs/` there (the `flutter` and `go`
  entries already exist).

**The build steps are not tested.** F-Droid builds everything from source on its own servers, so the
recipe has to run there: run `fdroid build app.kumo.vpn` (fdroidserver, Debian) and fix what fails, or
let the merge request's CI do it. The steps copy `.github/workflows/build.yml` (libbox with gomobile,
Xray with the NDK, then `flutter build apk`). Things to decide before sending the merge request:

1. **License text.** The repository says `GPL-3.0-only` here and in the packages, but the macOS and
   Windows resource files say `GPL-3.0-or-later`. Pick one and make them match.
2. **`assets/npvs/*.bin` and `crypt5-keys.json`.** Binary data files; the reviewers will ask where they
   come from and under what license.
3. **Committed binaries.** `android/app/libs/libbox.aar` and `jniLibs/arm64-v8a/libxray.so` are in the
   repository. The recipe removes them and builds both from source (`rm:`); they could also be taken
   out of the repository.
4. **ABIs.** The recipe builds one universal APK. F-Droid may want one APK per CPU with its own
   version code (`--split-per-abi`).
5. **The updater.** `--dart-define=FDROID=true` (see `lib/core/build_flavor.dart`) turns off the
   update check and install in this build, and the recipe removes `REQUEST_INSTALL_PACKAGES`.

Steps to send it: make a GitLab account, fork `fdroid/fdroiddata`, add the files, run
`fdroid lint app.kumo.vpn` and `fdroid build`, and open a merge request with the label "New App".