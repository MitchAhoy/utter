#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
: "${DEVELOPER_ID_APPLICATION:?Set the full Developer ID Application certificate identity}"
: "${NOTARY_PROFILE:?Set your existing notarytool Keychain profile name}"
: "${UTTER_GITHUB_REPOSITORY:?Set OWNER/REPOSITORY for the release and appcast}"
: "${SPARKLE_PUBLIC_KEY:?Set your public Ed25519 update key}"
: "${SPARKLE_PRIVATE_KEY_FILE:?Set the local path to the update signing key}"
: "${SPARKLE_BIN:?Set Sparkle's bin directory containing generate_appcast}"
[[ "$UTTER_GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid GitHub repository.' >&2; exit 1; }
release_version="${RELEASE_VERSION:-0.1.0}"
release_build="${RELEASE_BUILD:-1}"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
[[ "$release_build" =~ ^[0-9]+$ ]] || exit 1
test -x "$SPARKLE_BIN/generate_appcast"
test -f "$SPARKLE_PRIVATE_KEY_FILE"
release_dir="build/distribution/$release_version"
mkdir -p "$release_dir"
# The local xcconfig is ignored by Git and never contains API credentials.
release_work="$(mktemp -d -t utter-release)"
release_config="$release_work/Release.xcconfig"
trap 'rm -rf "$release_work"' EXIT
cat > "$release_config" <<CONFIG
UTTER_UPDATE_FEED = https:/\$()/github.com/$UTTER_GITHUB_REPOSITORY/releases/latest/download/appcast.xml
UTTER_UPDATE_PUBLIC_KEY = $SPARKLE_PUBLIC_KEY
CONFIG
xcodegen generate
xcodebuild -quiet -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme Utter -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Utter.xcarchive \
  -xcconfig "$release_config" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES \
  MARKETING_VERSION="$release_version" CURRENT_PROJECT_VERSION="$release_build" archive
release_app="build/Utter.xcarchive/Products/Applications/Utter.app"
codesign --verify --deep --strict "$release_app"
ditto -c -k --keepParent "$release_app" "$release_dir/Utter-notarization.zip"
xcrun notarytool submit "$release_dir/Utter-notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$release_app"
mv "$release_dir/Utter-notarization.zip" "build/Utter-notarization-$release_version.zip"
package_work="$(mktemp -d -t utter-release-dmg)"
trap 'rm -rf "$release_work" "$package_work"' EXIT
cp -R "$release_app" "$package_work/Utter.app"
ln -s /Applications "$package_work/Applications"
release_dmg="$release_dir/Utter-$release_version.dmg"
hdiutil create -volname Utter -srcfolder "$package_work" -ov -format UDZO "$release_dmg"
codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$release_dmg"
xcrun notarytool submit "$release_dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$release_dmg"
xcrun stapler validate "$release_dmg"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "https://github.com/$UTTER_GITHUB_REPOSITORY/releases/download/v$release_version/" "$release_dir"
release_sha="$(shasum -a 256 "$release_dmg" | awk '{print $1}')"
bash scripts/generate-cask.sh "$UTTER_GITHUB_REPOSITORY" "$release_version" "$release_sha" "$release_dir/utter.rb"
printf 'Release artifacts are ready in %s. Upload the DMG and appcast.xml to GitHub Releases.\n' "$release_dir"
