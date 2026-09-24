# Testing by domain

GOAT has three separate test layers: Swift package contracts, hosted macOS integration and presentation, and the website. Build/release tooling has its own Python suite. A test belongs with the production behavior it protects, not with the technology used to render it.

From the repository root:

| Command | Scope |
| --- | --- |
| `make test MODULE=Bleet` | Bleet package contracts and hosted chat presentation |
| `make test MODULE=Paddock` | Embedded preview, navigation policy and WebKit rendering |
| `make test MODULE=Pens` | Pen stores/tools and hosted permission flows |
| `make test-package MODULE=Inference` | Only the Inference package tests |
| `make test-app TEST_PLAN=Memory` | Only hosted Memory tests |
| `make test` | All package tests |
| `make test-app` | All ordinary hosted tests |
| `make test-tools` | Build, release and CI-routing Python tests |
| `make test-web` | Website Node tests under `web/tests` |
| `make verify` | Full app gate: lint, tooling, packages, hosted tests, build |

Names are case-sensitive. `MODULE=Tools` runs the GOATed, MCPClient, Pens and Shepherd consumers of its value-only contracts; `MODULE=goat` runs Hitch, which invokes the actual CLI. Unknown domain names fail. `make verify` clears focused test selections so a local module filter cannot narrow the full gate. Website changes also require `npm --prefix web run build:all` and `npm --prefix web run check:content`.

## Xcode

Open the maintained `apps/goat-macos/GOAT.xcodeproj`, choose the GOAT scheme, then select a domain under Product > Test Plan and run Product > Test. `All` is the default regression plan. Swift Testing suites are nested under `AppTests`, with a domain and behavior suite beneath it. Native XCTest classes remain discoverable in the same hosted bundle.

Host tests use an isolated GOAT home and test mode. The Swift Testing root is serialized because host tests share app state. Domain plans select existing tests; they do not copy test implementations or create extra app hosts.

## Ownership and useful coverage

- `Modules/Tests/<Domain>Tests` checks a module's contracts against real domain code and controlled fixtures. Pure package behavior should not require the app to launch.
- `App/Tests/<Domain>` checks host composition, permission flows and rendered behavior for that domain. App startup, preferences and uninstall belong under `App`.
- `App/Tests/Paddock` covers the embedded preview. These are app tests, even when the fixture contains HTML. The public website belongs only under `web/tests`.
- `apps/goat-macos/scripts/tests` checks distribution/build tools; `scripts/tests` checks repository CI routing.

Tests should demonstrate an observable outcome, including the failure or boundary that would regress. Keep meaningful data-loss, authority, cancellation, persistence and rendering checks. Do not add assertions that merely restate fixture setup, source-text snapshots as substitutes for behavior, or timing measurements with no regression criterion to the ordinary gate. Several assertions may belong to one coherent scenario; separate unrelated domains so either can run independently.

## Qualification and profiling

`make test-app TEST_PLAN=Qualification` selects synthetic profiling and live throughput fixtures. These workloads are separate from ordinary regression tests because their timings are observations, not portable pass/fail thresholds. Live tests still require their explicit opt-in environment and a configured endpoint; selecting a plan does not authorize changing an engine or executing returned tools.

See [transcript performance](transcript-performance.md) for the profiling procedure. Package live oMLX qualification retains its explicit opt-in guard. Skipped live tests are not evidence of successful live qualification.

## CI duration and preview diagnostics

CI runs lint once, then runs Release package tests, Release hosted tests and the
production Release build on separate macOS runners. The required `build-test`
check aggregates all three phases and lint. An unexpected skip, cancellation or
failure cannot pass that check. Content-only changes retain the explicit skip
policy in [ADR-0083](../adrs/0083-selective-app-ci.md). Local `make verify` remains
serial and complete. Each CI phase reports its duration in the run summary.

Dependency downloads are cached by OS/toolchain, architecture, phase and resolved
package versions. Compiled products and test homes are not cached. Tests always
execute, and the production build keeps its normal testability settings. See
[ADR-0095](../adrs/0095-parallel-verification-and-preview-diagnostics.md).

Hosted tests retain the full merged stdout/stderr next to their result bundle as
`Tests.log`. The console summarizes only three precisely matched WebKit framework
messages: retired helper services, empty connection IDs, and the helper's denied
read of `com.apple.networkd.plist`. Other diagnostics, including unknown sandbox
errors, crashes and test failures, remain visible. Set `GOAT_TEST_LOG_MODE=raw`
when invoking `make test-app` or `make verify` to print all messages. CI uploads
raw logs and result bundles for hosted test runs, including successful runs.

WebKit is now confined to HTML, SVG and bundled Mermaid previews. Syntax
highlighting and ordinary Markdown are native. Preview tests intentionally cover
separate ephemeral data stores and policy-driven view replacement, plus reuse of
a single artifact's view shell when toggling Source. Do not share cookies or
preview storage across artifacts to reduce a process count. Apple's deprecated
[`WKProcessPool`](https://developer.apple.com/documentation/webkit/wkprocesspool)
no longer controls pooling. Helper counts and framework noise are observations,
not portable test thresholds; compare the same full test plan and toolchain and
retain the raw logs. App Sandbox remains off under ADR-0007; adding private WebKit
entitlements is not a remedy for helper diagnostics.

### Live local worker pairing

The opt-in `liveParentDelegatesToSeparateWorkerAndResumes` test uses the saved engine connection and
credential without printing it. It warms the selected installed models, creates a disposable Pen with a
random source value, asks the parent to delegate reading it, verifies the child's citation, then checks
that the parent resumes on its original model and reports the value. No user project files are submitted.

Run against an idle engine with both models installed and pinned:

```sh
TEST_RUNNER_GOAT_LIVE_SUBAGENTS=1 \
TEST_RUNNER_GOAT_LIVE_ENGINE_NAME='Your engine profile name' \
TEST_RUNNER_GOAT_LIVE_MODEL='Qwen3.8-27B-MLX-4bit' \
TEST_RUNNER_GOAT_LIVE_WORKER_MODEL='Qwen3.5-9B-4bit' \
make test-app TEST_PLAN=Shepherd
```

Use the exact model IDs returned by the engine. Omitting the engine name selects the saved active profile.
The test is skipped by default and in CI. Passing deterministic tests alone does not qualify a live pair.
