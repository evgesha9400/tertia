# Homebrew Cask template for future Developer ID signed binary releases (v0.1.0 is distributed as source only).
cask "tertia" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/evgesha9400/tertia/releases/download/v#{version}/Tertia-#{version}-arm64.zip"
  name "Tertia"
  desc "Native macOS menu-bar app, WidgetKit desktop widget, CLI, and MCP server for Third Space London timetables and booking"
  homepage "https://github.com/evgesha9400/tertia"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Tertia.app"
  binary "#{appdir}/Tertia.app/Contents/Helpers/tertia"

  zap trash: [
    "~/Library/Application Support/TertiaClub",
    "~/Library/Containers/club.tertia.macos.widget",
  ]
end
