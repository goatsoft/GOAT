# Roadmap

The current release is **0.1.1 (Kid)**. The capabilities below are included in the downloadable Mac app. Future work has no promised delivery date.

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

Downloads and release notes are on [GitHub Releases](https://github.com/goatsoft/GOAT/releases/tag/v0.1.1). See [Known issues](KNOWN-ISSUES.md) for current limitations.

## Kid 0.1.1 maintenance release

0.1.1 remains on the Kid release line and is available as a signed, notarized Mac download. See the [release notes](RELEASE-NOTES.md) for the upgrade guidance. The maintenance scope is:

- Sidebar labels remain visible at maximum width, with a 300-point preferred width and a 600-point maximum. Repeated chat layout work is reduced.
- Settings → General → Manage shows storage locations in a tree, resets the listed appearance/general preferences immediately, and schedules recoverable uninstall after GOAT closes. Partial uninstall preserves GOAT Home and chats by default. Review the [reset and uninstall guide](how-to/MANAGE-GOAT-DATA.md) for exact removal choices.
- The Finder installer has a Retina background, a build badge drawn from the app identity, clearer Applications and CLI icons, readable labels and a support-folder row.

The maintainer accepted the tested maintenance candidate. The official release was rebuilt from the same source content and passed signing, notarization and mounted-package checks. See [Release readiness](RELEASE-CHECKLIST.md) for the acceptance requirements. These maintenance changes do not complete M7 or require a 0.2 release.

## M7: The polish pass

Yearling (0.2.0) is the planned release line for broader polish. The remaining checklist below separates implemented foundations from acceptance work; unchecked items are not promised features or completed qualification.

- [ ] **Command palette:** implement the broader ⌘K palette for chats, Pens, models and actions, with search, keyboard selection, dismissal and reliable focus restoration. The existing composer slash-command menu is a separate control.
- [ ] **Onboarding and empty states:** build on Kid's explicit first-engine setup. Review first chat, first Pen, unavailable engines, empty memory, loading, errors and recovery with a fresh profile and an existing installation. Users should have a clear next action without mistaking loading for missing data.
- [ ] **Accessibility:** audit core workflows with keyboard and VoiceOver, contrast, text sizing, Reduce Motion and Reduce Transparency. Existing labels and motion controls are foundations, not evidence of complete coverage.
- [ ] **Performance:** measure cold launch to an interactive window, warm-engine first-token latency, streaming scroll, long chats, tool-heavy turns, large workspaces and repeated previews. Retain the original targets of under one second to an interactive window, under 2.5 seconds to first token on the documented warm reference pairing, and 60 fps streaming scroll. Record hardware, model/server versions and measured results before marking this complete.
- [ ] **Herd Guarantee:** verify supported local chat, Pens, memory and stdio MCP with external networking unavailable. Separately demonstrate blocked remote preview fetches under the off-grid policy. Explicitly configured remote services remain subject to their own availability and connection policy.
- [ ] **Remaining presentation polish:** decide the bounded scope of optional easter eggs and non-critical copy. The professional default, About-scoped 1337 unlock and experience split already belong to Kid; they are not pending M7 features.

Honest token/context statistics, off-grid previews, formatting checks, the app test target and first-engine guidance were brought forward into Kid. M7 must recheck their behavior where relevant rather than count them as newly delivered features.

Complete the applicable checklist and [release acceptance gates](RELEASE-CHECKLIST.md) before declaring M7 finished. Yearling and Ibex remain reserved codenames with no promised delivery date. Ibex 1.0 is a separate release decision; completing this checklist does not automatically change the version to 1.0. [Versioning](VERSIONING.md) defines release identity.

## Ideas under consideration

Conversation branching and search, richer context retrieval, export/import, platform automation, managed skill setup, and contextual image/video work through the proposed Tether design remain future work. Kid does not provide third-party executable plugin loading, a managed GitHub skill installer or a media-generation workspace.

Changes to network behavior, executable capabilities or dependencies need an explicit design review. The [architecture decisions](adrs/README.md) retain the reasoning behind the current boundaries. Propose a concrete use case through the contributor process rather than assuming every idea will become a feature.
