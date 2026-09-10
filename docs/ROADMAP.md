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

The development branch includes the sidebar rendering fix, with a 300-point preferred width and a 600-point maximum. Settings → General → Manage groups storage paths into a tree and offers automatic uninstall after GOAT closes, with independent keep options and a private recovery folder. Partial uninstall defaults to preserving GOAT Home and chats, with app preferences unchecked; Uninstall all clears every keep option. Local-data choices live within uninstall. Preference reset applies the listed appearance and general defaults immediately without restarting GOAT. GOAT never quits as a side effect of preparing uninstall. These changes are not in the published Kid download.

Qualify automatic uninstall under the final signed distribution identity and evaluate standalone reset operations.

Continue improving accessibility, discoverability and compatibility based on observed user needs. Profile realistic long-running workloads and refine documentation as engine/runtime combinations are qualified.

Yearling and Ibex are reserved release codenames; a codename or version in planning is not a shipping commitment. [Versioning](VERSIONING.md) defines release identity.

## Ideas under consideration

Conversation branching and search, richer context retrieval, export/import, platform automation, managed skill setup, and contextual image/video work through the proposed Tether design remain future work. Kid does not provide third-party executable plugin loading, a managed GitHub skill installer or a media-generation workspace.

Changes to network behavior, executable capabilities or dependencies need an explicit design review. The [architecture decisions](adrs/README.md) retain the reasoning behind the current boundaries. Propose a concrete use case through the contributor process rather than assuming every idea will become a feature.
