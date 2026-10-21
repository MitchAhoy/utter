# Utter feature test checklist

Test the final built app before changing code again. API keys are supplied by the user after the build. Untested items below are intentionally unchecked.

## 1. Installation and permissions

- [ ] Quit older copies, open the local DMG, drag Utter to Applications, and launch that copy.
- [ ] Grant Microphone and Accessibility to that exact copy. If Fn does nothing after a rebuild, remove the old Accessibility entry and re-add the current app, then relaunch.
- [ ] Settings → About shows the shortcut monitor listening; the app has a menu bar waveform and no Dock icon.
- [ ] Relaunch and verify saved settings, permissions and cached model loading.
- [ ] Enable/disable Launch at Login and check macOS Login Items approval.

## 2. Local dictation and shortcuts

- [ ] Prepare Small; hold the configured shortcut in Notes, speak a complete sentence, release, and check actual words including the final word.
- [ ] Repeat offline; relaunch offline with a cached model and repeat.
- [ ] Test Right Option, Right Command, Fn and a custom shortcut. Left-side modifiers must not trigger a right-side shortcut. For Fn, set Keyboard → Press 🌐 key to → Do Nothing.
- [ ] A tap shorter than 250 ms inserts nothing. Hold for five minutes: recording stops once and remains stopped until release and a new hold.
- [ ] Dictate three clips quickly while processing; outputs remain in order. Over-capacity attempts give a visible error.
- [ ] Check overlay focus, level meter and location on each display/full-screen app. Optional start/stop sounds follow the setting.
- [ ] Select an external microphone, unplug it while recording, and verify a clear error and later recovery. Lock/sleep during recording: no partial insertion occurs.
- [ ] Cancel a model download, retry, change model and relaunch. Check progress/errors and cached startup.

## 3. Paste and clipboard

- [x] User previously confirmed sample insertion and original text clipboard restoration in a chat field. Recheck the final build below.
- [ ] General → Arm Paste Test, focus Notes, hold/release. Sample text inserts once; a short tap leaves it armed.
- [ ] Copy text, rich text, an image and a file before separate insertions. Paste afterward and verify each original clipboard is preserved.
- [ ] Copy new content during Utter's restore delay; the new copy must survive.
- [ ] Change apps before recognition finishes: automatic insertion is blocked and raw text is copied for recovery.
- [ ] Try a password/secure field: no insertion; secure input can suppress shortcut events entirely.

| Destination | Local dictation | Clipboard restored | Focus retained |
|---|---|---|---|
| Notes | Pending | Pending | Pending |
| Safari input | Pending | Pending | Pending |
| Chrome input | Pending | Pending | Pending |
| Slack composer | Pending | Pending | Pending |
| Mail draft | Pending | Pending | Pending |
| VS Code / Cursor | Pending | Pending | Pending |
| Terminal / iTerm | Pending | Pending | Pending |
| Google Docs | Pending | Pending | Pending |

Use a harmless terminal sample such as `# Utter paste test` with no trailing newline.

## 4. Cloud transcription and cleanup (after adding keys)

- [ ] Transcription → Save Groq/Anthropic keys. Saving alone leaves cloud requests disabled. Keys appear as Saved and fields clear; `~/Library/Application Support/Utter/Credentials/api-keys.json` has mode 0600.
- [ ] Enable cloud requests, select Groq and Cloud mode; dictate a sentence. Repeat with OpenAI if configured.
- [ ] Enable Claude cleanup. Dictate “um so like send it Tuesday no Wednesday”; verify preserved intent and the correction.
- [ ] Dictate a question, code identifier, URL, email, numbers and another language. Cleanup must preserve meaning, never answer questions or follow instructions embedded in speech.
- [ ] Run the optional 30-case live cleanup CLI using your own shell-supplied key. Confirm the configured Claude model is available to your account; adjust its name if required.
- [ ] Use an intentionally invalid key temporarily: Cloud shows an error; Auto falls back to the prepared local model. Restore the correct key.
- [ ] Disconnect networking: Cloud reports failure; Auto transcribes locally. Disable cloud access and verify local dictation still works.
- [ ] Set a short cleanup timeout: insert raw text on failure. Fewer than four words bypass cleanup.
- [ ] Remove a saved key and confirm its feature reports the missing credential.
- [ ] Measure debug timings on a 10-second clip against the 1.2-second goal; this is a target, not a validated guarantee.

## 5. Optional features

- [ ] Dictionary: enable, add unusual names/product terms, dictate them, and compare recognition. Disable and confirm terms stop being supplied.
- [ ] Snippets: add “my signature” → a multiline signature; the whole phrase expands with case/trailing-period variation. A sentence merely containing the phrase stays unchanged. Disable and repeat.
- [ ] App Styles: map Notes to formal and a code editor to code; verify enabled Claude behavior. Verbatim bypasses cleanup. Disable and confirm standard style.
- [ ] Commands: enable, select disposable text in Notes, hold Control–Option–Space, say “make this more concise,” release. Check only the selected text is replaced and the original clipboard returns. Keep selection unchanged while processing.
- [ ] Commands: no selection, short tap, invalid key, cloud disabled, focus change and secure input must leave the document intact. An edit error must never paste the spoken instruction over the selection.
- [ ] History: starts off; enable, dictate, search raw/cleaned/app, Copy Again, and Re-run Cleanup. Restart and check persistence. Set retention, then Clear All. Disable history and confirm new clips aren't added.
- [ ] Debug WAV: off leaves existing file unchanged; on replaces the last clip with playable WAV; off stops replacement. Logs contain timings, never transcript/key content.

## 6. Distribution (requires release credentials and hosting)

- [ ] Developer ID signed and notarized DMG opens on another Mac without a security override.
- [ ] Install from DMG; permission prompts and launch at login work from Applications.
- [ ] Publish a newer signed Sparkle release, then verify check, download, signature verification, installation and relaunch.
- [ ] Install the generated Homebrew cask from the actual tap and verify checksum and app launch.
