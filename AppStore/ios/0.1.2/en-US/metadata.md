# Muesli for iOS 0.1.2 metadata draft

Status: draft only. Not submitted for review or release.

## Promotional Text

Private voice notes and meeting transcription on your iPhone. Speak naturally, transcribe on device, and keep your words close.

## Description

Muesli turns your iPhone into a private, local-first speech workspace.

Capture voice notes, record in-person meetings, and turn speech into useful text with transcription that runs on your device.

VOICE NOTES

- Record quick thoughts or longer voice notes.
- Transcribe speech locally with an on-device model.
- Copy, share, and revisit saved transcripts.
- Use the Muesli keyboard to bring dictation into other apps.

MEETING TRANSCRIPTION

- Record in-person conversations from your iPhone microphone.
- Keep meeting transcripts organized and searchable.
- Choose note templates for balanced notes, decisions, and action items.
- Create optional AI summaries with a provider you connect.

MADE FOR YOUR VOICE

- Remove common filler words automatically.
- Add custom words, names, brands, acronyms, and phrase corrections.
- Choose the local transcription model that fits your workflow.

PRIVATE BY DEFAULT

Core speech transcription runs on your iPhone. Audio and transcripts stay local unless you explicitly turn on an optional connected feature. Text sync through your private iCloud account and cloud-backed meeting summaries are optional.

After the selected transcription model is downloaded, core transcription can work without an internet connection.

Muesli is open source. Inspect the code and follow development at github.com/Muesli-HQ/muesli-ios.

## Keywords

dictation,voice notes,speech to text,transcription,meetings,offline,keyboard,local,privacy

## Support URL

Canonical: https://muesli.works/help

Source: `muesli-landing/src/siteData.js` and the `/help` route in `muesli-landing/src/App.jsx`.

GA readiness blocker: the current page is written for the macOS app. Add iOS-specific help for microphone permission, model download, the custom keyboard, Full Access, meeting recording, and iCloud sync before using this URL for GA.

## Marketing URL

Canonical: https://muesli.works/

Source: `muesli-landing/src/siteData.js`, `muesli-landing/README.md`, and the site's canonical metadata.

GA readiness blocker: the current home page presents Muesli as a Mac app. Add an iOS product section or a dedicated iOS page before GA.

## Related URLs

- Privacy policy: https://muesli.works/privacy
- Terms of service: https://muesli.works/terms
- Public legal and privacy contact: pranav@muesli.works

GA readiness blocker: the privacy policy and terms currently describe Muesli as macOS software. Update both documents to cover the iOS app, its local storage, optional iCloud sync, microphone access, custom keyboard behavior, optional Full Access, optional providers, and analytics before GA.

## Copyright

2026 Muesli

Source: the `muesli-landing` site footer and `siteData.legalName` both identify Muesli. Confirm whether Apple should instead show an incorporated legal entity or individual before submission.

## App Review Information

### Reviewer contact

- Email: pranav@muesli.works
- First name: required before the contact block can be saved
- Last name: required before the contact block can be saved
- Phone number: required in international format with a leading `+`

App Store Connect requires all four reviewer contact fields together. Do not infer the missing name or phone details.

### Sign-in required

No. Core voice notes, local transcription, meetings, the dictionary, and settings do not require an account. ChatGPT sign-in is optional and only used if the reviewer chooses that summary provider.

### Review notes

Muesli is a local-first voice note and meeting transcription app.

No account is required for the core experience. On first use, select and download a local transcription model. Microphone access is required to record voice notes and in-person meetings.

The optional Muesli keyboard is installed through iOS Settings. Full Access lets the keyboard extension exchange a dictation request and result with the containing app through the shared App Group. The keyboard extension does not record audio itself.

Optional AI meeting summaries require the reviewer to connect a supported provider. This is not required to review local recording and transcription.

Suggested review path:

1. Launch Muesli and complete onboarding.
2. Download the recommended local transcription model.
3. Open Voice Notes, record a short phrase, stop, and review the saved transcript.
4. Open Meetings, enter a title, start and stop a short recording, then review the transcript.
5. Open Settings > Dictionary to review filler word removal and custom phrase correction.

## Release control

Use manual release for version 0.1.2. Do not add the version for review, submit it, or release it during metadata preparation.
