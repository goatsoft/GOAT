# ADR-0099: Virtualized transcript list

Status: Proposed · 2026-09-27
Supersedes the admission window and endless paging of
[ADR-0091](0091-content-bounded-transcript-layout.md) (its decision, its 2026-09-22 amendment and
the segment-level windowing of its segmented rendering amendment), section 4 of
[ADR-0094](0094-pure-swift-syntax-highlighting-and-tool-diffs.md), and
[ADR-0097](0097-appkit-transcript-scroll-executor.md). Refines
[ADR-0002](0002-ui-architecture.md) and [ADR-0028](0028-measured-bounded-rendering-and-fullscreen-backing.md).
Delivered under [#60](https://github.com/goatsoft/GOAT/issues/60) with
[#54](https://github.com/goatsoft/GOAT/issues/54) section 2, in the next release.

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

ADR-0002 allows AppKit where SwiftUI falls short, decided by measurement: the transcript is that
case. A lazy SwiftUI stack does not bound a huge row, and it re-estimates heights of variable rows
while scrolling upward, which moves content. SwiftUI keeps programmatic scroll targets that
ADR-0097 had to work around.

## Decision

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
`ThinkingSegmentation`), with their global indices. A 2 MiB reply is a few hundred rows; there is
no admission window, no segment window, no loader and no "part n of m". Reasoning and text above
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

- **Gesture-level tests.** Native tests send real scroll-wheel events with gesture and momentum
  phases to the hosted list, not programmatic scrolls followed by idle. During a gesture and its
  momentum, while rows above the viewport are measured, folded, inserted or removed, and while
  output streams below, the anchor row's screen position changes by at most 1 pt and pixels below it
  do not change.
- **Reachability and honesty.** Every message and every segment of a 2 MiB answer and 2 MiB
  reasoning is reachable by scrolling alone; the document height matches the sum of row heights
  within the estimate tolerance once measured.
- **Streaming.** Following keeps the end in view at display cadence; a reader who owns the viewport
  sees no movement while output arrives; completion and reasoning folding move nothing the reader is
  reading.
- **Width and fonts.** Resizing, inspectors and font changes keep the anchor row in place.
- **Qualification (manual and Instruments), recorded on #60.** Trackpad and mouse scrolling through
  long chats and 2 MiB replies, momentum included; keyboard and VoiceOver; themes and Reduce Motion;
  frame time, main-actor time and memory while scrolling and while a 27B model streams.

## Alternatives considered

- **Keep windowing and fix its behaviour.** Never swap during a gesture, correct position in the
  same pass, grow instead of replace, raise the budgets. Rejected as the design: it keeps loaders,
  swaps and a scrollbar that describes a window. Its synchronous correction rule is kept here.
- **SwiftUI `LazyVStack`.** Rejected: it does not bound a huge row, re-estimates variable heights
  while scrolling upward (content moves), and keeps the SwiftUI scroll-target behaviour ADR-0097
  had to work around.
- **SwiftUI `List`.** Bridges to `NSTableView` without exposing height caching or in-pass origin
  correction, and imposes list styling and selection semantics.
- **`NSCollectionView`.** Equivalent virtualization with more layout machinery than one column
  needs. `NSTableView` is simpler for a single column of variable-height rows.
- **One `NSTextView` (TextKit 2) document for the whole chat.** Selection across messages would be
  free, but code-block chrome, tool cards, disclosures and previews would become text attachments,
  discarding the SwiftUI row views built so far.
