# Transcript container comparison

Issue #60 owns this qualification. ADR-0099 remains proposed until the owner reviews the comparison.
The candidates are a flat SwiftUI `LazyVStack` with modern scroll APIs and an AppKit `NSTableView`
with reusable `NSHostingView` cells. Neither replaces the shipping transcript in this experiment.

Both consume the same test-only row model and use the production Markdown segment, reasoning,
user-message and tool activity views. Publication updates existing tail row objects and adds new
segment rows. The historical messages are deterministic synthetic input, never saved user chats.
Memory lookups, delegated investigations, file reads, command results and failures are replayed
records: the fixture does not execute tools, commands or inference, or contact a memory service.

The default history has 48 rounds. Answers contain prose, lists, tables, Swift fences (including
96-line collapsible blocks), HTML and SVG previews. Reasoning includes prose and fenced code.
Each live channel then grows to exactly 2 MiB, in UTF-8-safe publications of at most 16 KiB, with a
nominal 120 ms pause. A separate dense case repeats short paragraphs and one-line fences to
exercise the dense-content regression exposed by the earlier qualification. Both large streams repeat deterministic
blocks; the historical rounds vary their code/preview identifiers. This tests mixed presentation
and scale, not the cache-miss distribution of a unique 2 MiB model response.

## Reproduce

Run each candidate in a fresh Release process. Use the same machine, window dimensions, settings,
fixture parameters and instrumentation. Do not run Instruments captures concurrently.

```sh
TEST_RUNNER_GOAT_COMPARE=swiftui make test-app CONFIG=Release TEST_PLAN=Qualification \
  XCODE_FLAGS='GOAT_APP_BUNDLE_IDENTIFIER=dev.leet.goat.comparison -only-testing:GOATTests/TranscriptPerformanceTests/testContainerComparison'
```

Use `TEST_RUNNER_GOAT_COMPARE=appkit` for the other candidate. The separate bundle identifier
isolates test preferences from normal app use; the test plan supplies an isolated app home.

Optional environment variables (all prefixed `TEST_RUNNER_` when invoking Make):

| Variable | Default | Purpose |
| --- | --- | --- |
| `GOAT_COMPARE_BYTES` | 2097152 | Bytes per live channel; smaller smoke test only |
| `GOAT_COMPARE_ROUNDS` | 48 | Historical mixed rounds |
| `GOAT_COMPARE_CHANNEL` | both | `answer`, `reasoning`, or both |
| `GOAT_COMPARE_FOLLOW` | 1 | Set 0 to hold the reader after scrolling upward |
| `GOAT_COMPARE_DENSE` | 0 | Set 1 for dense paragraph/fence regression input |
| `GOAT_COMPARE_NAVIGATION` | 0 | Set 1 to assert direct-move and concurrent upward-input/growth regressions instead of timing |
| `GOAT_COMPARE_INPUT_ONLY` | 0 | With navigation mode, stop after static candidate input calibration |
| `GOAT_COMPARE_INSTRUMENTS` | 0 | Set 1 for a 15-second attach interval after READY |
| `GOAT_COMPARE_INTERACTIVE` | 0 | Set 1 to leave the window open for manual checks |

The interactive surface supports theme and font-size changes, a synthetic inspector, Latest,
a composer text field, and the production code/tool controls. It is not the complete application
shell: message header/footer labels are fixture scaffolding and the inspector reserves width.
Do not claim real engine/tool integration, complete app navigation, footer action parity or actual
inspector qualification from this harness. Segment rows use common fixture padding, not the
shipping transcript's complete boundary-margin and 68ch-column composition. Tool cards start
collapsed. Expanded tool details, actual trackpad momentum and spoken VoiceOver navigation need
separate manual qualification.

## Evidence to record

