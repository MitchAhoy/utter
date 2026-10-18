# Utter

A native macOS push-to-talk dictation app built with Swift 6 and SwiftUI/AppKit.
Requires macOS 14 or later; Apple Silicon is the primary target. MIT licensed.

## Current status

Hold your shortcut, speak, and release to transcribe on this Mac with WhisperKit
and paste at the cursor. Recordings stay in memory unless debug saving is enabled.
Right Option is the default shortcut; Fn/Globe, Right Command, and a custom
combination are selectable. Clips shorter than 250 ms are ignored; the maximum
recording is five minutes. Completed clips queue while the next hold records.

The previously verified recording, sample-paste, and clipboard-restoration flows
remain available. **Recording only** preserves the earlier microphone test mode.
The one-shot sample paste test is in General settings.

| Build phase | Status |
|---|---|
| 0: native scaffold | Built and manually verified |
| 1: hotkeys, recording, overlay | Built; core flow manually verified |
| 2: paste, permissions, secure input | Implemented; sample insertion and clipboard restoration manually verified; cloud transcription deferred |
| 3: Claude cleanup | Deferred while cloud APIs are disconnected |
| 4: on-device transcription and settings | Implemented; manual checkpoint below |
| 4: Cloud/Auto routing and API-key settings | Deferred with cloud integration |
| 5: signed distribution and updates | Not started |
| 6: dictionary, snippets, commands, styles, history | Not started |

No API key, cloud speech service, or cloud cleanup is used. Cleanup currently
passes recognized text through unchanged. The model itself may supply punctuation.
See BUILD_PROMPT.md and PLAN.md for the full specification and phase checkpoints.

## Build and run

Install full Xcode, open it once, and select its developer tools:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
brew install xcodegen
xcodegen generate
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
open build/Build/Products/Debug/Utter.app
```

The project is generated from `project.yml`. Do not edit or commit generated
Xcode projects. Direct dependencies are pinned: KeyboardShortcuts 3.1.0 and
WhisperKit 1.1.1 (Argmax's Swift package; WhisperKit product only).

## Start dictating without an API

1. Open Utter's menu → Settings → Permissions. Allow Microphone access and enable
   this Utter.app in Accessibility. Use **Reveal This Utter App** to find the
   exact build if macOS requires adding it manually.
2. Open Transcription. Select **On-device dictation**, then a model:
   **Large v3 Turbo** is the default for accuracy; **Small** prepares faster.
3. Click **Download & Prepare Model**. This explicitly downloads the public
   Core ML model and tokenizer from Hugging Face into
   `~/Library/Application Support/Utter/Models`. Progress and preparation errors
   appear beside the button. You can cancel and retry.
4. Wait for **Ready · On-device**, focus a text field in another app, then hold
   your shortcut, speak, and release. No sample test needs to be armed.
5. Later launches load the cached model without downloading it again. The model
   stays warm in memory. Transcription uses in-memory 16 kHz mono audio and a
   local tokenizer; it has no network fallback.

Under General, choose the system default microphone or a specific input device,
select a language or automatic detection, enable optional sounds, and configure
launch at login. Microphone choices are stored by stable device UID. If the
selected microphone disappears, recording reports an error rather than silently
switching devices. Launch at login uses Apple's SMAppService; macOS may require
approval in Login Items. Register a stable installed app before relying on it.

Fn users: set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”.

## Development signing

This machine has no Apple Development signing identity configured. Builds use
ad-hoc signing. macOS may keep showing an enabled Accessibility switch for an
older build while denying the new build. If this occurs, quit Utter, remove its
Accessibility entry, re-add the current app, enable it, and relaunch.

To preserve permissions across rebuilds, add your Apple ID under Xcode → Settings
→ Accounts and create an Apple Development certificate for your personal team:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Replace `YOUR_TEAM_ID` in that local file. Use the same team, certificate, and
bundle ID (`org.utter.app`) consistently. The local signing file is ignored by
Git. Developer ID signing, notarization, DMG packaging, and Sparkle are Phase 5.

## Automated verification

```sh
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
xcodebuild -project Utter.xcodeproj -scheme Utter -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
bash scripts/verify-phase0.sh build/Build/Products/Debug/Utter.app
bash scripts/verify-phase0.sh build/Build/Products/Release/Utter.app
```

Tests cover modifier edges, rapid presses, short-tap boundaries, cap rearming,
cancellation, recording errors, PCM/WAV encoding, stereo/mono resampling,
streaming continuity and the resampler tail, the five-minute audio memory cap,
debug-WAV replacement, multi-item clipboard restoration, transient/concealed
markers, concurrent clipboard changes, secure input, permission/focus errors,
pipeline timeouts and recovery, queue order, model installation receipts,
startup without downloads, cached preparation, retry, cancellation, and saved
model selection.

Clipboard tests use uniquely named pasteboards and simulated keyboard drivers.
They do not type into other apps or modify the user's clipboard. Routine tests
do not access the microphone, download models, or change login-item registration.

## Real local-model integration check

The command-line target uses the same provider as the app and a synthetic speech
fixture. It verifies recognition and rejection of silence. It never records the
microphone or posts paste events. Downloads happen only with `--download`.

```sh
xcodebuild -project Utter.xcodeproj -scheme UtterLocalCheck -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
say -v Samantha -o /tmp/utter-local-fixture.aiff \
  'The quick brown fox jumps over the lazy dog.'
