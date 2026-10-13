# ADR-0101: Bounded inline artifact lifetimes and literal math

Status: Proposed · 2026-10-13
Refines [ADR-0010](0010-paddock-artifacts.md), [ADR-0015](0015-preview-network-policy.md) and
[ADR-0091](0091-content-bounded-transcript-layout.md).

## Context

A bounded transcript can still retain several WebKit documents. Hiding a preview with opacity,
or replacing its document with a blank page, retains its web view and associated resources.
Pooling views across artifacts also risks sharing ephemeral website data between unrelated
artifacts. Display math needs an explicit fallback while no typesetter has been adopted.

## Decision

Admit at most three visible inline previews. Source mode and leaving the viewport retire the
artifact's web view. Each admitted view has its own nonpersistent website data store and retains
the existing JUDAS navigation, revocation and content-rule policy. The Paddock inspector keeps
its separate, explicitly opened preview. This is an admission pool, not a cross-artifact pool
of WebKit data stores.

Keep inactive preview snapshots only in memory, keyed by artifact identity. Limit them to eight
entries and 16 MiB of charged bitmap cost, charging at least a 2x RGBA bitmap. Snapshot limits
are accounting bounds, not a statement about total process memory. Measure initial document
geometry after the corresponding navigation completes, and clamp inline height between 80 pt
and the existing artifact-specific maximum. Expand opens the full artifact in Paddock.

Present tables in a horizontal scroller and expose header cells to accessibility clients.
Present display math delimited by standalone `$$` or `\[` / `\]` lines as explicitly labelled,
selectable source. Keep the original delimiters and backslashes, including incomplete streamed
math. Existing code fences are not reinterpreted. No math dependency or remote renderer is added.
Message storage, generation prompts and Markdown export retain the original source.

## Consequences and qualification

Returning to an inactive preview creates a fresh ephemeral document; interactive page state is
not preserved across retirement. Snapshots can show an earlier static frame of interactive
content. Initial content sizing does not certify later script-driven reflow.

The default tests cover preview admission, snapshot accounting, streamed preview completion,
literal math preservation and named code actions. Actual WebKit subprocess memory, retention,
keyboard/VoiceOver behavior and supported-OS qualification remain required by #85 and #87.
This decision does not accept either experimental transcript container under ADR-0099.

## Alternatives considered

Keeping hidden web views alive would not bound document lifetimes. Sharing a web view between
artifacts would complicate isolation and revocation. Adding a typesetter now would introduce a
new rendering dependency before its accessibility and resource behavior have been qualified.
