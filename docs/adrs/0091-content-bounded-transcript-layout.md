# ADR-0091: Content-bounded transcript layout

Status: Accepted · 2026-09-20

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
