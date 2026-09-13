# ADR-0086: Sampling parameters are model facts, not effort

Status: Proposed · 2026-09-11

Refines [ADR-0024](0024-deterministic-prompt-budgeting.md) and [ADR-0084](0084-model-inspection-favourites-and-recovery.md); revises the effort table in [docs/ENGINES.md](../ENGINES.md).

## Context

The wire encoder always sends `temperature` (0.7 for Graze and Trot, 0.6 for Climb and Summit) and never sends `top_p`, `top_k` or `min_p`. Local engines load each checkpoint's `generation_config.json` and apply its sampling defaults only when the request omits the field, so GOAT silently overrides tuned defaults for every model. Published recommendations disagree widely: Qwen3 documents 0.6 for thinking and 0.7 for non-thinking with specific top_p and top_k, DeepSeek-R1 documents 0.6 and warns against greedy decoding, GPT-OSS and Gemma 3 document 1.0, MiniMax M2 documents 1.0 with top_p 0.95 and top_k 40. Some OpenAI-compatible endpoints reject the field entirely with HTTP 400 "Unsupported parameter: temperature"; pinned server-side sampling also exists on vLLM and llama.cpp deployments. Effort has no principled relationship to any of these numbers.

Established practice is to omit temperature unless a provider rule or the user sets it, and to drop it while thinking is enabled. GOAT's own rule that a model name never selects a wire field applies here too.

## Decision

### Default: omit sampling fields

`CompletionBody` omits `temperature`, `top_p`, `top_k` and `min_p` unless a resolved sampling override supplies them. The engine's model defaults apply. Effort no longer contributes any sampling value on the generic path.

### Overrides are resolved like capabilities

A `SamplingOverride` (any subset of temperature, top_p, top_k, min_p) is resolved per request in this precedence, and the winning source is recorded in provenance:

1. An explicit per-model user override stored by engine profile identity plus exact model ID in Models settings, alongside the compatibility override. Evidence `userModelFamily`.
2. A model-family rule's optional `sampling` block. Recommended sampling is a published model-card fact, so `ModelFamilyRule` (built-in or user `model-families.json`) may declare it; it still cannot select a dialect or any other request field. Evidence `modelFamily` or `userModelFamily`. A family block may declare separate `thinking` and `nonThinking` values; the thinking set applies when the request enables native reasoning, otherwise the non-thinking set.
3. None. Fields are omitted.

Engine metadata can veto but never supply: when `supported_parameters` is present and does not list a field, that field is not sent regardless of override, and the Models tab shows the conflict.

The explicit Qwen local chat-template profile keeps its documented values, but its constants are re-verified against the current Qwen model card before this ADR is accepted; the present 1.0 for thinking modes does not match the 0.6 that Qwen3 documents.

### One registry for model facts, loaded from JSON

The model-family registry is the single source of family knowledge for both sampling and
capabilities. Built-in families ship as `model-families.builtin.json` bundled with the Inference
module, in the same `ModelFamilyRegistryDocument` schema as the user file and decoded by the same
validator; correcting or adding a shipped family is a JSON edit rather than a Swift one, and a
user file in GOAT Home (`~/.goat/config/model-families.json`, ADR-0009) adds or overrides
families without a rebuild. A user rule wins over a built-in it matches — the user file is consulted first and its rule replaces the built-in outright rather than merging — so an owner can patch or correct a family ahead of a release; the built-ins are the fallback. The former hard-coded Swift rule table and the `KnownModelProfiles`
shim that wrapped it are removed; every call site resolves through `ModelFamilyRegistry`.

Automatic compatibility resolution consults the registry. `ModelCompatibilityResolver.resolve`
takes the matched family profile and, when there is no explicit user override and no usable
engine metadata, resolves to source `modelFamily` with the family's capabilities instead of
`genericFallback`. Dialect stays engine configuration (ADR-0024); the family supplies
capabilities and, where published, a context window only. An engine-reported context window
always wins over the family's declared one on merge.

### Rejection recovery

An HTTP 400 whose body names a request parameter is classified `unsupportedParameter(name)`. The parameter is recorded on that model's compatibility metadata as unsupported with `observedResponse` evidence, the request is retried once without it, and the activity log records the change. This happens only before any token has been received.

### Presentation

Model details show Sampling: Engine default, Family recommendation (with the rule ID) or Custom, with the effective values. Response details show the values actually sent and their source, or "engine default". The effort submenu descriptions drop any mention of temperature.

## Consequences

Models run at the settings their authors tuned, endpoints that reject sampling fields work without configuration, and a user can still pin values per model. Existing chats keep their persisted provenance; new responses record the new source field. Provenance also stops under-reporting model resolution: `resolutionSource` shows `modelFamily` for a recognized model instead of a blanket `genericFallback`, `capabilities` records the resolved claims, and `effectiveContextLimit`/`contextLimitSource` report the window actually in force (user override, engine- or family-reported, or the estimated fallback) so a slow prefill or an overflow can be attributed. The effort table in docs/ENGINES.md loses its temperature column. Fixture tests cover omission by default, each precedence level, the metadata veto, thinking versus non-thinking selection and the one-shot rejection retry.

## Alternatives considered

Keep sending an effort-derived temperature (rejected: overrides tuned defaults and fails on strict endpoints). Infer sampling from the model name (rejected by ADR-0024's standing rule; family rules carry evidence and are user-visible, names are not). A global temperature setting (rejected: the right value is per model, and a global value would silently apply to every future model). Sending the family recommendation always (rejected: engine defaults are usually the same recommendation and omission is the only choice that cannot be wrong for an unknown model).
