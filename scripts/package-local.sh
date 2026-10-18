#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -quiet -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme Utter -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
package_work="$(mktemp -d -t utter-package)"
trap 'rm -rf "$package_work"' EXIT
mkdir -p build/distribution
cp -R build/Build/Products/Release/Utter.app "$package_work/Utter.app"
ln -s /Applications "$package_work/Applications"
hdiutil create -volname Utter -srcfolder "$package_work" -ov -format UDZO build/distribution/Utter-local.dmg
hdiutil verify build/distribution/Utter-local.dmg
shasum -a 256 build/distribution/Utter-local.dmg
