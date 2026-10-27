# Packages

Manifests for installing Kumo from package managers. They are written by
`tools/packaging.ps1` for one release (addresses and SHA-256 come from the GitHub release):

```
pwsh tools/packaging.ps1 -Tag v1.7.0
```

Run it again after each release, then submit the changed files where each store asks.
Nothing here is published until the steps below are done. Each store has its own account and review.

| Store | Files | What you do |
|---|---|---|
| **winget** | `winget/manifests/a/AbolDev/Kumo/<version>/` | `winget validate --manifest <dir>`, then open a pull request to `microsoft/winget-pkgs` with the folder (or run `wingetcreate submit`). |
| **Scoop** | `scoop/kumo.json` | Works right away from this repository: `scoop install https://raw.githubusercontent.com/AbolDev/kumo-client/main/packaging/scoop/kumo.json`. For `scoop install kumo`, put it in a bucket repository (for example `AbolDev/scoop-kumo`). |
| **Chocolatey** | `chocolatey/` | Make an account on chocolatey.org, then `choco pack` and `choco push --api-key <key>` in that folder. A moderator reviews each version. |
| **Homebrew** | `homebrew/Casks/kumo.rb` | Put it in a tap repository named `AbolDev/homebrew-kumo` (folder `Casks/`). Then: `brew install --cask AbolDev/kumo/kumo`. |
| **AUR** | `aur/kumo-bin/` | Make an AUR account with an SSH key, then push `PKGBUILD`, `kumo.install` and `.SRCINFO` to `ssh://aur@aur.archlinux.org/kumo-bin.git`. |
| **Flathub** | `flatpak/` | Pull request to `flathub/flathub` (branch `new-pr`) with these three files. Untested draft: the tray icon library and the review may ask for changes. The tunnel cannot be opened inside the sandbox. |
| **Snap** | `snap/snapcraft.yaml` | Register the name `kumo` on the Snap Store, build with `snapcraft`, then `snapcraft upload`. Untested draft. Strict confinement cannot open the tunnel. |
| **IzzyOnDroid** | `izzyondroid/REQUEST.md`, `../fastlane/` | Post the request text. The app's description and screenshots come from `fastlane/metadata/android`. |
| **F-Droid** | not prepared | Its builders must compile everything from source (sing-box libbox with gomobile, Xray, Flutter). That is a larger task; IzzyOnDroid comes first. |