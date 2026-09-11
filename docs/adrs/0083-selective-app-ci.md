# ADR-0083: Selective app verification for content changes

**Status:** Accepted · 2026-09-11 · refines [ADR-0018](0018-monorepo-and-github-tooling.md)

## Context

Documentation and website updates currently wait for the full macOS build and app tests, often around 17 minutes. These changes need web and content validation without rebuilding an unchanged application.

## Decision

Keep CI triggered for every push and pull request to `main`. A lightweight change detector compares the complete push range or the pull request's merge base to its head. Both sides of a rename count.

Skip macOS lint and app verification only when every changed path is in `docs/`, `web/`, shared brand `assets/`, or matches root `*.md`. Exclude root `LICENSE-ART.md` and `THIRD-PARTY-NOTICES.md` from that Markdown rule because they supply bundled app notices. App files, shared build inputs, workflows and unknown paths retain full verification. Missing or uncertain detection also retains full verification.

Website tests, both site builds, content links, distribution notices and generated module documentation remain checked. Release-tag verification is unchanged. The exact path policy and regression tests live in `scripts/ci-changes.py` and `scripts/tests/test_ci_changes.py`.

## Consequences

Content updates avoid allocating macOS runners. New root Markdown guides need no allowlist update. Changes to the detector itself still receive full verification. This changes CI routing, not the local `make verify` target or release qualification requirements.

## Alternatives considered

- Workflow-level path exclusions: rejected because skipped workflows can leave required checks pending and would omit content validation.
- An allowlist of individual root guides: rejected because new documentation would unnecessarily trigger app builds.
- A third-party filtering action: unnecessary for this small, tested policy.
