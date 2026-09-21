# ADR-0093: Maintained Xcode project and build-time release identity

**Status:** Proposed · 2026-09-21 · supersedes the generated-project ownership in ADR-0004

## Context

The app has a real Xcode project, but every Make build regenerates it. Intentional target, scheme and build-setting edits made in Xcode disappear. Contributors need a fresh-checkout IDE workflow with the same targets, pinned packages, signing defaults and provenance as command-line builds.

Generated projects with committed configuration files would preserve edits to those files, but Xcode's target-setting editor writes to the project itself. Retaining regeneration would still require manually transferring those edits to another source of truth. There are only two app targets; maintaining their project directly is an acceptable tradeoff.

## Decision

- Commit `GOAT.xcodeproj/project.pbxproj`, the shared GOAT scheme and its app dependency lock. The project owns targets, membership, dependencies and build settings. Remove the XcodeGen specification and regeneration from supported builds.
- Keep user schemes, workspace state and signing credentials out of version control. The local Modules package retains its own manifest and dependency lock.
- Keep `release.json` authoritative for version, build and codename. An always-run app build phase generates the input Info.plist in the derived-files directory from the committed template and current source identity. Direct IDE builds therefore refresh provenance without regenerating or editing the project.
- Preserve ad-hoc development signing. Official signing, hardened-runtime packaging, clean-tag validation and owner-approved publication retain their existing command-line release workflow.
- `make open` opens the maintained project. `make gen` remains a compatibility alias for validation, with no project rewrite. `make clean` removes build products only.
- Maintain domain test plans alongside the shared scheme. Package tests belong to their owning module; hosted tests share one isolated bundle with serialized domain suites. Website and build-tool checks remain separate. Qualification workloads are explicit, and command-line runs reject empty selections. See [Testing by domain](../reference/testing.md).
- Verify project/package composition, source membership, release metadata and dependency locks in CI. Verify both IDE and command-line build/test paths on supported macOS hosts before accepting this decision.

## Consequences

Settings edited in Xcode persist as reviewable project diffs. Contributors must include project membership changes when adding files and resolve project conflicts deliberately. Build-time metadata generation uses Python and Git but no network and never changes tracked source. Ordinary IDE development does not require XcodeGen or release credentials.

Apple documents [build-setting ownership and precedence](https://developer.apple.com/documentation/xcode/configuring-the-build-settings-of-a-target/) and [shared scheme configuration](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project/). The generated-project alternative supports [configuration files and scheme actions](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), but does not preserve direct project edits through regeneration.
