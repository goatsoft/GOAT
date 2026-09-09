# ADR-0040: Single-source release identity

Status: Accepted (implemented 2026-09-08)

## Context

The first public release must read `0.1 (Kid)`. Existing tooling uses canonical `0.1.0`, but version, codename, build and display strings are managed independently. Release tags can override the source version without agreement checks, and build numbers do not currently increment in CI as documented.

## Decision

Use one checked-in release record for canonical semantic version, codename and candidate build. Derive Xcode settings, UI labels and release artifacts from it. Display a zero-patch release as `major.minor (Codename)` while retaining the canonical three-component version for bundles, tags and filenames. Preserve nonzero patch components. Keep version identity independent of presentation mode.

Validate source, tag, built bundle and packaged app before creating release assets. Candidate builds advance monotonically; public versions advance only for an intentional release. Development/candidate qualifiers distinguish unpublished builds. The implementation and acceptance sequence is in [VERSIONING.md](../VERSIONING.md).

## Consequences

The public first-release label is `0.1 (Kid)`, with canonical `0.1.0` and tag `v0.1.0`. A mismatch fails explicitly instead of falling back to stale values. One metadata edit replaces several independent edits, and packaging validates the actual artifact.

Implemented by the release record, metadata validator, XcodeGen include, bundle/DMG checks and tagged draft workflow. Local candidates carry a source fingerprint and explicit channel. Candidate progression checks use source history and, for distributed artifacts, saved release manifests; source history alone does not prove which builds were shared. Public release acceptance remains separate. This refines ADR-0018 without rewriting its historical decision.

## Alternatives considered

Changing all machine versions and tags to two components would abandon the existing semantic-version convention unnecessarily. Keeping separate marketing labels in each UI makes drift likely. Deriving release numbers from milestone or commit counts would change product identity for reasons unrelated to a release.
