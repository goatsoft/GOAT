# ADR-0092: Selected toolchain resolution for Pen commands

Status: Accepted · 2026-09-20

Refines [ADR-0070](0070-confined-pen-command-jobs.md).

## Context

On Golden Gate, Apple's `/usr/bin` developer-tool shims may load private device frameworks during lookup. Inside a Pen sandbox this can fail before an approved git or Swift command runs. Resolving a Swift symlink all the way to `swift-frontend` also changes driver dispatch when that resolved name becomes argv[0].

## Decision

A dedicated local boundary runs only `/usr/bin/xcode-select --print-path`, with fixed arguments, bounded lifetime and no model text. It reads the host's selected developer directory before command confinement. The process-boundary checker permits this one implementation file; arbitrary commands still go through Pen authorization and sandboxing.

Prefer concrete toolchain paths over Apple shims. Preserve invocation names for driver aliases, while binding approval to the executable's filesystem identity and reporting its resolved path. Supply the selected toolchain PATH, macOS SDK and private module caches to child commands. Add only the selected toolchain directory to read-only runtime roots. Workspace/scratch writes, network grants, output limits, timeout and cancellation behavior remain unchanged.

Golden Gate's SwiftPM `swiftbuild` backend can still report a permission failure. Qualify the explicit native build mode (`--build-system native --disable-sandbox`) and report the recovery option. Do not silently rewrite model arguments or permit unconfined retries. Disabling SwiftPM's nested sandbox does not disable the outer Pen sandbox. Full Xcode project builds and detached services are not established by the package-build fixture.

## Consequences

Ordinary approved developer commands and shell children avoid unnecessary shim discovery. A changed toolchain or executable may require a fresh executable approval. Missing tools and sandbox/permission failures remain distinct from a successful command. The local locator is a reviewed process boundary, not a general command runner.

Golden Gate and Tahoe evidence is tracked in issue #33. A missing full Xcode installation must be reported as unavailable rather than a passed xcodebuild check.

## Alternatives considered

- Widen access to private device frameworks merely to satisfy shims. This adds unrelated runtime access.
- Canonicalize aliases before invoking them. This can select the wrong compiler mode.
- Remove process or filesystem restrictions for builds. This weakens the existing command contract.
- Silently select a different SwiftPM backend. Explicit arguments make the qualified mode reviewable.
