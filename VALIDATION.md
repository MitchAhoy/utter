# Validation record

Verified on 19 October 2026 on this Apple Silicon Mac with Xcode 27.1, Swift 6 strict concurrency and a macOS 14 deployment target.

## Completed machine checks

| Check | Result |
|---|---|
| XcodeGen project generation | Pass |
| Debug app and test-bundle compilation | Pass |
| XCTest via `scripts/test-local.sh` | **91 tests, 0 failures, 0 skipped** |
| All ten settings pages constructed and rendered | Pass: native UI smoke test with fake credentials and temporary history |
| Release app build | Pass |
| Debug/Release metadata, arm64, microphone entitlement and non-sandboxed configuration | Pass |
| Deep signature verification including embedded Sparkle | Pass, ad-hoc development signature |
| Local DMG creation, checksum verification and read-only mounted app validation | Pass |
| Small model, real speech fixture, networking denied | Pass; recognition approximately 0.208 seconds after preparation |
| Silence rejected by real local speech model | Pass |
| Cleanup CLI with API environment variable explicitly removed | Pass: skips without network calls |
| Release/package/cask/test shell script syntax | Pass |
| Generated Homebrew cask Ruby syntax using fixture metadata | Pass |
| Whitespace/conflict check (`git diff --check`) | Pass |

The inference timing is for the synthetic phrase “The quick brown fox jumps over the lazy dog.” It excludes model preparation and does **not** establish the full microphone-to-paste latency target. The Small model was installed explicitly into Application Support; model weights are not included in the DMG. Large v3 Turbo's configuration/installation logic is tested, but this final run did not download and infer with that larger model.

## Coverage and test isolation

The suite covers hotkey edges and cancellation, 250 ms boundaries, cap rearming, capture errors, PCM/WAV encoding, audio conversion and draining, five-minute memory bounds, debug file replacement, multi-item/multi-type clipboard restoration, concurrent copies, transient/concealed markers, secure input and focus guards, queue order/capacity, transcription and cleanup timeouts, fallback and recovery, model receipts/preparation/cancellation/retry, cloud request formats, authorization gates, sanitized HTTP errors, Auto routing, Keychain/preferences separation using fake credentials, thirty cleanup contract fixtures, command edit success/failure, exact snippet expansion, dictionary/style persistence, real SQLite search/persistence/retention/permissions/clearing, and settings construction/layout.

Routine tests use fake cloud transports, isolated pasteboards and temporary history databases. They do not record microphone audio, send synthetic paste events, download models, or call cloud services. The settings smoke test briefly displays a test window without requesting permission or starting capture. Cached NSView bitmaps do not fully capture SwiftUI's composited layers; they are a construction/rendering smoke check, **not** proof that every visual detail or interaction has been validated.

The 30 cleanup fixtures exercise the HTTP request/response contract with canned provider results. They **do not prove the live Claude model obeys the prompt**. The opt-in `UtterCleanupCheck` exists for that later test with the user's key.

## Local XCTest launcher limitation

`xcodebuild build-for-testing` succeeds. On this agent's Mac environment, the standard `xcodebuild test` app-host launcher repeatedly stalled in the dynamic loader before reporting test results. The same compiled XCTest bundle runs successfully through Xcode's `xctest` executable using the app's library/framework paths. `scripts/test-local.sh` makes that route reproducible and preserves inherited injected libraries/access controls. All 91 tests passed through that route. Standard hosted `xcodebuild test` is **not recorded as passing** here; CI retains that normal path and has not been run remotely.

SwiftPM dependency resolution also waited on its default Keychain authorization provider. The supported `-packageAuthorizationProvider netrc` option resolved the three public packages successfully and is included in local and CI commands. No credential file or account was created.

## User-confirmed earlier behavior

The user confirmed push-to-talk recording, debug WAV playback, sample insertion in a chat field and restoration of the original clipboard in previous builds. The user also confirmed that removing and re-adding the rebuilt app in Accessibility restored Fn monitoring. Final-build retesting is listed in [TEST_PLAN.md](TEST_PLAN.md).

## Remaining interactive and external verification

- Final app: real microphone-to-paste in Notes and every requested destination, all shortcut options, multi-display/full-screen placement, external microphone unplugging, sleep/lock, launch at login, and clipboard edge cases in real apps.
- Cloud: Groq/OpenAI recognition, Claude model availability, thirty real cleanup fixtures, command edits, real network/key failures, and end-to-end cloud latency. No live requests or credentials were used during this build. The requested `claude-haiku-5-5` default remains editable in Settings.
- Optional features: real spoken dictionary/snippet behavior, app-specific style quality, command selection behavior, history interactions and retention in daily use.
- Public release: Apple Developer ID signing, notarization/stapling, public GitHub release/appcast hosting, actual Sparkle update installation and Homebrew tap installation. Scripts/integration are implemented; no public release has been published.

This Mac has no configured Apple Development or Developer ID identity. The local installer is ad-hoc signed, not notarized. Permission grants may need refreshing for the final build; stable signing requires a consistent certificate and team. Private signing keys, notarization credentials and API keys have not been generated or stored by this work.
