# Roadmap

GOAT’s first release is **0.1 (Kid)**. The capabilities below are available to explore in the public source preview; binary release acceptance is still in progress. Future work has no promised delivery date.

## Kid: public source preview

- Native streaming chat with compatible engines, model selection, effort presets and generation statistics.
- Pens with project instructions, linked workspaces and local Git status.
- Herder file tools and confined non-interactive command jobs, with scoped permissions.
- Lead guidance, automatic chat naming and grouped tool activity.
- Local Markdown/LLM Wiki memory and optional bank-scoped Hindsight integration.
- Paddock previews for supported documents.
- Built-in extension controls, reusable skills and declarative GOATed packages.
- JUDAS connection policy, session Activity Log, themes and local reading preferences.
- Optional Hitch local API/CLI and the Pronk contributor example.

The remaining work is release qualification, content/distribution review and a verified installation experience. See [Release readiness](RELEASE-CHECKLIST.md).

## Next priorities

Improve onboarding, accessibility, discoverability and compatibility based on observed user needs. Continue profiling realistic long-running workloads and refine documentation as supported engine/runtime combinations are qualified.

Yearling and Ibex are reserved release codenames; a codename or version in planning is not a shipping commitment. [Versioning](VERSIONING.md) defines release identity.

## Ideas under consideration

Conversation branching and search, richer context retrieval, export/import, platform automation, managed skill setup, and contextual image/video work through the proposed Tether design remain future work. Kid does not provide third-party executable plugin loading, a managed GitHub skill installer or a media-generation workspace.

Changes to network behavior, executable capabilities or dependencies need an explicit design review. The [architecture decisions](adrs/README.md) retain the reasoning behind the current boundaries. Propose a concrete use case through the contributor process rather than assuming every idea will become a feature.
