# ADR-0095: Parallel verification and preview diagnostics

**Status:** Accepted · 2026-09-24 · Amended 2026-09-25 · refines [ADR-0083](0083-selective-app-ci.md)

## Context

Release verification runs package tests, hosted app tests and a production build
serially. Hosted tests enable testability; the production build does not. Reusing
the test build as the production qualification would change what the gate checks.
The workflow also repeats the separate lint job inside `make verify`.

Issue #28 predates native syntax highlighting. WebKit now hosts HTML, SVG and
Mermaid previews only. Framework helper diagnostics still obscure useful test
output. Each artifact's ephemeral storage and policy-driven replacement protect
preview isolation, so process count alone is not a suitable optimization target.

## Decision

Run lint once, then three independent macOS matrix phases: Release package tests,
Release hosted tests and the production Release build. Preserve `build-test` as
a required aggregate check. Fail closed on missing results, cancellation, failed
change detection and unexpected skips. Keep the explicit content-only route.
Local `make verify` and release qualification remain unchanged.

Cache dependency downloads using exact resolved-package, OS/toolchain,
architecture and phase identities. Do not cache compiled products or test homes:
they carry absolute paths, incremental build state and mutable test data. Builds
and tests always execute. Report phase timings so future build-cache work can be
justified by measurements instead of assuming an incremental build will be safe.

Preserve full hosted-test stdout/stderr alongside the result bundle. Summarize
only an exact allowlist of successful-run WebKit framework messages in the
console, with counts and an opt-out. Never suppress arbitrary errors or replace
the child process exit status. Upload the diagnostics on success and failure.

Retain per-artifact ephemeral storage. Do not introduce deprecated WKProcessPool
instances, shared website storage, app sandbox changes or test-only production
behavior to reduce helper counts. Existing Source-mode shell reuse remains the
supported reuse boundary. Wider pooling is outside this change.

## Consequences

The longest verification phase determines compute wall time instead of their
sum, subject to runner availability. Parallel jobs increase peak runner usage;
dependency caches reduce downloads but do not promise incremental compilation.
Release tests and the non-testable production build both remain mandatory.

Console noise decreases without discarding diagnostics or claiming that the
underlying framework messages have been fixed. Issue #28's original request for
fewer helper launches is not resolved by log summarization; any future reuse must
preserve isolation and demonstrate an actual measured reduction.

## Amendment: compiler-managed compilation cache (2026-09-25)

Issue [#59](https://github.com/goatsoft/GOAT/issues/59). Clean compilation, not
queueing or downloads, dominates the two Xcode phases.

**Decision.** Permit Xcode's compiler-managed compilation cache as a disposable
performance hint for the `app-tests` and `release-build` phases. The cache is a
content-addressed store outside DerivedData. Each compile job's key hashes its
complete inputs (sources, flags, SDK, dependencies and module outputs), so an edit
or setting change misses and recompiles; it cannot hit a stale entry. Every
verification invocation still runs its build commands and all applicable tests,
and the production build keeps its distinct testability settings. DerivedData,
build products, result bundles, test homes, credentials and signing material are
still never cached. Unrestricted DerivedData restoration remains prohibited.

**Identity.** Stores are namespaced by schema version (`xcode-cas-v1`), runner OS
and architecture, the existing OS build/Xcode/Swift toolchain identity, phase
(which separates testable and production builds), `Package.resolved` and the
Makefile that supplies command-line build settings. A namespace change starts
empty; there is no cross-namespace restore fallback.

**Trust and lifecycle.** Successful pushes to `main` save the trusted store.
Pull requests restore the newest store for their namespace from their own ref or
`main` and save only to their own PR-scoped cache, which GitHub never exposes to
`main` or other pull requests; no workflow promotes PR data. A `main`-only prune
job keeps the newest entry per namespace; unused namespaces expire through
GitHub's seven-day eviction. A restored store over 3 GB is discarded and the
phase builds cold. Misses and restore failures use the ordinary clean build.

**Rollback.** Set the repository variable `GOAT_CI_COMPILATION_CACHE=off` to skip
restore, save and pruning; the phases then run exactly as before this amendment.
Bumping the schema version invalidates every store.

**Measurements.** Local Release build of `c38eb23`, M1 Max, Xcode 27.0 (27A266a),
fresh DerivedData each run, shared package checkouts:

| Mode | Wall time | Compiler cache |
| --- | ---: | --- |
| Cache disabled | 184 s | n/a |
| Empty store (populating) | 195 s | 0 hits, 461 misses; 608 MB |
| Warm, same DerivedData path | 15-17 s | 331-337 hits, 0 misses |
| Warm, different DerivedData path | 187 s | 309 hits, 26 misses |
| Warm, one source edit in the app | 76 s | 336 hits, 1 miss; edit present in binary |
| Warm, edit reverted | 16 s | 337 hits, 0 misses; edit absent from binary |
| Warm, Swift compilation condition changed | 189 s | 312 hits, 26 misses |

**Rejected.** Reusing a store across DerivedData paths: the 26 whole-module
`SwiftCompile` jobs, which hold nearly all compile time, miss when intermediate
paths change. CI therefore keeps its stable `.build/DerivedData` path. Caching the
SwiftPM package phase is out of scope; SwiftPM does not use this store. Sharing a
store between the testable and production phases is not attempted until
measurements show compatible reuse.

CI measurements for cold, warm-unchanged and source-edit runs are recorded in the
implementing pull request and the run summaries, which now report per-phase
duration, cache state and size, compiler hits and misses and the largest entries
of Xcode's build timing summary.
