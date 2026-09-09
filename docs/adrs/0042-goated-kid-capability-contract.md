# ADR-0042: GOATed Kid capability and lifetime contract

**Status:** Accepted · 2026-09-05 · Implements the bundled-extension direction of [ADR-0036](0036-native-skills-and-hindsight-lifecycle.md); refines [ADR-0039](0039-preview-and-extension-lifetime-boundaries.md).

## Context

GOATed exposed scoped skills while prompts, tools and Hindsight lifecycle callbacks remained internal application wiring. A second builtin needs to exercise real public contracts before 0.1 (Kid). Describing an extension engine as complete without defining cancellation, ownership and failure behavior is not a release criterion.

## Decision

Ship API version 1 in the `GoatExtensions` Swift module. `GoatExtension` supplies a stable manifest and inert typed contributions. Activation validates compatibility, identifiers, dependencies, service collisions and capacities before atomically publishing registrations. Failed skill registration rolls back the entire extension. No activation constructor starts a process, timer or network connection. Explicit unregister deactivates the extension, its skills and dependent extensions.

Capability families are structured context entries, prompt sections, model tools, skills, turn observers, and application services. Services are separate from model tools: the model cannot invoke Hitch's application operations. The runtime has no mutable application, database, engine credential, approval UI, or browser bridge. Host services remain authoritative.

Scopes are application, Pen and chat. Effective registrations compose in deterministic scope/identity order. Duplicate effective tool names are excluded, and reserved host names cannot be replaced. Handles include the exact registration, provider index, tool name and turn UUID. Re-registering never makes old handles valid. Skills retain stable selection keys and generation-bound loaded resource handles. Companion skills can additionally depend on the consumer's scope and the owning builtin's availability.

One turn prepares one immutable extension snapshot. Context, schemas and prompt contributions are bounded before entering the existing `PromptBudgeter`; prompt contributions carry extension ID, version and registration provenance. Each native model invocation validates the supported schema dialect, asks the host to authorize the exact handle, revalidates after authorization, dispatches, then validates result size and registration lifetime. There is no extension-owned approval bypass or interception of stored transcript facts.

The Shepherd calls preparation while owning its single generation slot. `turnDidPersist` is delivered only after final assistant persistence succeeds, once per turn in this runtime. `turnDidEnd` runs on success, failure and cancellation before releasing that slot. Cleanup has an independent bounded task so cancellation does not skip observer cleanup. A chat move stops its active turn before changing Pen scope.

Provider calls have bounded waiting and cooperative cancellation. Runtime-owned invocation races release the waiter on cancellation, revocation or a deadline without joining an uncooperative provider. A deadline revokes and quarantines that extension for this runtime; restarting GOAT is required to retry it. Optional context/catalog/observer failures record bounded diagnostic codes and allow unrelated capabilities to continue. Authorization failure and stale handles fail closed. Diagnostics exclude raw provider errors, arguments, results and credentials.

The default provider deadline is five seconds, model tools have 120 seconds, and post-persist observers have 30 seconds. Limits also include 32 active extensions, 32 contributions per extension, 32 active turn snapshots, 16 in-flight calls per registration, 128 effective model tools, 64 KiB arguments and 256 KiB tool/service results. The API reference records the remaining payload limits. These are ceilings, not permission to perform arbitrary work.

Hindsight uses this public context/tool/observer contract. Its adapter captures the memory configuration for the turn and rejects changed bindings. Existing native memory services retain bank selection, explicit endpoint configuration and transport policy. Local Markdown/Wiki handoff writes remain host-owned. Pronk demonstrates prompt, model-tool, companion-skill and persistence-observer capabilities with Pen-isolated fictional game state. Both use the same runtime as Hitch.

## Trust and limits

Kid runs GOAT-bundled Swift code only. This contract does not load third-party libraries, execute skill scripts, fetch packages, implement a marketplace, or grant filesystem/network authority through a manifest. Source examples are compiled into the application by its developer. Installing user skill documents remains a separate data-only feature.

An in-process runtime cannot recover from every native crash, undo side effects already performed, or forcibly terminate arbitrary Swift code. Providers must cooperate and use only explicitly supplied resources. Quarantine prevents repeated activation of timed-out code. Exactly-once observer delivery applies to one live turn, not across crashes; durable effects must use idempotent storage where required. Hindsight retains its stable document identities.

## Verification

Package tests use barriers, fake providers and a manually advanced clock for lifecycle ordering, denied authorization, invalid input, collision handling, stale handles, hung-provider deadlines, cancellation and Pen isolation. App tests check durable persistence ordering, cleanup after preparation failure/cancellation, and Pronk routing/revocation. `make verify` includes the extension and local-control packages plus app tests. Hosted app tests disable ordinary startup and configured integrations.

## Alternatives considered

Keeping privileged builtin-only callbacks would not validate public extension contracts. A generic mutable event bus would weaken ownership and transcript durability. Task-group timeouts wait for all children and cannot bound an uncooperative provider. Third-party executable installation requires a separate signing, sandbox, compatibility and update decision and is outside Kid.
