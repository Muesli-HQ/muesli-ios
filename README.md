# Muesli for iOS

Private scaffold for the Muesli iOS app and keyboard extension.

Muesli iOS is expected to share product DNA with the macOS app, but not full feature parity. The first product surface is a custom keyboard that can hand off voice input to the containing app, then insert the resulting transcript back into the active text field.

## Architecture

```text
Muesli/
  Main iOS app. Owns microphone permission, recording, local model runtime, history,
  settings, onboarding, and future sync/account surfaces.

MuesliKeyboard/
  Custom keyboard extension. Owns the text-input surface and result insertion.
  It does not record audio directly.

Shared/
  DTOs and App Group storage used by both targets.
```

The keyboard creates a dictation request in the App Group container and opens the main app with `muesli://dictate?request=<uuid>`. The app records/transcribes, writes a `DictationResult`, and the keyboard polls the shared container to insert the result.

This follows the same broad pattern used by open-source iOS voice keyboard projects such as Wave, TypeWhisper, and Sayboard.

## Requirements

- Xcode 16+
- iOS 17+
- XcodeGen

```bash
brew install xcodegen
xcodegen generate
open MuesliiOS.xcodeproj
```

Set your Apple Developer Team on both targets and register:

```text
com.phequals7.muesli.ios
com.phequals7.muesli.ios.keyboard
group.com.phequals7.muesli
```

## Current Status

This repo is intentionally private while the iOS product shape, App Store model, and monetization are being validated. The scaffold includes the keyboard handoff path and a pluggable transcription engine boundary. The containing app now uses FluidAudio Parakeet v3 for on-device CoreML/ANE transcription; the model downloads on first transcription and is cached by FluidAudio.

## Next Milestones

1. Add explicit model download/state management UI.
2. Persist local history in the app container.
3. Add onboarding for keyboard installation and Full Access.
4. Decide what belongs in a future shared Muesli Swift package.
5. Add a WhisperKit backend if model choice becomes important on iOS.
