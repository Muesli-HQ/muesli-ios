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
- Before an already-synced legacy library can claim its first account scope, the current private zone must contain every stable text-record ID that carries evidence of prior CloudKit sync. The proof uses batched record existence requests with `desiredKeys: []`, so it downloads no authored content. Missing, partial, extra, incomplete-response, or wrong-record-type proof pauses sync instead of risking a cross-account upload; local-only libraries can claim normally.
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

## 2026-08-12 low-latency orchestration follow-up

Physical Production-entitled testing showed correct convergence but exposed avoidable
latency: every small local mutation waited one second and then paid account lookup,
zone lookup, legacy migration, fetch, and send in series. Fetch-first was an intentional
bootstrap safety decision while CKSyncEngine first hydrated server system fields; it is
not required for every steady-state mutation once the persistent engine is prepared.

The branch now shares the same operation contract as the macOS follow-up:

- `prepare()` creates/restores the persistent automatic CKSyncEngine and performs the
  account-boundary, zone, and legacy migration work once per valid engine lifecycle;
- `sendLocalChanges()` immediately registers SQLite `sync_dirty` pages and calls
  `sendChanges()` without a fetch-first round trip;
- `fetchRemoteChanges()` only fetches incoming changes for foreground/APNs delivery;
- `syncManually()` deliberately sends outgoing changes before fetching incoming ones;
- concurrent foreground, local, APNs, and manual triggers union their intent rather
  than overwriting one another;
- account/zone invalidation re-enters preparation, with one bounded same-account
  zone-recreation retry and no cross-account upload;
- bridge-device discovery remains throttled onboarding/UI metadata and runs outside
  the visible text-sync critical path;
- the app delegate creates the process-wide runtime at launch whenever sync is enabled,
  and routes CloudKit remote notifications to fetch-only work with a correct background
  completion result. CKSyncEngine delegate callbacks never start sync recursively.

All earlier safety work remains in place: the durable outbox, environment-scoped state,
hashed account boundary, no-content legacy provenance proof, same-account metadata
reset, size-aware batching, exact-version acknowledgements, conflict/retry handling,
privacy-safe diagnostics, recoverable WPM timing/one-time repair, local audio semantics,
and cancellation/account-change crash protection.

The recovery follow-up also closes lifecycle edge cases found during cross-platform
review:

- zone loss now includes direct or recursively nested `unknownItem`, `zoneNotFound`,
  and `userDeletedZone` errors;
- nested partial failures containing `notAuthenticated` or `permissionFailure` retire
  cached preparation so the account boundary must be proven again;
- a second zone/account-context failure after the bounded zone retry also invalidates
  the newly prepared state before it is rethrown;
- runtime batches own only the waiters present when that batch starts, so a failed
  send cannot discard a later APNs fetch; the later request drains exactly once;
- cancellation releases APNs/UI waiters before waiting for CKSyncEngine cleanup, so
  the application delegate's background completion cannot hang behind that cleanup;
- cancellation is also an execution barrier: requests accepted into the new generation
  remain queued until engine cleanup finishes, then start exactly once;
- APNs fetch waiters expire after a 20-second background budget and are removed exactly
  once without cancelling durable CKSyncEngine convergence;
- enabled startup now performs nonblocking send-then-fetch convergence, rebuilding
  ordinary persisted SQLite dirty rows even when restored engine pending state is empty;
- automatic zone-deletion/missing-zone delegate events only invalidate preparation and
  serialized state. The next external recovery fetch escalates to paginated send-then-fetch
  so metadata-reset rows rebuild the zone without delegate reentrancy;
- ancillary bridge refreshes coalesce, union forced refresh intent, cancel with the sync
  lifecycle, and require current-generation authority before publishing device identity;
- missing-provenance error traversal is depth-bounded like other recursive CloudKit
  classifiers.

The final lifecycle audit added two further barriers:

- overlapping cancellations are reference-counted, so a new-generation request cannot
  execute until every older CKSyncEngine cleanup has returned, regardless of completion
  order;
- bridge refresh cancellation now waits for the retired bridge task, cancels its concrete
  `CKModifyRecordsOperation`, and owns its continuation exactly once. This prevents a late
  private-CloudKit callback from publishing stale companion presence after sync disable or
  an account transition, without introducing any analytics identifier.

Validation used the existing DerivedData cache at
`/Users/pranavhari/Library/Developer/Xcode/DerivedData/MuesliiOS-hfpsukoywdcgmbddckyxgiejqtau`:

- focused `MuesliCKSyncEngineTests`: 39 tests, 0 failures (43 tests including
  `MuesliBridgeDeviceIdentityTests`);
- full iOS unit suite (UI tests skipped): 248 tests, 0 failures;
- `build-for-testing`: succeeded with signing disabled.

The final account-provenance review tightened the legacy claim gate from “any overlap”
to exact set equality. CloudKit returns only the matching expected `TextRecord` identities;
the account is claimed only when that set equals the complete local set requiring proof.
Missing IDs, partial overlap, unrequested IDs, incomplete responses, and wrong record
types fail closed; service errors still propagate. The request continues to use
`desiredKeys: []`, and neither authored content nor raw record identities are logged or
persisted as diagnostics. Fresh local-only libraries bypass this legacy proof and retain
normal first-account behavior.

Validation after provenance hardening, using the same DerivedData cache:

- focused `MuesliCKSyncEngineTests`: 43 tests, 0 failures;
- full iOS unit suite (UI tests skipped): 252 tests, 0 failures;
- `build-for-testing`: succeeded with signing disabled;
- `git diff --check`: clean.

## Remaining physical checks

1. Launch MuesliDev on the unlocked picophone and allow the one-time repair to sync.
2. Confirm MuesliDev on macOS reports a plausible WPM rather than a six-digit value.
3. Record a timestamped iPhone note with measurable duration; confirm it appears on the Mac and WPM remains plausible.
4. If inspecting SQLite, query aggregate counts and duration sums only. Do not inspect transcript text or record identifiers.
