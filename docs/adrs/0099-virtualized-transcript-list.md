# ADR-0099: Virtualized transcript list

Status: Proposed · 2026-09-27
If accepted, supersedes the admission window and endless paging of
[ADR-0091](0091-content-bounded-transcript-layout.md) (its decision, its 2026-09-22 amendment and
the segment-level windowing of its segmented rendering amendment), section 4 of
[ADR-0094](0094-pure-swift-syntax-highlighting-and-tool-diffs.md). Retains the single-owner native
scroll contract of [ADR-0097](0097-appkit-transcript-scroll-executor.md). Refines
[ADR-0002](0002-ui-architecture.md) and [ADR-0028](0028-measured-bounded-rendering-and-fullscreen-backing.md).
Proposed under [#60](https://github.com/goatsoft/GOAT/issues/60) with
[#54](https://github.com/goatsoft/GOAT/issues/54) section 2, subject to comparison and qualification.

Current comparison and migration qualification is tracked in
[#86](https://github.com/goatsoft/GOAT/issues/86), transferred from #60. Production qualification
remains in [#85](https://github.com/goatsoft/GOAT/issues/85). This transfer does not accept the ADR.

## Shipping amendment, 2026-10-15

GOAT 0.1.4 ships one part of this proposal: the transcript's outer stack is a `LazyVStack`
([#95](https://github.com/goatsoft/GOAT/pull/95), production qualification in #85), so only rows near
the viewport are laid out. The message and segment windows of ADR-0091 and the single native scroll
executor of ADR-0097 are retained. Everything in the transcript, loaders and progress included, sits
in the one lazy stack: a plain stack around it measured it in full again (Delivery 3 reasoning went
from 19 s to 78 s).

On the macOS 26 Mac Studio, Delivery 3 streams 2 MiB of expanded reasoning in 19.4 s wall and 4.1 s
CPU (main: 153.6 s), and a 2 MiB answer in 19.1 s and 5.7 s CPU, with a p95 frame delay of about
10 ms. The navigation owner was adapted to a lazy stack:

- Content changes issue no request while the reader owns the viewport; the lazy stack keeps its
  topmost visible row in place. An anchor that was in place and moved with layout above it (an
  anchor below the viewport's top edge, or a segment) is put back explicitly.
- Frames belong to the mounted instance that measured them, a returning instance reports its frame
  again, and frames measured outside the content space are ignored.
- Commands are planned and verified against the scroll view's own geometry and re-checked after
  each command, since SwiftUI reports geometry with its next update.
- A target the lazy stack has not laid out is revealed by an estimate from laid-out rows. When no
  row meets the viewport at all (the lazy stack can keep a row's old place after a drastic size
  change while it was unmounted), a SwiftUI scroll to the right row is the last resort; its landing
  is the executor's move, not the reader's.
- Loaders page only once no move is pending, the scroll view is still at that end and the kept row
  or segment has reported where it is. Settled messages in the window are prepared ahead of the
  lazy stack, and only the jump button animates.

This amendment does not accept the rest of the proposal (a flat list without admission windows).

## Current proposal refinement, 2026-10-13

The test-only native table fallback is retired under #86 after its unresolved Q1 memory growth
beyond 3 GiB. Historical comparison evidence remains in the reference. The flat SwiftUI candidate
now retains one-shot native scroll ownership from ADR-0097: a persistent SwiftUI position target
replayed after direct reader movement. Therefore any future acceptance would refine ADR-0097's
executor instead of superseding its ownership principle. The candidate has passed one local
startup/growth/reflow probe, but committed-source repetition, supported-OS and manual qualification
and owner acceptance remain required. The original proposal and historical reasoning below remain
as context; this refinement does not migrate the shipping container.

## Context

The transcript is a SwiftUI `ScrollView` over a non-lazy stack of fully measured rows. ADR-0091
bounded that stack's layout cost by admitting a window of at most 40 messages and about 16 KiB of
display source, and paged the window when a loader at either edge came into view. #60 Delivery 3
applied the same scheme inside long replies and expanded reasoning: each shows a window of at most
32 segments and 16 KiB, paged by loaders of its own. ADR-0097 added a single scroll executor so the
navigation owner (`TranscriptViewport`) could restore the reader's anchor after each page.

In use this is not a scrolling experience. Content appears and disappears under the reader:

- **Pages replace content mid-gesture.** Loaders fire at 1 % visibility, during a trackpad gesture
  or its momentum. Paging adds content above the viewport or removes it, and the only thing holding
  position meanwhile is SwiftUI's size-change anchor, which keeps the document's top fixed rather
  than the reader's content. The owner's anchor restore is blocked while the reader scrolls, and the
  next gesture phase cancels it as reader input. What the reader was looking at jumps by the height
  added or removed, and at best snaps back when the momentum ends.
- **Windows are small, so swaps are frequent.** One long reply fills the message budget alone and
  shows about three 6 KiB segments. Reading a long reply or chat is a sequence of swaps.
- **Paging replaces rather than grows.** Earlier and Later move a window by half its length and drop
  the other half, so reading back over what was just read rebuilds it.
- **A swap is several asynchronous steps.** Loader visibility, the owner's new window, off-main
  segment preparation, layout, then a restore retried up to 12 times at 50 ms. Intermediate frames
  are visible, and an abandoned restore loses the reader's place.
- **The scrollbar describes the window, not the chat,** and loader rows appear and vanish with it.

The paging tests measured stability for a programmatic scroll followed by idle, never for a live
gesture with momentum, which is where every failure above occurs. Windowing was a layout-cost
measure (ADR-0091's own context), not a scrolling design, and repairing each swap afterwards
(ADR-0097) cannot make it smooth. The preparation work built for #60 (segmentation, incremental
preparation, caches, code-block identities) is sound; the presentation around it is the problem.

ADR-0002 allows AppKit where SwiftUI falls short, decided by measurement. A lazy stack of whole
messages does not bound a huge row. A flat stack of bounded segments is a different candidate and
needs measurement before ruling it out. Variable-height estimation and retained programmatic
scroll targets are risks to test, including the interactions documented in ADR-0097.

## Comparison before acceptance

The owner requested a measured comparison under #60 before selecting the container. This ADR
remains **Proposed**. Compare a flat `LazyVStack` of bounded segment rows using modern SwiftUI
scroll APIs with the proposed `NSTableView`, using identical production content views, preparation,
fixtures and publication cadence. The current paged implementation's failures do not by themselves
rule out a flat SwiftUI list. In particular, segmentation bounds a huge message in either candidate.

The test-only comparison and its qualification limits are documented in
[Transcript container comparison](../reference/transcript-container-comparison.md). Neither
candidate replaces the shipping transcript until the results have been reviewed. Keep the existing
regression tests until equivalent behavior is demonstrated, including keyboard and momentum input.

The initial comparison does not validate the proposed native height/anchor policy: its prototype
moves the reader during growth and reflow. Both candidates also fail the dense short-fence
responsiveness case. A 6 KiB row can contain roughly 120 code blocks, so source-byte bounds alone
are insufficient evidence of cheap visible-row layout. Row granularity, geometry corrections and
complete qualification remain open before accepting this decision.

The complexity-bound follow-up reduced dense SwiftUI wall time from 94.85 to 20.29 seconds and
CPU from 93.10 to 16.53 seconds. Dense AppKit improved to 73.89 seconds but still stalls. This
supports finer segment packing without selecting a container. Those measurements used the original prototype, whose deferred measurements, unconditional
restoration and per-cell presentation did not implement the proposed native policy. Its 870 pt
following reflow and 65.5 pt reader-growth drift are not evidence against that policy. The revised
harness measures overscan before display, applies geometry deltas to the current origin, retains
height variants across reflow and inherits one window presentation environment. It adds strict
concurrent-input and direct-move regressions for both candidates. The reference separates the
historical measurements from review follow-up results; acceptance and full qualification remain open.

## Candidate direction after review

Recommend the flat SwiftUI segment list for the production migration, subject to owner acceptance
and the remaining qualification gates. The synchronous Markdown spacing fix in
[PR #84](https://github.com/goatsoft/GOAT/pull/84) removes the reproduced wheel/growth residual;
its strict navigation replay passes growth, input, following and reflow checks. Separate mixed and
dense replays complete both 2 MiB streams. These results supersede the earlier failed SwiftUI
navigation observations, but do not qualify hardware momentum, supported-OS accessibility or
full-app frame time. ADR-0099 remains Proposed and the shipping container remains unchanged.
The SwiftUI follow-up prepares one estimated viewport ahead in either direction
(up to 64 neighbouring rows per side), uses actual scroll-target visibility rather than lazy-row
creation, and uses one bottom size-change anchor while following. Explicit Latest and reflow
restoration use the same SwiftUI scroll-position binding; there is no per-publication bottom command.
Reader reflow restoration captures the visible row and its pixel offset from synchronous native
clip-bounds notifications, then restores its measured document offset once
through the binding. The initial bottom anchor is disabled after placement, and a reader ownership
transfer clears the previous command from the binding. Native observation only reads geometry;
it does not scroll or add an executor. Width/font guards retain the pre-reflow snapshot until the
restoration transaction finishes. Input and geometry ordering still require qualification, especially during
hardware momentum.

The production migration must also prepare nearby user Markdown through the same bounded
whole-document caches before those rows enter the viewport. The comparison already does this;
omitting it would reintroduce cold placeholder-to-rich height changes and invalidate comparison
parity. The overscan regression covers both assistant segments and user messages.

Preparation stays on its existing actor. A cold miss still retains plain text as an exceptional
fallback; prefetch aims to avoid showing it during ordinary scrolling. Do not add synchronous
main-actor parsing merely because a row meets the work score: that score is not a time guarantee.
Prepared settled segments use their final presentation while only provisional segments stream.
Oversized fence pieces stay source-only because their synthetic closures do not make complete
preview documents. Full-app completion, artifact lifecycle and accessibility still need validation.

Keep the native prototype as a fallback investigation. Its offscreen-streaming memory defect is
unresolved; the native design below is conditional on qualification and acceptance. No existing
production window, loader, navigation owner or executor is retired by this experiment.

## Native fallback design, pending comparison

### One list of block rows, all in the document

The transcript is a virtualized AppKit list: a view-based `NSTableView` with one column, no header,
no selection highlight and no row separators, inside the `NSScrollView` it manages, wrapped in one
`NSViewRepresentable` (`TranscriptList`). SwiftUI keeps the surrounding shell (reading column,
composer, jump control, inspectors).

The chat becomes a flat sequence of **block rows**, every one of them part of the document:

- a user message;
- an assistant message's header and status;
- a reasoning disclosure header, then, while it is open, each reasoning segment (the bounded
  excerpt while it streams, or every segment when it shows all);
- each answer segment;
- a tool activity group;
- a message footer (actions, statistics);
- compaction and the live progress row.

Answer and reasoning segments are exactly those of #68/#69/#78 and #80 (`MarkdownSegmentation`,
`ThinkingSegmentation`), with their global indices. Packed answers can produce a few hundred
rows at 2 MiB, while expanded reasoning with short blocks can produce several thousand. Both
shapes must be measured. There is no admission window, no segment window, no loader and no
"part n of m". Reasoning and text above
2 MiB become plain-text rows in the same list, bounded per row, with full-source copy unchanged.

Every row has a stable identity: the message ID, the row kind, and the segment index where there is
one. An edit, trim or restore that starts a new text revision epoch replaces that message's
segment rows; appended text only adds rows or changes the tail row.

### Only nearby rows exist as views

The table creates cell views only for visible rows and an overscan of about one viewport above and
below, and reuses them by row kind. A cell hosts the existing SwiftUI row view in an
`NSHostingView` with the transcript's environment (model, theme, syntax palette, code-block scope),
so rows keep their current rendering: `MarkdownSegmentView`, code-block chrome, reasoning prose,
tool cards and footers. Table updates are applied in batches on the main actor, never from inside a
table delegate callback (ADR-0028's reentrant-delegate warning).

Segment preparation follows the same range: `MarkdownSegmentCache` and the reasoning preparation
parse rows entering the overscan and release parses well outside it, under their existing budgets.
Rows not yet prepared lay out as their plain text, never as a placeholder or an empty row.

### Heights are cached, estimated and corrected in place

A height cache keys each row's height by its identity and content revision, the column width and
the fonts, and is bounded by count and cleared on memory pressure with the other rendering caches.
A row not yet measured uses an estimate from its kind, byte and line counts. Rows are measured when
they enter the overscan, within a per-frame time budget, visible rows first.

The reader's position is an anchor: the first visible row and the distance from its top edge to the
viewport's. Whenever rows above the anchor change height, are inserted or are removed (a
measurement replacing an estimate, a fold, a width or font change), the table applies the change
and moves the clip view's origin by the same amount **in the same layout pass, before the frame is
drawn**. What the reader sees never moves. This holds during a gesture and its momentum: the scroll
view continues from the corrected origin. If a supported OS does not continue momentum across such
a correction, height changes above the anchor are held at their previous value until scrolling
stops, and applied then with the same correction. There is no deferred request, no retry and
nothing a gesture can cancel.

Changes below the viewport need no correction.

### Following, reading and jumping

The transcript either follows the latest output or belongs to the reader, as in #54. Following
holds while the end of the document is within the bottom tolerance; any reader scroll away from it
hands the viewport to the reader, and scrolling back to the end, or Latest, resumes following. While
following, growth of the tail row keeps the document's end in view in the same pass, coalesced at
display cadence (ADR-0028). While the reader owns the viewport, nothing moves what they see:
streaming output lengthens the document below them.

Jumps (Latest, restoring a chat, find, a message link) scroll to a row and offset directly. A row
far from the measured region uses estimates on the way and is corrected by the anchor rule when it
lands. Restoring a chat places its saved anchor before the list is first shown.

### What this retires

- `TranscriptWindow` admission and paging, `ReplyWindow`, segment windows, `SegmentLoader`, held
  and kept windows, `TranscriptSegmentOwner`, and the message loaders.
- `TranscriptViewport`'s window, request, retry and abandonment lifecycle. What remains is the
  follow or reader ownership state and the anchor.
- `TranscriptScrollExecutor` and its bounds attribution (ADR-0097). The table positions itself;
  there is no SwiftUI `ScrollView` whose targets need working around.
- `TranscriptTextPartsView`'s pager above 2 MiB.

Segmentation, incremental preparation, revisions, the prepared-document caches, segment spacing,
code-block identities and chrome, syntax colours, highlight caches, reasoning folding and the
reading column stay, as row content and row inputs.

Loading history from the database page by page (#60 C2) remains separate work: it feeds the row
model and does not change presentation.

### Accessibility, keyboard and selection

Rows expose their content to VoiceOver in order, including every segment of a long reply; there
are no loader elements. Page Up/Down, Home, End and arrow keys scroll natively. Text selection stays
within a row, as it is within a view today; copying a whole reply or chat is #60 D7.

## Consequences

- Scrolling is native `NSScrollView` scrolling over the whole chat. Nothing is swapped in or out
  under the reader, and the scrollbar describes the whole conversation.
- Layout cost is bounded by the rows near the viewport, not by a content budget, so the 40-message
  and 16 KiB limits and their paging behaviour disappear. Very tall single rows are still bounded by
  segmentation, code-block collapse and per-row plain-text limits.
- Memory held by views is bounded by the overscan; prepared content keeps its existing byte budgets.
- The transcript's scroll container moves from SwiftUI to AppKit. Row content stays SwiftUI.
- #60: Delivery 3's rendering items stand. C1 (paging jumps and eviction) is resolved by removal
  rather than by growth and prefetch. B2 and D4 reduce to scrolling to a row. Measurements 4a and 4b
  are replaced by the validation below.
- #54 section 2 is rewritten around the list: one owner of follow or reader state, no executor.
- Tests of windows, loaders, held windows and executor attribution are removed with the code they
  cover.

## Validation

- **Input and anchor tests.** Automated probes calibrate unphased pixel-wheel input against a
  static control and each candidate. Both sample native row-marker bounds after a layout/settle
  interval; asynchronous SwiftUI geometry reports are not measurement input. During insertion,
  folding, remeasurement and growth, anchor-row displacement after accounting for requested input
  stays within 1 pt. Synthetic gesture phases sent directly to `scrollWheel(with:)` are invalid:
  AppKit can enter a tracking loop waiting for queued events. Actual trackpad gestures, momentum
  and the pixels below the anchor remain separate manual qualification.
- **Reachability and honesty.** Every message and every segment of a 2 MiB answer and 2 MiB
  reasoning is reachable by scrolling alone; the document height matches the sum of row heights
  within the estimate tolerance once measured.
- **Streaming.** Following keeps the end in view at display cadence; a reader who owns the viewport
  sees no movement while output arrives; completion and reasoning folding move nothing the reader is
  reading.
- **Width and fonts.** Resizing, inspectors and font changes keep the anchor row in place.
- **Qualification (manual and Instruments), tracked in #85 and #86 with historical evidence on #60.** Trackpad and mouse scrolling through
  long chats and 2 MiB replies, momentum included; keyboard and VoiceOver; themes and Reduce Motion;
  frame time, main-actor time and memory while scrolling and while a 27B model streams.

## Alternatives considered

- **Keep windowing and fix its behaviour.** Never swap during a gesture, correct position in the
  same pass, grow instead of replace, raise the budgets. Rejected as the design: it keeps loaders,
  swaps and a scrollbar that describes a window. Its synchronous correction rule is kept here.
- **Flat SwiftUI `LazyVStack` with bounded segment rows.** Under comparison. Segmentation bounds
  individual rows; modern position, geometry and phase APIs handle navigation. Remaining questions
  are height-estimate corrections during momentum, retained views and real content layout cost.
  ADR-0097's existing regressions must also be replayed without mixing scroll writers.
- **SwiftUI `List`.** Bridges to `NSTableView` without exposing height caching or in-pass origin
  correction, and imposes list styling and selection semantics.
- **`NSCollectionView`.** Equivalent virtualization with more layout machinery than one column
  needs. `NSTableView` is simpler for a single column of variable-height rows.
- **One `NSTextView` (TextKit 2) document for the whole chat.** Selection across messages would be
  free, but code-block chrome, tool cards, disclosures and previews would become text attachments,
  discarding the SwiftUI row views built so far.
