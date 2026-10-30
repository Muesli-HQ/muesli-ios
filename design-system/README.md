# muesli iOS design alignment

Reference: macOS PR #705, head `3d8e3f6d`. This is an iOS adaptation of its
Nunito Sans family, quiet layered surfaces, concise copy, and semantic colors.
The Mac PR is still in review; this is not a claim of final cross-platform parity.

## Audit and implementation

| Surface | Finding | Change |
| --- | --- | --- |
| Typography | System and rounded fonts mixed across core surfaces | Bundle the Mac's licensed Nunito Sans faces; shared semantic roles scale with Dynamic Type |
| Dashboard record action | Multiple concentric rings, gradients and shadows compete with content | One rounded rectangular action, 56pt minimum height, explicit label and recording state |
| Cards | Glass, tint, strokes and shadows applied at once | Opaque neutral raised surfaces with a subtle semantic border |
| Bottom navigation | Large capsule, glowing selection and undersized text | Contained rounded selection, no glow, 13pt scalable labels, 44pt targets |
| Stats | Decorative depth competes with recording | Flat neutral surface, shared typography and tabular digits |
| Audio import | Bespoke primary button | Shared 48pt minimum primary style with pressed/disabled states |
| Secondary actions | Circular blue controls dominate | Shared 12pt continuous corners and quieter tint |
| Copy | Dashboard repeats its platform and purpose | Remove the tagline; retain recording, permission, privacy and recovery instructions |

## Tokens

- Nunito Sans: title 28 bold; section 22 semibold; smaller title 19 semibold;
  headline 16 semibold; body 16; transcript 17; callout 15; helper 13.
- Every role uses a relative Dynamic Type style. SF Symbols keep system fonts;
  authorization codes keep monospaced fonts. Fonts load through UIAppFonts,
  with no runtime download or registration during rendering.
- Controls: 12pt continuous radius. Cards: 12–16pt. Touch targets at least 44pt.
  Capsules remain appropriate for small status badges; circles for recording
  transport controls, rather than every action.
- Preserve accent preferences; neutral surfaces establish hierarchy. Filled
  accent buttons use dark ink in dark appearance and white in light appearance.
  Stop states retain their semantic color.
- Keep native focus/selection, accessibility labels and app identity unchanged.
  No new decorative animation; pressed feedback uses opacity.

## Follow-up audit areas

- Fixed-height stat and navigation layouts at accessibility text sizes need
  adaptive layouts before claiming complete Dynamic Type coverage.
- Some screen-local system text and UIKit text editors still override the shared
  typography. Migrate these deliberately, preserving selection and undo.
- Ultra Dark is not added here: it needs its own appearance-state and contrast
  validation. Light/Dark/System remain the supported iOS choices.
- Meeting Q&A remains outside scope. No model, sync or recording behavior changes.

Validate light/dark, the keyboard extension, onboarding, empty/content states,
recording/transcribing/disabled states and large text on native iOS. A successful
build is not proof of visual quality or real-device accessibility.

## Validation — 2026-10-30

- Native simulator build passed (Xcode, iOS 26.5, existing iPhone 17 Pro).
- Bundled font registration test passed for all six faces.
- Existing dashboard smoke test passed, including switching Quick Note to Notepad.
- Inspected native empty-dashboard screenshots in Light and Dark. Text, button
  contrast and bottom navigation rendered correctly at the default text size.
- MuesliDev device build passed and was installed on picophone with existing
  data preserved. The user tested the updated UI and approved its appearance.
- Full app-wide visual review, accessibility-size layouts and keyboard-extension
  visual checks are not yet complete.

## PR #50 review follow-up

- Transcript overflow uses Nunito Sans with the same base size and Dynamic Type
  scaling as the rendered preview. Wrap-boundary checks cover standard, larger
  and accessibility text sizes.
- Removed circular hit-target overrides from the rounded sidebar and sync
  buttons. A native UI test verifies a tap inside the rounded corner opens the sidebar.
- Light green is now #047857. Contrast checks pass for primary-button foregrounds
  across every supported accent in both appearances.
- Font reproduction instructions link to the generator at its source commit and
  describe XcodeGen/UIAppFonts packaging.
- The simulator-only Island fixture waits for an explicit completion action
  instead of a background timer. Its copy presentation lasts 60 seconds for UI
  automation; production retains the existing 10-second window. The UI test
  reopens the Island if it collapses after Stop and still verifies processing,
  the real copy link and foreground clipboard confirmation.
- Validation: seven font/contrast/overflow unit tests and the corner-tap UI test
  passed. The first Island run exposed the short processing-state wait and the
  test was corrected; its end-to-end rerun passed in 35 seconds. Xcode's first
  run stalled collecting failure diagnostics and was stopped; the successful
  rerun disabled verbose diagnostic collection. Hosted CI has not been awaited.

### Dynamic Island publication follow-up

The simulator background task now has an expiration handler and idempotent
cleanup. An awaited callback immediately after ActivityKit's copy-state update
releases that task, before the separate display delay, and exposes
`islandPreview.copyPublished`. XCTest waits for this marker while foregrounded
before pressing Home. Production callers retain the default ten-second window
and do not supply the callback.

The native Dynamic Island end-to-end test passed in 41.4 seconds, including the
publication checkpoint, real copy link and clipboard confirmation. Build/test
log: `/private/tmp/pr50-publication-fix-tests.log`. Hosted CI was not awaited.
