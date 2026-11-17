cask "pangolingit" do
  # version and sha256 are rewritten by tools/create_dmg.sh for each release image; until the first
  # published image the checksum is not pinned.
  version "1.0.0"
  sha256 "a045a45948df2129ad7217905dd526aff2918bd8e4976e8fce380b4027e6fec4"

  url "https://github.com/fredmacbit/pangolingit/releases/download/v#{version}/PangolinGit.dmg"
  name "PangolinGit"
  desc "macOS native Git GUI client and FinderSync shell extension"
  homepage "https://github.com/fredmacbit/pangolingit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :ventura"

  app "PangolinGit.app"
  binary "#{appdir}/PangolinGit.app/Contents/MacOS/pangolin-wcrev", target: "pangolin-wcrev"
  binary "#{appdir}/PangolinGit.app/Contents/MacOS/pangolin", target: "pangolin"

  postflight do
    system_command "/usr/bin/pluginkit",
                   args: ["-e", "use", "-i", "be.macbit.pangolingit.finder"]
  end

  uninstall quit:      "be.macbit.pangolingit",
            launchctl: "be.macbit.pangolingit.agent"

  zap trash: [
    "~/Library/Application Support/PangolinGit",
    "~/Library/Caches/be.macbit.pangolingit",
    "~/Library/Group Containers/group.be.macbit.pangolingit",
    "~/Library/Logs/PangolinGit",
    "~/Library/Preferences/be.macbit.pangolingit.plist",
    "~/Library/Preferences/group.be.macbit.pangolingit.plist",
    "~/Library/Saved Application State/be.macbit.pangolingit.savedState",
  ]
end
