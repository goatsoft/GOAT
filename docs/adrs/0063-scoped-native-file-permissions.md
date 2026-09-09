# ADR-0063: Chat and Pen scopes for native file permissions

Status: Accepted · 2026-09-08

Refines the per-write approval decision in ADR-0061.

## Context

Creating or updating a project can require many native Herder file calls. Requiring a separate dialog for every file interrupts an explicitly authorized coding task. Users need to choose how long their permission lasts without granting authority outside the Pen.

## Decision

Keep Allow Once as the primary and default keyboard action. Its split-button menu offers Allow for This Chat and Always Allow for This Pen. Both broader choices authorize native file creation and exact edits. Chat permission persists when that same chat is reopened, including after app restart. Pen permission applies to all its chats, including future chats.

Store these grants in a dedicated SQLite table in Persistence, separate from MCP server/tool grants and model-editable Pen files. Bind each grant to the Pen UUID and the physical workspace identity (canonical path, device, inode and birth time); chat grants additionally bind to the chat UUID. Only the host's reviewed permission dialog can create a grant. Missing or unreadable permission storage defaults to asking; a failed grant save denies that operation and reports the storage failure.

Every write still prepares and validates the actual change. Remembered grants skip the dialog, never the filesystem checks, root revalidation, turn handle checks, exact-match requirements or commit-time content checks. External MCP tools, shell execution, other extensions, global chats and other Pens do not inherit these grants.

The chat toolbar displays file-permission status and exposes reset. Edit Pen exposes the persistent default and a reset for all file grants in that Pen, including chat grants. Resetting a chat grant affects that chat; resetting a Pen grant explicitly says it affects the Pen and its chats. Changing the bound workspace clears all Pen file grants. Moving a chat clears its chat grant; deleting a chat or Pen removes its grants. A different physical directory at the same path does not match an old grant.

Grant mutations are serialized and revisioned. Reset invalidates in-flight approvals immediately; a stale save or load cannot publish over a later reset. Cancellation or loss of workspace/turn authority while remembering an approval cancels the write and clears the newly requested scope. Revocation does not undo file writes already completed.

## Consequences

Multi-file tasks can proceed without repeated dialogs after explicit scoped approval. Permissions remain discoverable and reversible, and chat grants cannot silently become Pen-wide grants. The database gains one additive migration; existing installations start with no native file grants. Tool schemas and persisted MCP grants retain their current meaning.

## Alternatives considered

- Keep only Allow Once: too disruptive for ordinary multi-file coding work.
- Reuse app-wide MCP Always Allow: wrong ownership and scope for native Pen files.
- Keep chat grants only in memory: reopening a chat would contradict the chosen chat scope.
- Grant by path alone: another directory could replace the approved workspace at that path.
