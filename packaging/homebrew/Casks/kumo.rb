cask "kumo" do
  version "1.9.0"
  sha256 "d465fa1951a7c12344c47152312081f61e572c01f9d873089f91a2d24b003ec9"

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