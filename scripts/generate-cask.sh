#!/bin/bash
set -euo pipefail
repo="${1:?OWNER/REPOSITORY required}"
version="${2:?version required}"
checksum="${3:?SHA256 required}"
output="${4:?output path required}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || exit 1
cat > "$output" <<CASK
cask "utter" do
  version "$version"
  sha256 "$checksum"
  url "https://github.com/$repo/releases/download/v#{version}/Utter-#{version}.dmg"
  name "Utter"
  desc "Native push-to-talk dictation with on-device and bring-your-own-key modes"
  homepage "https://github.com/$repo"
  depends_on macos: ">= :sonoma"
  app "Utter.app"
  zap trash: ["~/Library/Application Support/Utter", "~/Library/Preferences/org.utter.app.plist"]
end
CASK
