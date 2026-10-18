# Utter

A native macOS push-to-talk dictation app, built with Swift 6 and SwiftUI/AppKit.
Requires macOS 14 or later. MIT licensed.

## Current status

Phase 1 is manually verified. Hold Right Option to record, release to stop. The non-activating
floating pill shows the input level and elapsed time. Settings offers Fn/Globe,
Right Command, and a custom combination via KeyboardShortcuts 3.1.0. Short taps
under 250 ms are discarded; clips are limited to five minutes. Sounds and debug
WAV saving are optional and off by default.

Phase 2 is partially implemented: API-independent paste, permission onboarding,
and a queued dictation pipeline with pluggable transcription and cleanup
protocols. Settings provides a one-shot **Arm Paste Test** flow using explicit
sample text. It does not transcribe the recording. Normal recording still works
without inserting any text unless the paste test was armed.

Cloud providers, API requests, API credentials, and Keychain settings remain
deferred at the user's request. Phase 2 is not complete until real transcription
is authorized and verified. Audio is released from memory after processing
unless debug saving was enabled for it. Sample input and transcripts are not
persisted or logged. See BUILD_PROMPT.md and PLAN.md for the remaining phases.

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
memory cap, and replacement of the debug WAV. Paste tests use uniquely named
pasteboards and simulated keyboard drivers, so they do not alter the user's
clipboard or type into apps. They exercise complete multi-item/type clipboard
restoration, transient/concealed markers, concurrent clipboard changes, secure
input, permission/focus errors, cancellation, timeout fallbacks, queue order,
recovery text, and the arrival of a new clip while cancellation unwinds. These tests do not access the
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

## Phase 2 paste-test checkpoint (no API)

1. Launch the new build. If macOS reset permissions after the ad-hoc rebuild,
   re-enable Utter in Accessibility and Microphone. The setup section appears
   automatically when grants are missing.
2. Copy some original text. In Utter Settings, enter a distinctive sample under
   **Test text insertion**, then click **Arm Paste Test**.
3. Focus an editable field in another app. Hold your shortcut for at least
   250 ms, then release. The sample should appear once, and the overlay should
   disappear without taking keyboard focus. Speech is not transcribed.
4. Paste again manually: the original clipboard text should still be there.
   Repeat with rich text, an image, and multiple copied files to verify their
   original clipboard representations are restored.
5. Arm another test, tap for under 250 ms, and confirm nothing is inserted and
   the test stays armed. Make a full recording to consume it. A later unarmed
   recording must not insert sample text. **Cancel Paste Test** disarms it.
6. Arm a test and switch to a different app while holding the key. No text
   should be injected into the new app; the sample is copied to the clipboard
   with an error explaining the recovery.
7. Test a secure password field with harmless sample text. If shortcut events
   reach Utter, insertion must be blocked with “Can't type into a secure field”.
   macOS may suppress shortcut monitoring entirely while secure input is active.
8. Change the clipboard during the 300 ms restore delay. Your new copy should
   remain. Lock or sleep while processing and confirm pending work is cancelled.

Verify real paste delivery manually in each app before marking this checkpoint
complete. Synthetic keyboard events have no delivery acknowledgment, so passing
unit tests alone does not prove that an app accepted the text.

| Destination | Manual result |
|---|---|
| Safari web input | Pending |
| Chrome web input | Pending |
| Slack message composer | Pending |
| Notes | Pending |
| Mail draft | Pending |
| VS Code / Cursor editor | Pending |
| Terminal | Pending |
| iTerm | Pending |
| Google Docs editor | Pending |

For terminal testing, use the sample `# Utter paste test` without a trailing
newline. No API account or key is needed for any of these checks.

## Privacy and permissions

Utter makes no API or other network requests and collects no telemetry or
analytics. Audio is recorded only while the shortcut is held. Debug saving is
explicitly opt-in; it replaces `~/Library/Application Support/Utter/debug/last-recording.wav`
with owner-only file permissions. Turning debug saving off does not delete an
existing WAV. Microphone and Accessibility grants are required for recording
and global modifier monitoring. Temporary paste text is marked transient and
concealed; original clipboard items are restored after approximately 300 ms
only if Utter still owns the clipboard. If insertion fails after text exists,
that raw text is intentionally left on the clipboard for recovery. Changing
apps during processing blocks automatic paste. The event tap passes modifier events through,
so their ordinary macOS behavior remains available. The microphone description
and audio input entitlement declare recording access. The app is intentionally
not sandboxed because later phases paste through synthetic keyboard events.
Future API credentials will live only in Keychain; audio will remain in memory
unless debug recording is explicitly enabled.
