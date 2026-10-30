cask "kumo" do
  version "1.11.0"
  sha256 "1467f63800d9c3664790a1fdf898fe10be0c4aed2cb830d7951b6ea94fdfcdd0"

  url "https://github.com/AbolDev/kumo-client/releases/download/v#{version}/kumo-macos-universal.dmg"
  name "Kumo"
  desc "Free VPN client powered by sing-box and Xray"
  homepage "https://github.com/AbolDev/kumo-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "Kumo.app"

  # The app is not notarized yet: the quarantine mark would stop it from opening.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Kumo.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/Kumo",
    "~/Library/Preferences/app.kumo.vpn.plist",
    "~/Library/Saved Application State/app.kumo.vpn.savedState",
  ]
end