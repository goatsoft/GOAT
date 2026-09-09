# ADR-0061: Native GOATed Pen file tools

Status: Accepted · 2026-09-07

Refines ADR-0059 and uses the GOATed contract in ADR-0042.

## Context

The local coder can emit structured calls and has successfully written and read a file through mac-shell. Subsequent project setup failed on an invented generator option, a timed-out command, and raw tool-call markup returned as ordinary text. More shell examples do not provide a reliable file interface. The external server also exposes command-policy changes and its own pending-command approval tools, which are unsuitable model capabilities.

## Decision

Bundle Herder (`goat.herder`) as a GOATed extension in the app. The Pens module owns `PenFileTools` and depends on the transport-neutral Tools schemas/results. The host binds one provider and registration to a configured Pen workspace for one turn. GOATed owns schema validation, invocation lifetime and handle revocation. Plain chats and tool-disabled requests do not advertise the file tools.

Expose four small tools: list, read, create and exact edit. Paths are workspace-relative, never model-selected roots. Resolve the user-selected root once using realpath, open it with directory descriptors and revalidate its identity. Subsequent traversal uses openat with O_NOFOLLOW. Reject parent traversal, absolute paths, embedded NULs, symbolic links, `.git` metadata and non-regular or multiply linked files. File operations execute on an actor, not the UI executor. Limit UTF-8 files to 128 KiB and directory listings to 200 entries; retain GOATed's 64 KiB encoded argument and 256 KiB result limits.

Reads use the configured Pen and enabled chat-tool authority. Writes require a new Allow Once decision over the exact path, workspace and content or replacement text, with no remembered write grant. Prepare the edit before approval; recheck workspace authority and existing content after approval and immediately before publication. Creates use exclusive atomic publication; edits use a staged atomic rename and preserve ordinary mode bits. Edits require one exact, unique old-text match. This is not a transaction with unrelated external writers; a write in the narrow interval after the last check and before rename cannot be excluded. No process is spawned, and no external MCP configuration or grant is changed.

Known mac-shell administration tools (add/remove whitelist entries, change security level, approve/deny pending commands) are omitted from discovery and rejected at invocation even for an old route. This is an explicit known-tool restriction, not a semantic classifier for every possible server. Owners still configure external servers themselves.

MCP invocation timeout messages explain that the outcome is unknown, the connection has been retired, and automatic replay is unsafe. Shepherd identifies raw Qwen-style function markup naming an offered tool when no structured call arrived, surfaces an execution failure, and never executes the text. A model/template/parser mismatch still needs correction at the engine.

## Validation and follow-up

Tests cover actual create/read/edit with exact newlines and Unicode, repeated listing, path and link escapes, stale approvals, replaced roots, cross-provider prepared writes, approval denial/cancellation, GOATed routes and revoked handles. Retain the full app regression suite.

The user selected strict confinement for a future built-in Pen shell. Defer that shell until subprocess filesystem authority is enforced and tested, including package managers, build tools, child processes, cancellation and network policy. Setting cwd is not confinement. The existing external MCP shell remains separate and broader in authority.

Model reliability must be checked with a bounded real-model create/edit/read-back diagnostic. Passing deterministic tool tests does not establish reliable completion of arbitrary coding projects.
