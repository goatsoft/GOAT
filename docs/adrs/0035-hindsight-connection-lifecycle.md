# ADR-0035: Hindsight has one managed connection lifecycle

**Status:** Accepted · 2026-09-03 · Refines [ADR-0005](0005-memory-architecture.md) and [ADR-0034](0034-hindsight-bank-scoped-mcp.md)

## Context

Hindsight is one of GOAT's three launch memory providers, but its first bank-scoped settings UI
presented it as a small connection action beside two full provider cards. A successful connection
also produced an immutable provider record. That made Hindsight look secondary and prevented the
normal Test, Edit, and Remove lifecycle already established by the Engine and MCP server editors.

The lifecycle still has to preserve the memory invariants. Editing a connection must be explicit,
must not migrate memory, and must not silently write to an untested bank. Removing a GOAT
connection must not call a destructive Hindsight operation or imply that the server bank was
deleted.

## Decision

Memory settings always presents three equal provider cards: Markdown, LLM Wiki, and Hindsight. An
unconfigured Hindsight card opens the connection editor. A configured card shows its server URL,
bank ID, current health, selection state, and an Edit action. The editor uses GOAT's shared dialog
shell and field/button styles, including the top-right close control.

The editor first tests the exact server and credential draft through Hindsight's official bank
list endpoint. Once the server responds, the user can select an existing bank or create a new one.
Bank discovery is paginated and bounded, follows no redirects, and does not run until the explicit
Test Server action. An existing bank requires a successful bank test for the exact current server,
bank, and credential draft before it is saved. Test Bank performs that validation independently;
Connect or Save also performs it inline when the current draft has not passed yet, so stale test
state cannot trap the primary action. Bank testing uses a temporary client, so an edited draft
cannot replace a healthy live session. A blank API key field reuses an existing stored key without
reading that secret back into the UI.

New-bank creation is the narrow exception to ADR-0034's prohibition on exposing Hindsight bank
management. The Settings editor may call only list banks, create an empty bank, and import a bank
template. It relists immediately before creation and refuses an existing bank ID, guarding
against accidental use of the API's create-or-update behavior. Template creation performs a
second collision check after dry-run validation; the upstream API does not provide an atomic
create-only precondition, so concurrent creation of the same user-selected ID remains a narrow
server-side race. The editor offers a blank bank, a bundled GOAT starter manifest, or user-supplied
version 1 template JSON. The starter manifest configures durable retention, observations, and a
user-context mental model; it does not invent memories or install directives. The user may
separately provide one optional initial memory, which is retained only after the new bank passes
GOAT's MCP provider contract.

A newly connected bank becomes the selected Global provider only after the provider contract and
`get_bank` check pass. If the optional initial memory is rejected, the valid connection remains
saved and GOAT reports the non-fatal ingest failure. GOAT exposes no bank deletion, existing-bank
template import, or general control-plane surface.

Current bank-scoped Hindsight records may be edited in place because the user explicitly approved
the replacement connection in this editor. Legacy coding-agent records still reconnect with a new
provider ID. Remove Configuration deletes every local Hindsight provider record and stored
Hindsight credential, including hidden records left by the older append-only lifecycle. It does
not invoke any Hindsight bank-management or memory-deletion tool. Any Global, new-Pen, or
persisted Pen binding that referenced a removed provider is changed to Markdown (local), and every
removed ID is scrubbed from provider history. The confirmation dialog states both effects before
the operation runs.

## Consequences

- Hindsight is visually and behaviorally a first-class peer of the two local memory providers.
- Health, bank identity, and server identity are visible on the provider choice itself.
- Connection edits are test-gated and do not disturb the active client until Save succeeds.
- Setup can discover an existing bank or explicitly create a collision-checked blank or templated
  bank without exposing destructive control-plane operations.
- The optional initial memory always comes from the user; GOAT does not fabricate seed facts.
- Removing GOAT configuration cannot delete or modify the external Hindsight bank.
- Removal is the only provider lifecycle action that changes affected bindings, and it does so
  visibly to keep the persisted configuration valid.

## Alternatives considered

Keep every connection record immutable and append a new one for each edit (rejected: it creates an
unbounded hidden provider list and does not match a single managed Hindsight option); leave an
unusable tombstone on removal (rejected: the provider would still appear configured); delete the
server bank with the local configuration (rejected: GOAT deliberately exposes no destructive
Hindsight capability); and seed a new bank with a fabricated memory document (rejected: durable
memory must originate with the user or a later explicit interaction).
