# AGENT.md: working in GOAT

Operational guide for any agent (or human) touching this repo. `CLAUDE.md` points here; this is the single source.

## What this is

GOAT: a native macOS 26 app, local-LLM work through compatible model engines ([oMLX](https://omlx.ai) recommended; contract in [docs/ENGINES.md](docs/ENGINES.md)), wiki/Hindsight memory, MCP client. **The Herd Guarantee is a product invariant: GOAT's own code never phones home**, no analytics, no update pings, no network call the app initiates for itself. Only user-configured endpoints (engine, MCP, Hindsight), Paddock preview *content* (policy-gated, ADR-0015), and explicitly requested, owner-approved Pen command networking (ADR-0070) use the network. Command whitelisting does not authorize GOAT telemetry or unsolicited app traffic.

## Read first

1. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): current ownership, scope and boundaries
2. [docs/adrs/](docs/adrs/README.md): settled decisions; don't relitigate them in code

## Monorepo layout (ADR-0018)

```
apps/goat-macos/   # the app: App/ + Modules/ + project.yml + Makefile + art/
web/               # the GitHub Pages landing site: Vite + Vue SPA (ADR-0041), `npm run build`
docs/              # user overviews/how-tos, technical reference and ADRs
.github/           # CI + release workflows, issue/PR templates, community health
assets/            # shared brand images (README/site logo)
```

`make` targets run from the repo **root** and delegate into `apps/goat-macos`. Swift paths below are relative to that app directory.

## Environment

Use a macOS 26 host with a compatible Xcode 26 toolchain for app builds and tests. The deployment target is macOS 26.0, Apple Silicon only. Check for XcodeGen before building. Engines run independently: read the configured endpoint and never hardcode a development port or assume which server answers.

## Build & test

```sh
make gen      # xcodegen generate   (rerun after ANY project.yml change)
make build    # xcodebuild build
make run      # build + quit/relaunch; never use during active work
make test     # tests for the local Modules package
make test-app # xcodebuild test: the GOATTests target (Shepherd + stream tests)
make format   # swift-format in place
make lint     # swift-format lint --strict (CI gate)
make verify   # lint + package/app tests + app build; run before app/build commits
make release  # Release config, hardened runtime
```

All targets work from the repo root (delegated) or from `apps/goat-macos` directly.

Documentation and website-only changes use the web and content checks in [Contributing](CONTRIBUTING.md#verify-a-change); they do not require a local app rebuild. [ADR-0083](docs/adrs/0083-selective-app-ci.md) defines the corresponding CI path policy, including root Markdown guides and bundled-notice exceptions. App/build changes and release qualification still require full verification.

## Hard rules

- **`.xcodeproj` is generated. Never commit it.** Edit `project.yml`, run `make gen`.
- **Module boundaries:** use the explicit graph in `Modules/Package.swift` and [docs/MODULES.md](docs/MODULES.md). No library imports the app. `import GRDB` only inside Persistence; `import MCP` only inside MCPClient. Backend modules do not import UI frameworks. Inference is an HTTP/SSE client, with **no ML frameworks in-process**. If a view needs a capability, extend the domain protocol. `make lint` checks these boundaries.
- **Swift 6 strict concurrency stays on.** No `@unchecked Sendable` without an ADR-worthy reason in a comment.
- **No new dependencies without an ADR.** The existing direct set is GRDB, MCP swift-sdk, swift-markdown-ui and HighlightSwift, plus their transitive dependencies. Do not add to it without an ADR.
- **Secrets:** the oMLX API key lives in `~/.goat/config/credentials.json`, chmod 0600, via `CredentialStore` (ADR-0012), never in GRDB, UserDefaults, or logs. Redact `Authorization`/`x-api-key` in any request logging.
- **No force unwraps outside tests.** Errors surface to the user in honest language (see DESIGN.md §9).
- **Colors/fonts/spacing through Caprine tokens** (`Caprine` theming): hardcoded values in views are a bug.
- **Streaming discipline:** UI updates coalesced at display cadence; DB checkpoints ~1s. Never bind a view to per-token updates.
- Architectural changes → new ADR in `docs/adrs/` (next number, format per its README). Keep the ADR index and current reference documentation in sync.
- **No em-dashes, ever.** Not in prose, code, comments, UI strings, or docs (JB's standing rule). Use a comma, colon, parentheses, or a new sentence instead. En-dashes in ranges (`4–14B`, `M0–M7`) and arrows (`→`) are fine.

## Conventions

- Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`…), imperative, ≤ 72-char subject.
- Tests: swift-testing (`@Test`) in each package; name behaviors, not methods. New engine/store/manager code lands with tests for its protocol surface.
- Whimsy budget (DESIGN.md §1.3): personality only in empty states, About box, easter eggs. Error paths stay deadpan.

## Gotchas

- Real-inference tests need a running oMLX and are tagged `.integration` (skipped by default); everything else runs against `FakeInferenceEngine`. Nothing ML executes in-process.
- Model weights live with the engine, never in the repo. Nothing in-repo should exceed a few hundred KB. Exceptions: the goat mascot art in `App/Assets.xcassets` (~3MB) and bundled renderer assets in `App/Resources` (mermaid.min.js, ~3.4MB; offline rendering is worth the bytes).
- Killing the app mid-stream must lose ≤ ~1s of transcript (checkpoint rule). There's a test; don't break it.
- Engines are external moving targets: **[docs/ENGINES.md](docs/ENGINES.md) is the compatibility contract**. Update it when a server changes behavior or a new one is verified. Server quirks belong in `StreamAssembler` (ADR-0016), never in views.
- **The engine API key lives in `~/.goat/config/credentials.json` (chmod 0600), NOT the Keychain** (`CredentialStore` in Herd). Reason: ad-hoc dev signing makes every rebuild a new identity, so the Keychain re-prompts for the password on every build, hostile for a localhost key. A file read never prompts. Tradeoff: less protected than the Keychain, accepted for a low-sensitivity local key. If GOAT ever ships stable-signed + notarized, revisit moving secrets back to the Keychain (a stable identity makes its ACLs stick).
- App Sandbox is **off** by decision (ADR-0007). Do not "fix" entitlements to enable it.

## Definition of done (any milestone)

`make verify` green · applicable criteria in docs/RELEASE-CHECKLIST.md demonstrably met · no TODOs without an issue-style marker (`// TODO(M5):`) · docs updated if behavior moved.

## Maintainer continuity

Private session notes may exist in ignored `.maintainer/HANDOVER.md`. Historical reports and planning belong outside the public tree; the release checklist contains public qualification requirements. Do not add private archive paths, diagnostic dumps or machine-specific evidence to public product docs.
