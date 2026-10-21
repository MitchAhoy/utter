#!/bin/bash
# Builds Release with the local signing certificate and installs it to
# /Applications, so there is one stable copy for macOS permissions.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f Config/Signing.local.xcconfig ]]; then
  echo "Run scripts/setup-local-signing.sh first." >&2
  exit 1
fi

xcodegen generate
xcodebuild -quiet -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme Utter -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build

app="build/Build/Products/Release/Utter.app"
if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
  echo "Build is still ad-hoc signed; check Config/Signing.local.xcconfig." >&2
  exit 1
fi
codesign --verify --deep --strict "$app"

osascript -e 'tell application id "org.utter.app" to quit' 2>/dev/null || true
pkill -x Utter 2>/dev/null || true
sleep 1
rm -rf /Applications/Utter.app
ditto "$app" /Applications/Utter.app
open /Applications/Utter.app
echo "Installed /Applications/Utter.app"
codesign -d -r- /Applications/Utter.app 2>&1 | tail -1