- Fresh-process cold and warm scrolling through mixed content, in both directions.
- 2 MiB answer and expanded-reasoning streams while following and while reading older content.
- Dense 2 MiB regression, alongside realistic input rather than as its substitute.
- User gesture and momentum behavior, including content-height changes above the anchor.
- Narrow width, font changes, code expansion/wrap, tool/delegation details and preview transitions.
- Keyboard and VoiceOver, including focus surviving reuse and scrolling to offscreen content.
- Instruments CPU, allocations and post-completion retention, including preview subprocesses when
  evaluating total application memory.

The test emits `COMPARISON_RESULT` JSON with process CPU, wall time, main-actor sleep overrun p95,
publication duration p95, resident memory and lifetime peak RSS, appeared-row counts, measured
height-update counts, and anchor displacement where the row remains measurable. Sleep overrun is
not key-to-pixel latency or FPS. Appeared-row counts do not prove how many offscreen views remain
retained. RSS covers the test-host process, not WebKit subprocesses. Null anchor values mean no
measurement, never a zero-displacement pass. Static reader and completion displacement must be
kept separate from intended movement during a gesture. The initial gesture is identical input,
not a guarantee of identical visible content: the containers estimate unmeasured heights
differently. Reader-held numbers primarily test each candidate's own anchor stability.

The revised native candidate measures visible rows and one viewport of overscan with a sizing
host before display. Exact heights are keyed by row identity, content revision, parsed preparation,
width and typography, with 4,096 cached variants. Visible rows have priority; additional overscan
measurement has an 8 ms budget per pass. Previous offscreen heights survive reflow as scaled
estimates. Reader correction applies only the document-coordinate delta above the anchor to the
current clip origin. Following reads the document height after layout. Neither path writes an
unchanged origin. SwiftUI height callbacks collect updates for the pre-display transaction;
bounds notifications never re-enter table data-source/layout work. Native overscan contributes
to the fixture owner's combined per-message preparation request.

Cells use a concrete SwiftUI root and inherit the window's resolved environment. The window alone
installs presentation styling. Reuse identifiers distinguish row kinds; changing the row identity
intentionally resets its local content/disclosure state, while updating the same row preserves it.
Frame observations in both candidates are outside observable UI state.

`GOAT_COMPARE_NAVIGATION=1` exercises a direct move after Latest, 192 upward wheel events while
an answer grows to 2 MiB, insertion and height changes above the reader, final bottom alignment,
and width/font changes in both directions. All assertions use a 1 pt tolerance. Wheel residuals
compare the row's screen displacement with the input event's pixel delta,
clamped at the document edges. They do not treat the observed clip-origin change as input, which
could hide an unwanted programmatic scroll. The sequence contains discrete pixel-wheel inputs with two zero-delta pauses; it does not fabricate gesture or momentum phases.
The direct-move probe accounts separately for explicit native height compensation and records
unexplained offset movement after the reader takes ownership. A failure does not identify a
particular private SwiftUI mechanism. These synthetic probes expose regressions, but cannot certify hardware momentum,
every possible layout transition or supported-OS behavior. A failing candidate remains unqualified;
the assertions are not converted to expected successes.

The fixture owns one combined preparation window per message and uses the production
`PreparedMarkdownDocumentCache` for synchronous row reads. Neighbouring rows do not prepare
independent one-segment windows. Unmounting a row does not discard the cached document;
scroll-back reuses it while admitted under the production cache budget. Per-message observable
working documents isolate live publications from historical rows and remain renderable when a
large document is declined by the 4 MiB front-cache entry cap. Cold misses lay out the segment
body as plain text, as ADR-0099 requires, rather than a spinner or an empty row. A regression checks that two
neighbouring rows retain both preparation identities through hide/show and scroll-back without
additional parsing. This removes the artificial per-row cache contention, but does not certify
cold-miss geometry or no-flash behavior; those still require the opt-in qualification.

All timings from the earlier per-row preparation fixture are historical and unsuitable for a
container selection. Both candidates must be remeasured with the shared preparation owner.

## Interpretation correction after review

