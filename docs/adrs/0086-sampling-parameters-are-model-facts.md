# ADR-0086: Model-family generation policies and engine defaults

Status: Accepted · 2026-09-20. Implementation and live qualification are distinct.

Refines [ADR-0024](0024-deterministic-prompt-budgeting.md), [ADR-0084](0084-model-inspection-favourites-and-recovery.md), [ADR-0085](0085-prefix-stable-prompts-and-usage-calibrated-budgeting.md) and [ADR-0089](0089-turn-continuity-and-engine-resilience.md).

## Context

Capability recognition is not a complete generation integration. The original registry supplied capabilities and context limits while generic requests still used effort-derived temperature and omitted reasoning history. A local Muse-Glimmer conversation exposed this gap: requests used temperature 0.6 instead of the published 1.0, and the effort control did not select Muse reasoning strength. Successful discovery calls repeatedly consumed long waits without task progress. These observations establish an integration mismatch, not proof that sampling alone caused repetition or latency.

The audit also found different defaults within broad rules: DeepSeek V3.1/V3.2, Qwen text/thinking/VL checkpoints, and GLM vision releases need distinct policies. Family recognition must not imply live qualification.

## Decision

### Source-backed generation facts

The bundled and owner JSON registries share a validated `ModelGenerationPolicy` schema. Each rule can declare optional sampling values, a documented plain-text reasoning instruction, a reasoning-history scope, primary-source links and limitations. [The family audit](../MODEL-GENERATION-POLICIES.md) records every bundled policy.

Supported sampling values are temperature, top-p, top-k, min-p, repetition penalty and presence penalty. Missing fields are omitted, allowing the server to resolve its own defaults. Effort controls output budget and verified reasoning controls; it does not supply generic temperature. Parameter meaning follows [Transformers generation configuration](https://huggingface.co/docs/transformers/en/main_classes/text_generation), while concrete recommendations come from each checkpoint. Transformers library defaults are not assumed to equal a server's defaults.

Validate finite temperature 0–2, top-p greater than 0 through 1, nonnegative integral top-k, min-p 0–1, and positive repetition penalty up to 2, and presence penalty from -2 to 2. These are GOAT's supported override ranges. Invalid policies are not applied. Unknown, unverified or access-gated variants use engine defaults. Example code and benchmark-specific settings are not automatically universal recommendations.

Rules match complete components at the right boundary: `qwen3` does not claim Qwen3.5, `glm-4.5` does not claim GLM-4.5V, and `minimax-m2` does not claim M2.1. Audited versions have separate rules. Drafter, MTP, assistant-checkpoint and base-model markers are excluded. Matching owner rules replace built-ins outright.

### Immutable resolution

Capture the matched rule and generation policy with the existing engine-profile/exact-model request snapshot. Sampling precedence is:

1. Per-model custom sampling, replacing the whole family recommendation. Blank custom fields use engine defaults.
2. Matched owner or bundled family policy. Non-thinking values apply only when GOAT requests that documented mode.
3. The explicit legacy Qwen-template override without a matched policy uses documented Qwen3 mode defaults.
4. Engine defaults, represented by omitted values.

An explicit `supported_parameters` or `supported_request_parameters` list vetoes fields outside the list. Missing metadata differs from an empty list. Independent explicit lists intersect; capability-only records do not erase a list. Engine restrictions win over both family and custom sampling.

### Reasoning instructions and history

Muse uses `Reasoning strength`: Graze low, Trot medium, Climb high, Summit xhigh. Advertised native reasoning effort takes precedence to prevent duplicate controls. Qwen3 hybrid models use their published `/think` and `/no_think` soft switch; fixed-mode checkpoints retain their mode. The explicit Qwen template option sends only verified `enable_thinking`, removing unverified template temperature, preservation and effort fields.

Canonical preparation adds instructions before budgeting and is idempotent. Stable inputs yield a stable prefix. Family-specific allowed native effort values intersect engine-advertised values. Qwen3.8, for example, accepts low, medium and xhigh but rejects high. Native wire fields still require an advertised engine contract or explicit compatibility selection. A family name does not invent an engine adapter.

History scopes follow audited templates: Muse receives all retained reasoning; selected Kimi, MiniMax and GLM releases receive reasoning after the latest user message; older Qwen checkpoints omit historical reasoning, while Qwen3.8 preserves it. Engine denial or conflicting history evidence wins. Unknown protocols omit replay. GPT-OSS Harmony and DeepSeek custom encoding remain engine-adapter responsibilities; their native history representation is not assumed interchangeable with `reasoning_content`.

The planner conservatively accounts for replayed reasoning. The encoder retains structured tool-call/result pairs independently of reasoning scope. Transcript storage is unchanged.

### Bounded rejection recovery

An HTTP 400 explicitly rejecting one named sampling field can trigger one retry before any text, reasoning or tool fragment arrives. Remove only that field, preserve messages and tools, persist revised effective parameters before retry, and log the omission. Unrelated 400s, invalid values and failures after output begins do not qualify.

Omissions carry into later rounds of the current turn. They are not permanent claims about the engine or checkpoint; later turns can re-evaluate changed configuration. A second sampling rejection on the same request surfaces normally. Transient retry and context-overflow handling keep separate bounds.

### Settings and provenance

Models settings show effective sampling, source, matched rule, reasoning instruction/history scope, omitted parameters, source links and limitations. Owners can apply custom values or reset to family defaults. Changes are disabled during generation and engine transitions.

Response provenance stores requested optional sampling values, source, rule, reasoning instruction and omissions, including recovery. Missing temperature displays as engine default. Legacy records retain their numeric temperature with unknown newly introduced fields. Diagnostics remain local. Server-side forced sampling can override a valid request; these records are not proof of executed sampler values.

## Qualification

Request fixtures verify exact JSON for representative families and every effort level, unknown-model omission, version boundaries, owner overrides, explicit empty parameter lists, metadata restrictions, stable canonical preparation, history scopes and unchanged tool pairing/round identity. Persistence checks cover legacy decoding and custom preferences. Fake-engine checks cover one-shot sampling recovery and no retry after output starts.

Run `make verify` and applicable documentation checks on the final implementation. Fixture success is not live-model qualification. Engine/runtime/checkpoint claims require actual evidence; cache effectiveness, latency and task completion are measured separately. This ADR claims no benchmark improvement.

## Alternatives considered

- Effort-derived sampling overrides checkpoint tuning without model evidence.
- One policy for similarly named versions ignores known differences.
- Unconditionally sending provider fields confuses model facts with the server API.
- Always omitting or always replaying reasoning contradicts different published templates.
- Persisting every rejection indefinitely risks retaining stale engine observations.

## Broader audit

The [inference integration audit](../INFERENCE-INTEGRATION-AUDIT.md) checks template rendering, server conversion, sampling resolution, cache stability and current catalog coverage. It separates source-level tests from deployed-engine qualification.

Converted checkpoints can bundle older templates than their upstream model. Muse provides a concrete example: an older conversion template appends a default reasoning-strength instruction even when GOAT supplied one. Qualification therefore covers the installed template and rendered prompt, not just the family rule and requested sampling. The audit records the source comparison and a progressive read/edit/command/recovery/handover protocol. Unknown deployed template behavior remains an explicit qualification limit.

## Implementation status

PR #27 implements source-linked policies, optional sampling, per-model settings, metadata veto, reasoning instructions/history scopes, bounded rejection recovery and provenance. Local Release verification and macOS 26 CI passed on 20 September 2026. Acceptance does not imply live qualification of every engine, template, checkpoint, and quantization pairing.
