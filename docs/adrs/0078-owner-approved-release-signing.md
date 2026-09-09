# ADR-0078: Owner-approved release signing

Status: Accepted · Refines [ADR-0007](0007-no-app-sandbox.md)

## Context

Ad-hoc signing allows contributors to build GOAT without Apple membership, but macOS cannot reliably preserve local-network permission across changed ad-hoc identities. Official downloads need a verified publisher, hardened runtime and notarization. The release owner must approve use of their signing key.

## Decision

Keep ad-hoc signing as the shared project default. Maintainers may select a certificate and team in an ignored `signing.local.mk`; make forwards those settings to Xcode. No private key or personal signing identity is committed.

Separate CI verification from the signing job. Release automation is disabled unless explicitly enabled for the configured owner in the official repository. Signing requires the `release-signing` environment, configured with that owner's approval and release-tag restrictions. The same owner may initiate and approve a run. Signing credentials belong only to that environment. Forks and pull requests have no official signing path.

Check all required signing secrets before certificate import. Verify the resulting app and CLI signatures against an Apple trust anchor, the expected Developer ID Application publisher and team, hardened runtime and a secure timestamp. Official releases must complete notarization and stapling; missing credentials or a rejected submission fail the workflow. Publication remains manual from a draft release.

## Consequences

Contributor builds remain available without paid Apple membership. Local acceptance builds can use a stable certificate while official signing remains disabled. GitHub environment protection must be configured outside YAML; private repositories without required-reviewer support must keep the release key local. A repository visibility change, credential export or publication is a separate owner action.

Configuration and signature regressions check missing credentials, wrong teams, non-Developer-ID certificates, malformed certificate encoding, absent hardened runtime and accidental notarization skipping. This does not replace live notarization and clean-machine Gatekeeper acceptance.
