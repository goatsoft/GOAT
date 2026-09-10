# Release readiness

**0.1 (Kid) is available as a signed, notarized Mac download.** This is the acceptance checklist for ongoing releases, not a claim that every configuration or workflow has been tested. See [Known issues](KNOWN-ISSUES.md#release-qualification) for the scope of Kid’s installation check. Detailed machine logs and historical reports remain in the private maintainer archive.

## Product and content

- Verify the intended release’s current workflows: engine/model selection, chat, Pens, native file and command tools, Lead, permissions, memory, previews, extensions and local control.
- Review the website, seven interface illustrations, documentation, README and known issues against the implemented build.
- Confirm private reporting contacts, privacy/storage disclosures, MIT/artwork scope and complete bundled notices.
- Review every file in the proposed public tree. Exclude private planning, diagnostic logs, credentials, generated build outputs and development-history backups.

## Runtime acceptance

- Exercise supported engine/model pairings and record versions, configuration and feature results. Distinguish transport fixtures from live qualification.
- Check configured MCP and Hindsight services, denied actions, revocation, timeouts and unknown-outcome recovery.
- Verify native commands with supported runtimes and explicit network policy. Do not generalise one successful fixture to arbitrary project reliability.
- Review keyboard and VoiceOver behavior, contrast, text scaling, themes, reduced motion and narrow/large windows.
- Profile idle, streaming, tool-heavy turns, long transcripts, large workspaces/memory maps and repeated preview use. Retain useful CPU, memory and responsiveness evidence; unit-test duration is not a substitute.

## Distribution

- Build from the final intended source revision with consistent version, build and codename metadata.
- Validate app and CLI architecture, Developer ID signing and notarization for official downloads, staged/mounted DMG contents, licence notices and checksums.
- Test installation and launch on a clean supported Mac. Verify the actual Gatekeeper path and local-network permission behavior.
- Qualify automatic uninstall with the final signed/notarized app: copied-helper execution, removal options, cancellation, other-instance exclusion, recovery records and app/CLI Trash handling. Use disposable installations and data; never interrupt active work.
- Preserve evidence for supported upgrades and any previously distributed builds. Do not reuse an existing artifact name with different contents.

## Publication

Verify the owner-only release tag rules and required approval on the `release-signing` environment before adding signing secrets or enabling releases. Run required CI on the final commit, review the draft release and verify download instructions. Make repository visibility, Pages deployment and release publication deliberate steps. Confirm both sites, cross-links and the published artifact before announcing availability.

Use [Versioning](VERSIONING.md) and [Releasing](wiki/Releasing.md) for the procedure. Candidate verification and content completion do not themselves approve a public release.
