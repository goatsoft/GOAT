# ADR-0026: Main-actor publication and worker-owned I/O

**Status:** Accepted · 2026-08-31 · Extends [ADR-0002](0002-ui-architecture.md), [ADR-0003](0003-persistence-grdb.md), [ADR-0016](0016-chat-content-pipeline.md), [ADR-0024](0024-deterministic-prompt-budgeting.md), and [ADR-0025](0025-progressive-single-flight-startup.md)

## Context

`ShepherdModel` is isolated to `MainActor` because it owns observable chat state. Its retained generation task was created from that actor, so it inherited the UI executor. Request snapshot construction, Pen instruction reads, attachment reads, prompt-budget scans, stream consumption, string buffering, and auto-title generation therefore shared the executor which renders the window. Coalescing observable text every 33 ms limited view invalidation, but it did not move the work which produced those batches.

Several view and model paths also performed synchronous file work directly. Image drops and imports read and resized images in callbacks, transcript rows decoded stored images in `body`, theme previews loaded with `NSImage(contentsOf:)`, the JSON editor read, validated, and wrote on the UI executor, and GOAT Home mutations called synchronous Pen, theme, engine, credential, and MCP stores from main-actor models. Slow storage, large images, large JSON, or a fast token stream could therefore stall input and window animation.

Step 3 established an off-main startup snapshot, but normal application use still needed the same executor boundary. Step 5 remains responsible for durable mutation ordering, corruption recovery, path validation, MCP capability security, and fail-closed persistence. Step 6 remains responsible for measured rendering caches and frame-budget tuning.

## Decision

### MainActor publishes state, workers produce it

Observable sessions, messages, settings, permission prompts, and AppKit presentation remain on `MainActor`. Blocking filesystem work, request canonicalization, prompt budgeting, stream iteration, image decoding, and JSON parsing do not.

Crossing from UI state to a worker requires an immutable `Sendable` snapshot. A worker returns values or already-coalesced deltas. It never receives an observable `ChatSession`, `ChatMessage`, `Pen`, SwiftUI binding, AppKit view, or mutable collection owned by the UI.

### Shepherd generation has an actor boundary

`ShepherdModel` keeps turn admission, ownership checks, transcript mutation, tool permission presentation, and persistence publication. `ShepherdGenerationWorker` owns the inference actor reference and performs these operations away from `MainActor`:

1. Load attachment bytes from an immutable transcript snapshot.
2. Assemble protocol turns and run `PromptBudgeter` canonicalization and trimming.
3. Consume the engine stream and accumulate token and thinking strings.
4. Publish one `ShepherdStreamUpdate` at no more than display cadence, or when the one-second crash checkpoint becomes due.
5. Plan and collect the small auto-title request.

Each publication rechecks the turn ID and session ID before touching UI state. Cancellation crosses the worker boundary through the retained turn task. The final buffered delta is flushed once on normal completion or error, without returning to per-token main-actor work.

Pen instructions are read away from the UI executor before the snapshot is handed to the worker. Tool discovery, permission decisions, and observable tool cards still cross `MainActor` because they are interactive state, while MCP transport and process work remain actor-owned.

### File stores execute behind serial workers

Synchronous store primitives remain usable by package tests and migrations, but app call sites reach them through non-main actors:

- `AppFileWorker` is the boundary for engine profiles, credentials, themes, and Pens.
- the MCP config worker owns config reads, writes, imports, and existence checks;
- `ImageFileWorker` owns security-scoped reads, ImageIO thumbnailing, PNG encoding, stored attachment reads, and theme preview decoding;
- the JSON editor worker owns file load, JSON validation, and atomic save;
- Pen landing-page scans, bookmark creation, folder lookup, and artifact export run in worker tasks.

URL construction is pure. GOAT Home directory creation happens in the worker-side store operation which needs it, not as a hidden side effect of reading a URL property.

MCP config mutations return an authoritative post-write snapshot before the app changes a connection. Main-actor config revisions reject stale reads and file-watcher results, while per-server reconnect revisions prevent an older retry from publishing or connecting an obsolete transport. Durable multi-store ordering and fail-closed recovery remain Step 5 concerns.

Views show a placeholder while an image or file snapshot is loading. View-owned import and decode tasks are cancelled when the view disappears or its identity changes, and stale results are checked before publication. File pickers and `NSWorkspace` calls stay on the main thread because they are AppKit presentation, but selected file contents are handled after that callback by a worker.

### Preserve explicit cadence and ownership

Stream batching remains 33 ms and persistence checkpointing remains approximately one second. Moving work must not weaken ADR-0023 turn ownership or ADR-0025 startup ownership. A cancelled or superseded operation cannot append a late delta, thumbnail, config snapshot, or file result to newer UI state.

Step 6 may replace fixed cadence with a measured adaptive policy, add bounded decoded-image and markdown caches, and add signposts. Those changes require evidence from local instrumentation rather than guesses.

### Required tests

- Prompt planning and attachment loading use the worker snapshot and preserve tool and image wire history.
- Streaming emits coalesced ordered updates, flushes its tail, and stops publishing after cancellation or ownership loss.
- Existing turn ownership, prompt-budget, crash checkpoint, and eight-round tool cap tests remain green.
- Image imports and stored thumbnails publish only decoded worker results and cancel stale view work.
- MCP config operations preserve the existing config and connection behavior while their file work is actor-owned.
- The full strict-concurrency verification suite remains the commit gate.

## Consequences

- Engine throughput and large prompts no longer compete directly with mouse, keyboard, animation, and window-resize work on `MainActor`.
- Stored images and theme previews no longer synchronously decode while SwiftUI evaluates a row.
- Large JSON and file imports gain explicit loading, checking, saving, and cancellation states.
- The app has several small worker actors and snapshot types, but their ownership is visible and compiler-checked.
- Serial file workers prevent simultaneous execution inside one store boundary. Step 5 still has to define authoritative revisions, transaction ordering, error propagation, and recovery across related stores.
- Worker execution alone is not proof of 60 fps. Step 6 measures main-thread publication, view recomputation, scroll behavior, and fullscreen rendering before tuning them.

## Alternatives considered

Keep the main-actor Shepherd and only lower the flush rate (rejected: prompt, file, and stream work still blocks the UI), wrap every call in an unstructured detached task (rejected: lifetime and stale-result ownership become implicit), make observable chat objects `Sendable` (rejected: mutable UI state would cross executors), decode images lazily with `NSImage(contentsOf:)` in view bodies (rejected: the first draw remains a synchronous file and decode path), and fold Step 5 persistence policy into this move (rejected: executor placement and durable security semantics need separate decisions and independently reviewable commits).
