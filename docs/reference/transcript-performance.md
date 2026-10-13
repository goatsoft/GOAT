# Transcript performance qualification

## Follow-up ownership (2026-10-13)

The remaining scope from [#60](https://github.com/goatsoft/GOAT/issues/60) is transferred to these
open issues. Closing the original audit records this transfer; Deliveries 3–6 remain incomplete.

| Remaining scope | Follow-up |
| --- | --- |
| Delivery 3 production performance, retention, accessibility and manual checks (Measurements 1c and 6) | [#85](https://github.com/goatsoft/GOAT/issues/85) |
| Experimental container startup anchors, native Q1, comparison and migration | [#86](https://github.com/goatsoft/GOAT/issues/86) |
| Delivery 4 bounded previews, tables and math | [#87](https://github.com/goatsoft/GOAT/issues/87) |
| Delivery 5 growing history, database paging and Measurements 4b–5 | [#88](https://github.com/goatsoft/GOAT/issues/88) |
| Delivery 6 empty state, editing/retry, search, keyboard, day separators and export | [#89](https://github.com/goatsoft/GOAT/issues/89) |

The dated evidence below remains historical. References there to gates being open in #60 now
resolve through this ownership table. No unchecked acceptance is certified by the transfer.
The maintenance release retains its separate [release checklist](../RELEASE-CHECKLIST.md);
ADR-0099 remains Proposed and the shipping container is unchanged.

## Workload and measurements

### Reader follow-up implementation

The reader adds day boundaries that remain stable across admitted windows, an empty
conversation state, explicit Earlier/Later controls, and a Latest shortcut that respects Reduce
Motion and the animation setting. Find searches message text off the main actor, returns at most
200 highlighted message excerpts, and sends selection through the existing viewport owner. Rich
replies are paged to the segment containing the match. The selected source excerpt remains
visible above the reader, including matches inside collapsed code. Oversized plain-text replies
currently open at their message boundary. Find (Command-F) and copy-last-reply (Shift-Command-C)
route through the focused chat window. Segment paging controls are real buttons, so a short
window can reach earlier text without requiring a preceding scroll gesture.

Edit and resend preserves attachments and atomically updates the user message while deleting
subsequent messages. A changed message or database history rejects the edit without partial
deletion. Compaction boundaries cannot be edited away. Markdown export preserves message source;
plain-text copy uses the renderer's plain-text conversion. Code actions retain individual
accessibility names and remain available to accessibility clients when visual controls are hidden.
The model/effort selector uses the theme's text color on its transparent background, including
Light and Pasture, instead of the color intended for text on a solid accent.

Inline previews admit at most three live artifacts. Offscreen and source-mode artifacts release
their web views; memory-only snapshots are capped at eight entries and 16 MiB of charged bitmap
cost. Admitted previews retain independent ephemeral website data stores and the existing JUDAS
policy. Initial document geometry is bounded between 80 pt and the existing preview-height cap;
Expand opens the artifact in Paddock. These limits are not a claim about WebKit subprocess RSS.
Tables scroll horizontally and expose header cells. Display math delimited by standalone `$$`
or `\[` / `\]` lines is explicitly shown as selectable source, with delimiters preserved.
No math-rendering dependency has been adopted.

Stored chats open with the latest 40 records, page by `(position, id)`, and retain at most 120
idle reader records. The navigation owner preserves stable message/segment anchors when cache
indices change. Saved provenance is decoded only when details are opened. Generation, retry and
editing explicitly hydrate complete history before inference or mutation; completed turns trim
the cache around the reader. Search examines cancellable storage pages with a 200-result cap;
explicit export reads a complete snapshot without replacing the reader cache. These are record
bounds, not a byte ceiling for arbitrarily large messages. [ADR-0102](../adrs/0102-paged-reader-history.md)
records the contract and its limits. Cold/warm performance, retention and supported-OS measurements
remain part of #88.

These implementation changes do not close the qualification gates in #85–#89. The experimental
startup probe now bounds first-marker readiness while checking that the clip moves no more than
1 pt during that interval; it also requires all 192 growth/input samples and zero missing anchors.
At `d138d2f` on macOS 27 / Xcode 27, the SwiftUI candidate still fails: 46,033 pt startup clip
movement, no startup anchor within the 200 ms bound, 191 of 192 growth samples, and 120 pt maximum
input residual. Later width/font reflow probes measured zero drift, but do not override the startup
and growth failures. The candidate is not accepted and the shipping container is unchanged. The subsequent one-shot
scroll experiment and native fallback retirement are recorded in the [comparison reference](transcript-container-comparison.md).

Issue [#29](https://github.com/goatsoft/GOAT/issues/29) requires runtime evidence,
including histories with fewer than 40 very large messages. The engine-free
`TranscriptPerformanceTests` workload creates 24 messages containing repeated
Markdown, Swift code, reasoning and tool results in a displayed native window.
It exercises idle, waiting between rounds and incoming output, with reader
ownership and bottom following in separate runs. No private chat is loaded and
no inference request is sent.

Run the workload alone in Release:

```sh
make test-app CONFIG=Release TEST_PLAN=Qualification XCODE_FLAGS='-only-testing:GOATTests/TranscriptPerformanceTests'
```

Each `TRANSCRIPT_PROFILE` record includes elapsed time, process CPU time, the
95th percentile of main-actor scheduling delay beyond a requested 50 ms sleep,
and process-lifetime peak resident memory in bytes. CPU time divided by elapsed
time gives utilization relative to one core. Scheduling delay is a responsiveness
proxy, not measured keyboard or pointer latency. Peak resident memory includes
the test host and earlier phases and is not an allocation delta or physical
footprint. Compare fresh test-host runs under the same conditions.

Use Instruments Time Profiler on the test host to attribute main-thread work to
native layout, Markdown preparation, highlighting, scrolling or other work.
The existing `MarkdownParse` and `TranscriptFollow` signposts and the workload's
`TranscriptWorkloadPhase` markers help align samples. Record hardware, OS build,
Xcode, source revision, build configuration, window dimensions, font, animation
settings and background load with each local receipt. Retain raw profiles
privately; public reports should contain synthetic findings only.

The workload is an investigation aid, not complete acceptance. Also exercise
composer typing, selection/copy, tool and reasoning disclosures, Earlier/Later
navigation, keyboard, narrow widths, font changes and reader
position. Use the existing transcript layout and reflow tests for regression
coverage. Repeat runtime qualification on Tahoe 26 and Golden Gate 27. Passing
tests or a faster scheduling proxy does not establish those interactive results.

## Presentation bounds

The transcript admits at most 40 messages and approximately 16 KiB of source
cost per window. At least one message is always admitted. Earlier/Later paging
keeps every message reachable; a reader-owned window holds its range during
incoming output. Latest or a new user turn restores following.

Responses through 2 MiB render as rich Markdown segments split at valid block
boundaries ([ADR-0091](../adrs/0091-content-bounded-transcript-layout.md)).
While a response streams, settled segments are parsed once and only the tail is
parsed again, so parse work grows linearly with the response. Settled segments also use their
final rendering style while the provisional tail streams: completion does not change every
segment's preview or streaming style at once. Complete HTML/SVG/Mermaid fences can preview when
their segment settles; oversized fence pieces stay source-only because their closures are
synthetic. The
`MarkdownSegmentParse` signpost marks each segment parse. A long response lays
out a window of at most two segments and 16 KiB of rendered bytes: its latest
segments while following, or those the reader pages to. Loaders at the window's
edges page it as they come into view, keeping the reader's segment in place. Only
the window's segments (and two on each side) keep their parses. The message
window charges a prepared response the bytes of its shown segments, including
repeated reference definitions.

Reasoning shown in full is windowed the same way through 2 MiB: its fence-aware
blocks are split at line boundaries into segments of at most 6 KiB, and a window
of at most two segments and 16 KiB is laid out, paged under its own key. It is
prepared off the main actor from a 120 ms sample of its text revision. While the
revision only appends, the held segmentation lexes each appended character once,
including within one long unfinished line, and a refresh copies at most one open
piece and one chunk of segments, so total work grows linearly with the reasoning
(`streamingPreparationWorkGrowsLinearly` checks completed lines, unbroken prose,
one long code line and long fence info through 2 MiB).

A response or expanded reasoning above 2 MiB is presented as
selectable plain-text parts, prepared off the main actor. Earlier text and Later
text navigate those parts; Latest text follows the newest part. Choosing an
older part holds that choice as output arrives. Copy retains the full original
source, including Markdown fences and whitespace. These are presentation bounds;
persistence and model context retain the complete content.

The message's text revision tells the preparation cache when text was only
appended, so a refresh never compares the response's prefix, and it visits only
newly settled segments and the provisional tail.

`SegmentPreparationWorkloadTests` (in the default app test plan) streams five
reply shapes from 32 KiB to 2 MiB at a fixed 4 KiB per refresh through the
preparation layer and prints one `SEGMENT_PREPARATION` record per shape and
size: parse count and bytes, scanned, copied and compared bytes, segments
visited (total and the most in one refresh), HTML bytes, segmentation, parse
and assembly time, refresh time percentiles, main-actor hand-off time, retained
cost and the cost of a completion trim. It asserts that work per reply byte
stays flat as the reply grows 64 times and that a refresh visits a bounded
number of segments. Times are observations, not thresholds. It measures the
preparation layer with enlarged cache budgets; live rendering under the default
budgets is covered by the window tests above.


## Recorded maintenance evidence

[PR #35](https://github.com/goatsoft/GOAT/pull/35) merged the bounded rendering changes and closed issue #29. The same engine-free Release workload on M1 Max/32 GB, macOS 27.0 and Xcode 27.0 took 19 seconds versus 133 seconds originally; main-actor scheduling delay p95 was 5–18 ms and peak RSS was 285 MB. These are synthetic single-host measurements with the limits described above.

The combined stack in [PR #36](https://github.com/goatsoft/GOAT/pull/36) passed six native disclosure/compaction tests and two reader/reflow tests on Tahoe 26.6.2 with Xcode 27.0. Its non-default test-seeded reader window starts at the requested anchor so there is content below it; normal following initialization is unchanged. Compaction screenshots were inspected at 360/700-point widths in light and dark themes.

A disposable native window on Golden Gate exercised earlier-part navigation, text selection, Command-C, keyboard-adjusted selection and complete copy/paste of a 400-line Unicode fixture spanning two parts. No saved conversations were loaded. This is targeted interaction evidence, not a claim that every application workflow was manually audited.

Compaction-specific keyboard expansion/collapse and restoration passed with the actual macOS Reduce Motion setting enabled. A fresh process restored compaction preferences, summary text and file metadata; deleting the summary retained both original messages in SQLite. These checks used disposable synthetic data.

## Dense-block bounds

Markdown packing also stops at 16 work units, with a fence costing four.
The score counts nonblank prose and table lines; it isolates an indivisible complex
block without changing its internal Markdown semantics. It is a packing heuristic, not a hard
bound on every nested view. The existing byte limits still apply. See the complexity amendment in
[ADR-0091](../adrs/0091-content-bounded-transcript-layout.md).

Cache admission includes prepared/scanner metadata and prepared code literals, so tiny segments
cannot bypass a byte-only budget. Actor limits are 32 MiB total / 24 MiB per reply, with completed replies capped at 16 MiB
inside that total and evicted before active streams. Front-cache limits are 16 MiB total / 4 MiB per reply; larger replies render from view-owned working documents without displacing unrelated cached history. These charged costs are not measurements of process RSS.
Code identity HTML extraction runs in preparation, using the existing parse's HTML, rather than
in main-thread view evaluation. Dense 2 MiB tests verify scanner retention, bounded admission,
linear scanning and cache lifecycle. Container responsiveness is measured separately in the
[container comparison](transcript-container-comparison.md).


## Delivery 3 integrated qualification (2026-09-27)

Delivery 3 is **not qualified complete**. A Release production-view workload on main
`90f4037` found an integrated live-follow performance problem despite the linear preparation
measurements above. The opt-in `TranscriptPerformanceTests.testInteractiveDelivery3Qualification`
hosts `ChatView` with synthetic messages and an isolated test home. It never sends to an engine.

Run the interactive surface with:

```sh
TEST_RUNNER_GOAT_DELIVERY3_QUALIFY=1 make test-app CONFIG=Release TEST_PLAN=Qualification \
  XCODE_FLAGS='GOAT_APP_BUNDLE_IDENTIFIER=dev.leet.goat.qualification -only-testing:GOATTests/TranscriptPerformanceTests/testInteractiveDelivery3Qualification'
```

The separate qualification bundle identifier also isolates its UserDefaults from normal app tests.
It provides theme, font, animation and synthetic inspector controls, a short code fixture, and
2 MiB answer/reasoning streams. Content fixture adds disposable tables, HTML/SVG/Mermaid previews,
literal display math and calendar-day boundaries; Empty fixture exercises the initial state. Finish closes the fixture; the opt-in test is skipped in normal
runs. For automatic answer then reasoning streams, also set `TEST_RUNNER_GOAT_DELIVERY3_AUTORUN=1`.
The host prints its PID, waits 15 seconds before automatic work, and waits 5 seconds after each
stream action so Instruments can attach and UI inspection can finish before measurement starts.
Interactive streams are view-owned tasks and respect cancellation. Closing the fixture stops
publication and never labels partial output as a completed 2 MiB result. The host uses a plain
native viewport around the autoresizing SwiftUI host, matching app/comparison layout ownership.

The stress source repeats a short paragraph and one-line Swift fence to exactly 2 MiB, published
in 16 KiB batches separated by a nominal 120 ms sleep. This deliberately tests high block density;
it is not a claim about a typical model response. The timer includes a 3-second completion settle.
The scheduling-delay metric is main-actor sleep overrun, not measured key-to-pixel input latency.

On M1 Max (10 CPU cores, 32 GiB), macOS 27.0 (26A428), Xcode 27, Release, initial 1180 × 780
content size and 14 pt reading font:

| Scenario | Wall time | Process CPU | Scheduling delay p95 | Process lifetime peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Answer, reader held, Time Profiler plus AX polling | 49.36 s | 47.95 s | 239.52 ms | 719.48 MiB |
| Expanded reasoning, reader held, Time Profiler plus interaction | 19.33 s | 8.90 s | 11.09 ms | 719.48 MiB |
| Answer, fresh host following live, no AX polling | 173.20 s | 171.75 s | 2018.28 ms | 537.88 MiB |

A 120-second Time Profiler recording began before the fresh-host stream; the final counters cover
the whole answer, including the period after recording ended. Its subsequent reasoning phase was
interrupted and is not a result. Other desktop applications and the XCTest host were running.
These are diagnostic single-host samples, not portable performance thresholds.

The polled trace was dominated by main-thread AttributeGraph and SwiftUI work, including
accessibility-tree construction. The unpolled run and a stack sample also show sustained
main-thread SwiftUI/AttributeGraph work. This identifies the integrated view/following path for
investigation; it does not prove one app function is the cause. Geometry and onChange
multiple-updates-per-frame warnings reproduced. Do not attribute all delay to parsing, or all
delay to the accessibility observer.

Separate Allocations captures were collected. The full reader-held reasoning capture recorded
229.61 MiB cumulative `Swift.__StringStorage` allocations with 5.36 MiB persistent at the end of
the 90-second recording, and 280 KiB persistent `ThinkingSegment` array storage. These are allocation
categories, not total process memory or cache-only retention. The answer allocation capture ended
before that instrumented stream completed, so final answer retention remains unqualified. Raw
traces stay private; they include machine paths and process environment information.

Manual checks observed live code recolouring in System/dark, Light, Pasture and Midnight, reading
font changes from 14 to 16 pt, and reflow with a synthetic 260 pt inspector. Reader-held expanded
reasoning accepted composer input and Earlier/Later paging and preserved position on completion.
These observations do not complete the entire manual matrix. The locked 1337 experience, actual
inspector at narrow widths, Reduce Motion/animations-off streaming, full keyboard/VoiceOver
navigation, font-family changes and macOS 26 still require qualification.

With VoiceOver enabled, the code block's outer accessibility label was exposed on its expansion,
wrap, save and open buttons as the same generic artifact name. Copy retained its own label.
This needs correction and a complete keyboard/VoiceOver retest. Light/Pasture also showed a
low-contrast model-selector label in the synthetic host; reproduce in the regular window before
classifying it as a product defect. Delivery 3 remains open in issue #60.

### Follow-up foundation and harness correction (2026-10-12)

The September measurements above are historical production-window diagnostics on `90f4037`.
They are not results for the preparation changes or flat-row experiment in
[PR #83](https://github.com/goatsoft/GOAT/pull/83). The
[latest comparison](transcript-container-comparison.md#swiftui-preparation-and-reader-capture-follow-up-2026-10-12)
records exact-SHA repeated navigation failures, improved reflow capture and separate 2 MiB
answer/reasoning/dense observations. Neither candidate is qualified; ADR-0099 remains Proposed.
These preparation and test-only experiment changes do not replace the shipping scroll container.
The failed navigation observations are historical; see the synchronous-spacing follow-up below
for the subsequent fix and its remaining qualification limits.

The old #82 CI reflow failure was a harness-sizing defect: a requested 980 pt viewport measured
65 pt because the direct `NSHostingView` exported its content sizing to the window. The normal
reflow fixture now wraps its autoresizing host in a plain `NSView` viewport. The separate direct-root
minimum-size regression remains, rather than suppressing production window constraints. The
interactive qualification host uses the same wrapper. No assertion tolerance was relaxed and no
retry was added to mask the failure. Default-plan tests also cover cancellation before startup and
teardown during both answer and reasoning streams, preserving incomplete state and stopping output.
An additional full-suite run exposed a pending initial restore in the older navigation reflow test
(37 pt residual). That fixture also used a bare hosting root. It now receives the same surrounding
viewport and asserts the requested width and height at initial placement and every reflow. The
existing anchor identity, fulfilled-request and zero-abandonment checks remain unchanged. This is
harness hardening, not evidence that the experiment's 22 pt wheel/growth defect is fixed.

Documentation describes delivered contracts, not proof of the remaining manual or live acceptance
checks. Supported macOS 26, hardware momentum, keyboard/VoiceOver code actions, integrated themes,
Reduce Motion, narrow inspectors, font changes, expanded-reasoning paging, answer retention and
frame-time/allocation qualification remain explicit gates in #60. Delivery 3 stays open.

### Synchronous-spacing follow-up

[PR #84](https://github.com/goatsoft/GOAT/pull/84) fixes settled rich rows changing height after
mounting. [ADR-0100](../adrs/0100-synchronous-markdown-block-spacing.md) records the opt-in
MarkdownUI policy, exact maintained dependency and first-layout regression coverage. Nearby user
messages are also prepared through the production caches before entering the comparison viewport.

The earlier `3f62ebc` replay with renderer `2.4.2-goat.1` passed all 192 growth samples
without a missing anchor, with zero wheel/growth residual and zero reflow drift. This is
historical evidence, not qualification of the reviewed dependency. On `cea0538` with the merged
`2.4.2-goat.2` renderer, the full replay fails startup anchor capture and records one missing
growth sample. An input-only diagnostic passes, but does not resolve the full replay failure.
A first-paint flush experiment also fails startup and is discarded. Container qualification
remains open; later zero-drift phases do not validate failed startup preconditions.
Separate earlier mixed and dense replays complete
2 MiB of reasoning and 2 MiB of answers. Publication wall time includes awaited preparation;
neither it nor sleep-overrun measurements establish frame rate. Process memory excludes preview
subprocesses. CPU sampling and allocation recording require separate interpretation because
allocation instrumentation materially slows the workload.

Recommend the flat SwiftUI list for the next production migration, retaining the current shipping
container until that migration is reviewed and qualified. Delivery 3 remains open for supported-OS,
hardware input, manual/accessibility, full-app frame-time and retention checks. Those gates remain
distinct from the Kid maintenance release.


### Dense reply admission follow-up

[ADR-0103](../adrs/0103-dense-reply-layout-admission.md) reduces the reply layout window to two
rich segments while retaining the existing byte limit and overlapping paging. This addresses
native layout cost from many tiny code fences; the 40-message transcript window is unchanged.
With mouse events excluded, the 40-row publication regression observes no settled-row body
evaluations during 20 updates to the live row. Database-prepend coverage verifies the owner's held anchor through
page replacement using the existing 1 pt executor tolerance.

Development measurements show a substantial dense-answer improvement, but do not establish
input latency, frame time or retention acceptance. Request/geometry update warnings remain.
The five tracked follow-ups and the release checklist still own the remaining qualification.