The initial and complexity-bound tables below are historical measurements of the prototypes at
`8bb7c88` and `13ad243`.
They are **not a like-for-like comparison of the proposed container policies**. The original
native candidate corrected displayed heights on a later turn, restored an absolute scroll target
on every publication, read the following target before layout, discarded all heights on resize,
and installed window presentation in each hosted cell. Its drift and timing cannot establish
that AppKit or ADR-0099's proposed policy is inferior. The original SwiftUI runs did not exercise
ADR-0097's direct-move replay or upward input overlapping growth. Their zero held-anchor result
is only an idle-reader observation, not scroll qualification. No container is selected.

## Initial comparison, 2026-09-27

Release, Apple M1 Max, 10 CPU cores, 32 GiB RAM, macOS 27 build 26A428. Each scenario used a
fresh process and 48 history rounds (402 initial rows). The mixed scenario streams 2 MiB of
expanded reasoning, then 2 MiB of answer text, ending at 5,019 rows. These are single runs,
not statistical estimates. The supported macOS 26 target still needs qualification. The machine
was not a controlled performance lab; do not interpret small differences as significant.

| Scenario | Container | Wall s | CPU s | Sleep overrun p95 ms | Publication p95 ms | Peak host MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| follow reasoning | swiftui | 20.29 | 5.36 | 9.45 | 12.04 | 224.3 |
| follow answer | swiftui | 20.31 | 14.63 | 34.13 | 19.12 | 369.6 |
| follow reasoning | appkit | 19.75 | 6.10 | 8.31 | 10.72 | 247.4 |
| follow answer | appkit | 24.81 | 22.33 | 76.25 | 64.97 | 404.6 |
| reader reasoning | swiftui | 19.96 | 1.19 | 9.84 | 8.93 | 211.1 |
| reader answer | swiftui | 20.12 | 1.20 | 9.63 | 9.37 | 286.3 |
| reader reasoning | appkit | 20.04 | 1.57 | 9.31 | 9.51 | 213.7 |
| reader answer | appkit | 20.01 | 1.54 | 9.68 | 9.25 | 286.5 |
| dense answer | swiftui | 94.85 | 93.10 | 887.44 | 1021.47 | 530.0 |
| dense answer | appkit | 193.41 | 192.86 | 1492.27 | 1865.56 | 616.6 |

Wall time includes the nominal streaming pauses and three seconds of completion settling.
Publication time includes awaiting preparation and regaining the main actor, so it is not a
pure parser benchmark. Peak RSS is cumulative within each process, including the preceding
reasoning phase for mixed answers. Instruments runs are separate from these timing runs.

### Geometry findings

- SwiftUI reader-held growth and completion: **0 pt** displacement for both channels.
- AppKit reader-held growth: **-65 pt** per channel; completion: **-0.5 pt**. The prototype fails
  the issue's 1 pt anchor criterion during growth. A successful test invocation is not a geometry pass.
- Narrow reflow after following: SwiftUI **0.01 pt**, AppKit **1,131.63 pt**. After reader-held
  streaming: SwiftUI **-0.21 pt**; AppKit's original anchor was unavailable, which is unqualified.
- Following answer completion moved a measured row by **-619 pt in both candidates**. Production
  HTML/SVG previews become available at completion, changing content height. This common movement
  is not evidence of a reader-owned jump: the held-reader case is measured separately. Exact
  bottom alignment and all completion shapes remain qualification work.
- The dense SwiftUI case reflowed within **0.06 pt**, but its streaming responsiveness failed.
  The dense AppKit case moved its measured row **-8,677.64 pt** at completion and **8,674.11 pt**
  on reflow, further evidence that the prototype's height/anchor policy needs correction.

The SwiftUI reader and dense logs each contained four `Geometry action is cycling between
duplicate values` warnings. Determine whether these originate in the fixture measurement hooks
or shared rendering before accepting the implementation; they are not waived by the anchor result.

### Instruments capture limits

