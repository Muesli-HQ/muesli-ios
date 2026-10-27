# TestFlight 0.1.9 (1) feedback follow-up

## Evidence and changes

- Two crash submissions (October 9 and 23) from the same anonymous tester stop in `AppIntents.PerformActionExecutorTask.verifySystemPolicyWith(intent:output:)`. The first explicitly mentions pressing the Action Button. Both are background crashes. The recording intents created a Live Activity but did not return its identifier. Both start results now return the actual ActivityKit identifier; capture is stopped if that identifier is unavailable. Stop results do not return an ended activity.
- One screenshot submission shows Whisper Large Turbo optimizing at 94%, followed by a misleading connection/download failure. The device reported about 837 MB free. There is no underlying error in the feedback, so storage exhaustion is a hypothesis, not a confirmed root cause. Setup now checks available storage, preserves completed assets after preparation failure, avoids catalog requests for completed downloads, and distinguishes network, storage, and runtime failures. Optimization is presented as preparation, and an unready selected model is not labeled active.
- The dashboard screenshot supplied by the user shows the completed Action Button setup card occupying space. The invitation now disappears once setup is complete; Settings retains the configuration entry.
- Evgenii's tracker row preserves Installed and records blocked on model setup. Recovery and sync remain unverified.

## Physical-device release checks

1. With an installed model and Live Activities allowed, invoke dictation and meeting shortcuts from the Action Button while Muesli is backgrounded and while the phone is locked. Confirm recording, visible Live Activity, second-press stop, saved output, and no crash.
2. Disable Live Activities and repeat: show a useful failure with no continuing microphone capture.
3. Complete Action Button setup, relaunch, confirm the dashboard card stays hidden and Settings still opens configuration.
4. On a device with limited storage, select Large Turbo: confirm actionable storage guidance. Free space and retry. Confirm completed files are reused and model preparation reaches Ready.
5. Test an interrupted download separately from an optimization failure. Confirm their messages differ and retry recovers. Ask the affected tester to validate the new build before clearing the model-setup block.

These changes are local; they have not been uploaded to TestFlight.

## October 27: model deletion and selector feedback

- The selector and downloaded-model list now consume the coordinator's observable on-disk inventory. Removal (including partial failure), download completion/failure, returning to Settings, and foreground activation refresh that inventory. A cached runtime Ready state no longer proves files exist, and deleting the selected model clears stale readiness without changing the selection.
- Dropdown rows show the model name and status icon only. Status text remains an accessibility value for VoiceOver. The active badge requires a ready runtime.
- Preparation and foreground warmup cannot start while model removal is in progress.
- All 18 focused model-catalog tests passed on picophone, including selected/nonselected file deletion, stale-ready icon, and removal/preparation race regressions. Result bundle: `/private/tmp/muesli-model-inventory-final-tests.xcresult`.

## iOS mirror-first download management

Branch: `codex/ios-mirror-download-feedback-fixes`.

- Uses the macOS immutable manifest contract at `assets.muesli.works`, first for Whisper Tiny English, Small English, Medium English, Large Turbo, and Parakeet v3. Models without a published mirror retain Hugging Face discovery.
- Rejects wrong model identity, unsafe/duplicate paths, missing required artifacts, invalid checksums, and wrong byte counts. R2 files are SHA-256 verified before installation. Hugging Face discovery is pinned to a commit and verifies LFS SHA-256 or Git blob SHA-1, including the Git blob header.
- Saves the source, manifest, generation, completed files, retry counts, and fallback phase before scheduling work. Background tasks retain the existing session identifier; their descriptions identify the persisted generation. Late callbacks from canceled, failed, or replaced attempts cannot complete a new attempt.
- Uses separate staging directories for R2 and Hugging Face. An existing installation is preserved until every new file passes validation. Directory-swap recovery restores the previous installation if the swap is interrupted. A failed fallback retains its own verified staging files for retry.
- Queues the full file manifest up front in the background URLSession. Feeding two tasks per wakeup delayed the physical-device check; Apple's [background-transfer guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) recommends scheduling multiple tasks together to avoid the relaunch rate limiter. The session requests two connections per host; iOS owns actual transfer scheduling.
- The mirror contains Core ML model artifacts, not all auxiliary Whisper tokenizer downloads. WhisperKit may still fetch tokenizer assets during first preparation. A verified download and a loaded runtime are reported separately.

