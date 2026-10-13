# Release readiness

**The current Kid release is available as a signed, notarized Mac download.** This is the acceptance checklist for ongoing releases, not a claim that every configuration or workflow has been tested. See [Known issues](KNOWN-ISSUES.md#release-qualification) for the scope of Kid’s installation check. Detailed machine logs and historical reports remain in the private maintainer archive.

## 0.1.3 maintenance scope

Qualify the model-management, compaction and recovery work; long-transcript navigation; oMLX status, limit and measurement changes; Custom endpoint restoration; maintained Xcode project; domain test organisation; focused test runners; and signed-build verification described in the [release notes](RELEASE-NOTES.md). Use the exact final 0.1.3 source and artifact for distribution evidence. Keep stable oMLX 0.6.4 as the qualified baseline and preserve the documented limits of the unreproduced throughput report.

### Merged-source verification, 2026-10-13

The local source reviewed is `d88919bec18912ccc16c3880c0b61c80b9b1d089` (PR #84),
with release identity 0.1.3 (Kid), build 1355. **Release qualification remains incomplete.**
The clean checkout was refreshed from `origin/main` and the qualification work continues on
`chore/0.1.3-reader-release-qualification`. This receipt does not establish final release-source
or artifact acceptance.

- [x] Inspect the merged shared Markdown style, explicit spacing policy, first-layout regression,
  stock-style comparison and preparation cancellation/staleness guards. The shared reader enables
  synchronous spacing by default; the shipping transcript container remains unchanged.
- [x] Confirm the project requires exact MarkdownUI `2.4.2-goat.2`, the app lock resolves
  `117d47541d19ca3dff036f8af782983aa9beb720`, and the local dependency checkout is clean at that commit.
  Distribution notices match the reviewed manifest.
- [x] Run release metadata, maintained-project, test-layout, module documentation, module/network
  boundary, transcript-colour and Swift formatting checks. All 66 build-tool tests pass.
- [x] Run all 21 website unit tests, build the website and documentation, and check 16,355 links
  and anchors across 161 pages, including matching licence files.
- [x] Pull current `main` and create a semantic Git Flow qualification branch before applying
  release-preparation changes. The refreshed source remains `d88919b`.
- [ ] Complete `make verify CONFIG=Release` on that source. The local macOS 27.0 / Xcode 27.0
  attempt passed lint/tooling but stopped before package tests because SwiftPM could not start
  its sandbox. A separate Bleet hosted-test attempt stopped at dependency resolution because
  Xcode could not write its caches. Neither attempt executed reader tests; these are environment
  blockers, not passing or failing reader regressions.
- [ ] Smoke-test the shipping reader using disposable synthetic content: settled rich rows on
  scroll-back; native scrolling; Earlier/Later/Latest navigation; reader-held incoming output;
  completion; font and width reflow; selection/copy; code actions; and reasoning/tool disclosures.
  Record actual keyboard/accessibility and visual observations separately from automated results.
- [ ] Finish the applicable product and runtime checks below, recording engine/model versions
  and supported-OS evidence. Existing historical receipts do not qualify this source.
- [ ] Review current release notes and download claims against the accepted source and artifact.
- [ ] Complete final-source CI, signed/notarized artifact checks, clean-Mac installation,
  upgrade and disposable uninstall acceptance, and owner review before publication.

The checks above used a writable temporary compiler cache and file-watcher polling where needed;
no production code or dependency checkout was modified. Raw logs remain private.
[ADR-0100](adrs/0100-synchronous-markdown-block-spacing.md) and the
[transcript performance record](reference/transcript-performance.md#synchronous-spacing-follow-up)
describe the merged change and the comparison's unresolved startup failure. Container migration
and broader Delivery 3 qualification remain separate work, with ADR-0099 still Proposed.

### Transcript implementation verification, 2026-10-13

The implementation checkpoint on `feat/transcript-followups-85-89` passes
`make verify CONFIG=Release` on macOS 27 with Xcode 27: package tests, 66 build-tool tests,
574 hosted app tests passed (3 skipped), and the Release app build. This verifies the
modified reader, not the untouched merged-source receipt above. The checks include real
accessibility action names, preview admission and snapshot limits, streamed preview completion,
day boundaries, search offsets, edit transactions and database page ordering.

The checkpoint above precedes database-backed reader loading added under ADR-0102. Its new
2,000-message regression passes initial 40-record admission, bidirectional reachability, a
120-record idle cache and complete-context hydration. Full `make verify CONFIG=Release` of that
integration passes on macOS 27 / Xcode 27: 575 app tests passed, none failed, 3 skipped; package
and tooling tests passed and the Release build succeeded. The initial PR CI attempt on macOS 26
failed to compile a new assertion, before executing app tests. Performance, retention, actual
keyboard/VoiceOver interaction, the experimental container comparison and macOS 26 acceptance
remain open. [ADR-0101](adrs/0101-bounded-inline-artifacts.md) records the preview policy.
This checkpoint does not qualify a release artifact.

### Reader follow-up qualification checkpoint

The follow-up work adds strict 40-row evaluation and database-prepend anchor regressions,
short-reasoning button navigation, and bounded rich-layout admission under
[ADR-0103](adrs/0103-dense-reply-layout-admission.md). The 32-group dense answer baseline took
188.04 seconds. Reducing admission to two groups produced a 19.12-second development run;
these timings and scheduling-delay proxies do not establish actual input or frame-time acceptance.
The separate CPU trace attributes substantial work to Markdown/native layout. Raw traces remain
private. The corrected source passes full `make verify CONFIG=Release` on macOS 27 / Xcode 27:
578 app tests passed, none failed, 3 skipped, package/tooling checks passed, and the Release app
built successfully. The 40-row measurement records zero settled evaluations across 20 publications;
its fixture isolates pointer and scene changes without relaxing that target. Earlier failed runs
exposed short-window reverse paging and incidental measurement-window invalidations; retain them.
One unchanged-source run also failed a scheduling-dependent subagent buffer-overflow assertion;
subsequent runs passed that test. This is not a release-artifact acceptance receipt.

Actual isolated-reader observations cover distinct code-action names, source copy with Unicode
and leading whitespace, search navigation with a visible selected excerpt, table headings,
calendar separators, the literal-math notice, Mermaid rendering, Light-theme selector contrast,
and the empty-state layout. They do not establish spoken VoiceOver, hardware momentum, all
fonts/themes, WebKit subprocess retention, or supported macOS 26 acceptance. In a separate real SwiftUI scene, Command-F opened Find from the composer and Shift-Command-C
copied the complete reply, including collapsed code. The earlier raw AppKit hosting fixture
exposes scene commands as disabled, so it is not a shortcut acceptance harness. Experimental
navigation and final-source CI remain separate gates. The macOS 26.6 CI Release build at
`9d421bb` exposed a `ChatView` type-checker timeout not seen with Xcode 27; the follow-up splits
that view expression into smaller composition properties. Retain the failed CI result and require
new CI acceptance of the correction. At `2b08d35`, macOS 26 / Xcode 26.6 CI passes the
Release build and all 578 ordinary app tests (three skips). The opt-in navigation workload
still fails startup/growth tolerances, bottom following and both reflow anchors. The shipping
expanded-reasoning workload takes 182.895 seconds with 2,250.138 ms scheduling-overrun p95.
These block qualification; see the [performance](reference/transcript-performance.md) and
[container comparison](reference/transcript-container-comparison.md) results. The correction
fixes compilation, not these runtime failures.

The follow-up at `64bb55d` also passes all 578 ordinary macOS 26 app tests, including
the bounded missing-target lifecycle and database-anchor readiness checks. Its synthetic
container and production responsiveness qualification remain unsuccessful. The subsequent
local theme/focus patch passes full Release verification with 579 app tests, zero failures
and three skips. An actual SVG-color regression covers Mermaid's initialization race.
The new focus shortcuts still need real-scene interaction verification.

Additional real-scene checks at `64bb55d` cover a narrow reader with its inspector open,
14–28 pt text, System/dark, Light, Pasture and Midnight, horizontal table scrolling and
selected-cell copy, Command-End from the composer, and native Markdown export preserving
Unicode, code whitespace, artifact fences and literal math. These checks exposed the
Mermaid startup-theme race addressed by the subsequent patch. They do not certify spoken
VoiceOver, hardware momentum, all font families or WebKit retention.

### Transcript follow-up ownership

The remaining scope of [#60](https://github.com/goatsoft/GOAT/issues/60) is explicitly transferred
to the following open issues. Closing the audit does not mark any unfinished delivery complete
or establish maintenance-release acceptance.

| Remaining scope | Follow-up |
| --- | --- |
| Delivery 3 production performance, retention, accessibility and manual checks (Measurements 1c and 6) | [#85](https://github.com/goatsoft/GOAT/issues/85) |
| Experimental container startup anchors, native Q1, comparison and migration | [#86](https://github.com/goatsoft/GOAT/issues/86) |
| Delivery 4 bounded previews, tables and math | [#87](https://github.com/goatsoft/GOAT/issues/87) |
| Delivery 5 growing history, database paging and Measurements 4b–5 | [#88](https://github.com/goatsoft/GOAT/issues/88) |
| Delivery 6 empty state, editing/retry, search, keyboard, day separators and export | [#89](https://github.com/goatsoft/GOAT/issues/89) |

The original audit and dated performance reports retain their unchecked tasks and failed runs
as historical evidence. The linked issues own completion of those gates.

## 0.1.1 maintenance scope

Qualify the sidebar visibility/width fixes, direct preference reset, recoverable automatic uninstall and revised Finder installer. The [roadmap](ROADMAP.md#kid-0-1-1-maintenance-release) keeps this scope separate from M7. Use the exact final 0.1.1 source and artifact for distribution evidence; 0.1.0 acceptance and earlier candidate artwork checks do not transfer automatically.

## Product and content

- Verify the intended release’s current workflows: engine/model selection, chat, Pens, native file and command tools, Lead, permissions, memory, previews, extensions and local control.
- Verify model-management states with zero, one, and many discovered models, including no-engine/no-model setup guidance.
- Verify missing, offline, stale-catalog, newly available, and migrated model preferences.
- Verify per-model compatibility, request snapshots, provenance, sanitized diagnostics, and typed load-error recovery.
- Verify compact model and effort menus with keyboard navigation, VoiceOver labels, focus restoration, and screen-edge placement.
- Verify printed tool markup is never executed and interrupted file repair reports bounded resumable progress.
- Confirm all model qualification claims are backed by actual engine evidence; do not publish untested candidate claims.
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
