# ADR-0004: XcodeGen + xcodebuild CLI builds

**Status:** Accepted · 2026-08-29

## Context

Requirement: built with the Xcode CLI, agent-friendly, no IDE-owned project state. A real `.app` needs an app target (Info.plist, entitlements, asset catalog, signing). Plain `swift build` can't produce a first-class bundle. Candidates: raw committed `.xcodeproj`, XcodeGen, Tuist, swift-bundler.

## Decision

- **XcodeGen** (`project.yml` is the source of truth) generating the project; **`.xcodeproj` is gitignored**.
- **`xcodebuild`** drives builds/tests; **Make** wraps the incantations: `gen · build · run · test · lint · verify · release`.
- Feature code lives in local SPM packages (`Packages/Goat*`) so most tests run with plain `swift test --package-path`: fast, no simulator, no project generation needed.
- Signing: local automatic dev signing for now; Hardened Runtime + notarization wired into `make release` when we ship (ADR-0007).

## Consequences

- Zero merge conflicts on project files; agents edit YAML, not pbxproj. New checkout: `brew install xcodegen && make run`.
- One brew-level tool dependency (xcodegen, currently not installed on the dev machine; M0 step one).
- Tuist's power (caching, graphs) unneeded at this scale; revisit only if build times hurt.

## Alternatives considered

Committed `.xcodeproj` (rejected: conflict magnet, agent-hostile), Tuist (rejected: heavier tool for the same job here), swift-bundler (rejected: less mature for full macOS app bundles + asset catalogs).
