# ADR-0104: Single-stack transcript

Status: Accepted · 2026-10-15 (0.1.4)

Supersedes the reader-facing windowing of [ADR-0091](0091-content-bounded-transcript-layout.md), [ADR-0102](0102-paged-reader-history.md) (its visible paging; the bounded record cache stays) and [ADR-0103](0103-dense-reply-layout-admission.md). Completes [ADR-0099](0099-virtualized-transcript-list.md). Retains [ADR-0097](0097-appkit-transcript-scroll-executor.md) ownership.

## Context

ADR-0099's lazy stack shipped inside the earlier windowing. The transcript still held a window of messages and paged it through "Earlier messages" and "Later messages" loaders; a long reply showed a window of its segments with "Earlier text" and "Later text"; open reasoning had "Earlier reasoning" and "Later reasoning" as well as "Show recent reasoning" and "Show all reasoning"; and text above the rich limit showed "Earlier text", "Later text" and "Latest text" parts. Each layer moved the reader's place, needed its own anchor bookkeeping, and was the source of most navigation defects found while qualifying 0.1.4. The owner's direction for 0.1.4: one lazy stack and nothing else, with the best reading experience.

## Decision

1. **One lazy stack of items.** The transcript lays out every loaded message as items of one `LazyVStack`: a short message is one item; a reply is a head (avatar and reasoning disclosure), items of about 2 KB of reasoning segments while the reasoning is open, one item per answer segment, and a tail (tools, error, actions). Text above the rich limit is one item per bounded plain-text part. The lazy stack only lays out items near the viewport, so a reply of any length scrolls virtually. There is no message window, segment window or loader.
2. **History loads invisibly.** The bounded record cache from ADR-0102 stays. When the first or last loaded item comes within a viewport of being shown, the adjacent database page loads; while it loads, a progress row shows at that end. The reader's anchor (item and offset) is restored after records are added or evicted, so nothing they see moves.
3. **Reasoning is folded or full.** Folded, it is one "Thought for 12s" line. Open, it shows all of it, segment by segment, as items. Streaming reasoning is open and followed while the transcript follows; it folds on completion as before (unless the reader chose, or folding is off). "Show recent" and "Show all" are removed.
4. **Answer segments prepare as they come into view.** Each answer item asks for its segment's parse when it appears; preparation keeps a margin around the segments shown and releases distant parses, bounding retained content without a visible window. Reasoning segments are plain text and need no parse.
5. **Anchors name items.** The navigation owner's anchor is an item and an offset into it. Find, reveal and restoration resolve a message and byte offset to its segment item.
6. **The streaming caret marks only output that is still arriving**: the last answer item of the active reply of a streaming chat.

## Consequences

The windowing types (`TranscriptWindow`, `ReplyWindow`, `SegmentWindow` windows, `SegmentLoader`, the segment-window bookkeeping and the paged text parts view) are removed. The scroll bar describes the loaded records rather than one window. Tests that asserted paging behaviour are replaced by tests of items, invisible history loading, anchor restoration across loads and evictions, reasoning fold or full, and the caret. Release qualification repeated Delivery 3 on the macOS 26 Mac Studio (see the [transcript performance reference](../reference/transcript-performance.md#single-stack-delivery-3-2026-10-15)). Showing a full viewport of a streaming reply costs more than the windowed transcript, which laid out only its latest two segments: under the 2 MiB stress workload, answer 22.4 to 23.9 s wall and 18.3 to 20.7 s CPU (windowed 19.1 s, 5.5 s) and reasoning 24.0 to 24.3 s and 13.2 to 13.5 s (19.3 s, 4.1 s). To keep that cost bounded, reasoning pieces and reasoning items are about 2 KB, segment items are built from values, a segment coming into view parses at the text already prepared, and a stream arriving faster than anyone reads (over 4 KB per sample) is sampled every 400 ms instead of 120 ms.
