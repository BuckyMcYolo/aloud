# Homebrew cask for Aloud. Lives in your tap repo (github.com/BuckyMcYolo/homebrew-tap
# under Casks/aloud.rb); users install with:
#   brew install --cask BuckyMcYolo/tap/aloud
#
# On each release: bump `version`, paste the sha256 that release.sh prints.
cask "aloud" do
  version "0.2.1"
  sha256 "a91344ee84f2688954b15a85c1cf0ccaee345aa53eb1167c18df82714ef54003"

  url "https://github.com/BuckyMcYolo/aloud/releases/download/v#{version}/Aloud-#{version}.dmg"
  name "Aloud"
  desc "Read any selected text aloud with a local Kokoro voice"
  homepage "https://github.com/BuckyMcYolo/aloud"

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Aloud.app"

  zap trash: [
    "~/Library/Application Support/Aloud",
    "~/Library/Caches/Kokoro",
    "~/.aloud",
  ]
end
