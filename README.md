# Utter

A native macOS push-to-talk dictation app, built with Swift 6 and SwiftUI/AppKit.
Requires macOS 14 or later. MIT licensed.

## Current status

Phase 1: hold Right Option to record, release to stop. The non-activating
floating pill shows the input level and elapsed time. Settings offers Fn/Globe,
Right Command, and a custom combination via KeyboardShortcuts 3.1.0. Short taps
under 250 ms are discarded; clips are limited to five minutes. Sounds and debug
WAV saving are optional and off by default.

No transcription, cleanup, paste, or API integration exists yet. A clip is
released from memory after capture unless debug saving was enabled for it.
See BUILD_PROMPT.md and PLAN.md for the remaining phases and manual checkpoints.

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

## Automated verification

```sh
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
bash scripts/verify-phase0.sh build/Build/Products/Debug/Utter.app
bash scripts/verify-phase0.sh build/Build/Products/Release/Utter.app
```

XCTest covers modifier edge handling and repeat presses, short-tap boundaries,
rapid clips, cap rearming, cancellation, errors, level updates, PCM/WAV encoding,
48 kHz stereo and 44.1 kHz mono conversion, streaming continuity, the audio
memory cap, and replacement of the debug WAV. These tests do not access the
microphone or grant system permissions. Native permission and focus behavior
requires the manual checks below.

## Phase 1 manual checkpoint

1. Quit the old build before launching the new one. Confirm no Dock icon appears.
2. Open Utter's menu → Settings. Set up your personal-team signing as described
   above before permission testing. Click **Allow Microphone**. Open Accessibility
   Settings, add this built Utter.app if needed, and enable it. Return to Utter
   and click **Retry Shortcut Monitor** (or relaunch if macOS requires it).
3. Enable debug saving. Focus Notes, hold **Right Option**, speak for a few seconds,
   and release. Check the live level meter, elapsed time, bottom-centered overlay,
   and that Notes retains focus. Click **Reveal Last Recording** and play the WAV.
   It should contain the whole clip, including the last word, at normal speed.
4. Confirm Left Option does not record. Hold both Option keys, release Right
   Option first, and confirm recording stops even while Left Option stays down.
5. Tap the shortcut for under 250 ms: the prior WAV must remain unchanged. Record
   several quick clips; the last complete clip should play correctly.
6. Switch to Right Command and test both Command keys. Test Fn after setting
   System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”. Select Custom,
   record a combination, and confirm holding/releasing it records correctly.
   Change back to Right Option and ensure the old custom shortcut is inactive.
7. Try a focused app on another display and in full screen. The overlay should
   follow the focused window's screen and never activate or take keyboard focus.
8. Enable sounds and test start/stop. Turn debug saving off, record again, and
   verify the existing WAV's modification time does not change. Quit/relaunch
   and confirm settings persist. Delete the old debug WAV yourself when done.
9. With an external mic selected as macOS's default input, disconnect it while
   recording. Expect an error and a clean recovery on the next press. Also test
   sleep or locking the session mid-recording: partial audio must be discarded.
10. Hold for over five minutes. Recording must stop at the cap and stay stopped
    until you release and press again. Revoke microphone/Accessibility permissions
    and verify recording stops and the Settings status reflects the missing grant.

Use macOS's default input device for this phase. A microphone picker belongs to
Phase 4. Permission persistence across rebuilds cannot be verified with an ad-hoc
signature; a consistent Apple Development identity is required for that check.

## Privacy and permissions

Utter makes no API or other network requests and collects no telemetry or
analytics. Audio is recorded only while the shortcut is held. Debug saving is
explicitly opt-in; it replaces `~/Library/Application Support/Utter/debug/last-recording.wav`
with owner-only file permissions. Turning debug saving off does not delete an
existing WAV. Microphone and Accessibility grants are required for recording
and global modifier monitoring. The event tap passes modifier events through,
so their ordinary macOS behavior remains available. The microphone description
and audio input entitlement declare recording access. The app is intentionally
not sandboxed because later phases paste through synthetic keyboard events.
Future API credentials will live only in Keychain; audio will remain in memory
unless debug recording is explicitly enabled.