A separate **CPU-only** Time Profiler capture of the dense SwiftUI run reproduced the stall
(92.03 s for the whole workload). Of 61,591 weighted CPU samples in the recorded interval,
97.8% were on the main thread. AttributeGraph appeared in 71.4% of sampled stacks and SwiftUICore
in 91.8%. Those inclusive stack-presence percentages overlap and are not exclusive CPU costs.
This supports investigating main-thread rendering/update work; it does not identify one offending
view or establish that a particular segment cap fixes it. The 60-second capture is a diagnostic
interval, not a complete allocation or retention qualification.

A separate mixed SwiftUI run was captured with Time Profiler plus Allocations. The 65-second
recording stopped before that instrumented answer completed. Its allocation statistics show
1,484,979,040 total heap bytes allocated and 75,594,864 persistent heap bytes at the recording
boundary. Those are allocation traffic and live tracked heap, not RSS or a final retention pass.
The 4 GiB JavaScript VM reservation is address space, not 4 GiB resident memory. Allocation stack
recording itself dominates many CPU samples, so these samples do not identify a rendering root
cause and their timings are excluded from the table above.

The matching AppKit attachment stalled before the first streaming phase and was terminated after
a stack sample showed XCTest waiting in its run loop. This is an inconclusive instrumentation run,
not evidence of a table-layout CPU hang. Complete, separate CPU and allocation captures through
post-completion settling, plus preview subprocess accounting, remain qualification gates.

### Interpretation and remaining checks

The initial evidence does **not** justify accepting the AppKit proposal or ruling out flat
SwiftUI. The native prototype needs anchor and reflow corrections before a fair acceptance run.
The flat SwiftUI candidate performs better on this mixed answer and preserves the measured reader
anchor, but the dense fence case still causes unacceptable main-actor delays. Neither is ready to
replace the production transcript. A container change alone has not completed #60.

A concrete follow-up hypothesis is **row complexity rather than source bytes alone**. The dense
repetition is 51 bytes: roughly 120 fenced code blocks plus paragraphs fit in a 6 KiB segment.
Both prototypes still lay out that whole segment as one row. Measure a rendered-block/complexity
cap or finer row units while preserving Markdown semantics and code identities; do not assume
that byte-bounded segmentation makes the work inside each visible row cheap. This is a hypothesis
from the fixture structure and timings, not an established profile attribution.

This experiment has not certified full-history reachability, real trackpad momentum, retained
focus during cell reuse, expanded tool details, code-action VoiceOver labels, the complete theme
and font matrix, actual inspectors, or the no-flash requirement. The UI-control bridge did not
reliably select the isolated comparison host; no manual accessibility pass is claimed. Replay
those checks in the selected production integration, retaining the existing navigation regressions.
The current tests record observations rather than asserting all of those acceptance criteria.

## Complexity-bound follow-up, 2026-09-27

The same Release fixtures now use packing capped at 16 top-level blocks or 16 work units, in
addition to bytes. A fence costs four units; nonblank prose/table lines cost one. Indivisible
lists/tables/quotes retain their semantics and are isolated when over the work threshold; this
is not a hard cap on every nested view. Code-identity HTML extraction moved into preparation,
sharing the existing HTML traversal. Prepared/scanner metadata and code literals now count
toward cache admission. See the [ADR-0091 amendment](../adrs/0091-content-bounded-transcript-layout.md).

Same machine, source content, window, cadence and fresh-process method as the initial run. The
smaller segments increase the initial row count to 434, the mixed final count to 5,288 and the
dense final count to 14,141. Container code is unchanged. These remain single-run observations.
The changes affect production preparation, but the timings below measure the comparison
containers, not the shipping paged transcript's complete composition.

