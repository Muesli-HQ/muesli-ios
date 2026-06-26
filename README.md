<p align="center">
  <img src="docs/assets/muesli-ios-readme-header.png" alt="Muesli on iOS download now solar punk illustration showing private local speech transcription on iPhone" width="900" />
</p>

<h1 align="center">Muesli for iOS</h1>

<p align="center">
  <strong>Local-first dictation and meeting transcription for iPhone</strong><br>
  On-device speech-to-text | Keyboard handoff | Private by default
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <a href="https://github.com/Muesli-HQ/muesli-ios/actions/workflows/ci.yml"><img src="https://github.com/Muesli-HQ/muesli-ios/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey?logo=apple" alt="iOS 17+" />
  <img src="https://img.shields.io/badge/status-early%20TestFlight-orange" alt="Early TestFlight" />
</p>

---

if you want early access - email me at pranav@muesli.works

## What is Muesli for iOS?

Muesli for iOS is the mobile companion to [Muesli for macOS](https://github.com/Muesli-HQ/muesli). It brings the same local-first product philosophy to iPhone: record speech, transcribe it on device with CoreML/ANE models, and keep audio and transcripts local unless you explicitly choose a cloud-backed summary provider.

The iOS app is not a one-to-one port of the macOS app. It is built around iPhone-native workflows:

- **Dictation app** for recording, transcribing, copying, and sharing speech.
- **Custom keyboard extension** for handing dictation from any text field to the main app and inserting the transcript back into the keyboard.
- **Meeting recorder** for offline conversations, local transcription, saved transcripts, optional speaker transcript formatting, and structured notes.

This repository is suitable for source review, local development, CI, and TestFlight release work. End-user installation currently goes through TestFlight rather than GitHub release assets.

---

## Features

- **On-device transcription** - FluidAudio Parakeet models run locally through CoreML/ANE; audio does not need to leave the iPhone for transcription.
- **Keyboard handoff** - The keyboard extension creates a dictation request in the shared App Group, opens the main app to record/transcribe, then polls for the result and inserts it into the active text field.
- **Keyboard Session Mode** - Keep the containing app ready for lower-friction keyboard dictation while the extension remains the text input surface.
- **Dictation history** - Saved local dictations can be copied, reused, and deleted from the main app.
- **Meeting recorder** - Record in-person conversations, save sessions, transcribe locally, browse transcript history, and retain meeting audio only when enabled.
- **Meeting templates** - Choose note formats for general meetings and structured follow-up workflows.
- **Optional meeting summaries** - Generate structured notes with ChatGPT sign-in or OpenRouter BYOK after local transcription.
- **Live Activities** - Track active meeting recording state from iOS surfaces when enabled.
- **Personal dictionary** - Apply custom words, phrase replacements, and filler-word filtering after transcription.
- **Local storage first** - App data is stored locally through the shared store and App Group boundary used by the app and keyboard.
- **Content-safe telemetry** - TelemetryDeck wiring is available for release builds, with events designed to avoid audio, transcript text, and user-provided content.
- **CI coverage** - GitHub Actions generates the Xcode project, builds the app, and runs unit tests plus UI smoke tests on an iPhone simulator.

---

## Install

### TestFlight

Muesli for iOS is currently distributed to testers through TestFlight. Public GitHub release assets are useful for engineering provenance, but iOS users should install signed builds through Apple's TestFlight/App Store distribution path.

### Build from source

**Requirements**

- macOS with Xcode 16+
- iOS 17+ simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Developer account for device builds, keyboard extension signing, App Groups, and TestFlight uploads

```bash
git clone https://github.com/Muesli-HQ/muesli-ios.git
cd muesli-ios

brew install xcodegen
xcodegen generate
open MuesliiOS.xcodeproj
```

For local simulator validation:

```bash
xcodebuild \
  test \
  -project MuesliiOS.xcodeproj \
  -scheme Muesli \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

For device/TestFlight builds, configure signing for:

```text
com.phequals7.muesli.ios
com.phequals7.muesli.ios.keyboard
group.com.phequals7.muesli
```

---

## Permissions

Muesli for iOS asks only for permissions needed by the selected workflow.

| Permission | Why |
|---|---|
| **Microphone** | Record speech for dictation and meetings |
| **Keyboard** | Use the Muesli custom keyboard from text fields |
| **Full Access** | Let the keyboard extension communicate with the containing app through the shared App Group |
| **Live Activities** *(optional)* | Show active meeting recording state |

The keyboard extension does not record audio directly. Recording is owned by the containing app so microphone permission, model runtime, and transcription state stay in one place.

---

## Architecture

```text
Muesli/
  Main iOS app. Owns onboarding, microphone permission, recording, local model
  runtime, dictation history, meeting sessions, summaries, settings, and telemetry.

MuesliKeyboard/
  Custom keyboard extension. Owns the text-input surface and result insertion.
  It creates handoff requests but does not run the microphone or transcription model.

Shared/
  DTOs, preferences, post-processing, local storage, and App Group contracts used
  by both the app and keyboard extension.

MuesliLiveActivityExtension/
  Live Activity surface for recording state.

LiveActivityShared/
  ActivityKit attributes shared between the app and extension.
```

The keyboard handoff path is:

1. The keyboard creates a `DictationRequest` in the App Group container.
2. It opens the app with `muesli://dictate?request=<uuid>`.
3. The app records audio, transcribes locally, and writes a `DictationResult`.
4. The keyboard polls the shared store and inserts the transcript into the active field.

Meeting sessions use the same local-first store, with optional retained audio, transcript records, speaker-oriented transcript text, and generated notes.

---

## Tech Stack

| Component | Technology |
|---|---|
| App | Swift, SwiftUI, Observation |
| Keyboard | UIKit keyboard extension with SwiftUI-hosted UI |
| Local ASR | [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet on CoreML/ANE |
| Storage | SQLite-backed shared store in the app/App Group boundary |
| Summaries | ChatGPT OAuth or OpenRouter BYOK |
| Live status | ActivityKit Live Activities |
| Telemetry | TelemetryDeck Swift SDK |
| Project generation | XcodeGen |
| CI | GitHub Actions, `xcodebuild test`, XCTest, XCUITest smoke tests |

---

## Repository Status

Muesli for iOS is early-stage software. The current repo is focused on:

- proving the iOS dictation and keyboard handoff loop;
- making meeting recording stoppable, recoverable, and locally inspectable;
- keeping transcription local by default;
- maintaining a clean TestFlight-oriented release path;
- adding CI checks that are useful for a Swift/iOS project without requiring signed device builds.

Expect active iteration around app polish, onboarding, summaries, iCloud/sync behavior, and App Store readiness.

---

## Development

Generate the project after editing `project.yml`:

```bash
xcodegen generate
```

Run the full local test suite:

```bash
xcodebuild \
  test \
  -project MuesliiOS.xcodeproj \
  -scheme Muesli \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

The test suite currently includes:

- unit tests for shared storage, model/post-processing DTOs, keyboard recovery policy, and meeting chunk transcript merging;
- UI smoke tests that verify launch, the Dictation shell, and navigation to Meetings.

---

## Privacy

Muesli's default design is local-first:

- audio is recorded by the app, not the keyboard extension;
- transcription runs locally with FluidAudio/CoreML models;
- saved dictations and meetings stay on device unless future sync features are explicitly enabled;
- TelemetryDeck events avoid audio, transcript text, and user-provided content;
- cloud summary providers are optional and separate from local transcription.

Review [Muesli/PrivacyInfo.xcprivacy](Muesli/PrivacyInfo.xcprivacy) and [MuesliKeyboard/PrivacyInfo.xcprivacy](MuesliKeyboard/PrivacyInfo.xcprivacy) for the current privacy manifests.

---

## Related

- [Muesli for macOS](https://github.com/Muesli-HQ/muesli)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [TelemetryDeck Swift SDK](https://github.com/TelemetryDeck/SwiftSDK)

---

## Contributing

Issues and pull requests are welcome. For larger changes, please open an issue first so implementation details can be discussed against the iOS architecture and TestFlight release path.

Before opening a PR:

```bash
xcodegen generate
xcodebuild test -project MuesliiOS.xcodeproj -scheme Muesli -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

---

## License

Muesli for iOS is released under the [MIT License](LICENSE).
