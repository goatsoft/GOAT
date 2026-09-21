# Roadmap

The current published release is **0.1.1 (Kid)**. **0.1.2 (Kid)** is in release preparation. The capabilities below are present in the current source; future work has no promised delivery date.

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

## Kid 0.1.2 maintenance release

0.1.2 brings the completed model-management work and the subsequent usability, engine, transcript and developer-workflow improvements into one Kid maintenance release. Its user-facing scope is:

- model inventory, favourites, capability filters, compatibility details and per-model preferences;
- conversation compaction, bounded recovery from transient engine failures and safer tool-call handling;
- responsive navigation and faithful copy for very large transcripts;
- clearer oMLX status, limits and performance measurements while retaining stable oMLX 0.6.4 as the qualified baseline;
- preservation of configured Custom endpoints while offline; and
- a maintained Xcode project, domain-owned tests, focused module runners and verified Developer ID builds.

The [0.1.2 release notes](RELEASE-NOTES.md#012-kid--in-preparation) describe the changes for users. Exact-candidate qualification and publication remain governed by [Release readiness](RELEASE-CHECKLIST.md).

## Model selection, capabilities and recovery

The model-management implementation is complete on PR #27 and passed local Release verification plus macOS 26 CI on 20 September 2026:

- **Models settings:** browse the active engine's catalog, inspect model capabilities and their evidence, review compatibility and load failures, maintain favourites, and receive setup guidance when no engine or model is configured.
- **Compact model menu:** show favourites at the top level and the remaining catalog in **Other models**, while retaining the selected model and the engine's management and refresh actions.
- **Effort submenu:** show the selected preset on the trailing side of the **Effort** row. Graze, Trot, Climb and Summit retain their existing meanings and shortcuts.
- **Per-model compatibility:** resolve request behaviour automatically when selecting a model, with an advanced override stored for that engine/model pairing in Models settings.
- **Catalog refresh:** support manual refresh and active-scene polling so newly available engine models can appear without an app restart.
- **Recovery and reporting:** recognise malformed tool attempts without executing printed markup, break unproductive file-repair cycles, and record the actual model, engine and effective settings per response.

Fake-engine qualification covers fragmented structured calls, mixed printed markup, exactly-once execution, continuation, and output-cap behavior. Live model qualification remains a separate activity and no candidate is treated as qualified from discovery alone. The [accepted model-management decision](adrs/0084-model-inspection-favourites-and-recovery.md) records the scope and acceptance boundaries.

## Inference efficiency

An inference-efficiency review on 11 September 2026 assessed GOAT's inference loop against established local-agent practice. PR #27 implements and verifies the resulting decisions: [prefix-stable prompts and calibrated budgeting](adrs/0085-prefix-stable-prompts-and-usage-calibrated-budgeting.md), [sampling parameters as model facts](adrs/0086-sampling-parameters-are-model-facts.md), [conversation compaction with `/compact` and an auto-compact threshold](adrs/0087-conversation-compaction.md), [single-round tool results](adrs/0088-single-round-tool-results.md), and [turn continuity and engine resilience](adrs/0089-turn-continuity-and-engine-resilience.md).

Live engine and checkpoint qualification remains separate. A Qwen3.8 27B 4-bit trial showed strong reasoning and tool selection but did not complete the Aurora repair. It also exposed an unclear effective output ceiling and a manual compaction that remained busy for more than 20 minutes. The [oMLX status and generation ownership decision](adrs/0090-omlx-capability-status-and-generation-ownership.md) and the maintenance backlog cover those usability gaps.

## Kid maintenance backlog

[Issue #30](https://github.com/goatsoft/GOAT/issues/30) is the maintenance umbrella. The ordered work is long-transcript responsiveness and memory pressure in [issue #29](https://github.com/goatsoft/GOAT/issues/29), oMLX status, memory, sampling ownership, and effective-limit reporting in [issue #31](https://github.com/goatsoft/GOAT/issues/31), and macOS 27 Golden Gate Pen-sandbox qualification while retaining macOS 26 Tahoe support in [issue #33](https://github.com/goatsoft/GOAT/issues/33).

PRs #35, #36, #40, #41 and #42 are merged. Qualification issues #24, #26, #29, #30, #31, #33 and #39 are closed. The [engine contract](ENGINES.md#maintenance-qualification-20-september-2026) records live qualification and its limits. Current delivery state is tracked on the [project board](https://github.com/orgs/goatsoft/projects/1). PR #41 distinguishes received-output estimates from server decode speed and records arrival/publication timings; [#38](https://github.com/goatsoft/GOAT/issues/38) remains open for the original unreproduced throughput discrepancy. Stable oMLX 0.6.4 remains the baseline. PR #42 delivered the maintained Xcode project, build workflow and domain test organization recorded in [ADR-0093](adrs/0093-maintained-xcode-project.md) and [Testing by domain](reference/testing.md). WebKit helper-process reuse and log-noise reduction #28 and native delegation #32 remain separate backlog work. The completed maintenance scope is assigned to 0.1.2; publication still requires exact-candidate acceptance.

Repeat controlled model qualification with Qwen3.8 27B 4-bit first, followed by Devstral, DeepSeek, and the practical GLM-4.7-Flash 31B candidate. Native subagent work in [issue #32](https://github.com/goatsoft/GOAT/issues/32) follows the usability fixes and starts with one sequential, read-only, isolated child before adding write, parallel, or recursive execution.

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
