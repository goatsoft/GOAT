# ADR-0056: Bounded rendering caches and responsive I/O

Status: Accepted · 2026-09-07 · Refines ADRs 0010, 0015, 0043, 0045 and 0055.

## Context

The Kid performance audit found repeated Mermaid shell work during SwiftUI updates, repeated WebKit policy compilation, web-view destruction when switching to Source, an idle audit timer, blocking socket I/O on Swift's cooperative executor, and whole-message reads/writes for streaming checkpoints. Existing Markdown and image caches already avoided repeated parsing and decoding, but did not respond to memory pressure. These are source-level findings; they do not establish a frame-rate comparison with competing products.

## Decision

Cache only derived rendering data with explicit keys, admission rules and invalidation. Preserve SQLite and filesystem stores as the durable sources of truth.

- Paddock prepares HTML/SVG/Mermaid shells on an actor. Its LRU retains at most four artifacts and 8 MiB of source plus generated UTF-8 bytes. Artifact identity/content and Mermaid theme/appearance determine reuse. Inputs above 2 MiB, or Mermaid above 100,000 bytes, offer Source/export instead of starting a rich preview. These are admission limits, not total WebKit memory guarantees.
- Cache immutable compiled WebKit rules, keyed by deterministic rule JSON. Concurrent requests share compilation; failures can retry. There are two rule documents today. They contain no user content or permissions. Network policy still runs on every new document and every policy change.
- Within the currently presented artifact, switching to Source blanks its document and retains only the web-view shell. Returning to Preview reloads the document. No hidden script is intentionally kept running. Policy changes recreate the view; revocation invalidates pending compilation and prevents the retired coordinator from reloading content. Dismantling blanks the document while keeping rules installed until release.
- The shared app presentation component uses this path for inline Mermaid too. Code previews have independent vertical scrolling and pass known languages to syntax highlighting. Markdown normalization moves into the existing parse cache, outside SwiftUI body evaluation.
- macOS memory-pressure notifications purge owned Markdown, image and HTML-shell caches. Their eviction never deletes records, attachment files or user documents. Source-byte limits are accounting proxies, not exact process resident-memory limits. Live view state, WebKit processes and third-party highlighter state are separate.
- Hoofprint consumes coalesced JUDAS event notifications, waits 200 ms only after activity, and publishes one bounded batch. Its task unregisters on release. The audit queue and overflow notice remain authoritative; no idle polling timer is required. Reading older activity no longer forces scrolling to the newest entry.
- Hitch's bounded blocking POSIX reads/writes run on a dedicated concurrent dispatch queue. At most eight admitted clients each own one I/O operation. Swift tasks suspend while the queue works; shutdown still interrupts descriptors, and the owning request closes them. Frame parsing searches only newly received bytes.
- SQLite checkpoints use one parameterized, cached `UPDATE` statement for text/thinking. Completion, ratings, tools and metadata are untouched. No schema, WAL mode, durability setting, checkpoint cadence or database authority changes.
- The Xcode project pins `ARCHS=arm64`, matching the existing Apple-Silicon-only scope and avoiding an unused Intel Release slice.
- Graph rendering computes camera projection once per node before depth sorting. The professional Activity Log no longer runs the decorative 30 Hz wordmark animation.

## Why not NSCache or a second database cache?

`NSCache` is Apple's general transient-object cache and is appropriate when best-effort eviction is sufficient. Its cost limit is explicitly not strict. Existing actor-owned LRU caches give GOAT deterministic admission/count/cost accounting, so this pass adds native pressure notifications rather than replacing them. SQLite already has page caching; GRDB owns connection/statement caches and WAL coordination. A duplicate chat-record cache would add invalidation and consistency work without demonstrated query benefit.

## Consequences and validation

Tests cover rule reuse/partitioning, real WebKit script and resource restrictions, Source-mode document retirement and shell reuse, cache bounds/theme invalidation/rebuild, event delivery/lifetime, socket framing/shutdown and narrow checkpoint semantics. Synthetic benchmark output reports observed times without hardware-independent thresholds. A Release Instruments run with long histories, many images and dense diagrams remains required for end-to-end latency, frame time, wakeups and peak-memory acceptance. Large-history paging, attachment metadata planning and richer source virtualization are tracked in the performance audit.

## References

- [Apple: improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple: NSCache cost-limit semantics](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)
- [Apple: memory-pressure dispatch source](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure)
- [SQLite: WAL](https://sqlite.org/wal.html)
- [GRDB](https://github.com/groue/GRDB.swift)
