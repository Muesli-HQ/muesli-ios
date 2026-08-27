# iOS Notepad capture and model switching handoff

## Pull request

- PR: https://github.com/Muesli-HQ/muesli-ios/pull/37
- Branch: `codex/ios-notepad-model-picker`
- Base: `main`

## Objective

Clarify the non-meeting dictation experience without requiring a new backend or persistence schema: Quick Note remains the short capture path, Notepad becomes a resumable text-first surface, and duration-promoted Long Voice Notes continue to retain their audio and playback guarantees.

## Implemented

- Added a centered Quick Note / Notepad selector to the dashboard capture card.
- Added dashboard model selection and keyboard model selection using the existing app-group store and cross-process event bus.
- Made Start Notepad open the editor and begin listening immediately.
- Made Notepad support repeated stop, transcribe, resume cycles while persisting the accumulated text.
- Removed playback affordances from Notepad records; Notepad is intentionally text-first.
- Preserved duration-promoted Long Voice Notes as a separate experience with audio persistence, recovery, and playback.
- Reused existing persisted session fields to distinguish Notepad from duration-promoted Long Voice Notes; no schema migration was added.
- Restored the standard single-color in-app waveform and added a dedicated timer lane so the timer cannot overlap it.
- Updated active recording controls to use a dark-green stop control with a white stop glyph and a solid-red discard control.
- Aligned the history playback control with the remaining metadata badges and omitted it for Notepad entries.

## Verification

- 37 tests passed across `RecordingSessionCapabilitiesTests` and `VoiceNoteLifecycleTests`.
- 87 tests passed across `KeyboardControllerTests`, `KeyboardWaveformTests`, `LongVoiceNotePersistenceTests`, and `SharedStoreTests`.
- Focused UI regression tests passed for Quick Note recording, direct-start and empty Notepad, active and completed Long Voice Note states, waveform rendering, discard controls, and expanded history metadata.
- `./scripts/ios-dev-test.sh --dev --device-id 8FAE4F9F-4C53-5DFD-9C28-BBF0973DA3D3` built, installed, and launched MuesliDev on Picophone while preserving app data.

## Notes and follow-up

- The model picker is intentionally backed by existing shared preferences and event primitives rather than a new backend model.
- Generated ImageGen mockups under `output/` and the local `design-qa.md` report were intentionally excluded from the PR.
- Review follow-up addressed Greptile/CodeRabbit findings by restoring Long Voice Note settings copy, anchoring the Notepad discriminator to the recording start time, and deleting both active and canonical Notepad segments while suppressing autosave during discard.
- The review follow-up passed 72 capability/shared-store tests and 38 Notepad/voice-note lifecycle tests.
- CI should be reviewed on PR #37 before merge.
