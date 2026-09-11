# Release a GOAT build

This guide is for maintainers. The maintenance candidate’s canonical version is `0.1.1`, public label **0.1.1 (Kid)** and intended release tag `v0.1.1`. The published 0.1.0 release remains unchanged. Identity comes from `apps/goat-macos/release.json`.

1. Review [Release readiness](../RELEASE-CHECKLIST.md). Complete content, distribution, live-service, clean-machine and performance checks appropriate to the release.
2. Follow [Versioning](../VERSIONING.md) to generate metadata, build a separate candidate and verify source/bundle/artifact agreement. Do not restart an app doing active work.
3. Record the candidate’s exact source revision and evidence. A later commit or squash requires a newly qualified artifact; old manifests cannot be relabelled.
4. After approval, tag the final accepted commit. When enabled, the release workflow checks the tag and builds a **draft** release. For a locally signed release, upload the exact qualified artifacts to a draft targeting that commit; keep automated signing disabled.
5. Review signing/notarization, the mounted DMG, checksums, notices, instructions and release notes before publishing the draft.

Repository visibility, website deployment and release publication are separate operations. The Pages workflow is manual-only and requires both its publication variable and explicit input. See [Website maintenance](../../web/README.md).

Use private Actions secrets for Developer ID and notarization credentials. An ad hoc candidate does not establish clean-machine Gatekeeper acceptance. CI uses a macOS 26 runner for app verification; successful CI alone does not close interactive acceptance.

## Public preview before the first release

The source repository and both websites can open before an app release is tagged. Keep `web/publication.json` at `releaseTag: null`; the website then links to source-build instructions. Use the [feedback guide](../PUBLIC-PREVIEW.md) to explain the scope and collect feedback.

Before the first public push, archive the development history privately, review the exact distributable tree and prepare one initial commit. Verify that commit from a fresh clone, including source builds, documentation, dependency notices and example packages. Do not publish archive branches or old tags. Once contributors can clone the public repository, preserve normal history instead of squashing it again.

Push the initial `main` to the private repository with publication disabled and let CI run. Review repository metadata, community links and any existing Actions logs before changing visibility. Configure branch protections, private vulnerability reporting and release-tag ownership. Required release-signing approval must be available and verified before adding signing secrets.

After source and content review, make the repositories public and manually publish both sites using [Website maintenance](../../web/README.md). Check HTTPS, navigation, search, legal pages and source-build links on the actual domains. No version tag or draft binary release is needed for this stage.

Release qualification continues during the preview. Signing, notarization and clean-Mac acceptance are required before official downloads; they are not claims made by publishing source. When the final commit is accepted, follow the tagged release procedure above. Publish the approved download before enabling its website link, then deploy the launch copy and announce availability.

## Signing setup

Contributor builds default to ad-hoc signing. For a stable local identity, create an ignored `apps/goat-macos/signing.local.mk` file with your certificate's exact name and team:

```make
CODE_SIGN_IDENTITY = Apple Development: Your Name (CERTIFICATE_ID)
RELEASE_SIGNING_IDENTITY = Developer ID Application: Your Name (YOURTEAMID)
DEVELOPMENT_TEAM = YOURTEAMID
```

Use `security find-identity -v -p codesigning` to find installed identities. A Developer ID Application identity can also sign local acceptance builds. `make build`, `make test-app` and `make release` pass these settings to Xcode. A certificate fingerprint can select an exact identity when names are duplicated. Command-line make assignments override the local file. `RELEASE_SIGNING_IDENTITY` defaults to `CODE_SIGN_IDENTITY` when not set. Certificates and their private keys stay in Keychain; the local file contains only the signing selection. Keep test harnesses separately signed and isolated from the normal app.

Official downloads use Developer ID Application signing with hardened runtime. The release workflow verifies the app and CLI's publisher and team, requires notarization to return Accepted, staples and validates the ticket, then records final checksums. It creates a draft for manual publication. See [Apple's Developer ID guidance](https://developer.apple.com/developer-id/).

## Local notarization

Local notarization can use a Keychain profile without exporting signing credentials to GitHub. Run `xcrun notarytool store-credentials "GOAT-notary"` in your terminal and follow its prompts for your Apple Account, team and app-specific password. Then run `NOTARY_KEYCHAIN_PROFILE=GOAT-notary DMG=/path/to/GOAT-0.1.1.dmg ./scripts/notarize.sh` from `apps/goat-macos/`. The script still requires Apple's Accepted result and validates the stapled ticket. Regenerate the artifact manifest and checksums after stapling. This does not enable the GitHub release workflow or replace clean-Mac acceptance.

## GitHub approval gate

Configure these controls before enabling the workflow:

1. Create the `release-signing` environment in `goatsoft/GOAT`. Require approval from the release owner. Allow that owner to approve their own runs, since the same person creates release tags. Disable administrator bypass and restrict deployment to `v*` tags.
2. Restrict creation, updates and deletion of release tags to the owner through a repository tag ruleset. Protect the release workflow and scripts through the repository's review rules.
3. Store the signing and notarization credentials **only in that environment**, not as repository or organisation secrets: `MACOS_CERTIFICATE` (base64 PKCS#12 certificate/private-key export), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY` (exact Developer ID Application name), `APPLE_TEAM_ID`, `NOTARY_APPLE_ID`, and `NOTARY_PASSWORD` (an app-specific password).
4. Set repository variable `GOAT_RELEASE_OWNER` to the owner's GitHub login. Set `GOAT_RELEASE_SIGNING_ENABLED` to `true` only after testing the environment's approval requirement. Missing or different values leave the workflow disabled.

Required reviewers are available for public repositories on GitHub Free, Pro and Team. Private repositories need an eligible Enterprise plan for this protection. While the repository is private without that feature, leave CI signing disabled and keep the signing key local. Making the repository public remains a separate publication decision. See [GitHub's environment requirements](https://docs.github.com/en/actions/how-tos/managing-workflow-runs-and-deployments/managing-deployments/reviewing-deployments).

The workflow runs only in the official repository for tags pushed by the configured owner, including checks on the actor requesting a rerun. Verification runs in a separate job without signing credentials. The signing job uses `release-signing`, so its environment secrets become available only after the configured approval. Fork and pull-request builds do not receive official signing credentials. A YAML environment name alone does not configure required reviewers; complete the repository settings above first.