The `MuesliDev` scheme has a device test target for integrity and recovery. The development-only `--muesli-validate-models` launch argument exercises the production background downloader and transcription engine and writes `Documents/model-validation.json`. `--muesli-validate-mirror-corruption` deliberately supplies one incorrect mirror checksum to exercise real Hugging Face fallback. `--muesli-validate-downloads-only` checks installed bytes without claiming runtime readiness. All hooks require the isolated development bundle; none runs in the production app.

## Validation

- `xcodebuild build-for-testing` succeeded for the app and test targets (arm64 iOS Simulator, Xcode 27.1).
- Physical iPhone 16 Pro (iOS 26.6.1): all 13 integrity/recovery and setup-error XCTest cases passed. Coverage includes same-size corruption, absent checksums, Git blob hashes, manifest coverage/paths, durable fallback generations, obsolete callback rejection, rollback, and interrupted installation recovery.
- Expanded physical-device regression run: 67 of 68 tests passed, including dictation/meeting Live Activity output identifiers, ended-activity omission, startup failure cleanup, and all 15 model catalog tests. The existing `testRecorderCapturesSamplesWithPlaybackDisabled` failed to start the device audio engine (`com.apple.coreaudio.avfaudio`, code 2003329396), also leaving its sample expectation unfulfilled. This remains a hardware-capture validation failure; no full physical Action Button success is claimed. Result bundle: `/private/tmp/muesli-feedback-device-regression.xcresult`.
- Whisper Tiny English: all 19 mirror files passed on-device hashes and byte counts; WhisperKit reached Ready and unloaded successfully. The audio encoder's first Core ML load took 92.55 seconds, with 96.83 seconds for total runtime loading. The tokenizer was fetched separately from Hugging Face. Evidence: `/private/tmp/muesli-tiny-runtime-passed.json` and `/private/tmp/muesli-mirror-device-validation4.log`.
- Large Turbo: all 17 mirror files passed on-device hashes and byte counts. The download resumed across the physical XCTest app restarts. Runtime preparation reached WhisperKit's Core ML feature-extractor load but did not produce a Ready result before that run was stopped to check the remaining downloads. Evidence: `/private/tmp/muesli-large-runtime-pending.json` and `/private/tmp/muesli-mirror-device-validation6.log`. This is a verified download, not a runtime pass.
- Small English: background download began, then the device connection was invalidated (`CoreDeviceError 3` / `Mercury 1001`) during validation. Medium English and Parakeet v3 were queued in the validation list but had not started. Their iPhone validation and the real on-device forced-corruption/Hugging Face fallback run remain outstanding. Evidence: `/private/tmp/muesli-mirror-remaining-downloads.log`. Do not infer validation from the published manifests or passing state-machine tests.
- A standalone Swift harness using the production `ModelSetupFailure.swift` passed low-space rejection, sufficient/unknown capacity, nested disk-error classification, network classification, and runtime-message redaction checks.
- Regression coverage was added for dictation/meeting Live Activity identifiers, model setup recovery, and hiding the completed dashboard invitation while retaining Settings access. Simulator execution could not complete: CoreSimulator required an update, then the isolated iOS 26.5 simulator stalled during initial migration/test launch. A restart and test-without-building retry did not recover it. The unit tests subsequently ran on the physical device as reported above; the dashboard UI test remains unexecuted.
- `git diff --check` passed. Physical Action Button/locked-screen and low-storage reproduction checks above remain outstanding.

## Parakeet Unified addition (2026-10-27)

