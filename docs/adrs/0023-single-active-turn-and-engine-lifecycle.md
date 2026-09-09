# ADR-0023: One active turn and revisioned engine lifecycle

**Status:** Accepted · 2026-08-31 · Extends [ADR-0002](0002-ui-architecture.md), [ADR-0006](0006-mcp-integration.md), [ADR-0016](0016-chat-content-pipeline.md), and [ADR-0021](0021-engines-as-managed-list.md); gates M6 ([ADR-0005](0005-memory-architecture.md))

## Context

GOAT has one live inference client, one permission surface, and one Shepherd, but chats expose independent send controls. A per-chat `isStreaming` flag does not prevent two chats from starting together, and async attachment preparation leaves a window where the same chat can start twice. A second start can replace the task handle for the first turn while both tasks continue to mutate transcripts, show permission prompts, persist messages, and use the shared engine.

Engine discovery, health refresh, profile edits, key changes, and active-engine switches also cross suspension points. An older operation can finish after a newer one and commit stale health, models, endpoint, or credentials. Actor and `@MainActor` isolation prevent data races, but they do not make a multi-step async operation current after an `await`.

M6 adds memory context assembly, builtin tools, and optional background reflection. Adding those jobs before turn ownership and engine lifecycle are explicit would multiply the same races and put first-token latency at risk.

## Decision

### One user turn app-wide for MVP

- GOAT admits at most **one user turn across the whole app**. The turn covers preparation, streaming, tool permission and invocation rounds, scheduling final persistence, optional auto-title, and teardown.
- Admission is synchronous and happens before attachment writes or any other `await`. A successful admission creates an immutable `TurnID` and records its `sessionID`. A second send is rejected as busy. It never implicitly cancels the existing turn.
- Navigation remains available while a turn runs. Send and Regenerate entry points reject other work until the owner finishes. The app-wide Stop command targets the owning turn even if the user has navigated to another chat; a chat-local Stop targets only that chat.
- `session.isStreaming` mirrors turn ownership for presentation, but it is not the authority for admission. The Shepherd's app-wide reservation is the source of truth.
- Auto-title currently runs inside the admitted turn, after the visible response and before teardown, so it cannot overlap another turn. M6 background generation adopts a lower-priority gate as specified below rather than copying this inline behavior.

### Identity and cancellation

- The reservation carries `TurnID` and `sessionID`. The turn task retains that reservation across suspension points, and teardown validates both values before clearing shared ownership or presentation state.
- Stop dismisses the owner's pending permission request and requests cancellation of its turn task. If generation has not started, Stop releases the preparation reservation immediately. A late preparation callback validates its `TurnID`; on lost ownership it persists the submitted text, discards attachment files which were never admitted, and cannot start a newer turn. Once generation has started, ownership remains held until guarded teardown, so a new turn cannot start while cancellation unwinds. `Task.cancel()` is a request, not proof that work has stopped.
- MVP has no separate persisted `stopped` outcome. Partial assistant output follows the normal flush and persistence path when the stream ends; cancellation-specific product state requires a schema decision outside this ADR.
- Teardown clears the reservation, task handle, and session presentation state only when the finishing `TurnID` and `sessionID` still own them. A late preparation task therefore cannot clear a newer reservation.
- Tool calls already dispatched may have external side effects. The loop checks identity and cancellation after schema discovery, permission, and invocation suspension points; late results are ignored, and undispatched tool events are persisted as stopped. Stop does not claim to undo completed external work.

### Revisioned engine lifecycle commits

- The MainActor records each user lifecycle intent synchronously with a monotonically increasing intent revision before scheduling async work. `EngineLifecycleController` accepts only increasing intent revisions and issues an operation token, so an older caller that reaches the actor late cannot supersede newer intent. Each operation captures its target profile ID and complete `EngineConfig`.
- Discovery probes and Add/Edit tests use isolated clients. They do not repeatedly reconfigure the live engine while searching candidates.
- An async lifecycle result may publish endpoint, profile URL, health, models, or default-model state only if its operation is still current and its target profile remains active. A superseded probe returns no resolution.
- A current discovery resolution updates the live engine once with the operation revision, then revalidates both intent and operation before publishing observable state. The live engine rejects lower revision commits at its own actor boundary. Candidate probes never mutate the live engine, so a failed discovery cannot leave it pointed at the last port tried. While the current lifecycle intent is pending, turn admission is disabled.
- Active-profile switches, active-profile edits, key changes, and live discovery are rejected while a user turn owns the engine. Read-only isolated Add/Edit tests remain allowed.
- A turn is stable because app-owned engine mutations are blocked for the life of its reservation and the inference stream snapshots its `EngineConfig` when the request starts. The turn does not carry an engine-revision field.

### M6 admission gate

M6 implementation does not join the app until all of the following are true. These are forward gates, not a claim that Step 1 alone already satisfies every item:

1. Tests prove global single-turn admission, including two immediate sends before attachment preparation finishes and sends from different chats. Preparation carries its `TurnID`, and a stopped preparation cannot start a later reservation for the same session.
2. Tests prove stop/late-event identity: a cancelled or superseded task cannot append, persist, present permission UI, or clear a newer owner.
3. Tests prove stale discovery, refresh, key, edit, and switch results cannot commit over a newer engine revision.
4. Memory context is captured once per admitted user turn and reused across its tool rounds. Wiki reads and writes are actor-serialized and stay off `MainActor`.
5. Auto-reflect and other model-backed memory work use the lower-priority engine gate, are cancellable, and cannot delay or overlap an admitted user turn.

## Consequences

- Transcript ownership, permission UI, persistence, and Stop semantics become deterministic across chats.
- Engine state reflects the newest lifecycle operation that has begun, not whichever network request happens to finish last. Engine-changing entry points mark the app as transitioning before scheduling that operation, so no turn is admitted in the handoff window.
- One-at-a-time generation leaves potential multi-chat throughput on the table. This is accepted for MVP because GOAT has one active engine, one model selection, and one permission surface. Concurrency can be reconsidered only with independent per-turn engine sessions and a new ADR.
- Turn IDs, engine revisions, guarded commits, and explicit teardown add code and tests. They replace timing assumptions with invariants that M6 can safely build on.
- M6 background conveniences such as reflection may be skipped under user load. Responsiveness and correctness take priority over maintenance work; the current inline auto-title remains part of its owning turn.

## Alternatives considered

Per-chat concurrent turns (rejected for MVP: shared engine lifecycle, permission UI, and task ownership are not independent), relying on `@MainActor` or actor serialization alone (rejected: actors re-enter across `await` and do not reject stale commits), cancelling the current turn whenever another chat sends (rejected: surprising and unsafe around tool side effects), and last-writer-wins health/discovery state (rejected: completion order is not user intent).
