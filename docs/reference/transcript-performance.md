# Transcript performance qualification

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
parsed again, so parse work grows linearly with the response. The
`MarkdownSegmentParse` signpost marks each segment parse. A long response lays
out a window of at most 32 segments and 16 KiB of rendered bytes: its latest
segments while following, or those the reader pages to. Loaders at the window's
edges page it as they come into view, keeping the reader's segment in place. Only
the window's segments (and two on each side) keep their parses. The message
window charges a prepared response the bytes of its shown segments, including
repeated reference definitions.

Reasoning shown in full is windowed the same way through 2 MiB: its fence-aware
blocks are split at line boundaries into segments of at most 6 KiB, and a window
of at most 32 segments and 16 KiB is laid out, paged under its own key. It is
prepared off the main actor from a 120 ms sample of its text revision; each
sample re-parses the reasoning, so the work per sample is linear in its length.

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
