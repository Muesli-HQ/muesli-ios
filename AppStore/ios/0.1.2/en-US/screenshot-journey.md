# iOS 0.1.2 customer journey screenshot manifest

This document follows a new customer from first launch through onboarding, permissions, voice notes, meetings, recovery, and settings. The corresponding captures live in `screenshots/journey-reference`.

These are product and QA reference captures. They are not automatically App Store submission candidates. Native permission prompts, failures, recovery dialogs, and UI-test fixtures are especially useful for documentation and review, but should not be placed in the public screenshot set without an editorial decision.

## Capture environment

- Version: 0.1.2
- Build: 8
- Device: iPhone 17 Pro Max Simulator
- Runtime: iOS 26.5
- Appearance: dark
- App bundle: `com.phequals7.muesli.ios`
- Resolution: 1320 x 2868 PNG
- Animation format: Simulator screen recording as MP4

The checked-in Xcode project did not include every current source file, so the simulator build was generated from the repository with XcodeGen in a disposable `/tmp` copy. No project or app source files were changed for these captures.

## Capture types

- **Real**: reached through normal interaction with the simulator build.
- **System**: native iOS permission UI.
- **Deterministic**: a production UI state seeded with the app's existing UI-test launch arguments. Used where Simulator audio cannot produce a stable transcript or interruption.
- **Animation**: MP4 companion showing that the waveform is moving, not a static decoration.

## First-run customer journey

| Step | Customer action and product state | File | Type | Public screenshot? |
| --- | --- | --- | --- | --- |
| 1 | Open Muesli, enter a name, and choose a primary use case. The complete path uses **Everything**. | `01-onboarding-welcome-use-case.png` | Real | Candidate after recapture with clean name |
| 2 | Review the required microphone and keyboard permissions before granting access. | `02-onboarding-permissions-before-microphone.png` | Real | Reference |
| 3 | Grant microphone access from the native iOS prompt. | `03-system-microphone-permission-prompt.png` | System | Reference only |
| 4 | Return to Muesli and confirm the permission checklist. Keyboard and Full Access are managed in iOS Settings. | `04-onboarding-permissions-complete.png` | Real | Reference |
| 5 | Optionally enable private iCloud text sync with a Mac. Audio is not synced. | `05-onboarding-optional-icloud-sync.png` | Real | Candidate |
| 6 | Choose **Scan Mac QR** and review why camera access is needed. | `06-onboarding-scan-mac-qr-camera-intro.png` | Real | Reference |
| 7 | Grant camera access from the native iOS prompt. | `07-system-camera-permission-prompt.png` | System | Reference only |
| 8 | Scan the Mac setup QR code to pair private iCloud sync. | `08-mac-qr-scanner-ready.png` | Real | Reference |
| 9 | Download the default local Parakeet 110M speech model. | `09-onboarding-model-download-started.png` | Real | Candidate |
| 10 | Confirm the model is downloaded and ready for on-device transcription. | `10-onboarding-model-downloaded-ready.png` | Real | Strong candidate |
| 11 | Arrive at the onboarding voice-note test. | `11-onboarding-test-voice-note-ready.png` | Real | Reference |
| 12 | Record a test note and see the live waveform react. | `12-onboarding-test-waveform-active.png`, `12-onboarding-test-waveform-animation.mp4` | Real + Animation | Strong candidate |
| 13 | Stop the test and wait for local transcription. | `13-onboarding-test-transcribing.png` | Real | Reference |
| 14 | Handle a no-speech result and retry. The Simulator cannot provide meaningful microphone speech. | `14-onboarding-test-no-speech-retry.png` | Real | QA only |
| 15 | Optionally configure an OpenRouter key and model for meeting summaries. | `15-onboarding-optional-meeting-summaries-openrouter.png` | Real | Reference |
| 16 | Alternatively choose ChatGPT sign-in and a summary model. | `16-onboarding-optional-meeting-summaries-chatgpt.png` | Real | Reference |
| 17 | Keep meeting summaries disabled and continue with fully local transcription. | `17-onboarding-meeting-summaries-disabled.png` | Real | Candidate |
| 18 | Finish onboarding at the empty Voice Notes home. | `18-voice-notes-home-empty-ready.png` | Real | Candidate |

## Voice-note journey

| Step | Customer action and product state | File | Type | Public screenshot? |
| --- | --- | --- | --- | --- |
| 19 | Start a voice note and see the live waveform and local recording status. | `19-voice-note-live-waveform.png`, `19-voice-note-live-waveform-animation.mp4` | Real + Animation | Strong candidate |
| 20 | Enter a long-form voice note with an always-available scratchpad. | `30-simulated-long-voice-note-active-scratchpad.png` | Deterministic | Candidate after device validation |
| 21 | Add ideas, questions, or follow-up actions to the scratchpad while recording continues. | `31-simulated-long-voice-note-with-scratchpad.png` | Deterministic | Strong candidate after device validation |
| 22 | Attempt to discard the note and review the destructive-action warning. | `32-voice-note-discard-confirmation.png` | Deterministic | QA only |
| 23 | Complete a long voice note and review its transcript and scratchpad. | `33-simulated-completed-long-voice-note.png` | Deterministic | Candidate after device validation |

