# ADR-0002: SwiftUI-first, `@Observable` MV, actor domain

**Status:** Accepted · 2026-08-29

## Context

Target is macOS 26 (Tahoe) with Liquid Glass. We want maximal platform fidelity (toolbars, Settings scene, menus, materials) with minimal architecture ceremony for a small codebase built largely by agents, where predictable, idiomatic patterns beat clever ones.

## Decision

- **SwiftUI everywhere**, AppKit only as a garnish via representables where SwiftUI falls short (e.g., fine-grained text view control if the transcript needs it, decided by M1 measurement, not preference).
- **MV with `@Observable`**: observable state objects per feature (`ChatSession`, `SidebarModel`, `SettingsModel`) injected via environment. No TCA, no VIPER: dependency-free unidirectionality where it matters (Shepherd → transcript buffer → view) without a framework tax.
- **Swift 6.2, strict concurrency.** Domain services are actors (`Shepherd`, `MLXInferenceEngine`, `MCPServerManager`, memory stores). UI-facing state is `@MainActor`. Streams cross boundaries as `AsyncThrowingStream` of `Sendable` events.
- **Streaming rule:** token events are coalesced and flushed to the observable transcript at display cadence (~30–60Hz max), never per-token view updates; persistence checkpoints ~1s. This rule is architecture, not optimization.

## Consequences

Idiomatic, low-ceremony code any Swift developer (or agent) can extend; Liquid Glass adoption is free. Discipline required where frameworks would have forced structure: module boundaries are enforced by SPM target separation (UI cannot import MLX/GRDB: they aren't dependencies of the app target's view layer, only of the packages' internals behind protocols).

## Alternatives considered

TCA (rejected: dependency + learning tax outweighs benefit at this scale), AppKit-first (rejected: slower to build, glass adoption harder), SwiftUI + SwiftData property wrappers as architecture (rejected with ADR-0003).
