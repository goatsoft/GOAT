# ADR-0097: AppKit transcript scroll executor

Status: Proposed · 2026-09-26

Refines [ADR-0002](0002-ui-architecture.md) and [ADR-0091](0091-content-bounded-transcript-layout.md).
Implements the scroll executor of [issue #54](https://github.com/goatsoft/GOAT/issues/54) section 2
([PR #71](https://github.com/goatsoft/GOAT/pull/71)).

## Context

Issue #54 gives the transcript one navigation owner (`TranscriptViewport`) and one scroll executor. It
prefers native SwiftUI positioning and allows a narrowly scoped AppKit adapter only for a reproducible
limitation on a supported OS.

SwiftUI keeps a programmatic scroll target and re-applies it after a move made without a gesture
(keyboard, scroller, or a direct clip-view scroll). That move does not clear the target:

- **`ScrollPosition` commands.** After the executor scrolled to an anchor and the reader then moved
  directly, the owner recording the reader's move led SwiftUI to scroll the reader back to the
  command's target. The call stack shows `HostingScrollView.updateAnimationTarget`, reached from
  `updateContext`. `aDirectMoveAfterAnInterruptedCommandIsTheReaders` fails every time with a
  `ScrollPosition` writer, with or without the initial offset. A minimal scroll view of fixed rows
  does not reproduce it, so the exact trigger is internal to SwiftUI.
- **The initial bottom offset.** `.defaultScrollAnchor(.bottom, for: .initialOffset)` is re-applied on
  any content-size change after such a move, even after the binding is rewritten.
  `ScrollPositionLimitationTests` reproduce this with fixed rows.

Workarounds that rewrote the binding did not hold. Writing it inside `onScrollGeometryChange` was
applied out of order ("tried to update multiple times per frame"): the viewport oscillated between two
offsets on CI and took a transient offset as the reader's. Writing it on a later turn let SwiftUI
re-apply the stale target first. Telling replays apart from geometry was an inference that still
depended on timing.

## Decision

- `TranscriptScrollExecutor` is the transcript's only scroll writer. It moves the enclosing
  `NSScrollView`'s clip view at once, without animation. A background `NSViewRepresentable` attaches
  it, and it is detached on dismantle. The transcript no longer uses `.scrollPosition`.
- Who moved the viewport is recorded where the move happens, not inferred from geometry. The executor
  observes the clip view's bounds changes, which are delivered synchronously inside the call that
  made them:
  - **Executor:** the change happened inside one of its commands.
  - **Layout:** the new origin is exactly the previous origin constrained to a resized document
    (`NSClipView` reflecting a document frame change).
  - **Other:** any other change. It counts as the reader's, unless the scroll geometry snapshot that
    reports it shows a layout change (content size, container size or insets).

  An offset that no recorded move explains is logged and changes no ownership.
- The initial bottom offset applies only until the first placement. After that it is turned off, and
  following is kept by the owner's requests. A restoring transcript is shown once its anchor's
  request ends (fulfilled, cancelled or abandoned, so the wait is bounded).
- The owner model, the bounded request lifecycle and the gesture-phase rules are unchanged.

## Consequences

- Nothing can re-apply a stale target, because SwiftUI holds no programmatic target after the
  initial placement.
- A move made without a gesture (keyboard, scroller) keeps the reader's position through streaming
  growth and view updates.
- One `NSViewRepresentable` and one bounds observer are added, with explicit attachment and
  teardown. There is no swizzling, no private-view assumption, and no constraint change from layout
  callbacks.
- Commands are not animated. The jump to the latest output is instant, as it was intended to be
  (`disablesAnimations`) with the `ScrollPosition` writer.
- **Removal criterion:** the known issue in `ScrollPositionLimitationTests` stops being recorded, and
  `aDirectMoveAfterAnInterruptedCommandIsTheReaders` passes with a `ScrollPosition` writer on every
  supported OS. Then native positioning should replace this adapter.

## Alternatives considered

- **Keep `ScrollPosition` and rewrite the binding after a direct move** (inside the geometry callback,
  or on a later turn). Rejected: out-of-order application and stale re-application, as above.
- **Classify replays by matching offsets against the last commanded target.** Rejected: it infers
  who moved from geometry and timing, and passed CI without a known cause.
- **Only turn off the initial offset and keep `ScrollPosition`.** Rejected: the `ScrollPosition`
  replay still reproduces in the transcript.
