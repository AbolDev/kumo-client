cask "kumo" do
  version "1.13.0"
  sha256 "3e95acb2eab1525e6e437d5d0506a71bc71b5c8fbc287dd315b621204290e3c6"

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