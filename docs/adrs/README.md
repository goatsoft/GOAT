# Architecture Decision Records

Immutable once accepted; superseding requires a new ADR that links back. Format: Context → Decision → Consequences → Alternatives considered.

Older records retain the package and type names used when accepted. [ADR-0054](0054-first-class-domain-modules.md) records the domain extraction and renaming; [Modules](../MODULES.md) is the current ownership and import reference.

| # | Title | Status |
|---|---|---|
| [0001](0001-inference-mlx.md) | On-device inference via MLX (`mlx-swift-lm`) | Superseded by 0008 |
| [0002](0002-ui-architecture.md) | SwiftUI-first, `@Observable` MV, actor domain | Accepted |
| [0003](0003-persistence-grdb.md) | GRDB/SQLite for persistence | Accepted |
| [0004](0004-xcodegen-cli-builds.md) | XcodeGen + xcodebuild CLI builds | Accepted |
| [0005](0005-memory-architecture.md) | Pluggable memory: wiki default, Hindsight optional | Accepted · Hindsight runtime superseded by 0036; refined by 0031, 0033, 0035, and 0037 |
| [0006](0006-mcp-integration.md) | MCP via official Swift SDK | Accepted |
| [0007](0007-no-app-sandbox.md) | No App Sandbox; Hardened Runtime at ship | Accepted · signing refined by 0078 |
| [0008](0008-inference-via-omlx.md) | Inference delegated to a local oMLX server | Accepted |
| [0009](0009-goat-home-and-mcp-config.md) | `~/.goat` home; file-based Claude-Desktop-compatible MCP config | Accepted |
| [0010](0010-paddock-artifacts.md) | The Paddock: artifact previews; custom transcript reaffirmed over SwiftyChat | Accepted |
| [0011](0011-liquid-glass-and-window-translucency.md) | Liquid Glass primitives + AppKit hook for true window alpha | Accepted |
| [0012](0012-credentials-in-goat-home.md) | Engine API key in `~/.goat` file (0600), not the Keychain | Accepted |
| [0013](0013-themes-as-data.md) | Themes are `ThemeSpec` data; custom themes from `~/.goat` | Accepted · refined by 0022 and 0030 |
| [0014](0014-activity-log-not-terminal.md) | Bottom panel is a read-only activity log, not a shell | Accepted |
| [0015](0015-preview-network-policy.md) | Herd Guarantee split from preview network access; off-grid toggle | Accepted |
| [0016](0016-chat-content-pipeline.md) | Chat pipeline: normalize at the engine, typed parts in the UI | Accepted |
| [0017](0017-engine-agnostic-openai-dialect.md) | Engine-agnostic OpenAI-dialect client; oMLX recommended | Accepted |
| [0018](0018-monorepo-and-github-tooling.md) | Monorepo layout (apps/web/docs) + CI/release/Pages tooling | Accepted · web/ refined by 0041 |
| [0019](0019-pens-as-folders.md) | Pens (projects) are folders in `~/.goat/projects`; OKLCH colour, AGENTS.md | Accepted |
| [0020](0020-engine-presets.md) | Engine presets (oMLX/vMLX/Ollama/LM Studio/llama.cpp) + Custom URL; engine-aware model management | Accepted · refined by 0021 |
| [0021](0021-engines-as-managed-list.md) | Engines are a managed list (engines.json) sharing the MCP servers' UX; one active at a time | Accepted |
| [0022](0022-theme-format-and-community-themes.md) | GOAT Theme Format; community themes as folders; built-ins read-only; System → Light/Midnight | Accepted · refines 0013, refined by 0030 |
| [0023](0023-single-active-turn-and-engine-lifecycle.md) | One active turn app-wide; revisioned engine lifecycle commits; M6 gate | Accepted |
| [0024](0024-deterministic-prompt-budgeting.md) | Deterministic prompt budget; capability-gated model setup and atomic trimming | Accepted |
| [0025](0025-progressive-single-flight-startup.md) | Progressive single-flight startup; local state before concurrent services | Accepted |
| [0026](0026-main-actor-publication-and-worker-io.md) | MainActor publishes Sendable worker results; generation and file I/O stay off-main | Accepted |
| [0027](0027-fail-closed-persistence-and-capability-bound-mcp.md) | Fail-closed local stores; bounded transports and generation-bound MCP authority | Accepted |
| [0028](0028-measured-bounded-rendering-and-fullscreen-backing.md) | Measured bounded rendering; transition-safe fullscreen backing | Accepted |
| [0029](0029-contextual-media-workspaces-and-tether.md) | Chat/Image/Video workspaces; Tether is the capability-driven media inspector | Proposed |
| [0030](0030-corporate-default-and-unlockable-1337-experience.md) | Corporate System default; About-unlocked 1337 experience pack ships in Kid | Accepted · refines 0011, 0013, and 0022 |
| [0031](0031-provider-aware-llm-wiki-map.md) | Provider-aware LLM Wiki Pages/Map/Connections browser; desktop memory map | Accepted · refines 0005 |
| [0032](0032-herd-workspaces-and-read-only-git-status.md) | Optional user-owned Pen workspaces; local Git status and opt-in initialization | Accepted · refines 0019 and 0026 |
| [0033](0033-exclusive-pen-and-global-memory-scopes.md) | Exclusive Global and Pen memory scopes; non-destructive chat moves | Accepted · refines 0005 |
| [0034](0034-hindsight-bank-scoped-mcp.md) | Hindsight as a bank-scoped server provider | Superseded by 0036 |
| [0035](0035-hindsight-connection-lifecycle.md) | Hindsight as one managed connection lifecycle | Accepted · refines 0005 and 0034 |
| [0036](0036-native-skills-and-hindsight-lifecycle.md) | GOATed extensions, native skills, and Hindsight lifecycle | Accepted · supersedes Hindsight runtime and scope in 0034 |
| [0037](0037-app-wide-memory-provider-and-pen-banks.md) | App-wide memory provider and explicit Pen banks | Accepted · refines provider routing in 0005, 0033, and 0036 |
| [0038](0038-professional-presentation-gate.md) | Local presentation gate and professional interface | Accepted · refines 0030 |
| [0039](0039-preview-and-extension-lifetime-boundaries.md) | Preview and extension lifetime boundaries | Accepted |
| [0040](0040-single-source-release-identity.md) | Single-source release identity | Accepted |
| [0041](0041-website-as-vite-vue-spa.md) | Public website as a Vite + Vue SPA on GitHub Pages | Accepted · refines 0018 |
| [0042](0042-goated-kid-capability-contract.md) | GOATed Kid capability and lifetime contract | Accepted |
| [0043](0043-local-goat-control-and-cli.md) | App-owned local Hitch and CLI | Accepted |
| [0044](0044-docs-site-vitepress.md) | Docs site as VitePress over `docs/`, beside the landing page | Accepted · extends 0041 |
| [0045](0045-judas-central-egress-policy.md) | JUDAS central connection policy and security activity | Accepted · refines 0015, 0024 and 0042 |
| [0046](0046-scoped-recent-memory-and-hindsight-map.md) | Scoped recent memory, Pen tabs and native Hindsight map | Accepted · refines 0031 and 0037 |
| [0047](0047-native-graph-controls-and-session-charts.md) | Native graph controls and session charts | Accepted · refines 0031 and 0046 |
| [0048](0048-spatial-memory-and-knowledge-graph.md) | Spatial memory and knowledge graph | Accepted · refines 0046 and 0047 |
| [0049](0049-native-map-input-ownership.md) | Native map input ownership | Accepted · refines 0047 and 0048 |
| [0050](0050-map-zoom-and-connector-motion.md) | Map zoom and connector motion | Accepted · refines 0047 and 0049 |
| [0051](0051-typed-memory-relationship-direction.md) | Typed memory relationship direction | Accepted · refines 0048 and 0050 |
| [0052](0052-pens-overview-and-visible-legend-help.md) | Pens overview and visible legend help | Accepted · refines 0051 |
| [0053](0053-local-reading-font-preferences.md) | Local reading font preferences | Accepted |
| [0054](0054-first-class-domain-modules.md) | First-class domain modules | Accepted |
| [0055](0055-local-network-service-authority.md) | Local-network service authority | Accepted |
| [0056](0056-bounded-rendering-and-responsive-io.md) | Bounded rendering caches and responsive I/O | Accepted |
| [0057](0057-foreground-engine-connection-recovery.md) | Foreground engine connection recovery | Accepted |
| [0058](0058-stable-transcript-reflow.md) | Stable transcript reflow and scroll ownership | Accepted |
| [0059](0059-project-context-and-tool-execution-guidance.md) | Project context and tool execution guidance | Accepted |
| [0060](0060-bounded-rich-list-measurement.md) | Bounded rich-list measurement | Accepted |
| [0061](0061-native-pen-file-tools.md) | Native GOATed Pen file tools | Accepted |
| [0062](0062-declarative-goated-packages.md) | Declarative GOATed packages | Accepted |
| [0063](0063-scoped-native-file-permissions.md) | Chat and Pen scopes for native file permissions | Accepted · refines 0061 |
| [0064](0064-composer-and-pen-permission-controls.md) | Composer and Pen file-permission controls | Accepted · refines 0063 |
| [0065](0065-bounded-tool-format-recovery.md) | Bounded recovery for unexecuted tool-call text | Accepted |
| [0066](0066-lead-and-continuous-tool-work.md) | Lead, early titles, and continuous tool work | Accepted · refines 0023; supersedes the round cap in 0006 and 0065 |
| [0067](0067-lead-waits-for-the-current-action.md) | Lead waits for the current action and approval | Accepted · refines 0066 |
| [0068](0068-file-edit-feedback-and-interruption-recovery.md) | Honest edit feedback and visible interruption recovery | Accepted · refines 0003, 0061, and 0066 |
| [0069](0069-coding-navigation-and-context-retention.md) | Coding navigation, context excerpts and accurate Stop results | Accepted · refines 0024, 0061 and 0068 |
| [0070](0070-confined-pen-command-jobs.md) | Confined Pen command jobs and separate owner whitelist | Accepted · implements command direction in 0061 |
| [0071](0071-optional-builtins-and-herder-settings.md) | Optional built-ins and Herder settings | Accepted |
| [0072](0072-tool-generation-telemetry-and-coder-recovery.md) | Tool-generation telemetry and coder recovery | Accepted |
| [0073](0073-owner-managed-command-whitelist.md) | Owner-managed command whitelist | Accepted |
| [0074](0074-grouped-transcript-tool-activity.md) | Grouped transcript tool activity | Accepted · refines 0058 |
| [0075](0075-chat-attachments-and-inline-artifacts.md) | Chat file attachments and inline artifact presentation | Accepted · refines 0056 and 0074 |
| [0076](0076-hindsight-health-and-session-ownership.md) | Hindsight health and session ownership | Accepted · refines 0035 |
| [0077](0077-host-coordination-and-resource-lifetimes.md) | Host coordination and resource lifetimes | Accepted · refines 0025, 0056 and 0076 |
| [0078](0078-owner-approved-release-signing.md) | Owner-approved release signing | Accepted · refines 0007 |
| [0079](0079-shared-aurora-worker.md) | Shared Aurora rendering worker | Accepted · refines 0041 and 0077 |
| [0080](0080-explicit-first-engine-setup.md) | Explicit first-engine setup | Accepted · refines 0021 |
| [0081](0081-owner-prepared-automatic-uninstall.md) | Owner-prepared automatic uninstall | Accepted |
| [0082](0082-direct-preference-reset.md) | Direct preference reset | Accepted · refines 0081 |

New session? Start with **[../../AGENT.md](../../AGENT.md)**, then [the roadmap](../ROADMAP.md).
