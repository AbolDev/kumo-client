# F-Droid

A draft of what the F-Droid maintainers need in https://gitlab.com/fdroid/fdroiddata :

- `metadata/app.kumo.vpn.yml` goes to `metadata/` there.
- `srclibs/sing-box.yml` and `srclibs/xray-core.yml` go to `srclibs/` there (the `flutter` and `go`
  entries already exist).

**Tested so far** (workflow `.github/workflows/fdroid-test.yml`, run by hand): the metadata passes droid rewritemeta, and the recipe's steps work on a plain runner: Go from source, libbox and Xray from source (`tools/fdroid_build.sh`), then `flutter build apk --dart-define=FDROID=true` (an APK with all three CPUs, 118 MB). **Not tested:** F-Droid's own build server (its sandbox, the scanner and the rules about binaries), so the merge request's CI may still ask for changes.

Things to decide before sending the merge request:

1. **License.** `GPL-3.0-only` everywhere (the macOS and Windows resource files and CONTRIBUTING.md follow it).
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