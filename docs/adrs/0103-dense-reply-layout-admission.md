# ADR-0103: Dense reply layout admission

Status: Proposed · 2026-10-13

Refines [ADR-0091](0091-content-bounded-transcript-layout.md). Qualification belongs to
[#85](https://github.com/goatsoft/GOAT/issues/85); this does not select the experimental
container in ADR-0099.

## Context

Source bytes do not adequately bound native view work. Each segment packs at most 16 work
units, but the reader previously admitted 32 such groups. Tiny fences can therefore mount
many code controls while remaining below the 16 KiB reply budget. Settled-row equality avoids
unrelated row evaluation but does not bound this single-message workload.

A fresh Release production-view run with a dense 2 MiB answer took 188.04 seconds with
1,719.77 ms p95 main-actor sleep overrun. A separate CPU capture reproduced the slowdown
and showed substantial native Markdown block measurement and placement. Admitting four
groups reduced wall time to 28.68 seconds, but p95 scheduling delay remained 169.30 ms.
These are single-host diagnostic observations, not input-latency or frame-time acceptance.

## Decision proposed

Admit at most two rich Markdown segments per reply, still subject to the 16 KiB rendered-byte
budget. The message window remains 40 messages. Preserve segment identity, prepared caches,
full source, model context and persistence. Larger replies remain fully reachable through
overlapping segment paging. When one segment fills the byte budget, paging may temporarily
show that segment and its neighbour to preserve the existing anchor contract. Earlier and
Later are actionable buttons as well as visibility boundaries: explicit activation takes
reader ownership, so short windows remain navigable even when their content fits without
scrolling. Automatic visibility paging is disabled when the content fits in the viewport,
preventing a newly mounted opposite boundary from immediately reversing an explicit page.
Synchronous paging does not display a perpetual loading spinner.

This is a layout admission bound, not a promise that an indivisible block or a whole preview
artifact is cheap. The existing oversized-block rules and separate preview admission remain
in force. A smaller window can require more paging; validate short segments, long prose,
large fonts and narrow widths, including loading while the reader holds an anchor.

## Validation

The two-group development run completed the answer in 19.12 seconds (8.23 ms p95 scheduling
delay) and expanded reasoning in 20.01 seconds (38.58 ms p95). Full regression and supported-OS
qualification still apply. Deferring request notifications did not eliminate SwiftUI's
multiple-updates-per-frame warnings and was discarded; those warnings remain under #85.

Retain the failed baseline and compare fresh Release answer and expanded-reasoning runs.
Verify bidirectional reachability, held anchors within 1 pt, cancellation, reflow, completion
and full-source copy. Repeat the production workload on supported macOS 26. CPU and allocation
traces, preview subprocess retention, actual input/frame measurements and manual keyboard/
VoiceOver checks remain separate acceptance gates. Do not infer those from scheduling delay.
