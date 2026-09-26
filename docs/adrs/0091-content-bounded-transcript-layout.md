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
   container closes, never inside fenced code, multi-line HTML or display math. A column-0 item of
   the same list continues it, so loose lists stay whole. Whole blocks pack to about 6 KiB.
   - **Bounds.** A segment's Markdown body never exceeds 16 KiB. Two things sit outside that bound
     and are stated separately: an HTML or SVG artifact document stays one whole segment, and the
     reply's reference definitions (at most 4 KiB, none once they exceed it) are appended to the
     text of every non-verbatim segment. Syntax a piece repeats is capped at a quarter of the
     maximum. A line longer than the maximum carries no block syntax (it cannot open or close a
     container or head a table), a deliberate departure from CommonMark that bounds both repeated
     syntax and scanner lookahead.
   - **Oversized blocks.** Fenced code is rebuilt in every piece with a fence that fits the syntax
     budget (the full opener, its language only, or a bare fence) and closed except for an
     unterminated final piece. Tables repeat their header and delimiter rows. Other blocks split at
     column-0 lines, then lines, whitespace or scalar boundaries, never inside a nested container. A
     nested container larger than a piece is split on its own: a fence in a list item or behind
     indentation is rebuilt as top-level code (its list nesting is not kept), and quoted fences,
     HTML and display math become verbatim pieces. Anything whose syntax cannot be rebuilt within
     the budget becomes verbatim pieces, which render as plain monospaced text. Known limits of
     pieces: a split paragraph or list item ends early, inline markup across a cut is not kept, and
     a one-item piece of a loose list renders tight. Consumers join pieces marked
     `continuesPrevious` without a block gap.
   - **Validation.** App tests render segments with MarkdownUI: whole-block segments produce exactly
     the whole reply's HTML (loose and tight lists, quotes, alerts, HTML comments, math, reference
     links), and fence, table and paragraph pieces keep every code line, row and word.
   - **Streaming.** A segment's index is its identity. The scanner is append-oriented: a line is
     committed once its role is decided (when it ends or exceeds the maximum, or for a possible
     table header, when its delimiter row is decided), committed segments are never revisited, and
     each extension reads only the new bytes plus a tail bounded by the segment maximum. Callers
     must only append; only the undecided tail is compared. Segments ending before the undecided
     tail are settled; the rest are provisional, and consumers compare segment text before reusing
     prepared content because a later definition can change it. Scanned and copied bytes are
     instrumented, and tests hold them linear in the reply for six reply shapes.
2. **Stable-prefix rendering** inside the existing message window. Settled segments are prepared
   once; only provisional segments are re-prepared as the reply streams. Rendered segments and
   prepared-content cache bytes are bounded independently of total reply length. The streaming caret
   (B1) marks only the tail. Integration contracts from the step 1 review:
   - Each streaming message holds one uniquely referenced `MarkdownSegmentation` and mutates it with
     `extend`; an edit or replacement starts a new one. The copying `resegment` API and
     materialising the whole `segments` array are not the hot path. Release builds do not check
     that committed text is unchanged.
   - `verbatimPiece` renders as plain text. Budgets charge the prepared representation actually
     rendered, including whole artifacts and the definition suffix, which sit outside the body bound.
   - Pieces of oversized blocks are not full Markdown semantic preservation (see step 1), so A1 stays
     open until this step's acceptance passes.
   - **As implemented.** `MarkdownSegmentCache` (an actor) holds each streaming reply's
     segmentation in place, starts a new one when the source no longer extends the previous one (an
     edit, or the trim at completion), and reuses a settled segment while the definition suffix is
     unchanged. Other segments are reused only when their text is unchanged. Its entries and the
     main-actor `PreparedMarkdownDocumentCache` (first-frame reuse) are charged rendered bytes plus
     source bytes. The window charges a prepared reply its rendered bytes. Segments stack with the gap
     MarkdownUI's block sequence would leave between the same blocks (the larger adjacent margin, or
     the default padding when neither block sets one). Pieces marked `continuesPrevious` have no gap.
     Only a reply's first segment can be an HTML or SVG artifact. The caret is placed by
     structure, not text: a tail segment carries it only when its last leaf block is a paragraph
     (read from the parsed segment's HTML), and it is drawn over the last of the segment's text
     layouts (`Text.LayoutKey`, in view order), so it never changes layout. Tails ending in code,
     headings, tables, thematic breaks, HTML blocks or images show no caret. The 8 KiB
     parts fallback still applies to the whole reply, so a reply renders at most two segments until
     step 3.
   - **Measured (Release, engine-free).** For a streamed reply with 1 KiB refreshes, parsed bytes per
     reply byte stay at about 4.0 at 32, 64 and 128 KiB. Parsing the whole reply at every refresh
     grows quadratically: at 128 KiB it would parse 8.45 MB instead of 0.54 MB. App tests also cover
     segmented and whole-reply heights across block boundaries, completion without reflow, and the
     caret on the final line only, including repeated endings and non-prose tails.
   - **Scope of the measurement.** It qualifies the preparation layer on synthetic replies. The live
     `StreamingMarkdownView` stops using it above the 8 KiB fallback, so it does not yet describe
     deployed rich rendering at those sizes. Parsed bytes are linear, but each refresh still compares
     the full source prefix (`MarkdownSegmentCache.source(_:extends:)`) and rebuilds the prepared
     segment array, so total preparation CPU work is not yet shown to be linear. Before step 3 lifts
     the fallback, profile the complete path and carry explicit source-revision and append
     information instead of rescanning the prefix, so step 1's scanner gains hold end to end.
   - **Whole-path preparation (as implemented after step 2).** `ChatMessage` carries a `TextRevision`
     for its text and reasoning: streamed appends keep the revision's epoch, and any other change (an
     edit, the completion trim, a restore or replacement) starts a new, process-unique epoch. The cache
     extends the held segmentation when the new revision extends the held one, so a refresh never
     compares the reply's prefix. A refresh visits only segments settled since the last refresh and the
     provisional tail; prepared segments live in fixed-size chunks shared with documents already handed
     to views, so a refresh copies only the chunk index and the chunks it changes. When the reply's
     reference definitions change, only settled segments containing a closing bracket (the only ones a
     definition can affect) are parsed again. Views, the front cache and the window charge match
     documents by revision.
   - **Measured whole path (Release, engine-free, CI macOS 26 runner).** Five reply shapes (mixed
     Markdown, long single-line paragraphs, fences including oversized ones, tables including oversized
     ones, and 16 reference definitions arriving at the end) streamed at a fixed 4 KiB per refresh from
     32 KiB to 2 MiB. Scanned, copied, compared, parsed and HTML bytes per reply byte stay flat (about
     9 to 15 in total, per shape, at every size). Per-refresh preparation time does not grow with the
     reply (median 0.4 to 0.9 ms, 1.7 to 2.1 ms for tables; 95th percentile 0.6 to 1.9 ms, 3.0 to
     3.4 ms for tables), at most three
     segments are visited per refresh, and handing a document to the main actor takes under 0.1 ms.
     Compared bytes are under 0.75 per reply byte (no prefix comparison). Exceptions, stated rather
     than hidden: the refresh that delivers late reference definitions re-parses every settled segment
     with a bracket once (106 ms at 2 MiB, off the main actor); a completion trim that changes the
     text starts a new epoch and costs one pass over the reply (about 15 ms at 2 MiB). A streaming
     reply retains about three times its source bytes (rendered segments, source and the scanner's
     bodies). These measure the preparation layer; the live view still uses the 8 KiB fallback, so
     live rendering at these sizes is measured with step 3.
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

