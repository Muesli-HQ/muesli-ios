# iOS CKSyncEngine migration handoff (2026-08-10)

## Scope

This branch migrates Muesli iOS text-record synchronization from the manual CloudKit cursor loop to `CKSyncEngine`. Audio remains local. It also adds privacy-safe progress state and repairs recoverable dictation timing metadata so synced records do not corrupt cross-device WPM metrics.

## Branch

- Repository: `muesli-ios`
- Branch: `codex/ios-cksyncengine-migration`
- Base: `origin/main` at `90f2942`
- Commits before this handoff:
  - `a14f7a9` Migrate iOS text sync to CKSyncEngine
  - `d1d56a6` Report privacy-safe iCloud sync progress
  - `a8b37c6` Fix CKSyncEngine account-change crash
  - `2643d0e` Repair synced dictation timing metadata

## Behavior

- `CKSyncEngine` owns CloudKit change fetching and upload scheduling.
- SQLite dirty state remains the durable source of pending local changes.
- Engine serialization is environment-namespaced so Development and Production state cannot collide.
- Account changes clear stale serialized engine state without cancelling the engine from inside its own delegate callback.
- Sync diagnostics expose only phase, timestamps, and counts; note text and record identifiers are never emitted.
- Dictation records now carry linked recording-session start/end times and a positive duration when recoverable.
- A versioned, environment-scoped repair marks only existing cloud-backed dictations with valid linked timing dirty once. It does not fabricate timing for legacy rows that lack it.

## Validation

- Full `MuesliTests` suite passed after the timing repair.
- A disposable MuesliDev device harness was signed with:
  - bundle: `com.phequals7.muesli.ios.dev`
  - app group: `group.com.phequals7.muesli.dev`
  - CloudKit container: `iCloud.com.mueslihq.muesli`
  - CloudKit environment: Production
- The updated app installed successfully over the existing picophone MuesliDev installation, preserving the same identity and application data.
- Final launch and two-way timing validation still require the phone to remain unlocked.

## Companion macOS defense

The macOS branch `codex/wpm-invalid-duration-defense` excludes untimed records from the WPM numerator and denominator while continuing to include their words in total-word metrics. That defense is intentionally separate from this iOS transport migration.

## Remaining physical checks

1. Launch MuesliDev on the unlocked picophone and allow the one-time repair to sync.
2. Confirm MuesliDev on macOS reports a plausible WPM rather than a six-digit value.
3. Record a timestamped iPhone note with measurable duration; confirm it appears on the Mac and WPM remains plausible.
4. If inspecting SQLite, query aggregate counts and duration sums only. Do not inspect transcript text or record identifiers.
