#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -quiet -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme Utter \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  ENABLE_DEBUG_DYLIB=YES build-for-testing
app_contents="$PWD/build/Build/Products/Debug/Utter.app/Contents"
developer_dir="$(xcode-select -p)"
# Run the same compiled XCTest bundle without LaunchServices' app-host launcher.
# Preserve inherited injected libraries and access-control instrumentation.
export DYLD_LIBRARY_PATH="$app_contents/MacOS${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FRAMEWORK_PATH="$app_contents/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
"$developer_dir/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest" \
  "$app_contents/PlugIns/UtterTests.xctest"
