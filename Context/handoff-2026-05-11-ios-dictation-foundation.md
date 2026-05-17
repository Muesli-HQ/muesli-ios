# Context Handover — Muesli iOS dictation foundation through delayed transcription

**Session Date:** 2026-05-11 23:26 IST
**Repository:** muesli-ios
**Branch:** main

---

## Session Objective

Start the private `muesli-ios` app as a mobile companion to Muesli macOS, get it building/running on the connected iPhone, implement keyboard-driven dictation insertion, align the UI with the macOS app styling, then add durable recording sessions and delayed transcription foundations before tackling Monologue-style persistent microphone access.

## What Got Done

- `Shared/DictationModels.swift:17` — Added `RecordingSessionKind` for quick dictation, keyboard dictation, and meetings so all audio flows can share one durable session model.
- `Shared/DictationModels.swift:100` — Added `RecordingSession` with phase, title, audio file, transcript, engine, and error fields.
- `Shared/DictationModels.swift:148` — Added `Transcript` and linked `DictationResult` to optional `sessionID`.
- `Shared/SharedStore.swift:97` — Added JSON persistence for recording sessions, sorted newest-first and capped to 500 sessions.
- `Shared/SharedStore.swift:121` — Added transcript persistence, replacing prior transcript for the same session.
- `Shared/SharedStore.swift:138` — Added app-group `Recordings/` audio file paths for durable local WAV storage.
- `Muesli/AudioRecorder.swift` — Refactored recorder start to accept a caller-supplied output URL so sessions can own stable audio files.
- `Muesli/DictationCoordinator.swift:108` — Added transcript copy helper for in-app history and meeting rows.
- `Muesli/DictationCoordinator.swift:285` — Refactored app/keyboard quick dictation to create durable sessions and persist audio before transcription.
- `Muesli/DictationCoordinator.swift:330` — Refactored stop/transcribe path to write `Transcript`, update session phase, and preserve failures.
- `Muesli/DictationCoordinator.swift:429` — Added meeting recording start flow with local audio persistence.
- `Muesli/DictationCoordinator.swift:466` — Added stop-and-queue meeting flow for delayed transcription.
- `Muesli/DictationCoordinator.swift:499` — Added manual delayed transcription for queued sessions.
- `Muesli/MeetingsView.swift:3` — Added Meetings tab UI with title input, start/stop-and-queue, saved sessions, manual transcribe, transcript display, and copy.
- `Muesli/RootView.swift:60` — Added Meetings section to the app shell.
- `Shared/MuesliHaptics.swift:4` — Added haptic helpers for dictation start/stop.
- `MuesliKeyboard/KeyboardController.swift:117` — Added haptics for keyboard start/stop dictation.
- `MuesliKeyboard/KeyboardController.swift:167` — Added clear behavior: delete the last Muesli-inserted text when known, otherwise fall back to one backspace.
- `MuesliKeyboard/KeyboardRootView.swift:76` — Replaced the keyboard `space` key with a `clear` key using `delete.left`.
- `MuesliKeyboard/KeyboardViewController.swift:14` — Wired keyboard deletion through `textDocumentProxy.deleteBackward()`.
- `Tests/MuesliTests/SharedStoreTests.swift` — Added tests for session persistence/replacement and transcript replacement.
- Git commits pushed to `main`:
  - `17c712e` — Add keyboard clear key.
  - `33f5532` — Add durable recording sessions.
  - `af969ab` — Add dictation haptic feedback.
  - `7de2cc0`, `f794079`, `a1168b5` — Preserve and improve keyboard handoff state.
  - `48d1418` — Add keyboard dictation handoff.

## What Didn't Work

- **Direct microphone capture inside custom keyboard**: iOS keyboard extensions cannot directly own normal microphone capture in the way the main app can. Current flow opens Muesli to record, then user swipes back to keyboard for insertion. Learning: persistent mic requires an app-side activity/session, not a pure keyboard-extension fix.
- **Monologue-style persistent mic not implemented yet**: User flagged Monologue appears to use Live Activities to keep an app-side audio session alive while the keyboard remains usable. Current repo has `UIBackgroundModes/audio`, but no ActivityKit target/code yet.
- **Bottom globe/mic alignment**: User noticed the system globe/mic row is visually asymmetric. That row is iOS system keyboard chrome, not the SwiftUI keyboard view; the app cannot reliably position those icons from the extension.
- **Full-field clear**: Third-party keyboards do not get arbitrary access to a host app's whole text field. Implemented safe clear for the last Muesli-inserted text, with single-backspace fallback.
- **OSStatus -50 during onboarding test dictation**: Earlier test dictation failed due to audio session/recording setup. It was fixed before the durable session work; dictation then worked on device.

