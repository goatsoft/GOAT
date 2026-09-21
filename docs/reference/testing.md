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
