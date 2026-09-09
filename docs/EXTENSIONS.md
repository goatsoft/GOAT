# GOATed extension API v1 · Kid

GOATed (GOAT Extension Dynamics) is the typed runtime in `GOATed`. Kid supports bundled Swift extensions, user skill documents and declarative `.goated` packages. [Package format 1](reference/PACKAGES.md) adds reviewed Global/Pen prompt and skill contributions, plus inert MCP setup suggestions. Swift source examples must be compiled into the app; runtime installation of executable packages and skill-script execution are not supported. [ADR-0042](adrs/0042-goated-kid-capability-contract.md) defines the decisions and limits.

## Build and activate

An `Extension` supplies a `ExtensionManifest` (ID, version, API version and required extension IDs) and `ExtensionContributions`. Construct providers without starting work. Call `try await runtime.activate(extension, scope: .application)` and retain the returned `Registration`. Call `try await runtime.unregister(registration)` to revoke its contributions and dependent extensions. Merely dropping a value token does not unregister it.

Activation is atomic, including skills. Duplicate extension IDs in a scope, service names, incompatible API versions and missing dependencies fail before publication. Application, Pen and chat scopes compose. A required dependency must already exist at application or the same scope. Unload a scope with `deactivateScope`.

The following lifecycle excerpt is illustrative: IDs, host tools and the local directory are supplied by the embedding app. Use the linked Pronk implementation for a complete compiled example.

```swift
import GOATed
import Pronk

let runtime = ExtensionRuntime()
let registration = try await runtime.activate(
    PronkExtension(stateDirectory: explicitlyChosenLocalDirectory))
let context = ExtensionContext(
    view: ExtensionView(chatID: chatID, penID: penID), turnID: turnID)
let snapshot = try await runtime.prepareTurn(context, reservedToolNames: hostToolNames)
// Feed snapshot context and prompt sections through the host's prompt budgeter.
// Expose snapshot.tools; dispatch only their exact handles through runtime.invoke.
await runtime.endTurn(turnID, outcome: .completed)
try await runtime.unregister(registration)
```

The complete [Pronk implementation](../apps/goat-macos/Modules/Sources/Pronk/PronkExtension.swift) is compiled and tested in the package. [Its walkthrough](wiki/Pronk-Example.md) explains every contribution.

## Capability contracts

| Capability | Provider contract | Consumer rule |
|---|---|---|
| Structured context | `ContextProvider.contextEntries(for:)` | Budget typed identifier/title/summary entries before inference. |
| Prompt context | `PromptProvider.prompt(for:)` | Treat text as untrusted context. Runtime wraps it with ID/version/registration provenance. |
| Model tools | `ModelToolProvider.tools(for:)`, `invoke(_:context:)` | Use the immutable turn handle and host authorization callback. Never resolve by name alone after approval. |
| Skills | `SkillProvider.listSkills()`, `loadSkill(named:)`, `readResource(skill:path:)` | Advertise metadata, progressively load instructions, then permit bounded resources. |
| Scoped companion skills | `ScopedSkillProvider.listSkills(for:)` | Recheck consumer scope and capability availability on catalog/load/resource resolution. |
| Lifecycle | `TurnObserver.turnWillPrepare`, `turnDidPersist`, `turnDidEnd` | Durable events follow successful persistence. Cleanup follows every outcome. |
| Application services | `ServiceProvider.invoke(operation:argumentsJSON:)` | Explicit host-owned entry points; never automatically exposed to the model. |

`CompanionSkillProvider` is a data-only helper. `FileSkillProvider` confines resources to regular files under an explicitly supplied root and rejects unsafe paths, symlinks, malformed metadata and excessive sizes. Existing standalone `registerSkillProvider(_:extensionID:scope:)` registrations remain supported. Skill-name collision and reserved-command rules remain authoritative; selection keys are stable while resource handles include registration generations.

## Turn lifecycle and failures

`prepareTurn` owns preparation and returns one immutable snapshot. Scope and catalog identity remain fixed for that turn. Failed preparation cleans up its observers. The app stops an active chat before moving it to another Pen. Runtime `invoke` validates input, calls the host's authorization closure, rechecks registration and turn, invokes the captured provider and validates the result. Extensions cannot approve themselves, mutate committed transcript rows or replace credentials.

The host calls `didPersist` only after its final assistant row is durable. The runtime delivers it at most once per live turn; it does not guarantee exactly-once side effects across a crash. Use stable idempotency keys for durable integrations. `endTurn` revokes turn handles and pending turn work, then calls cleanup observers. Optional provider errors produce redacted diagnostics; rejected authorization, invalid input and stale identities fail closed. `activeExtensions()` and `recentDiagnostics()` provide bounded inspection.

Hindsight uses an adapter over the existing memory service, capturing configuration at preparation and rechecking it before use. Its tool catalog and companion skill require an enabled, healthy route. Local memory's explicit `/handoff` behavior is preserved. Post-persist observer failures cannot erase a successfully saved reply.

## Limits

| Boundary | API v1 ceiling |
|---|---|
| Active extensions / contributions per extension / live turns | 32 / 32 / 32 |
| Concurrent calls per registration | 16 |
| Standalone and extension skill registrations | 128 |
| Tool schemas per provider / effective schemas per turn | 64 / 128 |
| Tool description / schema | 4 KiB / 16 KiB |
| Tool/service argument / result | 64 KiB / 256 KiB |
| Prompt section / combined prompt sections | 16 KiB / 64 KiB |
| Context entries per provider / turn | 128 / 256 |
| Context identifier / title / summary | 1 KiB / 1 KiB / 16 KiB |
| Combined structured context | 256 KiB |
| Observer receipt / retained diagnostic codes | 4 KiB / 128 entries |
| Default call / model tool / post-persist observer deadline | 5 s / 120 s / 30 s |

The host additionally bounds the observer transcript to the latest 64 messages with at most 4,096 characters per message; the memory transport retains its own byte limits. A test can inject `ExtensionClock` and a default deadline. Tests advance barriers instead of sleeping against real time.

Cancellation is cooperative. The waiter is released when cancelled, revoked or timed out; provider code may still be unwinding. Deadlines quarantine the extension until the runtime is recreated. An in-process Swift extension can still crash the process or perform a side effect before revocation. No native sandbox or arbitrary code loader is implied by this API.

## Tool schema dialect

Supported types: object, array, string, integer, number, boolean and null. Objects require explicit `properties` and `additionalProperties: false`. Supported keywords are `required`, `items`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `maxItems`, and `description`. Nested validation is bounded to fewer than 12 levels. Unsupported keywords fail at registration. Unknown input fields and wrong types fail before authorization. Providers must still validate domain meaning and current state.

## Verification

Run `swift test --package-path apps/goat-macos/Modules --no-parallel` and `make verify`. With dependencies already cached, add `--disable-automatic-resolution` to Swift commands and `-disableAutomaticPackageResolution -skipPackageUpdates` to Xcode commands. The runtime tests use fake providers and a controllable clock. Local-control tests create private temporary Unix sockets. Hosted app tests disable normal startup; no live endpoint is required.

## JUDAS host policy

Managed outbound requests follow [JUDAS](wiki/JUDAS.md), the central host connection policy. Extensions do not receive a policy-control capability. Hitch has no security-settings endpoint. Native bundled Swift remains trusted code; this policy does not sandbox arbitrary binaries. See [ADR-0045](adrs/0045-judas-central-egress-policy.md).
