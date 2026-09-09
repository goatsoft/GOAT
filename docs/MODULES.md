# Modules

Kid has 17 library modules and the `goat` executable in one local Swift package. Each library is a separate compiler target with explicit dependencies. Module names describe ownership; they do not imply a sandbox or an independently installable extension.

The [architecture guide](ARCHITECTURE.md) explains the relationships. [ADR-0054](adrs/0054-first-class-domain-modules.md) records the extraction; the [audit](ARCHITECTURE.md) records follow-up work.

<!-- module-catalogue:start -->
## Catalogue

| Module | Owns | Dependencies |
|---|---|---|
| [Bleet](#bleet) | Observable session and transcript state with incremental live metrics. | Inference, Persistence |
| [Caprine](#caprine) | Themes, colour rendering and reusable visual primitives. | Herd, Pens |
| [GOATed](#goated) | Scoped extension capabilities, registration lifetimes, skills and declarative .goated packages. | Tools |
| [Herd](#herd) | Local home, credentials, attachment files and user workspace bindings. | None |
| [Hindsight](#hindsight) | Optional bank-scoped memory service transport and store. | Herd, JUDAS, MCPClient, Memory, Tools |
| [Hitch](#hitch) | Same-user local control API, replay ledger and Unix socket. | GOATed |
| [Hoofprint](#hoofprint) | Bounded activity history, event-driven audit publication and local rendering signposts. | JUDAS |
| [Inference](#inference) | Engine contracts, capability discovery, prompt budgets and streaming. | Herd, JUDAS |
| [JUDAS](#judas) | Host connection policy, revocation and bounded security events. | None |
| [MCPClient](#mcpclient) | MCP server configuration, transport and capability-bound invocation. | JUDAS, Tools |
| [Memory](#memory) | Provider-neutral memory contracts, scope and local stores. | Herd, JUDAS |
| [Paddock](#paddock) | Artifact values, HTML shells, navigation policy and WebKit host. | Caprine, JUDAS |
| [Pens](#pens) | Folder-backed Pen metadata, instructions and serializable colour. Native workspace file operations support the bundled GOATed Herder extension. | Herd, JUDAS, Tools |
| [Persistence](#persistence) | Chat database, migrations, records and tool-grant storage. | Herd |
| [Pronk](#pronk) | The offline, Pen-scoped fictional-goat extension example. | GOATed, Herd, Tools |
| [Shepherd](#shepherd) | Single-turn orchestration, worker execution, tool rounds and durable handover. | Bleet, GOATed, Herd, Hoofprint, Inference, MCPClient, Memory, Persistence, Tools |
| [Tools](#tools) | Transport-neutral tool discovery, requests and results. | None |

## Bleet

Observable session and transcript state with incremental live metrics.

Source: [Modules/Sources/Bleet](../apps/goat-macos/Modules/Sources/Bleet).

Public seams: `ChatSession`, `ChatMessage`, `LiveGenerationMetrics`.

No transport or tool execution; streamed display state is coalesced by Shepherd.

Validation: ComposerStatusTests, ShepherdModelTests, persistence host tests.

## Caprine

Themes, colour rendering and reusable visual primitives.

Source: [Modules/Sources/Caprine](../apps/goat-macos/Modules/Sources/Caprine).

Public seams: `Caprine`, `ThemeSpec`, `ThemeStore`, `ThemeCatalog`.

Theme files are bounded local data; font declarations never download assets.

Validation: ThemeFontTests, theme persistence tests, ReadingFontTests.

## goat

The Hitch command-line executable.

Source: [Modules/Sources/goat](../apps/goat-macos/Modules/Sources/goat).

Public seams: `goat --help`.

Connects only to the private local socket; the running app owns persistence and approvals.

Validation: HitchTests invokes the actual executable.

## GOATed

Scoped extension capabilities, registration lifetimes, skills and declarative .goated packages.

Source: [Modules/Sources/GOATed](../apps/goat-macos/Modules/Sources/GOATed).

Public seams: `ExtensionRuntime`, `Extension`, `ExtensionPackage`, `ToolHandle`, `SkillProvider`.

Bundled native code remains trusted; handles are scoped, revocable and bounded. User archives are validated in memory without extraction or execution.

Validation: GOATedTests (including package admission and scope), AppToolRouterTests and UserExtensionTests.

## Herd

Local home, credentials, attachment files and user workspace bindings.

Source: [Modules/Sources/Herd](../apps/goat-macos/Modules/Sources/Herd).

Public seams: `Home`, `LocalFileStore`, `CredentialStore`, `AttachmentStore`, `HerdWorkspaceFileWorker`, `GitWorkspaceWorker`.

Owner-only credentials and bounded filesystem reads; Git probes stay local and initialization is explicit.

Validation: PersistenceSecurityTests, AttachmentStoreTests, HerdWorkspaceTests.

## Hindsight

Optional bank-scoped memory service transport and store.

Source: [Modules/Sources/Hindsight](../apps/goat-macos/Modules/Sources/Hindsight).

Public seams: `HindsightControlClient`, `HindsightProviderClient`, `HindsightMemoryStore`, `HindsightLimits`.

Uses JUDAS and the bounded MCP adapter; bank authority and response limits are explicit. No automatic cross-Pen migration.

Validation: HindsightBrowserTests, MemoryModelTests, Hindsight configuration tests.

## Hitch

Same-user local control API, replay ledger and Unix socket.

Source: [Modules/Sources/Hitch](../apps/goat-macos/Modules/Sources/Hitch).

Public seams: `HitchRequest`, `HitchReply`, `HitchDispatcher`, `HitchServer`, `LocalSocket`.

Off by default; private Unix socket, no TCP, no credentials API, no approval bypass.

Validation: HitchTests includes real temporary sockets and the built CLI.

## Hoofprint

Bounded activity history, event-driven audit publication and local rendering signposts.

Source: [Modules/Sources/Hoofprint](../apps/goat-macos/Modules/Sources/Hoofprint).

Public seams: `ActivityLog`, `RenderSignposts`.

Bounded to 500 in-memory entries; no durable telemetry or endpoint.

Validation: JudasActivityTests; rendering and Shepherd host tests.

## Inference

Engine contracts, capability discovery, prompt budgets and streaming.

Source: [Modules/Sources/Inference](../apps/goat-macos/Modules/Sources/Inference).

Public seams: `InferenceEngine`, `OpenAICompatEngine`, `PromptBudgeter`, `EngineLifecycleController`.

Configured endpoints through JUDAS; context is data, never permission; no in-process ML.

Validation: InferenceTests covers wire handling, budgets, capabilities and lifecycle ownership.

## JUDAS

Host connection policy, revocation and bounded security events.

Source: [Modules/Sources/JUDAS](../apps/goat-macos/Modules/Sources/JUDAS).

Public seams: `Judas`, `JudasHTTPClient`, `JudasRegistration`, `JudasMode`, `LocalNetworkAddress`.

Configured / local-networks-only / blocked policy; redirects rejected. Not an OS firewall or native-code sandbox.

Validation: JudasTests, JudasMCPTests, JudasActivityTests and the network boundary checker.

## MCPClient

MCP server configuration, transport and capability-bound invocation.

Source: [Modules/Sources/MCPClient](../apps/goat-macos/Modules/Sources/MCPClient).

Public seams: `MCPServerManager`, `MCPServerConfig`, `MCPError`.

Only module importing the external MCP SDK. JUDAS admits transports/processes; app approvals bind to configuration identity.

Validation: MCPClientTests and MCPModelSecurityTests.

## Memory

Provider-neutral memory contracts, scope and local stores.

Source: [Modules/Sources/Memory](../apps/goat-macos/Modules/Sources/Memory).

Public seams: `MemoryStore`, `MemoryContext`, `WikiMemoryStore`, `LLMWikiMemoryStore`, `MemoryConfigurationStore`.

Exclusive Global or Pen scope, bounded descriptor-relative filesystem operations; provider content does not grant authority.

Validation: MemoryTests and MemoryModelTests.

## Paddock

Artifact values, HTML shells, navigation policy and WebKit host.

Source: [Modules/Sources/Paddock](../apps/goat-macos/Modules/Sources/Paddock).

Public seams: `PaddockArtifact`, `PaddockDocumentCache`, `PaddockHTML`, `PaddockNavigationPolicy`, `WebPreview`.

Bounded in-memory document preparation; ephemeral WebKit, shared immutable rules, Source-mode document retirement and JUDAS revocation.

Validation: PaddockTests, PaddockWebRenderingTests, PaddockBenchmarkTests, RenderingPerformanceTests.

## Pens

Folder-backed Pen metadata, instructions and serializable colour. Native workspace file operations support the bundled GOATed Herder extension.

Source: [Modules/Sources/Pens](../apps/goat-macos/Modules/Sources/Pens).

Public seams: `PenSpec`, `PenStore`, `PenFileRef`, `OKLCH`, `PenFileTools`, `PenCommandTools`.

Validated identifiers, staged writes, explicit workspace binding; no UI framework or database dependency. File tools use a turn-bound workspace and descriptor-relative traversal, reject symlinks and multiple hard links, bound reads, and require host approval before writes. Commands use a deny-default macOS sandbox, isolated environment, separate owner whitelist and JUDAS network admission.

Validation: PersistenceSecurityTests, PensHomeTests and scope tests. PenFileToolsTests and AppToolRouterTests cover writes, path boundaries and approval revocation.

## Persistence

Chat database, migrations, records and tool-grant storage.

Source: [Modules/Sources/Persistence](../apps/goat-macos/Modules/Sources/Persistence).

Public seams: `ChatDatabase`, `ChatRecord`, `MessageRecord`, `ToolGrantRecord`, `PenFileGrantRecord`, `ToolEventSnapshot`.

Async GRDB pool with indexed reads; cached narrow checkpoints preserve independent metadata. Durable records never depend on render caches.

Validation: DatabaseTests and PersistenceWriterTests.

## Pronk

The offline, Pen-scoped fictional-goat extension example.

Source: [Modules/Sources/Pronk](../apps/goat-macos/Modules/Sources/Pronk).

Public seams: `PronkExtension`.

Bundled example using public GOATed contracts; state stays in the selected Pen scope; no network or scripts.

Validation: CapabilityTests exercises contributions and scope; examples/pronk documents usage.

## Shepherd

Single-turn orchestration, worker execution, tool rounds and durable handover.

Source: [Modules/Sources/Shepherd](../apps/goat-macos/Modules/Sources/Shepherd).

Public seams: `ShepherdModel`, `ShepherdEnvironment`, `ShepherdToolSource`.

One active turn for GUI and Hitch; persistence and capability checks gate progress. Worker I/O stays off MainActor.

Validation: ShepherdModelTests and turn-ownership host tests.

## Tools

Transport-neutral tool discovery, requests and results.

Source: [Modules/Sources/Tools](../apps/goat-macos/Modules/Sources/Tools).

Public seams: `ToolProvider`, `ToolSchema`, `ToolCallRequest`, `ToolResult`.

Contracts carry data only; no transport, database, UI or authority implementation.

Validation: GOATed, MCPClient and host router contract tests.

<!-- module-catalogue:end -->

## Tether and media generation (proposed)

[ADR-0029](adrs/0029-contextual-media-workspaces-and-tether.md) reserves Tether for media drafts and the contextual Image/Video inspector. It does not own a running engine or job. A separate media engine protocol and job coordinator would own queueing, progress, cancellation and durable media results. These are future components, not implemented modules or Kid release claims.

Bleet attachments already exist in Herd and Bleet. Paddock remains the artifact viewer. Neither is a substitute for media generation.

## Host features

The app remains the composition root for startup, routing, permissions, Settings, engine selection, Hindsight extension binding, presentation preferences, the command palette and onboarding work. Bleet screens, Pens screens, Stats, memory graph layout/rendering and app-aware Caprine controls remain host features. Their domain state and services come from the modules above. A screen does not need an empty package to be documented and owned.

## Source migration

The former GoatCore contents now belong to Herd, Pens, Persistence, JUDAS, Caprine and Inference. GoatInference becomes Inference, GoatMemory becomes Memory, GoatMCP becomes MCPClient, GoatExtensions becomes GOATed, and GoatHitch becomes Hitch. Pronk moves out of the runtime. Infrastructure type prefixes are removed, for example `GoatDatabase` becomes `ChatDatabase`, `GoatHome` becomes `Home`, and `GoatExtensionRuntime` becomes `ExtensionRuntime`.

`MCPClient` avoids the SDK module named `MCP`; `ChatDatabase` avoids GRDB’s `Database`; `RuntimeClock` avoids Swift’s `ContinuousClock`. Persisted identifiers, file locations, JSON keys and extension IDs stay unchanged. Historical ADRs retain their original names; this catalogue describes the current tree.

## Verification

Run `make verify` for module imports, network boundaries, formatting, all package tests and hosted app tests. `make build` compiles the app; `make cli` builds the local client. Package tests use explicit serial scheduling because deadline assertions must not compete with blocking transport/process integration tests. This retains the assertions rather than weakening their deadlines.

The machine-readable [catalogue](../apps/goat-macos/Modules/catalogue.json) is checked against Package.swift. The public website uses that same catalogue at build time; no module discovery request runs in the browser.

After editing module metadata, run `make module-docs` to refresh this catalogue and each source guide. `make lint` rejects stale generated documentation.
