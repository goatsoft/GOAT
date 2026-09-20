# ADR-0090: oMLX capability status and generation-setting ownership

Status: Accepted · 2026-09-20

Refines [ADR-0008](0008-inference-via-omlx.md), [ADR-0017](0017-engine-agnostic-openai-dialect.md), [ADR-0021](0021-engines-as-managed-list.md), and [ADR-0086](0086-sampling-parameters-are-model-facts.md).

Implemented in [PR #36](https://github.com/goatsoft/GOAT/pull/36) for [issue #31](https://github.com/goatsoft/GOAT/issues/31). The Qwen3.8 trial established the need for server memory facts and effective output ceilings. See the [engine qualification record](../ENGINES.md#maintenance-qualification-20-september-2026) for tested configurations and limits.

## Context

GOAT correctly uses one engine-neutral OpenAI Chat Completions path for generation. The configured oMLX server also exposes bounded read-only status that the generic path does not consume. In oMLX 0.6.4, `/api/status` reports server and request state, cache metrics, and model memory used and allowed. `/v1/models/status` reports loaded state plus context and output limits.

This creates two practical gaps. GOAT cannot show the memory and load information owners need when a large model pushes unified memory into swap. It can also send a bundled family sampling recommendation even when the owner expects an oMLX model profile or recipe to control sampling. Under oMLX's normal resolution, a request value precedes a model setting unless the server forces its configured value. An implicit GOAT family value can therefore replace an oMLX recipe without being an explicit owner choice.

oMLX 0.7.0.dev4 adds recipe and MTP work but is a prerelease whose release notes warn about core-library regressions. Stable 0.6.4 is the current GOAT maintenance qualification baseline. This is a dated qualification choice, not a permanent version pin.

## Decision

### Keep one generation contract

`OpenAICompatEngine` remains the generation boundary. GOAT does not add an oMLX generation transport, manage model downloads, or call oMLX administration routes. Non-oMLX engines continue through the existing generic path.

An optional oMLX capability adapter may read `/api/status` and `/v1/models/status` from the exact configured engine origin. Detection and decoding are bounded, authenticated through the existing engine credential, isolated from shared cookies, revision-bound to the active engine, and treated as unavailable when unsupported or malformed. Status failure does not make an otherwise healthy Chat Completions engine unusable.

### Make sampling ownership explicit

Each engine profile gains an explicit generation-setting ownership mode:

- **Engine managed:** omit implicit family sampling so the engine model profile or recipe resolves it. Explicit owner per-model values may still be sent and retain their provenance.
- **GOAT managed:** keep ADR-0086 precedence for owner per-model values followed by matched family recommendations.

Detected oMLX profiles default to engine managed after migration unless the profile already has an explicit GOAT per-model override. Existing non-oMLX profiles retain GOAT-managed behavior to avoid changing established requests silently. The setting and effective source are visible in Models settings and response diagnostics. Model-family reasoning history, compatibility facts, and verified template switches remain independent of sampler ownership.

### Report status without inventing precision

GOAT can show oMLX model memory used and configured ceiling in Nerd Stats or a compact chat meter, along with loaded/loading state and active/waiting request counts. Missing fields display as unavailable, never zero. The meter labels this as oMLX process/model memory, not total macOS memory, pressure, or swap. System-wide memory and swap require a separate local operating-system measurement if GOAT later adds them.

Context and maximum-output metadata from `/v1/models/status` join only by exact engine and model identity under the same configuration revision. Provenance distinguishes server status from catalog metadata and GOAT fallback values. Request counts describe server queue state, not model progress.

### Preserve owner control of engines

oMLX continues to own model profiles, recipes, template forcing, quantization, MTP, ANE use, cache implementation, memory ceilings, and eviction. GOAT can explain detected status and link to the engine, but it does not duplicate these controls.

One saved engine remains active at a time. GOAT surfaces an unavailable active profile and supports explicit switching to another configured profile. It never silently sends a turn to a different endpoint.

## Consequences

Owners can see the oMLX memory facts needed to distinguish a large loaded model from GOAT transcript cost. Engine recipes are no longer accidentally shadowed by an implicit client sampler policy. Diagnostics can state which layer supplied context, output, and sampling values.

The adapter adds versioned vendor capability code, bounded fixtures, and stale-revision tests while leaving generation generic. Live qualification records the exact macOS, oMLX, checkpoint, quantization, template/profile, and ownership mode. Qwen3.8 27B 4-bit is qualified first, followed by Devstral Small 2, DeepSeek R1 Distill and GLM-4.7-Flash. A later stable oMLX 0.7 release is requalified before becoming a release baseline.

This ADR does not claim that server memory equals total resident memory or that family sampling caused any observed model failure. It defines ownership so future evidence can be interpreted correctly.

## Alternatives considered

- Mirror every oMLX setting in GOAT. This creates two administrators for one engine and couples the app to fast-moving runtime internals.
- Always send GOAT family sampling. This can silently override a deliberate engine recipe.
- Always omit every sampling value. This removes useful explicit owner overrides and weakens non-oMLX behavior already covered by ADR-0086.
- Read operating-system memory and infer per-model use. oMLX already reports its own bounded model/process facts; system pressure is a separate measurement.
- Automatically fail over to a healthy saved engine. That can send conversation data to an endpoint the owner did not select.

## Sources

- [oMLX](https://omlx.ai/)
- [oMLX README](https://github.com/jundot/omlx/blob/main/README.md)
- [oMLX releases](https://github.com/jundot/omlx/releases)
- [GOAT maintenance issue #31](https://github.com/goatsoft/GOAT/issues/31)
