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
- Balanced Quick Note discard and stop actions as an equal-sized, centered pair on the same baseline.
- Added a Notepad burst-discard action beside the live waveform; it cancels only the passage currently being recorded and preserves the accumulated Notepad document.
- Kept the idle and processing Notepad controls centered instead of letting the microphone drift back to the trailing edge after transcription.
- Moved both Notepad recording actions inside the capsule so discard sits left of the centered waveform and stop sits at its right edge.
- Preserved manually typed Notepad text when the user discards the first spoken burst by completing a text-only history item while still cancelling its audio.
- Aligned the history playback control with the remaining metadata badges and omitted it for Notepad entries.
- Connected Notepad to the existing Keep Mic Ready audio engine. With the toggle enabled, stopping a burst leaves the microphone session warm instead of tearing down and rebuilding AVAudioEngine.
- Decoupled Notepad capture from transcription: the next burst can start immediately while completed bursts transcribe serially in the background, preserving spoken order in one stable Notepad session.
- Merged completed speech into the latest saved document and then into the live editor, so text typed while transcription is pending is retained.
- Kept each Notepad burst's audio transient and removed it after transcription; the persistence schema remains unchanged.

## Verification

- 37 tests passed across `RecordingSessionCapabilitiesTests` and `VoiceNoteLifecycleTests`.
- 87 tests passed across `KeyboardControllerTests`, `KeyboardWaveformTests`, `LongVoiceNotePersistenceTests`, and `SharedStoreTests`.
- Focused UI regression tests passed for Quick Note recording, direct-start and empty Notepad, active and completed Long Voice Note states, waveform rendering, discard controls, and expanded history metadata.
- Focused UI assertions verify Quick Note action symmetry and that discarding a Notepad burst keeps the editor open and ready for another passage.
- Focused UI assertions verify the idle Notepad microphone is centered and the active capsule orders waveform, stop, and burst discard on one baseline.
- Persistence coverage verifies that discarding the first burst retains manually typed text as a reopenable Notepad without audio.
- The full unit suite passed: 280 tests, 0 failures.
- Focused Keep Mic Ready / Notepad persistence coverage passed: 11 tests, 0 failures.
- Focused Notepad UI coverage passed: 2 tests, 0 failures (`testStartNotepadBeginsRecordingWithoutASecondMicTap` and `testEmptyNotepadIsAnEditorWithAReusableMicrophone`).
- A generic iOS device build completed successfully with code signing disabled.
- `./scripts/ios-dev-test.sh --dev --device-id 8FAE4F9F-4C53-5DFD-9C28-BBF0973DA3D3` built, installed, and launched MuesliDev on Picophone while preserving app data.

## Notes and follow-up

- The model picker is intentionally backed by existing shared preferences and event primitives rather than a new backend model.
- Generated ImageGen mockups under `output/` and the local `design-qa.md` report were intentionally excluded from the PR.
- Review follow-up addressed Greptile/CodeRabbit findings by restoring Long Voice Note settings copy, anchoring the Notepad discriminator to the recording start time, and deleting both active and canonical Notepad segments while suppressing autosave during discard.
- The review follow-up passed 72 capability/shared-store tests and 38 Notepad/voice-note lifecycle tests.
- CI should be reviewed on PR #37 before merge.