## Key Decisions

- **Decision**: Keep iOS in a separate private `muesli-ios` repo.
  - **Context**: iOS has different distribution, app extension, CoreML/ANE constraints, and may have monetization/sync strategy distinct from MIT macOS app.
  - **Rationale**: Avoid coupling early iOS architecture and private monetization experiments to the public macOS repo.
  - **Alternatives rejected**: Same repo monolith, or new org with `muesli-macos` and `muesli-ios` immediately.

- **Decision**: Build iOS as a companion app, not full macOS feature parity.
  - **Context**: iOS model support is constrained by ANE/CoreML-compatible engines and keyboard extension rules.
  - **Rationale**: Prioritize dictation, keyboard insertion, local transcript history, and later sync/meeting capture.
  - **Alternatives rejected**: Attempting all macOS features first, especially meetings parity before basic dictation UX.

- **Decision**: Use durable JSON session/transcript storage first.
  - **Context**: Need reliable local audio/session foundation before sync, Live Activities, or background queues.
  - **Rationale**: Existing app already uses lightweight app-group JSON storage; this was lower-risk and testable.
  - **Alternatives rejected**: Jumping straight to Core Data/SQLite or cloud sync before the data model stabilizes.

- **Decision**: Delayed transcription is manual for now.
  - **Context**: User asked to implement "until delayed transcriber" before Live Activities.
  - **Rationale**: Queued sessions prove durable audio + transcript persistence without adding BGTaskScheduler or Live Activities complexity.
  - **Alternatives rejected**: Automatic background transcription in the same pass.

- **Decision**: Do not claim persistent microphone access is fixed until ActivityKit is actually wired.
  - **Context**: User tested and still had to swipe to Muesli and back.
  - **Rationale**: The current handoff design still depends on foreground app recording; Monologue-style behavior is separate app-lifecycle work.
  - **Alternatives rejected**: Cosmetic keyboard state changes that imply persistence but do not keep audio capture alive.

## Lessons Learned

- Custom keyboard extensions can insert/delete through `textDocumentProxy`, but they do not have broad access to host text fields.
- The system globe/mic row around a third-party keyboard is not part of the app's SwiftUI keyboard view.
- For keyboard dictation on current iOS, the practical architecture is: keyboard writes a request to shared storage, app records/transcribes, keyboard polls shared storage and inserts the result.
- Monologue/Wispr Flow-like UX likely depends on keeping the containing app alive with a visible system affordance, not bypassing iOS mic rules inside the extension.

## Nuances & Edge Cases

- `MuesliiOS.xcodeproj` is generated and ignored. Run `xcodegen generate` after adding Swift files or target config changes.
- App-group storage must be available for keyboard extension status, commands, results, sessions, transcripts, and audio paths.
- Clear key only knows text inserted through Muesli in the current keyboard controller lifetime. If the keyboard is recreated, clear falls back to one delete.
- `MuesliWaveformView` is level-reactive only when passed a real `level`; avoid fake/random animation for recording/transcribing if the user expects audio-reactive feedback.
- The device install command used successfully:
  `xcrun devicectl device install app --device 00008140-001C6D2C11FA801C /Users/pranavhari/Library/Developer/Xcode/DerivedData/MuesliiOS-hcoztiskpbclebgabuedktrhbepi/Build/Products/Debug-iphoneos/Muesli.app`
- Builds still show a pre-existing warning: "All interface orientations must be supported unless the app requires full screen."

## Codebase Map (Files Touched)

### Modified