- Added only Parakeet Unified English INT8 (`parakeet-unified`); default stays Parakeet 110M. Offline transcription includes token timings; no streaming encoder variants are downloaded.
- Updated FluidAudio from 0.14.5 to exact 0.17.3, matching the macOS integration. Removed an unused helper referencing the removed DownloadUtils type.
- Uses the macOS mirror path and three required Core ML bundles plus vocabulary/metadata, approximately 614 MB. Existing source-isolated, checksum-verified background download and Hugging Face fallback apply. Runtime loading uses CPU/Neural Engine and generation checks against obsolete loads.
- Device build and 36 focused tests passed (`/private/tmp/muesli-unified-tests.xcresult`). Tests cover INT8-only selection, exclusions for FP16/streaming encoders, mirror coverage, and unchanged default, alongside readiness and cancellation regressions.
- Physical download reached 44% from the mirror, then slowed to approximately 8 KB/s even with MuesliDev foregrounded. A host-side transfer from the same mirror reached approximately 8.5 MB/s. No confirmed cause for the device slowdown. Download is left intact; runtime loading and fixture transcription have NOT yet passed on iPhone.
- Optional debug-only `--muesli-validate-audio <Documents filename>` runs a supplied fixture through the prepared engine and records its transcript and token count. This run's synthetic fixture is `muesli-unified-fixture.wav`; no personal recordings are used.

### October 27 — automatic readiness and model presentation

- Recording surfaces recheck an idle model as they appear; preparation remains automatic and recording stays gated on runtime readiness across both backends. Existing preparation, ready, and failure states are preserved. Onboarding also blocks test capture until ready and prepares newly selected models automatically.
- The shared readiness panel exposes the current preparation stage and download progress, with retry only after failure. A deliberately deleted model still requires selecting a model again, rather than silently redownloading it.
- Matched the running macOS DevC model presentation: Parakeet Unified and Parakeet v3 without precision/parameter suffixes, NVIDIA artwork reused from the macOS repository, smaller model headings. The smaller English and streaming variants are labelled Parakeet Compact and Parakeet Realtime.
- Device regression results: `/private/tmp/muesli-readiness-branding-tests.xcresult`: 24 tests passed on picophone (21 model catalog/readiness, 3 transcription cancellation), zero failures.

### Transcription recovery and final branding

- Quick Notes offer Stop Transcription without quitting. Cancellation preserves recoverable audio, releases the UI promptly, and ignores stale results. Short-note retries run directly from the dashboard; long recordings retain their existing editor flow.
- WhisperKit runtime event text is no longer shown during Quick Note transcription. Removed the redundant on-device execution row.
- Whisper uses the same scalable OpenAI mark as the macOS app, rendered with the current theme foreground. Final development build passed and was installed and launched on picophone.

## PR #44 review follow-up

- Discard superseded transactions' current and retired staging directories before clearing their journal. Installed models, rollback backups, and unrelated stages remain untouched. Cleanup runs after cancellation under the state queue; a cleanup error keeps the old journal available for retry.
- On retry, revalidate staged files before the storage check. Count only missing bytes for transfer while preserving the full model-preparation allowance. Stale journal entries and corrupt files cannot reduce the estimate.
- Show readiness in Notepad, start preparation on entry, and disable its microphone until ready. Keep recovery-row deletion independent of disabled retry controls.
- All 16 download/setup tests passed on picophone (`/private/tmp/muesli-pr44-download-fixes.xcresult`). Final UI changes compiled and all 24 readiness/cancellation tests passed (`/private/tmp/muesli-pr44-ui-fixes.xcresult`).
- Initial GitHub simulator build passed; unit/UI tests remain in progress. Claude review failed after one turn with `is_error:true` and no diagnostic explaining its underlying cause. Devin reports a skipped full review because its trial expired and no credits remain.

## CI UI-fixture correction

The hosted simulator build and 401 unit tests passed (two skipped), but two UI tests failed: model Settings readiness and direct-start Notepad. The UI fixture declared its runtime ready without supplying a downloaded inventory, so foreground/Settings disk refresh cleared readiness. Added a debug-only fixture inventory used only by the explicit UI-test launch path; production still uses filesystem checks, and injected unit-test inventory checks retain precedence.

Both previously failing UI tests passed locally on the dedicated iOS 26.5 simulator with their assertions unchanged. Evidence: `/private/tmp/muesli-pr44-ci-ui-repro.xcresult`. The separate Claude reviewer failure remains unresolved; its logs contain only an immediate generic execution error.