| Scenario | Container | Wall s | CPU s | Sleep overrun p95 ms | Publication p95 ms | Peak host MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| dense answer | swiftui | 20.29 | 16.53 | 27.49 | 5.87 | 285.8 |
| dense answer | appkit | 73.89 | 72.33 | 169.10 | 376.54 | 442.6 |
| follow reasoning | swiftui | 20.32 | 3.96 | 9.73 | 13.83 | 227.2 |
| follow answer | swiftui | 19.64 | 11.06 | 8.17 | 3.85 | 377.3 |
| follow reasoning | appkit | 19.83 | 6.07 | 8.33 | 12.43 | 251.6 |
| follow answer | appkit | 23.17 | 19.30 | 62.61 | 57.67 | 388.7 |
| reader reasoning | swiftui | 20.24 | 1.36 | 9.50 | 9.31 | 206.6 |
| reader answer | swiftui | 20.16 | 1.48 | 9.25 | 9.25 | 280.4 |
| reader reasoning | appkit | 20.14 | 1.37 | 9.41 | 8.92 | 222.4 |
| reader answer | appkit | 20.17 | 1.40 | 9.68 | 9.48 | 291.3 |

Dense SwiftUI CPU fell about 82%, and peak host RSS fell from 530.0 to 285.8 MiB. Dense AppKit
also improved, but still consumed 72.33 seconds CPU and showed 169.10 ms p95 overrun. The result
supports complexity-aware packing; it does not establish a frame-rate or key-to-pixel guarantee.
The original actor-local main-thread counter has been removed: it could not detect HTML work
performed outside that actor, so its zero values were not evidence of off-main coverage.
The package tests prove full/incremental equivalence and settled-boundary stability. Three default-
budget 2 MiB cache cases (tiny empty fences, mixed tiny fences/prose and tiny table candidates)
retain the scanner, charge metadata, scan linearly, bound retained parses and verify front-cache admission independently of renderability. Oversized
entries are declined without evicting unrelated cached history. Table lines deliberately have ordinary line cost: weighting every tiny table line like
fence controls amplified metadata enough to threaten scanner retention. The table-density
regression covers this distinction without increasing the cache budgets again.

SwiftUI held the reader anchor at 0 pt through both channels and completion, with -0.02 pt reader
reflow. The native answer drifted -65.5 pt while reading, and its reasoning-growth anchor was
unavailable. Native completion shifted -0.5 pt per channel; reader reflow was -1.01 pt. Following
reflow was -0.23 pt for SwiftUI and +869.62 pt for AppKit. Dense reflow was -0.02 pt for SwiftUI
and unavailable for AppKit. Most following completion anchors were unavailable, so no completion-
geometry pass is claimed. Exact bottom alignment is not certified by the requested follow mode.
SwiftUI still logged three geometry-cycling warnings in the dense run.

A separate CPU-only Time Profiler run completed the dense workload in 21.80 seconds wall and
19.20 seconds CPU. Across the recorded interval, 20,130 weighted samples put 95.3% on the main
thread; SwiftUICore and AttributeGraph appeared in 88.2% and 70.9% of inclusive stacks. These
percentages overlap. The absolute workload is much smaller, but UI update/layout work still
predominates. This supports reducing view work, not moving UI layout off MainActor. The capture
includes setup and settling and is not an allocation or input-latency certification.

ADR-0099 remains proposed. The native estimate/anchor policy and SwiftUI geometry cycling still
need investigation; supported-OS, input, accessibility, allocation/retention and no-flash gates
remain open. Neither this improvement nor successful workload assertions certify Delivery 3.

The code-height regression helper now measures the inner rendered content inside a fixed outer
host. This removes window/content sizing feedback during asynchronous code preparation, while
retaining its collapse/expansion assertions and adding a fixed-window assertion. Three fresh-
process chrome-suite repetitions passed. No timing threshold or original height assertion was
relaxed to address the reproduced AppKit constraint-loop crash.

## Initial verification

`make verify CONFIG=Release` passed: lint, package tests, the app test plan (548 passed,
three opt-in skips, one existing expected ScrollPosition limitation), and the Release app build.
All six opt-in uninstrumented scenario invocations passed their workload integrity assertions.
The website's 21 unit tests, both builds and content checks passed. The first sandboxed website
build hit an EMFILE watcher limit; the rerun with a larger per-process file-descriptor limit passed.

