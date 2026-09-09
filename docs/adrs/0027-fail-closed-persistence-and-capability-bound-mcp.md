# ADR-0027: Fail-closed persistence and capability-bound MCP

**Status:** Accepted · 2026-08-31 · Extends [ADR-0003](0003-persistence-grdb.md), [ADR-0006](0006-mcp-integration.md), [ADR-0009](0009-goat-home-and-mcp-config.md), [ADR-0012](0012-credentials-in-goat-home.md), [ADR-0015](0015-preview-network-policy.md), [ADR-0019](0019-pens-as-folders.md), [ADR-0021](0021-engines-as-managed-list.md), and [ADR-0026](0026-main-actor-publication-and-worker-io.md)

## Context

GOAT stores transcripts in SQLite and user-owned configuration, credentials, themes, Pens, attachments, and MCP definitions in GOAT Home. Several stores previously treated a missing file, malformed data, an unreadable path, and a failed write as the same empty or default state. A later successful-looking mutation could then overwrite the only recoverable copy. Related database and filesystem mutations also lacked one durable ordering rule, so a late save could replay a deleted object or inference could begin before its initial transcript row existed on disk.

MCP servers are executable or remote security principals. The previous boundary reused the SDK transports whose pre-decode queues were not bounded, identified grants by server name, allowed configuration replacement between approval and invocation, and let stale reconnects publish capabilities. A malicious or broken server could consume unbounded memory, race a replacement server into an existing grant, or leave the UI advertising tools from a dead generation.

The app also renders model-authored Markdown and Paddock content. The Herd Guarantee requires off-grid mode to close every application-controlled preview egress path immediately, including content that was already compiling or loading when the policy changed.

## Decision

### Local stores distinguish absence from failure

A missing optional file returns `nil` or an empty collection. Malformed, unreadable, oversized, symlinked, special, or otherwise unsafe files throw a typed error and remain untouched. Callers surface that failure and do not replace it with defaults.

GOAT Home stores use atomic replacement through a permissioned temporary file, synchronize file contents before rename, and synchronize the containing directory where supported. Credential and MCP files are written with mode `0600`; other managed files retain explicit user-readable permissions. Managed text and JSON reads are capped at 8 MiB, owner-only credential reads at 1 MiB, and attachments at 25 MiB. Files are opened once with `O_NOFOLLOW` and `O_CLOEXEC`, checked with `fstat`, bounded before allocation, and read through that same descriptor. Components must be valid UUIDs or safe single path components and the resolved target must remain contained by its expected root.

Folder mutations are staged before publication. A replacement is prepared in a hidden sibling directory, validated, and then exchanged or renamed into place. Database and filesystem writers carry monotonically increasing revisions so an older completion cannot replay state after a newer save or delete. Migration markers are written only after the durable destination exists.

Transcript durability is part of turn ownership. The initial assistant row must commit before inference starts. Tool intent and tool result rows must commit before a tool executes or another model round begins. A failed durable barrier stops the turn. Pen deletion clears durable database links before removing the folder so a filesystem failure leaves recoverable unlinked data instead of dangling links.

High-frequency cosmetic metadata, such as a best-effort timestamp refresh, may remain optimistic when losing it cannot alter transcript, permission, engine, or project ownership.

### MCP inputs and transports have explicit bounds

The MCP configuration is at most 5 MiB, contains at most 128 servers, and enables at most 32. GOAT starts no more than four connections concurrently. Server names, commands, arguments, environment entries, URLs, and headers are validated before they become executable configuration. Remote HTTP endpoints require HTTPS. Plain HTTP is admitted only for explicit loopback literals and localhost names.

The pinned MCP SDK exposes a public transport seam but no pre-decode memory limit, so GOAT owns bounded stdio and HTTP transports while retaining the SDK client and protocol types. Each raw JSON or SSE event is limited to 2 MiB and each server may queue one decoded frame. Stdio duplicates close-on-exec descriptors, writes whole frames through one FIFO writer, handles CRLF, treats unexpected EOF as connection failure, and terminates on queue overflow. HTTP uses an ephemeral session with no cache, cookie store, credential store, or redirects; validates exact response media types and JSON-RPC IDs; and cancels every request stream when the call ends.

HTTP MCP support is deliberately limited to request-response tool traffic over POST. Persistent GET SSE sessions, OAuth discovery, and browser authentication are outside this decision and must not be inferred from accepting an HTTP server URL.

