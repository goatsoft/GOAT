# Contributing to GOAT

Help improve a native Mac workspace for local AI. Code, documentation, accessibility feedback, engine compatibility reports and small examples are all useful contributions.

Read the [Code of Conduct](CODE_OF_CONDUCT.md). For sensitive vulnerabilities, use [SECURITY.md](SECURITY.md) rather than a public issue.

The current published release is **0.1.1 (Kid)**. Start with the [preview guide](docs/PUBLIC-PREVIEW.md) for useful testing areas and current limitations. Apple Developer membership is not required to build or contribute; official signing credentials are never needed for contributor builds.

## Choose a focused change

Describe the problem and expected behavior before starting a large feature. Check the [roadmap](docs/ROADMAP.md), [architecture](docs/ARCHITECTURE.md) and relevant [decisions](docs/adrs/README.md). Keep a contribution reviewable: one clear problem, its solution and meaningful verification.

Compatibility reports should include GOAT, macOS, engine and model versions, the feature exercised and a minimal reproduction. Remove credentials and private project/chat data. A server preset or one successful request does not establish every capability.

## Build locally

Use an Apple Silicon Mac with macOS 26 or later and Xcode with the macOS 26 SDK. Select the intended Xcode installation with the normal developer-tool configuration. From a fresh checkout:

```sh
make open
```

Select the shared **GOAT** scheme and **My Mac**, then use Product > Build (Command-B), Run (Command-R) or Test (Command-U). Debug uses the normal LLDB debugger. Run opens a development GOAT instance, so finish any active GOAT chat or command first. To experiment with separate data, duplicate the scheme as a user scheme and set `GOAT_HOME` to a disposable directory in its Run environment. Do not commit that personal scheme. Tests already use isolated state.

`apps/goat-macos/GOAT.xcodeproj` is maintained source. Edits to target settings and the shared scheme persist and belong in the same commit as the change. Add new source files to the appropriate GOAT or GOATTests target in Xcode; `make lint` checks membership. Do not regenerate the project. `make gen` remains a validation-only compatibility alias. `make clean` preserves the project.

The project owns app/test build settings. `Modules/Package.swift` owns the local package graph. `release.json` owns version, build and codename; each app build generates current provenance in DerivedData. Do not override those identity fields in Xcode. Ad-hoc signing works without an Apple Developer account; official release signing remains in the documented Make workflow.

The app dependency lock is `apps/goat-macos/GOAT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The local package and CLI retain a separate lock in `Modules/Package.resolved`. Commit intentional dependency updates from Xcode and refresh third-party notices after reviewing both locks. Command-line builds require the pinned versions.

```sh
make build
make test-app
```

When no GOAT chat or command is active, open the built app at `apps/goat-macos/.build/DerivedData/Build/Products/Debug/GOAT.app`. The convenience `make run` target quits/relaunches GOAT; never use it during active work. Use a separate derived-data directory for acceptance builds when necessary.

## Verify a change

For domain selection in Make and Xcode, see [Testing by domain](docs/reference/testing.md). `make test MODULE=Bleet` and `make test MODULE=Paddock` run the tests owned by those domains. Website tests use `make test-web`; build/release tooling uses `make test-tools`.

`make verify` checks metadata, module/network boundaries, formatting, package tests, app tests and the app build. It does not start a live model request. Run it before committing app/build changes. Use the checks relevant to documentation and website edits as well:

```sh
cd web
npm ci
npm run test:unit
npm run build:all
npm run check:content
```

The web toolchain requires Node 22 or later. Build output is ignored. Run `make module-docs` from the repository root after changing the module catalogue; generated module READMEs are not edited independently.

CI skips the macOS lint, app tests and app build when a change only touches `docs/`, `web/`, shared brand `assets/`, or root `*.md` files, including newly added Markdown guides. The root Markdown rule excludes `LICENSE-ART.md` and `THIRD-PARTY-NOTICES.md` because they supply bundled app notices. Website tests, both site builds, content links, distribution notices and generated module documentation are still checked. App code, app dependencies, packaging, shared licence notices, build scripts, workflows and unrecognised paths trigger full app verification. An uncertain comparison also keeps full verification. Release tags retain their full release checks regardless of changed paths.

After editing CI change detection, run `python3 -m unittest discover -s scripts/tests` from the repository root.

[ADR-0083](docs/adrs/0083-selective-app-ci.md) records the CI routing decision and its fallback behavior.

Real-inference tests require a deliberately configured service and are separate from normal fixture tests. Record the actual environment when reporting live compatibility. Do not interrupt another task’s app instance to run a test.

## Preserve the boundaries

GOAT’s own code has no telemetry or automatic update requests. Configured engines, MCP, Hindsight, previews and approved command networking have explicit boundaries. Keep permission checks separate from model instructions and preserve revocation behavior.

The local Swift package has 17 library modules plus the `goat` executable. Database access stays in Persistence; the external MCP SDK stays in MCPClient. Inference remains an HTTP client. Follow [AGENT.md](AGENT.md) for coding conventions and the [module catalogue](docs/MODULES.md) for dependency direction. New dependencies or architectural changes require a reviewed ADR.

## Submit a contribution

Create a focused Git-flow-style branch from `main` using a semantic prefix such as `feat/...`, `fix/...`, `chore/...`, `refactor/...`, `docs/...`, `test/...` or `perf/...`; do not use an unclassified branch name. Open a pull request against `main` with the concrete problem, resulting behavior and relevant validation. Use a conventional commit subject of at most 72 characters. Apply the appropriate repository labels/tags to the pull request, including the change type and any relevant area or risk labels. Include screenshots with synthetic content for interface changes, and update the documentation when behavior changes.

Code, documentation and examples are MIT-licensed. GOAT artwork has separate [terms](LICENSE-ART.md); preserve attribution and use your own branding for a distributed modified fork. Contributions should not add material you lack permission to distribute.
