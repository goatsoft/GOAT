# ADR-0025: Progressive single-flight startup

**Status:** Accepted · 2026-08-31 · Extends [ADR-0002](0002-ui-architecture.md), [ADR-0003](0003-persistence-grdb.md), [ADR-0006](0006-mcp-integration.md), [ADR-0009](0009-goat-home-and-mcp-config.md), and [ADR-0024](0024-deterministic-prompt-budgeting.md)

## Context

`AppModel.shared` is created before the first window. Its initializer previously read and migrated the engine file, read credentials, opened SQLite, ran every database migration, and sealed incomplete messages after a crash. `ContentView.task` then ran theme and Pen file work, restored chats, probed the engine and selected model, and finally loaded every enabled MCP server in one serial chain.

This made filesystem or database latency part of time to first frame. An unavailable engine or slow MCP server also delayed restored chat selection and the first genuinely empty state. Multiple windows could start the same sequence again, and cancellation of one view-owned task could interrupt shared application initialization. During restoration, the UI presented empty arrays as real emptiness and accepted New Chat or configuration mutations which a later snapshot assignment could overwrite.

MCP added another head-of-line delay. Enabled servers connected one at a time, even though they have independent processes, transports, tools, and failure outcomes.

## Decision

### Keep the composition-root initializer cheap

`AppModel.init` reads only small `UserDefaults` presentation values and creates service objects with inert fallback configuration. It performs no GOAT Home file reads, credential reads, database open, migration, recovery, theme scan, Pen scan, engine request, or MCP process launch.

Local bootstrap runs from an app-owned task after the first SwiftUI surface exists. A detached local loader opens and validates `GoatDatabase`, performs crash recovery and legacy migrations, reads engine and theme files, and returns Sendable records and specifications. Observable `ChatSession` and `Pen` objects are created only when that snapshot is atomically published on `MainActor`.

This loader is the first bounded off-main file boundary. Step 4 generalizes the boundary to the remaining Shepherd, attachment, Pen, theme, and view file work.

### One startup operation for the application

`StartupCoordinator` retains one unstructured startup task. Every window and every repeated `start()` caller awaits that same task. Cancelling a view waiter does not cancel application initialization. A completed startup is not repeated.

Startup exposes these observable phases:

1. `launching`: the lightweight composition root exists.
2. `restoringLocalState`: database and GOAT Home state are loading away from `MainActor`.
3. `connectingServices`: chats, Pens, themes, engine profiles, and selection are available while the engine and MCP attempts settle.
4. `ready`: the initial engine and MCP attempts have both reached a terminal outcome. Ready does not mean every optional service is healthy.
5. `failed`: durable local state could not be established. The user gets the error and an explicit Retry action.

The coordinator can be reset only by that explicit failed-startup Retry path. A retry cannot race user mutations because persistent mutation remains gated while local state is unavailable.

### Local state is the first interactive boundary

The sidebar and detail pane show a restoring surface until the database-backed local snapshot is published. They never interpret initial empty arrays as an empty pasture. New Chat, New Pen, Settings configuration, drag, rename, and other persistent mutations remain unavailable until that publication.

If a successful snapshot contains no chats, GOAT first inserts one chat durably, then publishes and selects it. A database open, read, or initial insert failure does not silently enter a lossy in-memory mode. Startup moves to `failed` and offers Retry.

Restored selection and lazy transcript loading begin before service connection finishes. Transcript loading has separate loading, failed, and Retry presentation, so a failed read is not an indefinitely blank chat.

The one-time database-project to Pen migration checks every legacy project ID on every needed run and creates only missing Pen folders. A partial prior migration no longer prevents the remaining projects from being recovered.

If a chat points to a Pen which was not materialized, the chat appears in the loose Chats section instead of disappearing from every sidebar group. Distinguishing missing files from unreadable or malformed engine, Pen, theme, credential, and MCP stores, plus fail-closed recovery and atomic write rules, belongs to the Step 5 persistence decision. Moving those reads does not declare their existing parsers validated.

### Services settle concurrently and do not own local usability

After local publication, engine discovery, selected-model capability probing, and MCP startup begin concurrently. Chat history, local navigation, and persistent CRUD stay usable while they run. Send depends on its direct requirements: durable local state, loaded transcript, healthy settled engine/model capability, and a free app-wide turn slot. It does not wait for an unrelated MCP server to finish connecting.

MCP first reconciles and publishes every configured server as disconnected or connecting. Enabled servers without a retained client then connect concurrently. The app mirrors each terminal result as it arrives, so one slow or failed server does not prevent another server from becoming visible and usable. `ready` waits for all initial attempts to settle, but the rest of the app is already progressive.

Operation ownership, truly hard MCP deadlines, process cleanup, and stale reload rejection remain required by Step 5. This ADR removes serial startup dependency without claiming those security properties early.

### Measure locally

Debug diagnostics use a monotonic clock and record local restore, engine connection, MCP connection, and total startup duration. These are local logs only. No telemetry or network reporting is added.

### Required tests

- Concurrent callers execute one startup operation, and later callers join its completed result.
- Cancelling a view waiter does not cancel the retained startup task.
- An explicit failed-startup reset permits one fresh attempt.
- Phase readiness distinguishes local availability from service settlement and persistence failure.
- Composer admission rejects unavailable local state independently of engine, transcript, and turn-busy state.
- MCP reconciliation publishes all enabled pending servers as connecting before connection work and disabled servers as disconnected.

The full verification suite remains the commit gate.

## Consequences

- The window can render before database migration or GOAT Home scanning completes.
- Restored chats become browseable before engine and MCP startup settle, and a slow tool server no longer serializes every other server.
- False empty states and snapshot-overwrite mutations are removed from startup.
- Persistence failure is louder, but GOAT no longer invites the user to create unsaved work without consent.
- The initial empty chat adds one awaited database insert before local publication. This small durability cost is intentional.
- Startup has explicit state and additional tests instead of relying on array emptiness and engine health as indirect signals.
- Some synchronous file entry points still exist after startup. Step 4 moves them behind worker boundaries, and Step 5 serializes and secures their persistence semantics.

## Alternatives considered

Keep eager initialization and add a splash screen (rejected: it hides blocking rather than removing it), detach the existing serial `start()` function wholesale (rejected: observable objects and UI publication belong on `MainActor`), allow ephemeral chat after database failure (rejected: silent data loss), wait for every service before exposing restored state (rejected: local data does not depend on localhost service health), connect MCP servers serially (rejected: independent failures create avoidable head-of-line latency), and cancel startup with its first view (rejected: application lifetime is not view lifetime).
