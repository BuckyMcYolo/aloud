# Homebrew cask for Aloud. Lives in your tap repo (github.com/YOURUSER/homebrew-tap
# under Casks/aloud.rb); users install with:
#   brew install --cask YOURUSER/tap/aloud
#
# On each release: bump `version`, paste the sha256 that release.sh prints.
cask "aloud" do
  version "0.2.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/YOURUSER/aloud/releases/download/v#{version}/Aloud-#{version}.dmg"
  name "Aloud"
  desc "Read any selected text aloud with a local Kokoro voice"
  homepage "https://github.com/YOURUSER/aloud"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Aloud.app"

  zap trash: [
    "~/Library/Application Support/Aloud",
    "~/Library/Caches/Kokoro",
    "~/.aloud",
  ]
end
