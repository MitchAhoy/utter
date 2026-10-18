# Local dictation verification — 19 October 2026

This checkpoint adds the on-device portion of Phase 4 while cloud-dependent
parts of Phases 2–4 remain deferred under the no-API constraint.

## Passed

- Xcode 27.1; Swift 6 with complete strict-concurrency checking.
- Debug XCTest: **68 passed, 0 failed, 0 skipped**.
- Debug and Release app builds.
- Bundle checks in both configurations: macOS 14 minimum, arm64, LSUIElement,
  microphone usage declaration, audio-input entitlement, signature integrity,
  and no app-sandbox entitlement.
- Real Small-model download and preparation through the same provider used by
  the app. Cache is in `~/Library/Application Support/Utter/Models`.
- In-memory recognition of synthetic speech: “The quick brown fox jumps over
  the lazy dog.” The check requires the five distinguishing words to appear.
- Zero-valued audio is rejected rather than generating a transcript.
- Cached model preparation, recognition, and silence rejection all pass with
  networking denied to the checker process using:

  ```sh
  sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    build/Build/Products/Debug/UtterLocalCheck small \
    "$HOME/Library/Application Support/Utter/Models" \
    /tmp/utter-local-fixture.aiff
  ```

- Cached inference for that synthetic fixture took approximately 0.20 seconds.
  This measures inference only, excluding model loading, recording, queueing,
  clipboard insertion, and restoration.

The user previously confirmed hotkey recording, sample-text insertion into a
chat field, and restoration of the original clipboard contents.

## Still requires manual verification

Real microphone dictation into Notes and the other destinations in README.md;
selected external microphone behavior; multi-display/full-screen overlay focus;
model-download cancellation with a real connection; and launch-at-login system
approval. The latest app may need Accessibility re-granted because builds remain
ad-hoc signed. A personal-team identity has not been configured.

Large v3 Turbo is offered as the default but has not been downloaded or run in
this verification. Small is installed and tested on this machine. Neither cloud
transcription, Claude cleanup, nor Cloud/Auto fallback is connected. Distribution,
notarization, updates, and the Phase 6 features are still outstanding.
