# ADR-0060: Bounded rich-list measurement

Status: Accepted · 2026-09-07

Refines ADR-0058's transcript row measurement.

## Context

A real chat containing two approximately 5 KiB assistant responses, each with twelve fenced code blocks inside lists, could saturate the main thread and delay the entire app. Paragraph-only transcript reflow fixtures and an isolated composer did not reproduce it. A restarted Release process remained near 100% CPU after removing an unrelated send-button animation loop.

A five-second sample showed recursive SwiftUI ideal-size and explicit-alignment calculations through nested rich content. Parsing had already completed; a Markdown parse cache could not remove this layout cost. Physical footprint remained around 130 MiB rather than showing runaway growth during observation.

## Decision

Use a direct two-child Layout for Markdown list markers and bodies. Measure the marker, offer the remaining width to the body, and place both at the top. Avoid asking native Label baseline alignment to traverse a body containing paragraphs, nested lists and horizontal code scrollers.

Give the assistant body an explicit top alignment boundary. Retain full-height fixed sizing for transcript rows. The list layout avoids recursive alignment within this measurement boundary. Reflow validation uses a displayed window so native scroll settling and display-cycle layout execute; hidden-window capture intermittently produced empty viewports even with full-height sizing. Retain the 40-message measured window, stable IDs, cached parsing, code highlighting, selection, links and Paddock actions.

Keep a static ready send-button glow with event-driven hover/press feedback. Editor measurements follow actual text/font/width changes and coalesce pending work; unrelated SwiftUI updates do not reconfigure selection attributes. Typing the next draft remains available while generation owns Send.

## Consequences and validation

The same saved conversation was restored in the normal Release app. CPU snapshots fell from about 100% to 1.4% and then 0.7%; the follow-up three-second sample showed the main thread waiting for events. A captured window confirmed the code-rich response was populated. These observations establish a fix for this reproduced idle stall, not a complete app performance certification or a proof that every possible leak is absent.

Add a visible-window regression containing nested ordered/bulleted lists and 24 code blocks, native text insertion, event-loop delay measurement and resizing. Retain existing transcript selection/reflow and composer undo/submission tests. PERF-07 remains the broader Release interaction and memory gate.

## Alternatives considered

- Add more parse caching: parsing was outside the sampled hot path.
- Remove code highlighting or flatten responses to plain text: would discard working rich-content features.
- Return to an unbounded lazy transcript: would reintroduce the earlier reflow and disappearance issue.
