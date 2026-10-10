# Template for krz/homebrew-tap's Casks/orgstar.rb; scripts/release-mac.sh fills in the version
# and checksum. Install with:
#   brew tap krz/tap https://gitbay.org/krz/homebrew-tap.git && brew install --cask orgstar

cask "orgstar" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://gitbay.org/krz/orgstar/releases/download/v#{version}/orgstar-#{version}.dmg"
  name "orgstar"
  desc "Native org-mode editor and agenda"
  homepage "https://gitbay.org/krz/orgstar"

  depends_on macos: ">= :tahoe"

  app "orgstar.app"

  zap trash: [
    "~/.config/orgstar",
    "~/Library/Application Support/Orgstar",
    "~/Library/Preferences/sh.krz.orgstar.plist",
  ]
end
