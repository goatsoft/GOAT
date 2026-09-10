# Roadmap

GOAT’s first release is **0.1 (Kid)**. The capabilities below are included in the downloadable Mac app. Future work has no promised delivery date.

## Available in Kid

- First-launch engine guidance, an empty connection list and automatic activation of the first saved engine.
- Native streaming chat with compatible engines, model selection, effort presets and generation statistics.
- Pens with project instructions, linked workspaces and local Git status.
- Herder file tools and confined non-interactive command jobs, with scoped permissions.
- Lead guidance, automatic chat naming and grouped tool activity.
- Local Markdown/LLM Wiki memory and optional bank-scoped Hindsight integration.
- Paddock previews for supported documents.
- Built-in extension controls, reusable skills and declarative GOATed packages.
- JUDAS connection policy, session Activity Log, themes and local reading preferences.
- Optional Hitch local API/CLI and the Pronk contributor example.

Downloads and release notes are on [GitHub Releases](https://github.com/goatsoft/GOAT/releases/tag/v0.1.0). See [Known issues](KNOWN-ISSUES.md) for current limitations.

## Next priorities

The development branch includes the sidebar rendering fix, with a 300-point preferred width and a 600-point maximum. Settings → General → Manage GOAT data also includes a review-only reset and uninstall prototype. It separates preference reset, selected local data and app/CLI removal, shows storage locations, and copies a backup and recovery checklist. It does not reset preferences, create backups, delete data or quit GOAT. These changes are not in the published Kid download.

Evaluate the reset and uninstall prototype before implementing cleanup operations.

Continue improving accessibility, discoverability and compatibility based on observed user needs. Profile realistic long-running workloads and refine documentation as engine/runtime combinations are qualified.

Yearling and Ibex are reserved release codenames; a codename or version in planning is not a shipping commitment. [Versioning](VERSIONING.md) defines release identity.

## Ideas under consideration

Conversation branching and search, richer context retrieval, export/import, platform automation, managed skill setup, and contextual image/video work through the proposed Tether design remain future work. Kid does not provide third-party executable plugin loading, a managed GitHub skill installer or a media-generation workspace.

Changes to network behavior, executable capabilities or dependencies need an explicit design review. The [architecture decisions](adrs/README.md) retain the reasoning behind the current boundaries. Propose a concrete use case through the contributor process rather than assuming every idea will become a feature.