Tool discovery is limited to 16 pages and 256 tools per server. One description is at most 16 KiB, combined descriptions are at most 256 KiB, one schema is at most 64 KiB, and combined schemas are at most 512 KiB. Invocation arguments and the accumulated textual result are each bounded to approximately 32 KiB. Stderr diagnostics retain only a short tail.

### Authority is bound to configuration and connection generation

The server fingerprint hashes the complete canonical transport configuration, including command, arguments, environment, URL, and headers. Every successful connection also receives a random generation identifier. Published tool routes carry both values as a capability token.

Permission and invocation are one operation at the Shepherd boundary. The app validates the exact route before showing a permission sheet, after the decision, and after writing a grant. The manager validates it again immediately before and after the protocol call. Reconfiguration, disconnect, process exit, transport failure, or a newer connection invalidates the token. A grant stores the exact configuration fingerprint; legacy name-only grants fail closed. Editing a server revokes its existing grant and test result.

Permission requests have stable request IDs. Cancellation resolves the matching continuation as denied, so stopping a turn cannot invoke a tool after its sheet disappears. Model-facing tool names use a bounded collision-resistant encoding rather than a reversible concatenation of untrusted names.

Configuration mutations and watcher reloads use intent revisions. A stale read, test, reconnect, or file event cannot settle or publish a newer configuration. A failed mutation reloads the authoritative valid file when possible; corruption fails the whole MCP capability set closed without overwriting the source. Imports are read-only and never create, follow, or chmod the source file.

### Off-grid is an immediate egress boundary

Assistant and Paddock Markdown use image providers that reject remote image resolution. When off-grid preview policy becomes active, every WebKit preview stops loading, navigates to a blank document, cancels pending compilation, and rejects results from the prior policy generation. Dismantling a preview performs the same cleanup.

### Required tests

- Missing, malformed, symlinked, special, oversized, and permission-sensitive files exercise distinct outcomes without destructive recovery.
- Atomic store and revision tests prove that an older save cannot replay a newer delete or relink.
- Attachment tests prove single-descriptor bounded reads and root containment.
- MCP tests cover config limits, exact fingerprints, loopback policy, read-only imports, bounded LF and CRLF stdio frames, EOF, queue overflow, closed readers, SSE limits, result limits, generation tokens, and stale connection rejection.
- App tests cover fingerprint-bound grants, complete permission previews, cancellation before invocation, and durable transcript barriers.
- Strict-concurrency, package, app, and repository verification remain the commit gate.

## Consequences

- Corruption and unsafe paths stop the affected operation instead of silently becoming first-run state.
- Transcript, permission, and engine authority now follow explicit durable and revisioned ordering.
- An MCP server has bounded raw buffering and cannot inherit approval merely by reusing a display name.
- MCP HTTP behavior is narrower than the full protocol transport surface. Expanding it requires bounded streaming and authentication decisions first.
- Direct child processes receive termination and escalation, but Foundation `Process` does not create a dedicated process group. Descendants which daemonize or escape the direct child remain a documented residual risk until launch moves to a controlled `posix_spawn` process group.
- A crash during a staged folder exchange can leave a hidden `.goat-stage-*` backup for later cleanup. SQLite and the filesystem still cannot form one atomic transaction, so ordering deliberately favors recoverable unlinked data.
- Malformed legacy lowercase UUID records remain visible as recovery work rather than being normalized automatically.
- Step 6 can measure rendering without conflating UI stalls with unbounded transport input or synchronous durability work.

## Alternatives considered

Treat corrupt files as empty and rewrite them on the next save (rejected: destroys recovery evidence), rely on path preflight followed by a second open (rejected: permits path-swap races), make every cosmetic mutation a blocking durable barrier (rejected: adds latency without protecting authority), retain the SDK transports unchanged (rejected: their pre-decode buffers have no application limit), bind grants only to server name or configuration hash (rejected: replacement and reconnect generations remain ambiguous), revalidate after approval but invoke through a separate lookup (rejected: the lookup can race another replacement), allow HTTP redirects and shared credentials (rejected: expands egress and authority beyond the configured endpoint), and kill an inferred process group from `Foundation.Process` (rejected: GOAT does not own a reliably isolated group under that launch API).