These green checks do not override the measured performance and geometry failures above.

## Decision

Pending owner review. Keep ADR-0099 proposed and Delivery 3's qualification gates open.

## Follow-up verification

`make verify CONFIG=Release` passed on the final implementation: lint, package tests (including
32 Bleet tests), 549 app tests passed, three opt-in skips, the existing expected ScrollPosition
limitation, and the Release app build. All six final uninstrumented workload-integrity runs and
the final CPU-profile run passed. The code-chrome suite also passed three fresh-process
repetitions after fixing its measurement host. Website unit tests, both site builds and built-
content checks cover the updated reference and ADRs. Performance and geometry acceptance remain
separate from these successful test invocations.


## Review checkpoint: qualification remains open

This checkpoint publishes the review changes for inspection, not container acceptance.
The cache and identity changes passed `make verify CONFIG=Release` with 551 app tests,
three opt-in skips and the existing expected ScrollPosition limitation. Subsequent changes
to the opt-in comparison harness have not completed the full verification gate.

The stricter navigation probe still fails. Runs showed requested scrolling that was not
reflected in viewport movement, anchor loss during reflow, and one stalled Debug run whose
app process reached approximately 3.5 GB resident memory before it was stopped. These are
unresolved observations, not established production defects: event injection, sizing and
container behavior still need to be isolated. Historical timing tables below their dated
headings do not qualify this revised harness. No current container winner, bounded-memory
qualification or Delivery 3 completion is claimed. ADR-0099 remains Proposed.


## Allocation and evidence correction

Prepared segment chunks now grow on demand rather than reserving 64 elements for the first
segment. Admission charges actual allocated element capacity plus a per-live-segment string
allowance. Capacity accounting updates with copy-on-write mutations, and snapshots remain
independent. Small-cache regressions use 2,400 / 1,800 byte actor limits and 1,200 / 600 byte
front-cache limits instead of 48,000 / 24,000. Dense multi-chunk replies still need metadata
budgeting; removing the small-reply floor is not proof of a lower worst-case 2 MiB cost.

The removed actor-local thread counter is not replaced with another assertion inside the same
actor. Only profiling across the actual preparation/rendering call paths can establish how much
work occurs on the main thread. Earlier local verification and remote CI are separate evidence;
the PR body identifies the applicable checkpoint and outstanding checks.


The reflow CI failure on `32fe141` was not just an ink threshold miss: the test requested
980 pt and recorded a 65 pt hosting view and window. The reflow fixtures and comparison
window now install the SwiftUI host inside an AppKit viewport owner instead of making the
hosting view the window's direct content root. Existing width, scroll-fill and visible-ink
assertions are unchanged. This addresses the observed test-host sizing failure; it does not
establish a cause for all earlier comparison failures or qualify either container.


## Follow-up scope: production hosting and unresolved failures

`GOATApp` creates the transcript window through SwiftUI `WindowGroup`, applying a minimum
880 by 560 point frame around `ContentView`; `ContentView` supplies `NavigationSplitView`
chrome around `ChatView`. No production source explicitly assigns a transcript `NSHostingView`
to `NSWindow.contentView`. About uses `NSHostingController` with its own window and has no
transcript; sheets are SwiftUI-managed. This source audit does not prove that SwiftUI's internal
hosting implementation can never resize unexpectedly. A separate direct-root regression now
keeps a transcript in a direct `NSHostingView` with the production minimum-size contract and
asserts requested widths through font and width changes.

The earlier `reflowRestoresTheReadersAnchor` pending-request failure was not root-caused.
Its rerun and local repetitions passed; its additional diagnostics remain. It is not attributed
to the later 980-to-65 point host contraction. A repeat failure still needs investigation.

Tracked qualification failure Q1: the AppKit Debug navigation run stalled after reporting
`following_gap_pt=0`, before completing the first width/font reflow, with approximately 3.5 GB
app resident memory. That observation predates shared preparation and per-message invalidation.
The cause remains unproved. Q1 belongs to issue #60's container qualification, not to completed
Delivery 3 work; subsequent results must explicitly state whether the run reaches both reflows.


