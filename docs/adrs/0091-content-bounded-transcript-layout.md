# ADR-0091: Content-bounded transcript layout

Status: Accepted · 2026-09-20 · Amended 2026-09-22 · Segmented rendering amendment proposed 2026-09-26

Refines [ADR-0056](0056-bounded-rendering-and-responsive-io.md) and
[ADR-0074](0074-grouped-transcript-tool-activity.md). Qualification is tracked in
[issue #29](https://github.com/goatsoft/GOAT/issues/29).

## Context

A synthetic Release workload with 24 coding messages reproduces main-thread
layout stalls without an engine. Sharing the syntax-highlighting runtime reduces
memory, and directly measuring the assistant document at its available width
reduces layout cost. Neither makes a window containing hundreds of rich code
blocks responsive. Equating unchanged row inputs did not improve this workload.
A message-count limit alone does not bound the rendered content.

## Decision

Keep native, fully measured rows and stable message identities. Admit at most 40
messages and approximately 16 KiB of display-source cost into a window, always
admitting one message so a large entry cannot become unreachable. Charge text,
reasoning and tool-row overhead, with each source cost capped at the budget. This is a deterministic
layout admission proxy, not a process-memory guarantee.

Earlier and Later overlap half the current window where possible. A single-message
window advances without overlap, so an oversized entry cannot prevent paging.
Every original message remains reachable. A reader-owned window is frozen while
output arrives; only explicit paging, Latest or sending a new turn changes it.
Bottom following may advance the admitted window as the active response grows.
Existing scroll ownership and native width/font reflow remain authoritative.

Text above 8 KiB uses explicit, selectable plain-text parts instead of laying out
an arbitrarily large rich document. Prepare parts off the main actor, preserving
every Unicode scalar, whitespace and fence marker. Concatenating parts reproduces
the source exactly. Initially show the latest part; choosing an earlier part
holds that choice during incoming output and takes reader ownership. Full-source
copy remains available. Apply the same bound when full reasoning is expanded.
These presentation limits never alter persistence or model context.

Keep one owned syntax-highlighting runtime and use the existing dependency's
public API. Preserve exact code when converting to attributed text; failed or
changed conversion falls back to the original source. The dependency's open
HTML-conversion report remains distinct from measured layout performance.

Implementation qualification remains tracked in issue #29; acceptance of this
architecture does not claim completed cross-platform runtime qualification.

## Validation

Compare the same engine-free Release workload before and after on each qualified
OS. Cover paging reachability with uneven message sizes, an oversized single
entry, Unicode round trips, active growth while reading, tool order, selection,
copy, disclosures, narrow widths, font changes, keyboard. Unit
tests and profiling proxies do not substitute for interaction checks. Tahoe and
Golden Gate qualification must be recorded separately before acceptance.

## Alternatives

- Replace the outer stack with a lazy stack alone. It does not bound a huge
  individual row and changes native measurement and anchoring behavior.
- Keep 40 fully rendered messages. The Release workload demonstrates why this
  is insufficient even after local resource and layout fixes.
- Truncate stored text. That loses user data and changes model context.
- Hide an entire tool round behind a disclosure. That reverses ADR-0074's visible
  narration and independent chronological tool-detail decisions.

## Amendment: Automatic scroll-observed endless scrolling (2026-09-22)

Manual "Earlier messages", "Later messages", and "Latest" buttons are replaced with native SwiftUI scroll-visibility observations (`.onScrollVisibilityChange`) at the transcript boundaries. Approaching the top boundary automatically engages an inline loading indicator (`GoatLoadingIndicator`) and advances the window backward while preserving the user's visible anchor position. Approaching the bottom boundary automatically loads later messages, smoothly transitioning back to bottom following at the conversation floor. The underlying 40-message / 16 KiB display budget from ADR-0091 remains enforced.

## Amendment (proposed): Segmented rich rendering and segment-level windowing (2026-09-26)

Status: Proposed. Tracked by [#60](https://github.com/goatsoft/GOAT/issues/60) (A1, A3, B1, C1).
The 8 KiB plain-text parts fallback above stays in force until every step's acceptance tests pass.

**Problem.** Replies over 8 KiB lose rich rendering, and streaming re-parses the whole reply on
every refresh, so parse work grows quadratically with reply length.

**Decision.** Render a reply as independently prepared Markdown segments, and bound layout per
segment rather than per message. Deliver it in three reviewable steps:

1. **Segmentation** (`MarkdownSegmenter` in Bleet, pure). Segments break only at valid top-level
   block boundaries: a column-0 line after a blank line, a column-0 fence opener, or the line after a
   fence closes, never inside fenced code, multi-line HTML or display math. Whole blocks pack to about
   6 KiB, and a segment never exceeds 16 KiB. Oversized blocks are split explicitly: fenced code
   repeats its opener in every piece, tables repeat their header and delimiter rows, and other blocks
   split at column-0 lines, then lines, whitespace or scalar boundaries, never inside a nested
   container while another cut exists. HTML and SVG artifact documents stay whole. Reference
   definitions are appended to every segment. A segment's index is its identity. Only segments that
   end before the final, possibly partial line are settled; the rest are provisional, and consumers
   compare segment text before reusing prepared content because a later definition can change it.
2. **Stable-prefix rendering** inside the existing message window. Settled segments are prepared
   once; only provisional segments are re-prepared as the reply streams. Rendered segments and
   prepared-content cache bytes are bounded independently of total reply length. The streaming caret
   (B1) marks only the tail.
3. **Segment-level windowing**, built on the single transcript navigation owner from
   [#54](https://github.com/goatsoft/GOAT/issues/54) section 2. The window admits segments rather
   than whole messages, so a long reply renders rich and pages within itself, with one scroll
   executor, stable segment identities and preserved reader anchors.

**Acceptance per step.** Tests for boundary crossings while streaming, oversized fences, tables and
paragraphs, completion without reflow, paging reachability, anchor preservation, and parse work
that grows linearly with the reply. The fallback is retired only when step 3 passes them.

**Rejected.** Fixed-size byte chunks (they break fences, tables, lists and paragraphs). Assuming a
parsed prefix is permanently stable (definitions and container openers can change it). A second
scroll owner inside long messages (it would compete with #54's navigation model).

