# ADR-0043: App-owned local Hitch and CLI

**Status:** Accepted · 2026-09-05 · Extends [ADR-0032](0032-herd-workspaces-and-read-only-git-status.md) and [ADR-0042](0042-goated-kid-capability-contract.md).

## Context

GOAT needs a programmatic interface that reuses its existing app services and proves GOATed's application-service contract. Running an independent headless writer would introduce a second owner of chat persistence and generation. A network listener would create unnecessary exposure for a local-only product.

## Decision

Ship the `goat.hitch` bundled extension and `goat` executable from `GoatHitch`. The extension registers a typed application service through GOATed. A thin app adapter delegates to the existing chat creation, send, persistence and Shepherd cancellation operations. The CLI never opens the database or writes chat files.

Hitch is off by default. Settings > GOATed > Extensions explicitly enables it and explains the authority granted to programs running as the current macOS user. The app must be running. There is no autonomous daemon or remote-control mode.

Use a Unix-domain stream socket at `<GOAT_HOME>/control/goat.sock`: directory 0700, socket 0600, same-user peer identity checked on both ends. An owner-only lock file held with `flock` serializes instances and permits safe removal of stale socket entries. Unsafe existing entries fail closed. The implementation has no TCP bind, remote host option, URL redirect, discovery beacon, telemetry or key export. A custom filesystem socket path is supported by the CLI.

Each connection carries one bounded newline-delimited JSON request and response. API version 1 supports status; paginated Pen/workspace and chat listings; chat creation; message submission; turn snapshots; and cancellation of control-owned turns. It does not expose raw database access, credentials, arbitrary shell commands, permission grants or workspace file contents. See [the CLI/API reference](../wiki/CLI-and-API.md) for the wire format and commands.

Requests have UUID identities. Mutating requests are replayed from a session-local ledger, including concurrent retries, and a reused identity with different content is rejected. Once the 1,024-entry ledger fills, new mutations fail explicitly instead of evicting identities and potentially repeating a side effect. Reads continue. The ledger resets when control is disabled or the app exits; retry guarantees do not extend across that boundary.

The app owns at most 128 control turn records per enabled session. It freezes each final response snapshot, so later GUI messages cannot change an earlier control result. A turn must acquire the same single generation reservation as GUI submissions; competing requests fail explicitly. The host persists the submitted user message before generation and the assistant result before lifecycle retention.

`goat send --follow` and `goat watch` emit bounded JSON response snapshots by polling at 200 ms. This provides incremental text without retaining an unbounded event queue. Final text is capped and reports truncation. Full content remains in the app. A lost CLI connection does not cancel an admitted turn; its UUID can be used to watch or cancel it while that enabled session remains alive. Disabling control closes clients and revokes the service; an already admitted chat turn remains owned by the app and can be stopped there.

MCP tool approval stays in the app's existing permission UI. Clients receive `awaiting_approval`, not permission-granting endpoints. Existing explicitly configured engine, memory and MCP policies still govern what a submitted chat can do. Control itself adds no egress. “Local control” is not a new privilege to activate an integration or change its destination.

## Consequences

The CLI and GUI share one persistence and generation owner. Same-user local programs gain the described application access only when the user enables it. This is not a sandbox against malicious code already running as that user. Socket permissions, bounded clients (eight), bounded frames, read/write deadlines, version validation and explicit failures constrain the interface.

The CLI is built with `make cli` and shipped beside the app in the DMG; it is signed during DMG packaging using the selected signing identity. Installation onto a user's PATH is explicit, with no shell-profile modification by GOAT.

## Verification

Tests cover concurrent replay, conflicting identities, full-ledger behavior, invalid operations/version/arguments, disabled dispatch, socket round trips, directory and socket permissions, symlink rejection, instance exclusivity, shutdown and restart. App tests verify that runtime routes preserve the existing turn and persistence boundaries. No live model or external service is required.

## Alternatives considered

A localhost HTTP server would need additional browser/origin and authentication decisions while offering no required Kid capability. Direct CLI database writes would duplicate coordination. A permanent streaming queue adds retention/backpressure complexity; bounded snapshots meet Kid's incremental-output requirement. A separate headless app lifecycle is deferred.
