# ADR-0102: Paged reader history and complete turn context

Status: Proposed · 2026-10-13
Refines [ADR-0003](0003-persistence-grdb.md), [ADR-0056](0056-bounded-rendering-and-responsive-io.md) and [ADR-0091](0091-content-bounded-transcript-layout.md).

## Context

The measured transcript admits a bounded render window, but opening a chat still reads and decodes
its entire stored history. The same message array also supplies generation, compaction, feedback
and local-control receipts. Replacing that array with a database suffix without changing those
consumers would silently truncate context or associate a receipt with an older reply.

## Decision

Open a stored conversation with the latest 40 records. Page in either direction using the stable
`(position, id)` key, retaining at most 120 idle reader records with overlap. Preserve the preceding
visible message date across cache boundaries. The existing viewport remains the navigation owner;
it remaps array indices around a stable message/segment anchor when the cache changes. Async pages
check history revision, selection, cancellation and turn ownership before publication. Only actual
asynchronous loading shows progress. Page errors keep the current reader content and allow retry.

Before generation, retry or editing, reserve the turn and hydrate its complete history. Reuse loaded
message objects and preserve the newly submitted user row. A failed hydration never starts inference.
Compaction restoration also verifies complete history. Persisted positions are recorded for subsequent
paging. After Shepherd captures final local-control receipts and releases its turn, trim the idle
cache around the reader's anchor. Active generation retains the existing complete-context contract;
this is not a new prompt-budget policy or a constant-memory generation claim.

Saved provenance bytes are retained without decoding until response details are opened. Re-saving a
historical message preserves those original bytes. Search examines cancellable database pages with a
200-result cap. Explicit Markdown export and memory feedback can read a complete history snapshot
without replacing the reader cache. Local-control receipts use the submitted message identity instead
of an array index. Displayed current metrics do not change to an older turn just because the reader
pages upward.

## Consequences

Initial and idle cache bounds are record counts, not a byte ceiling for arbitrary message bodies.
One unusually large stored record can still be expensive. Unsaved messages are retained when
persistence fails, even if the cache temporarily exceeds its normal record cap. Explicit full export and generation remain
proportional to the history they process. No database schema or dependency changes are required.
The 2,000-message fixture checks initial admission, all-message reachability, both paging directions,
identity-preserving hydration, cache trimming and inspection isolation. It does not establish cold-disk
latency, supported-OS accessibility or production retention qualification.

## Alternatives considered

Keeping all histories loaded would preserve existing consumers but leave opening and idle retention
unbounded. Feeding a page directly into Shepherd would lose earlier context. A second transcript
navigation controller would split anchor ownership. This change keeps the existing executor and
makes complete-history access explicit at the consumers that need it.
