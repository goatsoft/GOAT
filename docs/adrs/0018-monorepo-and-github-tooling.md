# ADR-0018: Monorepo layout + GitHub build/release tooling

**Status:** Accepted · 2026-08-30 · `web/` refined by [ADR-0041](0041-website-as-vite-vue-spa.md)

The layout decision remains current. The original publication plan below is superseded by [ADR-0040](0040-single-source-release-identity.md) and [ADR-0078](0078-owner-approved-release-signing.md): the public preview has source and documentation, Pages publication is manual, and official downloads require signing and notarization. App CI now uses macOS 26. Private planning is excluded from the public tree. Follow [Releasing](../wiki/Releasing.md) for the current procedure.

## Context

GOAT is going open source. A single flat repo mixing the Swift app, docs, and a marketing/site directory would tangle three audiences (users, contributors, the curious) and three release cadences. We also need reproducible builds, downloadable releases, browsable docs, and a public face, none of which existed.

## Decision

**Monorepo, three top-level areas:**

```
apps/goat-macos/   # the app (App/ + Packages/ + project.yml + Makefile + art/)
web/               # the GitHub Pages landing site (Vite + Vue SPA since ADR-0041)
docs/              # shared docs: PLAN, DESIGN, ENGINES, ADRs, wiki/ source
.github/           # CI + release workflows, issue/PR templates, community health
assets/            # shared brand images
```

`make` targets run from the repo root and delegate into `apps/goat-macos`, so developer muscle memory (`make build`, `make verify`) is unchanged.

**GitHub tooling:**

- **CI** (`ci.yml`): swift-format lint (needs no SDK) + package/app build & tests on push and PR.
- **Release** (`release.yml`): tag `v*` → Release build with Hardened Runtime → DMG (pure `hdiutil`, no extra deps) → optional notarization (skipped unless Apple secrets are set) → checksums → a **draft** GitHub Release. Signing is **ad-hoc by default, notarize-ready**: the full Developer ID path is wired but gated on secrets, so the project ships usable binaries today and Gatekeeper-clean ones the moment credentials exist ([ADR-0007] governs the runtime).
- **Pages** (`pages.yml`): deploys `web/` on change.
- **Docs** live three ways by nature: **ADRs/PLAN** in-repo for contributors, the **wiki** (source in `docs/wiki/`) for users, **Issues/Discussions** for the conversation.

## Consequences

Clean separation with no DX regression. Binaries are downloadable from day one; notarization is a secrets-only upgrade. One real constraint: GOAT targets macOS 26, and GitHub-hosted runners may lag. Workflows pin `macos-15` with a one-line bump point, or a self-hosted Xcode-26 runner. Placeholder `OWNER/REPO` strings in the site and docs are the only things that need filling in after the repo is created.

## Alternatives considered

Separate repos per concern (rejected: coordination tax, atomic cross-cutting changes become multi-PR); app at repo root with site on a `gh-pages` branch (rejected: branch-as-directory is harder to reason about than `web/`); Fastlane for release (rejected: a 30-line script + `hdiutil` covers it without the dependency); notarized-only releases (rejected: blocks all binaries behind a paid account before the project has users).
