# ADR-0095: Parallel verification and preview diagnostics

**Status:** Accepted · 2026-09-24 · refines [ADR-0083](0083-selective-app-ci.md)

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
