# Release identity and candidate preparation

Implemented by ADR-0040. Public release approval, clean-machine acceptance and performance qualification are still separate gates; see [release readiness](RELEASE-CHECKLIST.md).

`apps/goat-macos/release.json` is the editable product identity: canonical `version`, `codename` and positive integer `build`. The current development identity is **0.1.0 / Kid / 1339**, above the legacy build 1337. Increment the build when preparing a new candidate with changed content. The record alone does not make a candidate distributable.

| Surface | Kid value |
|---|---|
| About and Activity Log, either presentation mode | `0.1 (Kid)` |
| Website label and GitHub draft title | `GOAT 0.1 (Kid)` |
| Bundle version / tag / DMG filename | `0.1.0` / `v0.1.0` / `GOAT-0.1.0.dmg` |
| Secondary UI diagnostics | `Development · build 1339` or `Candidate · build 1339` |

Only a zero patch is omitted from display; `0.1.1 (Kid)` keeps its patch. Choose codenames from [CODENAMES.md](CODENAMES.md). Patch candidates preserve their release-line codename. Versions change for releases, not milestones or rebuilds.

## Build and validation

`make gen` validates the record and generates `.build/release-settings.yml`, which XcodeGen includes. The tracked generated Info.plist contains build-setting references. Missing metadata, malformed versions and conflicting `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` or `GOAT_CODENAME` environment/Make overrides fail. Run `make gen` before opening the generated Xcode project. Direct edits or overrides in Xcode are not a supported release path; bundle validation catches drift before packaging.

Normal builds use **Development**. `make release` and `make dmg` use **Candidate** even with Release optimisation. A **Release** channel requires an explicit matching `RELEASE_TAG`, an exact canonical tag pointing to HEAD, and clean source. About and Log always disclose the channel of unpublished builds; missing UI metadata is shown as unknown rather than falling back to Kid.

Bundle metadata records HEAD, a SHA-256 of the working source and whether it was dirty. The source fingerprint includes tracked and nonignored untracked files, file contents and executable bits, excluding generated `App/Info.plist`. Ignored build output, dependency caches and local data are not hashed. This binds packaging to the working source, including uncommitted candidates; it is not a reproducible-build or supply-chain attestation.

```sh
make verify CONFIG=Release SWIFT_FLAGS='-c release'
cd web
npm run build
npm run docs:build
cd ..
make dmg DIST=/absolute/path/to/a/new/candidate-directory
```

For acceptance while the normal app is running, use a separate derived-data directory, for example `DERIVED=/path/to/separate-derived-data`, on both Make commands. These commands build and launch test hosts; they do not use `make run` or restart the normal app. Never restart GOAT during active chat or command work.

Packaging validates the original app, staged app and app inside a read-only mounted DMG against the current record and source fingerprint. It checks signatures, arm64 app/CLI architecture, CLI byte agreement, bundled and disk-image licence text, and the Applications shortcut. The filename comes from the record; no `dev` fallback or independent filename version exists. Existing candidate outputs are refused: choose a fresh `DIST` directory. A generated `release-metadata.json` records identity, channel, source and artifact hashes; `SHA256SUMS.txt` covers the DMG and manifest.

Increment `build` for a new candidate with changed content; keep it stable for a rebuild of the same candidate. The validator checks progression against the last different checked-in record and the legacy floor. For a previously distributed candidate, also provide its saved manifest:

```sh
python3 apps/goat-macos/scripts/release-metadata.py check --channel Candidate \
  --previous /path/to/previous/release-metadata.json
```

The distributed manifest is necessary to distinguish a new candidate from a rebuild when the release record itself has not changed. Git history alone cannot establish which local artifacts were shared. Confirm there were no privately distributed builds above 1337 before externally distributing this first managed candidate.

## Tagged draft workflow

After acceptance and explicit release authorization, the tag-triggered workflow:

1. Validates the source, exact tag, macOS/SDK host and previous GitHub release manifests, including drafts. Existing tags owned by a release, regressing builds/versions, changed patch codenames and absent legacy manifests fail closed.
2. Runs lint, release-script regressions, optimised package tests, app tests, a normal Release build, and website/docs builds on the tagged commit.
3. Builds/signs the app and CLI, packages and remounts the DMG, requires notarization and stapling, and regenerates the manifest/checksums after stapling.
4. Uses `gh release create --draft --verify-tag`, with the derived title and explicit assets. It never uploads replacement assets to an existing release. Workflow runs are serialized rather than cancelled.

The website reads its displayed label from the release record. `web/publication.json` controls availability separately. With `releaseTag` null, the main action leads to setup documentation. Set the exact approved `v<version>` tag only at launch; downloads then point to that tag’s artifact, with no runtime release lookup. `web/package.json` is checked against the record as a compatibility mirror.

See [Releasing](wiki/Releasing.md) for signing and runner setup. A CI definition is not evidence that remote CI ran. Draft creation is not publication approval, notarization is not clean-machine acceptance, and ordinary tests do not complete runtime performance qualification.
