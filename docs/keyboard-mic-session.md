# Keyboard microphone sessions

Keyboard dictation starts an app-owned microphone session when persistence is
enabled (the default). The first activation opens Muesli; the user returns to the
host app manually. Subsequent dictations use the running microphone without
switching apps. Automatic app return is outside this change.

## Controls and preference

Home has a compact Keyboard mic toggle. On enables persistence and starts the
session; Off ends the current session without changing the saved preference.
Settings exposes the inverse preference, Turn mic off after each dictation.
Mic-off is also available from the handoff screen, Settings, Lock Screen, and
expanded Dynamic Island. Launching the app alone never activates the microphone.

The canonical preference remains `muesli.keyboardSession.enabled`. If an experimental
development build saved `muesli.keyboardSession.keepReadyBetweenDictations`, its
newer choice is migrated to the canonical key and the duplicate is removed.

## Lifecycle

The existing keyboard reducer owns microphone session identity and cancellation
generation. Dictations create individual audio segments within that session.
Finishing a segment preserves standby. Mic-off invalidates pending startup/retry
work, seals any active segment, releases the engine, and ends the session activity.
Captured speech can finish transcribing and be delivered after the mic stops.
A stale Island action cannot stop a newer microphone session or an unrelated meeting.

Idle audio callbacks refresh background-start readiness. The audio tap is created
in a nonisolated context so the audio thread does not inherit main-actor isolation.
Permission completion checks ownership before starting cancelled audio work.

## Shared handoff rules

Both processes apply `KeyboardHandoffState.accepts` inside a SQLite transaction.
Normal progress can skip ahead but cannot regress. Inserted/cancelled outcomes
cannot resume; copy-required can become inserted; pending cancellation only accepts
cancellation acknowledgements, failure, or cancel recovery. Existing recovery paths
remain available. Keyboard taps, Action Button starts, and app adoption use the same
atomic `claimRequest` transaction to publish the pending request and its initial
handoff together. Preparing a keyboard launch URL remains local. Competing starts
cannot replace an unsettled owner, including during startup, recovery, cancellation,
or pending text insertion. A completed, cancelled, copy-required, or failed handoff
allows the next request; duplicate adoption preserves progress, while delayed starts
for delivered/cancelled requests are rejected. Progress updates cannot transfer
ownership. Pending-request and command cleanup match the request being finished.
A rebuilt keyboard restores terminal ownership before adopting transient snapshots.

## Waveforms and activities

A mic session has its own ActivityAttributes rather than a synthetic recording or
history row. It shows Listening, Mic ready, or Mic paused. Recording uses the same
five-bar amplitude envelope, sampler, renderer, and tint as Action Button activities.
Updates are coalesced to at most two per second with one meter update in flight.
Ready/paused states clear waveform data. Successful dictation briefly shows a
completion checkmark for five seconds, then clears it while retaining mic-off
controls. Initial standby never shows a completion checkmark. Starting another
recording or ending the mic session cancels the old completion timeout. Older
activities decode without samples or a completion deadline.

The keyboard's listening waveform uses native bars driven by metered input rather
than an animation timeline and Canvas. Meter publication is capped at 12.5 Hz
(approximately 10 Hz with the 20 Hz sampler), with 1% level precision and native
120 ms interpolation between updates. Reduce Motion disables interpolation. This
avoids depending on animation resumption
after screen timeout. Waiting animation and electric-spectrum rendering retain
their existing behavior.

## Validation and device checks

Regression tests cover session cancellation during permission startup, real-audio
standby readiness, duplicate insertion, late handoff updates, keyboard recreation,
terminal outcomes, recovery, preference migration, and waveform sampling/decoding.
Pico testing confirmed persistence across dictations, recovery to idle after text
insertion, waveform visibility after timeout, and the shared Island waveform.

Before release, repeat permission denial, microphone shutdown during recording and
processing, lock/unlock, audio-route changes, and switching to meeting capture.
Confirm mic-off releases microphone access while captured text can finish delivery.
Test with Live Activities disabled and with AirPods. Simulator tests do not establish
all hardware interruption or ActivityKit scheduling behavior.
