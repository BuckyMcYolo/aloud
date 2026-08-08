# Homebrew cask for Aloud. Lives in your tap repo (github.com/BuckyMcYolo/homebrew-tap
# under Casks/aloud.rb); users install with:
#   brew install --cask BuckyMcYolo/tap/aloud
#
# On each release: bump `version`, paste the sha256 that release.sh prints.
cask "aloud" do
  version "0.2.0"
  sha256 "35b1e154e64b2e21412c0c726e7ddfc306b44efe18ea66cb6270519943cba497"

  url "https://github.com/BuckyMcYolo/aloud/releases/download/v#{version}/Aloud-#{version}.dmg"
  name "Aloud"
  desc "Read any selected text aloud with a local Kokoro voice"
  homepage "https://github.com/BuckyMcYolo/aloud"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Aloud.app"

  zap trash: [
    "~/Library/Application Support/Aloud",
    "~/Library/Caches/Kokoro",
    "~/.aloud",
  ]
end