### Input calibration correction

Directly calling `scrollWheel(with:)` with a fabricated began phase is not equivalent to
feeding a native gesture event stream. On the static AppKit control, a sampled stalled call
was inside AppKit's gesture tracking loop waiting for queued events; later direct changed-phase
calls were not a valid substitute. Those earlier residuals are not container evidence.

The probe now sends unphased pixel-wheel input and first runs the identical sequence against a
static flipped AppKit document with no SwiftUI, preparation or anchor correction. The standalone
control delivered all 60 pt inputs exactly (zero error). Each candidate run records its own
control result too. The summary is named `wheel_growth_max_residual_pt`, replacing the misleading
`gesture_growth_max_residual_pt`; hardware trackpad gestures and momentum remain unqualified.
The initial-offset regression now explicitly appends a row after the non-gesture move and records
`initial_offset_growth_drift_pt`, separately from direct-move replay and concurrent wheel input.


### Release navigation results after the review fixes (2026-09-28)

Same qualification host as above, fresh Release processes, 48 mixed history rounds and a
2 MiB live answer. These are navigation probes, not FPS or full-app qualification. The static
candidate input checks were separate follow-up runs with the same fixture and containers;
`GOAT_COMPARE_INPUT_ONLY=1` makes that isolation reproducible. Both delivered input with zero
error. Thus the growth residuals below cannot simply be dismissed as absent input delivery.
Hardware event dispatch and trackpad momentum are still outside this synthetic test.

All geometric tolerances are 1 pt. **Unmeasured means no result, never a pass.**

| Check / summary field | AppKit | SwiftUI |
| --- | --- | --- |
| `input_control_max_error_pt` (static AppKit control) | 0, pass | 0, pass |
| `candidate_static_input_error_pt` (follow-up) | 0, pass | 0, pass |
| `direct_move_drift_pt` (main run) | 0, pass | 0, pass |
| `direct_move_drift_pt` (static-input follow-up) | 0, pass | 83, **fail** |
| `initial_offset_growth_drift_pt` | 0, pass | 677, **fail** |
| `wheel_growth_max_residual_pt` | 1, pass | 60, **fail** |
| Wheel samples / missing anchors | 192 / 0 | 192 / 0 |
| `following_gap_pt` | Unmeasured: resource abort | 0, pass |
| Reflow: 820 pt width / 20 pt font | Unmeasured: resource abort | 39.318 pt, **fail** |
| Reflow: 1180 pt width / 14 pt font | Unmeasured: resource abort | 38.640 pt, **fail** |
| Resident bytes at growth completion | 1,793,540,096 | 351,109,120 |
| Overall probe | **Aborted / unqualified** | **Failed / unqualified** |

The SwiftUI direct-move discrepancy is preserved rather than selecting the passing sample.
The failures establish behavior under this probe; they do not identify a private SwiftUI cause.
The new static-input assertion is now also part of the full navigation probe.

**Q1 reproduced:** AppKit exceeded an external runaway guard after the wheel/growth summary and
before the bottom-alignment result. The sampled host RSS was 3,274,976 KiB (about 3.12 GiB),
so the runner terminated that test host. The guard is resource protection, not an accepted
product memory budget. No following/reflow result can be inferred from that aborted run.
This is a more precise observation than the older 3.5 GB paragraph, and remains tracked in #60.
Per-message invalidation and the smaller front-cache cap did not eliminate the failure; its cause
is still unproved. No container winner or Delivery 3 completion follows from these measurements.

Validation for the review implementation: full local `make verify CONFIG=Release` passed,
including the quarter-cache accounting and direct-host regressions. The explicit shared-window
reuse and historical-invalidation/offscreen-release tests passed. The opt-in navigation runs
above failed as recorded; their assertions are not suppressed by the normal test-plan skips.
