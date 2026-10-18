# Utter

A native macOS push-to-talk dictation app, built with Swift 6 and SwiftUI/AppKit.
Requires macOS 14 or later. MIT licensed.

## Current status

Phase 0: a menu bar app with a waveform icon and **Quit Utter**. Recording,
hotkeys, transcription, cleanup, and paste are not implemented yet. No API
integration or API credentials are needed for this phase. See BUILD_PROMPT.md
and PLAN.md for the remaining phases and their manual verification gates.

## Build and run

Install full Xcode, open it once to finish setup, and select its developer tools:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
brew install xcodegen
xcodegen generate
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
open build/Build/Products/Debug/Utter.app
```

The project is generated from `project.yml`. Generated Xcode projects and build
products are ignored by Git. Do not edit the generated project.

## Development signing

The initial build uses an ad-hoc signature because no development signing
identity was available during setup. Before permission testing in Phase 1,
add your Apple ID under Xcode → Settings → Accounts and create an Apple
Development certificate for your personal team. Then:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` in that local file. Keep using the same team, certificate,
and bundle identifier (`org.utter.app`) so macOS permissions survive rebuilds.
The local file is ignored by Git. Both build configurations include it.
Developer ID signing and distribution belong to Phase 5.

## Phase 0 verification

```sh
bash scripts/verify-phase0.sh build/Build/Products/Debug/Utter.app
```

The script checks bundle metadata, the arm64 executable, its signature, and
microphone entitlement. Also build Release to check both configurations.
No unit test target exists yet; this phase contains only app startup and a menu.

Manual checks before Phase 1:

1. Launch the app and find the waveform icon in the menu bar.
2. Confirm there is no Dock icon, startup window, or permission prompt.
3. Open the menu and choose **Quit Utter**; confirm the icon disappears.
4. Launch it again and repeat to check clean startup and shutdown.

## Privacy and permissions

This scaffold makes no network requests, records no audio, and collects no
telemetry or analytics. The microphone usage description and hardened-runtime
audio input entitlement prepare for later recording. The app is intentionally
not sandboxed because later phases paste through synthetic keyboard events.
Future API credentials will live only in Keychain; audio will remain in memory
unless debug recording is explicitly enabled.