build/Build/Products/Debug/UtterLocalCheck small \
  "$HOME/Library/Application Support/Utter/Models" \
  /tmp/utter-local-fixture.aiff --download
```

Repeat without `--download` to verify cached loading. A separate run under a
process sandbox denying networking can verify that cached loading and recognition
operate without network access. The synthetic fixture is temporary test data;
user recordings are not saved by this check.

## Current manual checkpoint

1. After granting permissions for the new build, choose Small or Large v3 Turbo,
   download and prepare it, then dictate into Notes. Check actual recognized
   words, punctuation, the final word, retained focus, and the On-device pill.
2. Copy text before dictating. After insertion, manually paste again and confirm
   the original clipboard is restored. Repeat with rich text, images, and copied
   files. A new copy made during the 300 ms restore delay must remain intact.
3. Turn off networking after the model is ready and dictate again. Relaunch while
   offline and verify the cached model becomes ready and still transcribes.
4. Record successive clips while a previous clip processes. Check ordered results.
   Change apps before a result arrives: insertion must be blocked, and the raw
   recognized text should be copied to the clipboard for recovery.
5. Try silence, rapid presses, sub-250 ms taps, and a five-minute hold. Test all
   hotkey choices, left/right modifier discrimination, and full-screen/multi-display
   placement. The overlay must never take keyboard focus.
6. Select an external mic, record, and disconnect it mid-recording. Expect a clear
   error. Choose a connected microphone and verify recovery. Also lock/sleep
   mid-recording: partial audio and pending insertions must be cancelled.
7. Test model-download cancellation/retry and reopening with a cached model.
   Verify microphone, language, mode, sounds, and hotkey selections persist.
   Test launch-at-login enable/disable and any macOS approval prompt separately.
8. Confirm the Cleanup tab reports pass-through and no cloud connection. In
   General, verify debug saving off does not change an existing debug WAV.

Real paste delivery still requires checking each destination. A posted keyboard
event has no acknowledgment from the receiving app.

| Destination | Manual result |
|---|---|
| Chat text field: sample paste and clipboard restoration | Confirmed by user |
| Notes: real local dictation | Pending |
| Safari / Chrome web inputs | Pending |
| Slack composer / Mail draft | Pending |
| VS Code / Cursor editor | Pending |
| Terminal / iTerm | Pending |
| Google Docs editor | Pending |

For terminal sample-paste testing, use `# Utter paste test` without a trailing
newline. Secure fields must block insertion with “Can't type into a secure field”
when macOS delivers shortcut events; secure input can also suppress monitoring.

## Privacy

No telemetry or analytics. Speech and recognized text stay on this Mac. Network
access is used only for explicit model downloads; transcription itself uses the
local model and tokenizer. No API keys are requested or stored in this build.
Future API credentials must use Keychain.

Audio is memory-only unless **Save the last recording as a WAV file** is enabled
under General. That setting replaces
`~/Library/Application Support/Utter/debug/last-recording.wav` with owner-only
file permissions. Turning it off stops saving but does not delete an existing
WAV. Debug mode also logs stage durations only, with no audio or transcript text.
No transcript history is stored.

Temporary paste text carries transient/concealed markers. The original clipboard
is restored after approximately 300 ms only if Utter still owns it. If insertion
fails after recognition, raw text is intentionally left on the clipboard for
recovery. A focused-app change blocks automatic insertion. The app is deliberately
not sandboxed because synthetic paste requires it.
