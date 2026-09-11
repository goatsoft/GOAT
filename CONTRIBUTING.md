# Contributing to GOAT

Help improve a native Mac workspace for local AI. Code, documentation, accessibility feedback, engine compatibility reports and small examples are all useful contributions.

Read the [Code of Conduct](CODE_OF_CONDUCT.md). For sensitive vulnerabilities, use [SECURITY.md](SECURITY.md) rather than a public issue.

The first public tree is the **0.1 (Kid) source preview**. Start with the [preview guide](docs/PUBLIC-PREVIEW.md) for useful testing areas and current limitations. Apple Developer membership is not required to build or contribute; official signing credentials are never needed for contributor builds.

## Choose a focused change

Describe the problem and expected behavior before starting a large feature. Check the [roadmap](docs/ROADMAP.md), [architecture](docs/ARCHITECTURE.md) and relevant [decisions](docs/adrs/README.md). Keep a contribution reviewable: one clear problem, its solution and meaningful verification.

Compatibility reports should include GOAT, macOS, engine and model versions, the feature exercised and a minimal reproduction. Remove credentials and private project/chat data. A server preset or one successful request does not establish every capability.

## Build locally

Use an Apple Silicon Mac with macOS 26 or later, Xcode with the macOS 26 SDK, and XcodeGen. Select the intended Xcode installation with the normal developer-tool configuration. From the repository root:

```sh
brew install xcodegen
make gen
make build
```

The project is generated from `apps/goat-macos/project.yml`. Never commit `.xcodeproj` output. `make build` also regenerates it and does not launch GOAT.

The app dependency lock is `apps/goat-macos/Package.resolved`; `make gen` copies it into the generated project and build targets require those versions. The local package and CLI have a separate lock in `Modules/Package.resolved`. Review both locks and refresh third-party notices when updating dependencies.

When no GOAT chat or command is active, open the built app at `apps/goat-macos/.build/DerivedData/Build/Products/Debug/GOAT.app`. The convenience `make run` target quits/relaunches GOAT; never use it during active work. Use a separate derived-data directory for acceptance builds when necessary.

## Verify a change

`make verify` checks metadata, module/network boundaries, formatting, package tests, app tests and the app build. It does not start a live model request. Run it before committing app/build changes. Use the checks relevant to documentation and website edits as well:

```sh
cd web
npm ci
npm run test:unit
npm run build:all
npm run check:content
```

The web toolchain requires Node 22 or later. Build output is ignored. Run `make module-docs` from the repository root after changing the module catalogue; generated module READMEs are not edited independently.

CI skips the macOS lint, app tests and app build when a change only touches `docs/`, `web/`, shared brand `assets/`, or the root README, contribution, community and agent guides. Website tests, both site builds, content links, distribution notices and generated module documentation are still checked. App code, app dependencies, packaging, shared licence notices, build scripts, workflows and unrecognised paths trigger full app verification. An uncertain comparison also keeps full verification. Release tags retain their full release checks regardless of changed paths.

After editing CI change detection, run `python3 -m unittest discover -s scripts/tests` from the repository root.

Real-inference tests require a deliberately configured service and are separate from normal fixture tests. Record the actual environment when reporting live compatibility. Do not interrupt another task’s app instance to run a test.

## Preserve the boundaries

GOAT’s own code has no telemetry or automatic update requests. Configured engines, MCP, Hindsight, previews and approved command networking have explicit boundaries. Keep permission checks separate from model instructions and preserve revocation behavior.

The local Swift package has 17 library modules plus the `goat` executable. Database access stays in Persistence; the external MCP SDK stays in MCPClient. Inference remains an HTTP client. Follow [AGENT.md](AGENT.md) for coding conventions and the [module catalogue](docs/MODULES.md) for dependency direction. New dependencies or architectural changes require a reviewed ADR.

## Submit a contribution

Open a pull request against `main` with the concrete problem, resulting behavior and relevant validation. Use a conventional commit subject of at most 72 characters. Include screenshots with synthetic content for interface changes, and update the documentation when behavior changes.

Code, documentation and examples are MIT-licensed. GOAT artwork has separate [terms](LICENSE-ART.md); preserve attribution and use your own branding for a distributed modified fork. Contributions should not add material you lack permission to distribute.
