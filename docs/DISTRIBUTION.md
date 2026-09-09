# Distribution contents

The public source tree contains the application, its build tools and tests, website sources, current documentation, architecture decisions, reusable examples and required licence notices. Generated sites, application bundles, disk images and private maintainer evidence belong outside that tree.

## Source repository

| Area | Purpose |
| --- | --- |
| `apps/goat-macos/` | Native app and modules, tests, build configuration and source assets. |
| `web/` | Both static sites, shared assets and locked build dependencies. |
| `docs/` | User guides, reference, current project documentation and ADRs. |
| `examples/` | Reusable example sources and deliberately included importable packages. |
| `assets/` | Shared artwork used by repository documentation. |
| `.github/` | CI, deliberate publication workflows and contribution templates. |
| Root licences and community files | Terms, attribution, contribution and security guidance. |

Keep architectural decisions even when later decisions supersede them, with clear status and links. Move session handovers, historical audits, one-off planning and acceptance logs to a private maintainer archive. Do not include that archive or a development-history bundle in a source release.

Artwork source files used to maintain the application’s presentation belong with the project and retain their separate terms. Remove unused exports only after checking code, asset-catalogue and website references. Example `.goated` files must match their documented source and contain no private data or executable extension payload.

## Licences and notices

GOAT code, documentation and examples use MIT. GOAT logos, mascots, icons and other identified brand assets use the separate artwork terms. Third-party components retain their upstream licences; GOAT’s MIT declaration does not relicense them.

The root [third-party notices](../THIRD-PARTY-NOTICES.md) identify bundled dependencies and link to full licence text. Refresh notices against the actual resolved dependencies before preparing a release. Keep upstream copyright statements, notices and licence exceptions intact.

### Refresh the notices

The tracked `apps/goat-macos/Package.resolved` pins the app's reviewed dependency graph. `make gen` restores it into the generated Xcode project; build targets require that resolution. `Modules/Package.resolved` separately pins the package tests and CLI. After a deliberate dependency update, copy the reviewed app resolution back to the tracked lock before refreshing notices. The notice check compares that lock with the recorded app dependencies even without an Xcode checkout.

Run `npm ci` in `web/`, generate the Xcode project and resolve its packages. Then run from the repository root, supplying the checkout directory used by that build:

```sh
python3 scripts/distribution-notices.py \
  --swift-checkouts /path/to/DerivedData/SourcePackages/checkouts \
  --app-resolved apps/goat-macos/GOAT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
python3 scripts/distribution-notices.py --check
```

The refresh checks installed versions and Swift revisions, preserves full licence texts and records input/output hashes. Review new or changed licences and upstream attribution sources under `third-party/`. When Mermaid dependencies change, rebuild and review the embedded renderer against the same dependency graph; matching the top-level version alone does not establish the versions of its embedded dependencies. The CLI can resolve a different Swift package version from the app, so its separate notices must remain included. The check detects drift; it does not provide a legal assessment or identify code copied outside declared dependencies.

## Build outputs

Before distributing a Mac build, include GOAT’s MIT licence, artwork terms and complete dependency notices in the application resources and disk image. Verify their bytes in the mounted image as well as the application and CLI signatures. A source-repository link alone is not a substitute for notices required with binary redistribution.

Website builds must serve the full third-party notices alongside the rendered legal pages. Check both the landing and documentation domains. Keep dependency manifests and attribution sources available to future maintainers.

## Final review

Inspect the exact candidate tree for credentials, personal paths, diagnostic payloads, generated projects, build products, model weights and obsolete reports. Review file sizes and binary assets as well as Markdown. Confirm download links refer to approved artifacts and that contact channels are operational.

Use [Release readiness](RELEASE-CHECKLIST.md) for acceptance and [Versioning](VERSIONING.md) for source and artifact identity. Do not treat this document as evidence that a particular build has passed those checks.
