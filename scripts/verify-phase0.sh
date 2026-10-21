#!/bin/bash
set -euo pipefail

app_path="${1:-build/Build/Products/Debug/Utter.app}"
plist_path="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/Utter"
entitlements_path="$(mktemp -t utter-entitlements)"
trap 'rm -f "$entitlements_path"' EXIT

plutil -lint "$plist_path"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist_path")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")" = org.utter.app
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist_path")" = 14.0
test -n "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$plist_path")"
test -x "$executable_path"
lipo "$executable_path" -verify_arch arm64
codesign --verify --strict --verbose=2 "$app_path"
signature_description="$(codesign -dv "$app_path" 2>&1)"
if [[ "$signature_description" == *"(adhoc,runtime)"* ]] && test -d "$app_path/Contents/Frameworks/Sparkle.framework"; then
    echo 'FAIL: Ad-hoc builds cannot use hardened-runtime team validation with Sparkle. Use the development signing config or a real signing identity.' >&2
    exit 1
fi
codesign -d --entitlements :- "$app_path" > "$entitlements_path" 2>/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$entitlements_path")" = true
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements_path" 2>/dev/null | /usr/bin/grep -q true; then
    echo 'FAIL: Utter must not be sandboxed.' >&2
    exit 1
fi
echo 'PASS: menu bar metadata, microphone declaration, arm64, signature, and entitlements.'
