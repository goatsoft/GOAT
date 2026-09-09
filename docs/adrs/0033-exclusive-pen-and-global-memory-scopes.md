# ADR-0033: Exclusive Pen and global memory scopes

**Status:** Accepted · 2026-09-03 · Refines [ADR-0005](0005-memory-architecture.md)

## Context

Global memory and Pen memory answer different questions. Global memory is durable context for
loose chats, while a Pen's memory belongs to that Pen and should not surface in unrelated work.
The local stores already live under separate roots, but an early `MemoryContext` contract allowed a
Pen to read both scopes and the Settings browser followed the selected chat. Either behaviour can
make a Pen's knowledge look global.

A chat can later be moved into, out of, or between Pens. Memory is scoped to a Pen or Global store,
not to an individual chat, so automatically transferring all notes with a moved chat would copy or
merge knowledge that may belong to other chats.

## Decision

Global and Pen memory are exclusive scopes. A loose chat reads and writes only Global memory. A
Pen chat reads and writes only that Pen's memory. The application Settings browser always opens the
Global store. A Pen's landing page is the only browser for that Pen's store. The shared
Pages/Map/Connections control is secondary navigation and uses a neutral selected state rather
than GOAT's primary accent.

Moving a chat changes only its `projectID`, which selects the memory scope for future prompt
reads, model tools, feedback, and explicit remembers. Existing notes remain in their original
Global or Pen store. GOAT does not copy, merge, relabel, or delete them. The transcript moves with
the chat, but it is not treated as an implicit memory migration.

This scope guarantee applies to local Markdown and LLM Wiki providers. Hindsight remains its own
explicit shared-bank provider because its coding-agent contract has no per-chat or per-Pen bank
parameter. GOAT must not label a shared Hindsight bank as isolated Global or Pen memory.

## Consequences

- A Pen cannot accidentally receive global notes, and Settings cannot accidentally browse a Pen.
- A moved chat begins using destination memory on its next memory operation without destructive
  file work or surprising knowledge transfer.
- Transferring knowledge between scopes is a future explicit, one-way copy workflow with a visible
  selection and provenance, not a side effect of moving a chat.
- The one-scope `MemoryContext` contract makes accidental unioning fail in core tests before it can
  reach prompt construction.

## Alternatives considered

Read global plus Pen notes for every Pen chat, automatically migrate all source notes when moving
a chat, infer a memory subset from transcript messages, and silently duplicate notes into the
destination. These either leak context, attribute shared Pen knowledge to one chat, or make an
irreversible and often lossy copy without user consent.
