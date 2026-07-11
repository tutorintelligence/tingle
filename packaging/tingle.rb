# Cask for tutorintelligence/homebrew-tap (repo: homebrew-tap, file: Casks/tingle.rb).
# Users: brew install tutorintelligence/tap/tingle
cask "tingle" do
  version "0.1.0"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"

  url "https://github.com/tutorintelligence/tingle/releases/download/v#{version}/tingle-#{version}.zip"
  name "tingle"
  desc "Menu bar companion for the Teenage Engineering EP-2350 'ting': dictation, macros, ultrasonic button detection"
  homepage "https://github.com/tutorintelligence/tingle"

  auto_updates true # Sparkle owns updates; brew is install/discovery

  depends_on macos: ">= :ventura"

  app "tingle.app"

  uninstall quit: "com.tutorintelligence.tingle"

  zap trash: [
    "~/Library/Application Support/tingle",
  ]
end