- `Shared/DictationModels.swift` — Added durable session/transcript models and linked dictation results to sessions.
- `Shared/SharedStore.swift` — Added recording session, transcript, and durable audio file storage.
- `Shared/MuesliHaptics.swift` — Added start/stop haptic helpers.
- `Shared/MuesliWaveformView.swift` — Existing waveform component used for level-aware UI.
- `Muesli/AudioRecorder.swift` — Added support for caller-provided audio output URL.
- `Muesli/DictationCoordinator.swift` — Central orchestration for quick dictation, keyboard handoff, meetings, queued transcription, copy, haptics, and session state.
- `Muesli/DictationView.swift` — In-app dictation UI previously updated with waveform/state improvements.
- `Muesli/MeetingsView.swift` — New meetings recorder and delayed transcription UI.
- `Muesli/RootView.swift` — App shell, keyboard handoff overlay, and section routing including Meetings.
- `Muesli/SettingsView.swift` — Settings displays keyboard/model/runtime state.
- `Muesli/OnboardingView.swift` — Onboarding includes name/use-case/permissions/test dictation; telemetry opt-in screen was removed.
- `MuesliKeyboard/KeyboardController.swift` — Keyboard state machine, shared-store polling, handoff, insert latest, haptics, and clear.
- `MuesliKeyboard/KeyboardRootView.swift` — Keyboard SwiftUI layout and primary/clear/return controls.
- `MuesliKeyboard/KeyboardViewController.swift` — Bridges SwiftUI controller to `textDocumentProxy` insert/delete.
- `Muesli/Info.plist` — Includes microphone usage and `UIBackgroundModes/audio`.
- `MuesliKeyboard/Info.plist` — Requests open access for shared app-group communication.
- `Tests/MuesliTests/SharedStoreTests.swift` — Added persistence tests.
- `project.yml` — XcodeGen project definition for app, keyboard extension, tests, FluidAudio, and TelemetryDeck.

### Read / Referenced

- macOS Muesli repo — Used for UI/style inspiration and onboarding expectations.
- OSS iOS dictation apps via Exa — Used for architecture inspiration around custom keyboard + app handoff.
- WhisperKit/FluidAudio docs/repositories — Used to decide initial iOS runtime direction around CoreML/ANE-compatible transcription.
- Monologue and Wispr Flow apps on user's iPhone — Used as UX references for keyboard dictation and persistent microphone expectations.

### Related (Not Touched)

- ActivityKit / Live Activities target code — Needed next for persistent app-side recording affordance.
- BGTaskScheduler/background transcription — Needed later if queued meetings should transcribe automatically.
- Cloud/local sync layer — Needed later for two-way macOS/iOS sync and Pro monetization.
- SQLite/Core Data storage — Likely future replacement if sessions/transcripts/audio metadata grow beyond JSON.
- App Store distribution metadata — Not yet addressed beyond development builds.

## Next Steps

1. **Implement Live Activity persistent recording foundation** — Add ActivityKit dependency/code, activity attributes, app-side recording lifecycle, and a visible Dynamic Island/Lock Screen state for keyboard dictation. Keep privacy copy explicit: on-device transcription, local audio.
2. **Connect keyboard to Live Activity-backed app session** — Keyboard should start/stop through shared commands while the containing app keeps the audio session alive; verify that subsequent dictations do not require the swipe-to-app flow when a Live Activity session is already active.
3. **Add robust state recovery** — On keyboard appear, read current session/status and show `Listening`, `Transcribing`, `Ready`, or actionable error rather than stale yellow/open states.
4. **Improve meeting sessions** — Add rename/delete/export, duration display, and explicit queued/transcribing/completed filters.
5. **Add automatic delayed transcription later** — Use BGTaskScheduler or foreground queue processing after manual delayed transcription is stable.
6. **Design sync model** — Decide whether sync starts as file/package sync, CloudKit, custom backend, or macOS peer-to-peer handoff.
7. **Investigate full-screen/orientation warning** — Either support all orientations or mark app full screen if appropriate.

## Open Questions

- Can ActivityKit plus background audio reliably avoid the swipe-to-Muesli flow on iOS 26.4, or does the app still need one manual foreground activation per recording session?
- Should the keyboard dictation session be always-on with an explicit Live Activity toggle, or should each dictation create a short-lived activity?
- For meetings, should transcription be immediate by default after stop, queued by default, or user-selectable?
- What is the first sync target: dictation text only, audio + transcript, meeting sessions, model/settings profile, or all of these?
- Should JSON persistence be replaced before sync work begins?
