# ADR-0100: Synchronous Markdown block spacing

Status: Proposed · 2026-10-13
Refines [ADR-0091](0091-content-bounded-transcript-layout.md) and the comparison under
[ADR-0099](0099-virtualized-transcript-list.md).

## Context

A bounded, prepared Markdown segment can still change height after mounting. MarkdownUI 2.4.1
collects block-margin preferences into view state and applies collapsed spacing on a later layout.
Nested lists and quotes contribute the maximum margin of their entire subtree. The comparison
reproduced a 22 pt change in neighbouring settled rows at unchanged width while native wheel
input moved the clip view by exactly the requested amount. Prefetching parsed Markdown alone
did not remove this presentation change.

Upstream [MarkdownUI is in maintenance mode](https://github.com/gonzalezreal/swift-markdown-ui)
and directs new development to [Textual](https://github.com/gonzalezreal/textual). The fork is a
bounded maintenance commitment for this renderer fix, not a decision to make MarkdownUI the
long-term renderer. A future renderer migration requires separate evaluation of prepared-content
reuse, bounded segments, code actions, typography, accessibility and reader-anchor behavior.

Applying a layout-value key directly to margin modifiers lost inherited margins and failed the
existing spacing tests. Applying extra scroll corrections around delayed presentation also
interfered with reader input. The fix belongs in block layout.

## Decision

Maintain a narrowly scoped MarkdownUI fork with an opt-in synchronous block-spacing policy.
The adopted source is `v2.4.2-goat.2` at
`117d47541d19ca3dff036f8af782983aa9beb720`. Its upstream base is MarkdownUI 2.4.1 plus all four
commits through `8371aeb`: documentation corrections, configurable list-marker minimum width,
`Theme: Sendable` for Swift 6, and the maintenance-mode notice. The default list-marker setting
is preserved. The synchronous-layout patch leaves that base's default renderer and existing
margin-preference API unchanged for other callers.
GOAT's shared reader style opts in with explicit margins matching its existing theme:
paragraphs, HTML and tables have zero top and one em bottom margin; headings have 1.5 rem top
and one rem bottom margin; thematic breaks have two em on both sides. Code chrome, quotes and
lists add no margins of their own. Containers inherit the maximum across every descendant.

A SwiftUI `Layout` collapses adjacent margins in the first layout pass. Tight list spacing
suppresses the preceding item's bottom margin inside the list, but retains the list's outward
margin. Unspecified margins use a hidden probe of SwiftUI's default padding, rather than a
hardcoded platform value. Measurement and placement use the same width proposal.

The policy must match the actual styles. Arbitrary styles that add content or change inherited
font sizes retain the preference-based renderer unless they provide a matching policy. No
Markdown parsing moves onto the main actor; the layout operates on the prepared block tree.

The renderer dependency is reviewed and merged before tagging the exact source GOAT adopts.
Layout regressions cover intrinsic width under finite and unlimited offers, collapsed and tight
spacing, measured default padding, and placement/alignment. Hosted GOAT tests insert content into
an already displayed window and observe every height; disabling the policy makes that regression
fail. Stock-renderer comparisons across block shapes, widths and fonts guard the explicit policy
against changes to the shared styles and complement segment-boundary spacing coverage. Both
paths use the adopted upstream base; this comparison does not establish rendering parity with
unmodified 2.4.1.

Pin the fork to an exact release and commit, retain upstream licences, regenerate distribution
notices, and qualify that resolved source before merging. Local edits to package checkouts are
experiments and cannot support a release verification claim.

## Consequences

- Settled rich rows have their final spacing when mounted, including on scroll-back.
- Segment-boundary spacing retains its existing contract and tests.
- GOAT owns a small renderer patch until an equivalent upstream solution is available.
- Theme changes that alter block spacing must update the explicit policy and its tests together.
- The comparison still uses one scroll writer and the existing preparation actors and cache budgets.
- This fix does not migrate the shipping transcript container or complete the remaining manual,
  accessibility and Instruments acceptance of issue 60.

## Alternatives considered

- **More scroll corrections:** rejected after native correction experiments failed reader input.
- **A constant gap between every block:** changes existing typography and nested-list spacing.
- **Layout values on margin modifiers alone:** does not reduce descendant margins through containers.
- **Render plain text before rich content:** retains a visible height transition and is not a fix.
- **Migrate to Textual now:** deferred, rather than rejected as unsuitable. Replacing the renderer
  requires adapting and qualifying GOAT's preparation, segment, cache, styling and interaction
  contracts. That migration has not been qualified against the realistic 2 MiB transcript workload
  and would expand this maintenance fix. Evaluate Textual separately before extending the fork's
  scope or committing to a long-term renderer.
