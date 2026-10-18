# Utter — Plan

An open-source, push-to-talk dictation app for macOS. It's a self-hosted alternative to Wispr Flow's dictation features. Meeting notes are out of scope for now.

**Decisions so far**
- **Native macOS app**: Swift 6, SwiftUI with AppKit, running as a menu bar app.
- **Hybrid transcription**: a cloud API by default, with on-device fallback via WhisperKit.
- **Cloud LLM cleanup pass**: Claude Haiku 5.5 by default. Providers are pluggable so open-source users can swap them.
- **Expected usage**: about 20–30 minutes of dictation a day, roughly 3–4k words.
- **v1 scope**: only the core loop (hold key → speak → release → clean text appears at the cursor). Dictionary, snippets, command mode, per-app styles and history come after the core loop feels right.

---

## 1. How it works

```
[Hold hotkey] → AVAudioEngine records 16 kHz mono into memory
     → floating "listening" pill (non-activating panel, never steals focus)
[Release]     → audio → Transcription provider (Groq Whisper | OpenAI | local WhisperKit)
              → raw text → Cleanup provider (Claude Haiku 5.5, ~1.5s timeout → fall back to raw)
              → paste at cursor: save clipboard → set text → synthetic ⌘V → restore clipboard
```

Target latency from key release to text appearing is under 1.2 seconds for a typical 10–15 second clip. Groq Whisper takes about 0.2–0.5s and Haiku about 0.4–0.8s.

## 2. Build phases

| Phase | Goal | Done when |
|---|---|---|
| **0. Setup** | Toolchain and accounts | Xcode is installed, `xcodegen` builds an empty menu bar app, and the API keys work from curl |
| **1. Skeleton** | Menu bar app, push-to-talk hotkey, mic capture | Holding the key records and releasing saves a WAV you can play back |
| **2. MVP** | Cloud transcription and paste at cursor | You can dictate into Slack, Chrome, Notes, Cursor and Terminal. **Start using it daily from here.** |
| **3. Cleanup** | LLM pass for filler words, punctuation, self-corrections and lists | "um so like send it tuesday no wednesday" becomes "Send it Wednesday." |
| **4. Hybrid** | Local WhisperKit fallback, settings UI, Keychain storage, onboarding for permissions | It works offline, and a fresh install walks the user through granting permissions |
| **5. Ship** | Signing, notarization, DMG, Sparkle auto-update, Homebrew cask, README | A stranger can install it in two minutes |
| **6. v1.x** | Personal dictionary, snippets, command mode, per-app styles, local history | Each feature ships behind a setting |
| **Later** | Meeting notes | — |

A rough time budget, building with Claude Code: phases 0–3 take a weekend or two, phases 4–5 another one or two weekends, and each phase 6 feature takes an evening or two. The slow parts are permissions, hotkey edge cases and code signing, not the AI work.

## 3. Resources

**Software (free)**
- Xcode. It's free from the App Store, but large (about 10 GB or more). This Mac currently has only the Swift command-line toolchain.
- XcodeGen (`brew install xcodegen`). The project is generated from a `project.yml` file, so Claude Code can build it from the command line without opening Xcode.
- Swift packages: WhisperKit (argmaxinc) for local transcription, KeyboardShortcuts (sindresorhus) for the shortcut recorder UI, and Sparkle for updates in phase 5.

**Accounts and API keys**
- Groq API key, for Whisper transcription. This is the default because it's the cheapest and fastest.
- Anthropic API key, for the cleanup pass with Claude Haiku 5.5.
- OpenAI key (optional), for a second transcription provider.
- Apple Developer Program, $99 a year. You only need it in phase 5, to distribute signed and notarized builds. For your own use, a free Apple ID's personal team signing is enough.
- GitHub, free, for the open-source repo and Releases.

**Your hardware**: an M4 Pro with 24 GB of RAM. That runs local Whisper (large-v3-turbo) comfortably, so the local fallback will be good rather than a toy.

## 4. Monthly cost

Assumptions: 25 minutes a day, 30 days, which is 750 minutes (about 12.5 hours) of audio a month. Clips average about 12 seconds, so that's about 125 clips a day, or about 3,750 a month.

**Transcription (pick one)**

| Provider | Rate | Monthly |
|---|---|---|
| Groq `whisper-large-v3-turbo` | $0.04/hr, 10-second minimum per request | **≈ $0.60** (includes the cost of short clips rounding up to 10s) |
| OpenAI `gpt-4o-mini-transcribe` | ~$0.003/min | ≈ $2.25 |
| Deepgram Nova-3 (streaming) | ~$0.0048–0.0077/min | ≈ $3.60–5.80 |
| Local WhisperKit | — | $0 |

**Cleanup with Claude Haiku 5.5** ($0.10 per million input tokens, $0.50 per million output tokens; thinking turned off for speed)
- Each request is about 2,000 input tokens (instructions, dictionary and context) and about 80 output tokens.
- Over a month that's about 7.5M input tokens ($0.75) and about 0.3M output tokens ($0.15), so **≈ $0.90**. Prompt caching of the fixed instructions can bring this lower.

**Total**

| | Monthly | Yearly |
|---|---|---|
| API usage (Groq + Haiku) | **≈ $1.50** (even at 2× usage, ~$3) | ~$18–36 |
| Apple Developer Program (only if you distribute signed builds) | $8.25 | $99 |
| **Your own build, signed for public release** | **≈ $10** | **≈ $117–135** |
| **Your own build, personal use only** | **≈ $1.50–3** | **≈ $18–36** |
| Wispr Flow Pro (annual billing) | $12 | $144 |
| Wispr Flow Pro (monthly billing) | $15 | $180 |
| Wispr Flow Free | $0, but capped at 2,000 words a week on desktop | — |

At ~3,500 words a day, you'd hit Wispr's free cap in about half a day, so the free tier isn't a real option.

**Bottom line**
- **Personal use only:** you save about $125–160 a year compared with Wispr Pro.
- **Publishing signed builds:** the $99 Apple fee eats most of that, leaving about $10–60 a year. At that point the reasons to build are ownership, privacy (local mode), customization and the open-source project, not cost.
- **Not counted above:** your build time and any Claude Code subscription, which you likely already pay for.

Pricing was checked in October 2026 and may change. Groq's and Anthropic's rates come from their own docs. The OpenAI and Deepgram rates come from third-party aggregators, so check those before relying on them.

## 5. Known gotchas (also in the build prompt)

1. **Permissions reset when the code signature changes.** macOS ties Accessibility and Microphone permissions to the signature. Sign dev builds with one consistent identity, or you'll be re-granting permissions on every rebuild.
2. **Fn/Globe key conflicts.** Holding Fn as the hotkey clashes with the emoji picker and macOS dictation, unless System Settings → Keyboard → "Press 🌐 key to" is set to "Do nothing". Ship with Right Option as the default and Fn as an option.
3. **Not App Store compatible.** Posting synthetic keystrokes requires an app outside the sandbox, so distribute directly with a DMG and Homebrew instead.
4. **The LLM might answer instead of cleaning.** If you dictate "what's the capital of France", the model must return the question, not "Paris". The fix is to wrap the transcript in tags and use a strict system prompt, backed by a test suite.
5. **Clipboard handling.** Restore the user's clipboard after pasting, and mark the temporary item as transient so clipboard managers ignore it.
6. **Secure input fields.** Password fields block synthetic paste. Detect this and show a notice instead of failing silently.
7. **Existing open-source alternatives.** Projects such as VoiceInk already exist. Look at them for prior art on hotkeys and paste behavior, and to work out what will make Utter different.
