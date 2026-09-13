# ADR-0085: Prefix-stable prompts and usage-calibrated budgeting

Status: Accepted · 2026-09-11

Revises [ADR-0024](0024-deterministic-prompt-budgeting.md) (prompt budget policy version 4) and the title timing in [ADR-0066](0066-lead-and-continuous-tool-work.md). Informed by a 2026-09-11 review of established local-inference and coding-agent practice.

## Context

Every compatible local engine keeps a prefix or KV cache keyed on the exact request bytes. When the first message changes, the whole conversation is prefilled again; on Apple Silicon prefill is the slow phase, and one private transcript recorded a 208 second time to first token. GOAT currently changes the system message on precisely the rounds where the conversation is longest: `recoveryGuidance` is appended to the system string after a failed tool call, the tool-format repair instruction is added as a prompt section, Hindsight recall entries are rendered into the system turn per request, and the automatic chat title is requested between the first response and its tool execution, which evicts the cached prefix before the next round.

The budget estimator charges tool results, arguments, identifiers and schemas at one token per UTF-8 byte and natural text at a two-bytes-per-token floor. Measured tokenizers land between 3.2 and 4.0 bytes per token on source code and command output. On a 32k window with an 8k output reserve, two 20 KiB file reads exhaust the planned budget while the engine could have accepted them. The 8,192-token fallback window compounds this. Effort output ceilings of 1,024 to 8,192 tokens are also charged against reasoning models whose thinking tokens count toward `max_tokens`; the same transcript recorded four `length` finishes at 2,048.

Established practice converges on three points: volatile text goes after the cacheable prefix, the previous response's server `usage` is the primary token accounting, and output reserves are a window fraction or a per-model figure rather than a small fixed ceiling.

## Decision

### The system turn is a pure function of stable chat state

The system message is derived only from the GOAT preamble, the day, the Pen brief and agent guide, the enabled tool catalog, the skills catalog and the memory index. It is byte-identical across every round of a turn and across turns unless one of those inputs changes.

Per-round steering leaves the system turn. Recovery hints and the one-round tool-format repair instruction are delivered as a host note prefixed `[GOAT note]` appended to the final turn of the newest exchange: the last tool result when the round ended in tools, otherwise the newest user message. It never becomes a turn of its own, so exchange structure, role alternation and the budget are unchanged, and it is never persisted as transcript.

The memory index stays at the end of the system turn: it is stable for the life of a chat with the built-in stores, and moving it to a separate message would break role alternation on templates that require it. Per-request Hindsight recall is the remaining volatile input; keeping it stable across a turn is left to the compaction work in [ADR-0087](0087-conversation-compaction.md).

Automatic titles are requested after `executeTurn` returns, never between a response and its tools. The title prompt uses the first user message and the first non-empty reply as today.

### Usage-calibrated estimates, policy version 4

Tool results, arguments, identifiers and schemas are charged at 3.5 bytes per token. The byte-for-byte rule is retained only for runs that look like base64, hashes or minified data under the existing opaque-run threshold. Natural text keeps its adaptive estimator.

Each completed response with exact server `usage.prompt_tokens` records a calibration ratio for the chat: `usage.prompt_tokens / report.estimatedInputTokensAfter`, clamped to 0.5...2.0 and smoothed by averaging with the previous ratio. The next plan compares raw estimates against the budget divided by the ratio, which is the same test as scaling every estimate, and the report records the ratio, the raw estimate and the calibrated estimate; the meter shows the calibrated figure. A chat without usage keeps ratio 1.0, and the ratio is session-scoped. The plan remains deterministic: the ratio is an explicit input recorded in `PromptBudgetReport`, and fixtures pin its arithmetic.

`prompt_tokens_details.cached_tokens` (or a top-level `cached_tokens` / `prompt_cache_hit_tokens`) is decoded when present and recorded in `GenStats` and generation provenance, so the activity log can report prefix-cache hits. Surfacing it in the Stats inspector is left to later polish.

### Window and output reserve

The fallback window when no engine reports one becomes 16,384 tokens, still marked estimated. Models settings gains a per-model context-window override keyed by engine profile and model ID; a user value is evidence tagged `userModelFamily` and never exceeds an engine-reported window.

The output reserve is `min(effortCeiling, windowTokens / 2)` where the effort ceiling is 2,048 / 4,096 / 8,192 / 16,384 for Graze / Trot / Climb / Summit whenever `capabilities.reasoning` is supported or unknown, and the previous 1,024 / 2,048 / 4,096 / 8,192 only when reasoning is explicitly unsupported. Effort no longer sets sampling parameters (see [ADR-0086](0086-sampling-parameters-are-model-facts.md)).

## Consequences

Repair rounds, recall changes and titles stop re-prefilling the conversation; the cached-token figure makes this verifiable. Planned input capacity roughly doubles on tool-heavy chats and converges on the engine's real count after one response. Reasoning models truncate far less often. Policy version 4 invalidates the version 3 fixtures; every fixture is re-pinned with the calibrated arithmetic. The estimate can still disagree with an unusual tokenizer, which the safety reserve and calibration absorb; an engine overflow error remains possible and is handled by [ADR-0087](0087-conversation-compaction.md).

## Alternatives considered

Keeping the conservative estimator and raising only the fallback window (rejected: the loss scales with tool volume, not window size). A model-specific tokenizer (rejected again: unavailable from many local servers, incompatible with the engine-agnostic client). Injecting steering into tool results instead of a trailing note (viable and equivalent for caching; the trailing note is simpler to budget and works when the round has no tool result). Keeping titles before tools (rejected: ADR-0066 chose it for earlier naming, but the prefill cost on local engines is larger than the benefit).
