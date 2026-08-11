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
  - `f6d267e` Harden CKSyncEngine account and batching safety

## Behavior

- `CKSyncEngine` owns CloudKit change fetching and upload scheduling.
- SQLite dirty state remains the durable source of pending local changes.
- Engine serialization is environment-namespaced so Development and Production state cannot collide.
- The first CloudKit account is stored only as a SHA-256 scope. A different account clears pending engine work and pauses sync without requeuing or uploading the local library.
- Before an already-synced legacy library can claim its first account scope, the current private zone must contain at least one matching stable text-record ID. The proof uses batched record existence requests with no desired fields, so it downloads no authored content. A missing zone or zero overlap pauses sync instead of risking a cross-account upload; local-only libraries can claim normally.
- Same-account zone recreation clears obsolete record change tags/system fields before migration, then safely requeues the preserved local text.
- CloudKit chooses size-aware upload batches through its record-provider API while SQLite still loads each local page once.
- Sync diagnostics expose only phase, timestamps, and counts; note text and record identifiers are never emitted.
- Dictation records now carry linked recording-session start/end times and a positive duration when recoverable.
- A versioned, environment-scoped repair marks only existing cloud-backed dictations with valid linked timing dirty once. It does not fabricate timing for legacy rows that lack it.

## Validation

- Full `MuesliTests` suite passed after the review fixes: 225 tests, 0 failures.
- A disposable MuesliDev device harness was signed with:
  - bundle: `com.phequals7.muesli.ios.dev`
  - app group: `group.com.phequals7.muesli.dev`
  - CloudKit container: `iCloud.com.mueslihq.muesli`
  - CloudKit environment: Production
- The updated app installed successfully over the existing picophone MuesliDev installation, preserving the same identity and application data.
- Final automated device validation was blocked by a disconnected Xcode Wi-Fi tunnel; rerunning it requires the picophone to be unlocked and reachable from this Mac.

## Companion macOS defense

The macOS branch `codex/wpm-invalid-duration-defense` excludes untimed records from the WPM numerator and denominator while continuing to include their words in total-word metrics. That defense is intentionally separate from this iOS transport migration.

## Remaining physical checks

1. Launch MuesliDev on the unlocked picophone and allow the one-time repair to sync.
2. Confirm MuesliDev on macOS reports a plausible WPM rather than a six-digit value.
3. Record a timestamped iPhone note with measurable duration; confirm it appears on the Mac and WPM remains plausible.
4. If inspecting SQLite, query aggregate counts and duration sums only. Do not inspect transcript text or record identifiers.
