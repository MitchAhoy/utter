# Utter

Native, open-source push-to-talk dictation for macOS 14+. Swift 6, SwiftUI and AppKit; Apple Silicon first. MIT licensed.

![Illustration of Utter's hold, release and insertion flow](docs/dictation-flow.gif)

*Illustrated workflow; this GIF is not a recording of the app.*

Hold your shortcut, speak, and release. Utter transcribes, optionally cleans the text, and pastes at the cursor without changing your clipboard. Right Option is the initial shortcut; Fn/Globe, Right Command and custom combinations are available. Accidental taps under 250 ms are ignored; recordings stop at five minutes. Up to three completed/processing clips queue in order.

## Install and start

For this local build, open `build/distribution/Utter-local.dmg`, drag Utter to Applications, and launch that copy. Quit any development copy first. This package is ad-hoc signed for local testing, with hardened runtime off because ad-hoc signatures have no team ID for framework validation. Developer ID releases enable hardened runtime and notarization. Use the same app location when granting permissions and configuring launch at login.

1. Open the waveform menu bar icon → Settings → Permissions. Allow Microphone and enable this copy of Utter in Accessibility. **Reveal This App** locates the exact build.
2. Under Transcription choose **On-device dictation**, select Small or Large v3 Turbo, and click **Download & Prepare Model**. Large v3 Turbo is the initial model choice; Small prepares faster. Downloads explicitly fetch public Core ML models and tokenizer files from Hugging Face to `~/Library/Application Support/Utter/Models`.
3. Wait for **Ready**, focus a text field in another app, and hold your shortcut while speaking. Cached models load on later launches without downloading and stay warm in memory.
4. Fn users: set System Settings → Keyboard → **Press 🌐 key to → Do Nothing** to prevent emoji/dictation conflicts.

General settings include microphone selection, language, optional sounds, launch at login, an API-independent sample paste test, and debug recording. The overlay never activates its window. If the selected microphone disappears, Utter reports an error instead of silently switching devices.

## Add your API keys when ready

No credentials ship with Utter. **Cloud requests start disabled** and saving a key does not enable them.

Under Settings → Transcription, paste keys into the secure fields and Save:

| Service | Used for |
|---|---|
| Groq | `whisper-large-v3-turbo` transcription |
| OpenAI, optional | `gpt-4o-mini-transcribe` transcription |
| Anthropic | Claude cleanup and spoken editing commands |

Keys are stored only in macOS Keychain, under `org.utter.app.api-keys`; the fields never redisplay saved secrets. Remove deletes the corresponding Keychain item. Keys are not stored in preferences, history or repository files. No validation call runs when saving.

Enable **Allow cloud API requests**, choose Groq or OpenAI, then select Cloud or Auto. Cloud uploads audio to the selected provider. Auto tries cloud and falls back to a prepared local model on cloud errors or when cloud is unavailable. Prepare a local model first if you want offline fallback. Local mode uses local speech recognition; independently enabled Claude cleanup can still send the resulting text to Anthropic. Turn cloud access off for fully offline dictation. **Recording only** captures without transcription or insertion.

Under Cleanup, enable Claude and choose its timeout (initially 1.5 seconds). Errors/timeouts insert the raw transcript. Fewer than four words and verbatim app styles skip cleanup. The requested model identifier defaults to `claude-haiku-5-5` from BUILD_PROMPT.md and is editable to match your Anthropic account's available models. Its live availability and output quality remain to be checked after you supply a key. The prompt treats speech as text to transform, preserves questions and identifiers, and never intentionally answers dictated questions.

## Optional features

Each starts disabled and has its own settings page:

- **Dictionary:** one term per line, supplied to speech recognition and as cleanup context.
- **Snippets:** a whole spoken trigger phrase expands after cleanup; matching ignores case and trailing sentence punctuation. For example, “my signature” can insert a multiline sign-off.
- **App Styles:** choose an application or enter its bundle ID; select casual, formal, code or verbatim cleanup behavior.
- **Commands:** select text in another app, hold Control–Option–Space (customizable), speak an edit such as “make this more concise,” and release. Requires cloud access and an Anthropic key, plus a ready transcription provider. Utter copies the selection, restores the clipboard, and replaces it with the edit. Failed edits never paste the spoken instruction over the selection. Keep the target selection unchanged until insertion completes.
- **History:** opt-in local SQLite stores raw/cleaned text, app, time and processing path. Search, Copy Again, Re-run Cleanup, retention (1–365 days), and Clear All are provided. Audio is never included. Disabling history stops new records; use Clear All to remove existing records. Retention is enforced when saving or reading history.

History uses macOS's SQLite library directly, keeping the dependency list restricted to the three permitted Swift packages. Optional automatic dictionary learning is not included.

## Privacy and failure behavior

No telemetry or analytics. Speech stays in memory unless **Save the last recording as a WAV file** is enabled. That debug option replaces `~/Library/Application Support/Utter/debug/last-recording.wav` with owner-only permissions; disabling it stops saving and does not delete an existing WAV. Debug stage logs contain timing/path only, never transcripts or keys.

Cloud access sends audio to Groq/OpenAI for transcription and text to Anthropic for enabled cleanup/commands. Each provider's policies apply. Network access is also used for explicit model downloads and, in configured public releases, optional Sparkle updates. Development builds have no update feed or update signing key and make no update checks.

Temporary paste text has transient/concealed markers. Utter restores all original clipboard items/types after approximately 300 ms only while it still owns the clipboard. New clipboard copies are preserved. If insertion fails after recognition, raw text is intentionally copied for recovery. Secure input and switching to another app block insertion. Synthetic paste has no receiving-app acknowledgment; test your destinations using [TEST_PLAN.md](TEST_PLAN.md). The app is not sandboxed because synthetic keyboard events require it.

## Build and verify

Install full Xcode, open it once, select its developer tools, and install XcodeGen:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
brew install xcodegen
xcodegen generate
xcodebuild -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme Utter \
  -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
open -n build/Build/Products/Debug/Utter.app
```

`project.yml` is the source of truth; generated Xcode projects stay out of Git. Direct dependencies are pinned: WhisperKit 1.1.1, KeyboardShortcuts 3.1.0 and Sparkle 2.10.0. The `netrc` authorization-provider setting avoids a SwiftPM Keychain lookup hang on this development Mac; no credential file is required for these public dependencies.

On this Mac, Xcode’s app-host test launcher can stall before XCTest starts. `bash scripts/test-local.sh` builds for testing and runs the identical compiled XCTest bundle directly, preserving runtime instrumentation. CI retains the standard `xcodebuild test` path.

[VALIDATION.md](VALIDATION.md) records actual verification results and limits. [TEST_PLAN.md](TEST_PLAN.md) covers interactive testing after the build. XCTest uses mock cloud transports and isolated test data; it makes no billable API requests, records no microphone audio, and does not type into other apps.

Local inference integration check (uses the app's real provider):

```sh
xcodebuild -packageAuthorizationProvider netrc -project Utter.xcodeproj -scheme UtterLocalCheck \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
say -v Samantha -o /tmp/utter-local-fixture.aiff 'The quick brown fox jumps over the lazy dog.'
build/Build/Products/Debug/UtterLocalCheck small \
  "$HOME/Library/Application Support/Utter/Models" /tmp/utter-local-fixture.aiff
```

Append `--download` only if the model isn't installed. The check also verifies silence rejection. `UtterCleanupCheck` tests 30 cleanup fixtures against Anthropic only when you explicitly provide `ANTHROPIC_API_KEY`; without it, the tool skips without a network call. Set `ANTHROPIC_MODEL` if needed. Routine tests verify request/response contracts; only this opt-in live check evaluates the real model's transformations.

## Signing and distribution

Ad-hoc rebuilds can invalidate macOS permissions even when the old Accessibility switch remains enabled. Quit Utter, remove the old entry, re-add the current app, enable it, and relaunch. For stable development signing, configure an Apple Development certificate in Xcode → Settings → Accounts, copy `Config/Signing.local.xcconfig.example` to ignored `Config/Signing.local.xcconfig`, and set your team. Keep the identity and `org.utter.app` bundle ID consistent.

```sh
bash scripts/package-local.sh
```

This builds Release, creates and verifies the local DMG, and prints its SHA-256. Public distribution is prepared by `scripts/release.sh`: Developer ID archive, notarization, stapling, signed DMG, Sparkle appcast and generated Homebrew cask. Supply `DEVELOPMENT_TEAM`, `DEVELOPER_ID_APPLICATION`, an existing `NOTARY_PROFILE`, `UTTER_GITHUB_REPOSITORY` (`OWNER/REPO`), `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY_FILE`, and `SPARKLE_BIN` (the Sparkle distribution's directory containing `generate_appcast`). Optional `RELEASE_VERSION` and `RELEASE_BUILD` default to 0.1.0 and 1. Keep private signing keys outside this repository. Upload the resulting DMG and appcast.xml to the matching GitHub Release; publish the generated `utter.rb` in your Homebrew tap. No fake public release URL or checksum is shipped.

The appcast points to GitHub Releases, verifies Ed25519 signatures, and supports user-controlled automatic checks. Signing identities, notarization credentials, a public release repository and update signing keys are external release prerequisites; no public release has been published. GitHub Actions builds/tests pull requests and Release builds once the repository is hosted on GitHub.

## Bring-your-own-key budget

The following are **planning estimates copied from PLAN.md, not a current pricing quote**. Assumes 25 minutes/day for 30 days; verify vendor pricing before relying on these numbers.

| Configuration | Estimated monthly usage cost |
|---|---|
| Local speech recognition, cloud off | $0 |
| Groq transcription | ~$0.60 |
| OpenAI transcription | ~$2.25 |
| Claude cleanup | ~$0.90 |
| Groq + Claude | ~$1.50–3 |

An Apple Developer subscription is a separate distribution expense. See [PLAN.md](PLAN.md) for assumptions and the original comparison.