## Meeting journey

| Step | Customer action and product state | File | Type | Public screenshot? |
| --- | --- | --- | --- | --- |
| 24 | Open Meetings and start a new recording from the empty state. | `20-meetings-home-start-new-empty.png` | Real | Candidate |
| 25 | Choose a note template: General, 1:1, Standup, Interview, Lecture, Customer Call, or Planning. | `21-meeting-template-picker.png` | Real | Candidate |
| 26 | Name the meeting and confirm the chosen template. | `22-meeting-title-and-template-ready.png` | Real | Candidate |
| 27 | Record the meeting with a live waveform and manual notes available beside it. | `23-live-meeting-waveform-manual-notes.png`, `23-live-meeting-waveform-animation.mp4` | Real + Animation | Strong candidate |
| 28 | Add manual agenda and action notes while recording. | `24-live-meeting-with-manual-notes.png` | Real | Strong candidate |
| 29 | Stop the meeting and see audio and notes enter local processing. | `25-meeting-processing-audio-and-notes.png` | Real | Reference |
| 30 | See an in-progress meeting in the meetings list. | `26-simulated-live-meeting-list-card.png` | Deterministic | Candidate after device validation |
| 31 | Review a live meeting transcript. | `27-simulated-live-meeting-transcript.png` | Deterministic | Strong candidate after device validation |
| 32 | See that an interrupted meeting needs recovery. | `28-simulated-meeting-needs-recovery-card.png` | Deterministic | QA only |
| 33 | Open the interrupted session and choose **Stop & Recover**. | `29-simulated-interrupted-meeting-stop-and-recover.png` | Deterministic | QA only |

## Settings and complete exploration

| Step | Customer action and product state | File | Type | Public screenshot? |
| --- | --- | --- | --- | --- |
| 34 | Open Settings and view the complete control surface: Voice Notes, Meetings, Dictionary, Models, AI Summaries, Sync & Privacy, Appearance, and About. | `34-settings-home.png` | Real | Candidate |
| 35 | Inspect the active local model, runtime, language, execution mode, and downloaded models. | `35-settings-local-models-parakeet.png` | Real | Strong candidate |
| 36 | Enable filler-word removal and maintain a custom dictionary for names, brands, and acronyms. | `36-settings-dictionary-filler-words.png` | Real | Strong candidate |
| 37 | Configure optional meeting summaries or leave them disabled. | `37-settings-ai-summaries-chatgpt-disabled.png` | Real | Reference |
| 38 | Review private iCloud sync: text can sync between iPhone and Mac, while audio never syncs. | `38-settings-sync-and-privacy.png` | Real | Strong candidate |

## Remaining captures for a fully exhaustive library

The following should be captured in a later pass, preferably on a physical device where relevant:

1. iOS Settings keyboard installation path and Full Access toggle.
2. Muesli Keyboard visible in an Apple app, idle and actively dictating.
3. Successful real-device voice-note transcript produced from microphone speech.
4. Successful real-device meeting transcript with speaker turns.
5. Completed meeting summary for each supported provider.
6. Model picker showing Parakeet and Whisper choices plus download/remove states.
7. Voice Notes retention, Live Activity, and keyboard setup settings.
8. Meeting audio retention, Live Activity, and default template settings.
9. Appearance themes and accent choices.
10. About screen with version 0.1.2 (8), source repository, privacy policy, terms, and acknowledgements.
11. iCloud-connected sync state and successful Mac pairing.
12. Offline/error states: model download retry, insufficient storage, revoked microphone permission, and camera denial.

## Recommended App Store story

Keep the public set benefit-led and avoid setup friction as the opening story:

1. Private on-device voice notes with live waveform.
2. Local Parakeet model downloaded and ready.
3. Long-form voice note with scratchpad.
4. Bot-free meeting recording with manual notes.
5. Live or completed meeting transcript.
6. Personal dictionary and filler-word removal.
7. Private text sync with Mac, with audio never synced.
8. Muesli Keyboard dictating into an Apple app.

Native permission prompts, retry states, discard confirmations, and recovery screens belong in QA/reviewer documentation rather than the public marketing sequence.

## Naming convention

- Still: `NN-area-state-detail.png`
- Animation: `NN-area-state-animation.mp4`
- Keep still and animation companions on the same sequence number.
- Use product-language names, not implementation names.
- Do not put personal information, API keys, patient information, or real meeting content in captures.

## Capture caveats

- Simulator microphone input did not produce meaningful speech, so successful transcript and recovery screens use existing deterministic UI-test fixtures.
- Deterministic captures show production UI but should be validated and, where practical, recaptured on a physical device before being used as public App Store imagery.
- The first onboarding screenshot inherited the stored UI-test name. Recapture it with a clean name before public use.
- System permission screens are documentation of the real first-run journey, not recommended App Store screenshots.
