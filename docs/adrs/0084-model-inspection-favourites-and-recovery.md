# ADR-0084: Model inspection, favourites and recovery

**Status:** Proposed · 2026-09-11 · extends [ADR-0021](0021-engines-as-managed-list.md), [ADR-0024](0024-deterministic-prompt-budgeting.md), [ADR-0065](0065-bounded-tool-format-recovery.md) and [ADR-0066](0066-lead-and-continuous-tool-work.md)

## Implementation status

The current development branch implements the core design described here: a Models settings tab with favourites and setup guidance, compact native model menus, per-model compatibility resolution, preference migration and fallback, active-scene catalog refresh, request provenance, typed engine/model failure diagnostics, printed-tool-markup safety, and bounded file-repair progress.

Build/test qualification and live engine/model qualification remain pending. This ADR stays Proposed until those checks are complete and the design is reviewed for acceptance.

## Context

The composer menu becomes difficult to scan as an engine's model catalog grows. Discovery labels do not expose enough evidence to distinguish capabilities, load failures and incompatible request styles. A speculative draft checkpoint can appear beside complete chat models even though it requires a base model and a compatible runtime.

Observed chat failures include repetitive output, malformed tool markup and repeated file deletion/recreation without implementation progress. The current engine-level request style can apply a specialised template to another selected model. The persisted chat's current model and effort also cannot identify which settings produced every historical response after model switching.

These observations justify investigation and recovery work. They do not establish that GOAT caused every malformed response or that a different output budget will fix a model.

## Proposed decision

### Models settings and evidence

Add **Models** as a dedicated Settings tab. Its initial scope is all models advertised by the active engine, retaining the one-active-engine generation contract. Engine settings continues to own saved connections, credentials, activation and setup. Downloads, deletion and model residency remain external-engine responsibilities.

Model details expose exact identity and available metadata: architecture and base/draft role, format, quantization, size, context/output limits, tools, vision, reasoning and supported parameters. Missing facts remain unknown. Show metadata source, freshness, selected request style and the effective mapping of GOAT effort presets. Separate engine-reported support, name hints, fallback assumptions and versioned live qualification.

Reuse the existing bounded metadata adapters and JUDAS authority. Inspection does not generate completions. Slow, missing or malformed metadata must not freeze navigation or mark a healthy engine offline. Preserve the selected-model handshake deadline and stale-result rejection. An aggregate picker that routes across several active engines is outside this proposal.

### Favourites and composer menu

Persist favourite preferences by engine profile identity plus exact model ID. Models settings and the composer share that state. Favourite models appear at the top level; **Other models** contains the remaining catalog without duplicates. The composer capsule identifies the selected model even when it is not a favourite, and that model's submenu row retains its checkmark.

With no favourites, keep Other models and the Models settings action available. Removing a favourite does not change the selected model. Missing or offline favourites retain their preference identity with an honest unavailable state. Preserve existing selection, active-turn and coder-first fallback rules. Favourite ordering is presentation, not evidence of capability.

Replace the expanded effort section with one row, for example **Effort    Trot ›**. Its submenu contains Graze, Trot, Climb and Summit, their descriptions, selected state and existing shortcuts. Keep per-chat persistence and generic/native effort semantics. The reference menu does not imply adding a Thinking toggle or copying another product's effort labels.

### Compatibility and diagnostic provenance

The owner has selected **automatic resolution with an optional per-model override** as the direction. Store overrides by engine profile identity plus exact model ID. Adding an engine should require connection information, not a choice between a generic API and a model family's template. The OpenAI-compatible API is the transport contract; Qwen-specific thinking controls are optional model/runtime behaviour, not an alternative model provider. The engine remains responsible for applying the checkpoint's actual chat template.

In **Models → model details**, show **Compatibility: Automatic**, the resolved behaviour and its evidence. An advanced override lets an owner select a documented request style for that pairing and reset it to Automatic. Resolution order is an explicit pairing override, then fresh model metadata interpreted through the documented engine adapter, then the generic OpenAI-compatible path without unproven family-specific fields. Model names can suggest what to inspect but cannot establish support.

Switching models resolves that model's settings automatically. Qwen thinking controls, reasoning replay and protocol recovery guidance must not carry into a GLM or Gemma request merely because all models use the same engine. Preserve the bounded metadata check, revision cancellation and immutable in-flight request snapshot. Recheck evidence when the endpoint, runtime or checkpoint changes, and surface a conflicting manual override with its reason.

Migration must preserve the old engine-level setting as reviewable legacy data rather than copying it to every model. Bind it to a model only when the prior association is known; otherwise show it as needing review. Keep new model selections on Automatic and explain any changed effective behaviour before the next request. Do not alter an in-flight generation. The migration and exact conflict-resolution interaction require fixtures and review before this ADR is accepted.

Record engine identity, model ID, request style, effort, effective generation settings and capability evidence at request creation, together with finish reason and available timing provenance. Later selection changes must not relabel old responses. Legacy records explicitly show missing provenance rather than inheriting the current chat selection. Persist only known runtime/checkpoint revisions.

Expose details and a local, user-reviewed report. The default shareable form omits credentials, raw conversation content, private paths and endpoint details. No telemetry or automatic upload is introduced. Engine-reported facts and estimates remain distinct.

### Recovery

Extend bounded malformed-tool diagnosis to observed supported formats while preserving fenced examples and ordinary source code. Never execute printed XML, partial arguments or truncated calls. Recovery must not duplicate completed structured calls from a mixed response or teach an unrelated engine's template.

Keep file-exists recovery focused on read/edit or skipping already-correct content. Legitimate obsolete-file deletion belongs in separate guidance. Use the bounded no-progress check implemented for repeated same-path destructive repair cycles and unchanged failures, with an actionable pause and explicit recovery. Preserve productive long-running work, legitimate repeated edits, permissions, cancellation and the stored transcript. Do not replace this with a global tool-round cap or an automatic model switch.

## Consequences and acceptance

The menu remains compact while detailed evidence has a stable home. This requires shared engine-scoped favourite state, capability/report models and a backward-compatible per-response provenance migration. Model browsing does not make GOAT responsible for loading weights or qualifying arbitrary hardware automatically.

Validate empty and large catalogs, long names, no/missing favourites, same IDs on different engines, refresh races, offline transitions and historical messages without provenance. Check keyboard, VoiceOver, focus restoration, light/dark appearance and screen-edge submenu placement. Compare sanitised engine-direct and GOAT requests when investigating output corruption, with tools on/off, fresh/long context and supported request styles. Source-code assertions alone are not live model qualification.

## Alternatives considered

- Keep a flat model/effort list: does not address catalog growth or capability discoverability.
- Put every engine's models into one live picker: requires routing and lifecycle work beyond the current request.
- Infer support or a request template from the model name: does not establish the server's actual contract.
- Increase output limits to address repetition: can lengthen an unproductive response without identifying its cause.
- Add a fixed tool-round ceiling: interrupts useful long tasks without specifically identifying a no-progress cycle.
