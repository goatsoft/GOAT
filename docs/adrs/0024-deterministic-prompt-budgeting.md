# ADR-0024: Deterministic prompt budgeting and capability-gated model setup

**Status:** Accepted · 2026-08-31 · Extends [ADR-0005](0005-memory-architecture.md), [ADR-0006](0006-mcp-integration.md), [ADR-0016](0016-chat-content-pipeline.md), [ADR-0017](0017-engine-agnostic-openai-dialect.md), and [ADR-0023](0023-single-active-turn-and-engine-lifecycle.md) · Policy version 3 revised to version 4 by [ADR-0085](0085-prefix-stable-prompts-and-usage-calibrated-budgeting.md) (prefix-stable prompts, usage calibration, protocol estimate, 16,384 fallback, reasoning-aware output reserve); the parked rolling-summary decision is superseded by [ADR-0087](0087-conversation-compaction.md)

## Context

The selected model reports an optional context window through `ModelRef.contextLength`, but the Shepherd currently assembles all eligible history and estimates only message text plus tool-schema characters. The actual request also contains system instructions, memory, image tokens, tool schemas, assistant tool-call IDs and arguments, tool results, role wrappers, and an output allowance. A character-only gauge can therefore say a request fits while the engine rejects it or silently truncates it.

The tool loop makes trimming structural. An assistant message containing `tool_calls` and the corresponding `role: tool` results form one protocol unit. Dropping only one side produces invalid or misleading history. M6 adds a memory digest to the system prompt, so prompt budgeting must be deterministic and tested before that content joins the request.

Rolling-summary compaction remains parked. MVP needs a transparent suffix-selection policy that is cheap, repeatable, and honest when even the newest exchange is too large.

## Decision

### One versioned budget policy

`GoatInference` owns a pure `PromptBudgeter` beside the canonical request types. Given the same model, policy version, system prompt, tool schemas, and ordered exchanges, it produces the same `PromptPlan` and `PromptBudgetReport`. It performs no file, network, database, or UI work.

For MVP policy version 1:

1. `windowTokens` is the selected `ModelRef.contextLength` when it is positive. If the engine omits it, GOAT uses a conservative **8,192-token fallback** and marks the source as estimated in the report. It never substitutes a larger value for a positive engine-reported window.
2. `requestedOutputTokens` is the request override when present, otherwise the selected effort's `maxTokens`.
3. `outputReserve` is `min(requestedOutputTokens, windowTokens / 2)`. The effective `max_tokens` sent to the engine is this reserve, so the engine cannot consume capacity promised to the input. Any clamp is reported.
4. `safetyReserve` is five percent of the window, clamped to **256...2,048 tokens**. It covers chat-template markers, tokenizer variance, and engine-specific framing.
5. `inputBudget = windowTokens - outputReserve - safetyReserve`. A non-positive budget is a local, actionable error. GOAT does not send a request it already knows cannot fit.

No user setting silently changes these constants. Changing the fallback, estimator, reserve formula, or truncation order increments the policy version and updates its fixture tests.

### Model support is transport-wide, not a family allow-list

Every model exposed by an OpenAI-compatible engine uses the same chat, streaming, tools, vision, and prompt-budget path. Model names never select request fields. DeepSeek, Qwen, Gemma, Llama, Phi, gpt-oss, Mistral and Devstral, Nemotron, MiniMax, Kimi, Hunyuan, Ling, GLM, Step, MiMo, and other compatible models therefore receive the same generic Effort presets and effective output clamp.

The vision-name heuristic is presentation metadata only. It can add a label or warning, but it never strips a user-selected image or blocks the generic multimodal content-array request.

Dedicated coding variants, including Devstral, Qwen Coder, DeepSeek Coder, Codestral, Code Llama, StarCoder, Granite Code, CodeGemma, OpenCoder, and Kimi Dev, lead the model picker and are preferred only when no saved default remains valid. This is presentation and first-run selection policy. A `coder` name never enables tools, reasoning, vision, fill-in-the-middle, or a provider field.

The former Qwen3 `/no_think` and `/think` name-derived prompt mutation is removed. It made one family appear privileged and could not prove the active template accepted the control. Every native request control now requires explicit metadata from the active engine, except an explicit engine profile selected by the user. The **Qwen local chat template** profile is such a contract: it may send Qwen's documented `chat_template_kwargs` and replay prior assistant reasoning in `reasoning_content`; a model ID can never enable it.

### Probe selected-model capabilities before sending

Startup, engine changes, and model changes perform a bounded, metadata-only handshake for the selected model. The composer displays a compact progress indicator and remains disabled while the handshake is pending. A timeout, unsupported endpoint, malformed body, or absent capability field resolves to the generic-compatible state. It never changes a healthy engine to offline and never prevents ordinary chat after the bound expires.

`GET /v1/models` remains the required catalog and can contribute non-standard context and capability fields when present. GOAT then uses only the adapter selected by an explicit engine preset:

| Adapter | Optional metadata call | Accepted evidence |
|---|---|---|
| Generic, oMLX, vMLX, custom | `GET /v1/models/{model-id}` | Explicit context, capability, supported-parameter, and allowed-value fields only |
| LM Studio | `GET /api/v1/models` | Context, vision, positive tool-training hint, and reasoning availability; native-chat reasoning options do not prove a Chat Completions field |
| Ollama | `POST /api/show` and `GET /api/ps` | Model capabilities and declared/effective context; `thinking` plus Ollama's documented OpenAI-compatible contract proves `reasoning_effort` with `none`, `low`, `medium`, `high`, and `max` |
| llama.cpp | `GET /props?model=...` | Effective context, vision, complete tool-template support, and `supports_reasoning_effort` |

These calls contain the exact catalog model ID and no prompt, transcript, attachment, tool schema, or generated content. GOAT never generates a test completion, loads or unloads a model, requests llama.cpp slots, or probes an arbitrary vendor path for a Custom preset. Every metadata operation has a hard two-second wall-clock deadline and accepts at most 256 KiB (1 MiB for the health catalog and Ollama's detailed model response). It uses a dedicated ephemeral session with caches, cookies, and shared credential storage disabled. Oversized reads are explicitly cancelled. Redirects to a different normalized HTTP origin are rejected so an engine credential cannot escape its configured host. The redirect delegate is immutable after initialization; that invariant is the reason for its narrow `@unchecked Sendable` conformance.

Engine roots must be HTTP or HTTPS URLs with a host and no URL userinfo, query, or fragment; API credentials have one separate field. Diagnostics contain only a sanitized host and effective port. Model IDs are opaque percent-encoded path components, including dot-only values. Catalogs are capped at 1,024 entries, model IDs at 512 UTF-8 bytes, duplicate IDs are removed, and control-bearing IDs are ignored before the catalog reaches UI or logs.

Fallback discovery is scoped by preset: oMLX/vMLX use ports 8000/8001, Ollama 11434, LM Studio 1234, and llama.cpp 8080. This prevents a provider-specific adapter from issuing its metadata calls to an unrelated service. Custom remains generic. Capability results are not retained in an engine-wide model cache; every explicit model selection performs the requested fresh bounded probe, while the current catalog retains the result for request snapshots and display. Navigating between chats that resolve to the same model does not repeat the network check or disable the composer.

Capabilities are tri-state: supported, unsupported, or unknown. Unknown preserves the portable request path. Generic capability arrays provide positive evidence only because their omissions are not standardized; absence becomes unsupported only in a documented exhaustive adapter such as Ollama. Explicitly unsupported tool-template metadata omits MCP schemas for that model; a training-quality hint does not. Vision metadata improves the badge and warning, but never silently deletes a user-selected image.

The selected model's immutable capability snapshot is copied into every `GenerationRequest`. A later model or engine change therefore cannot alter a suspended request. Model selection has one MainActor mutation path and a separate monotonic probe revision. A stale, cancelled, or previous-engine probe cannot publish into the current catalog.

Every model receives generic temperature and output-budget effort presets. `reasoning_effort` crosses the wire only when metadata explicitly advertises that exact parameter, reasoning support is positive and unambiguous, and the value is in the advertised or adapter-documented set. Graze selects the lowest allowed value, Summit the highest, and Trot/Climb the nearest allowed medium/high value. Missing or conflicting evidence emits no native field.

Incoming reasoning is normalized from `reasoning_content`, `reasoning`, `thinking`, inline `<think>` tags, and supported typed content parts. It is persisted locally with the transcript for user disclosure. The generic path never replays it. The explicit Qwen local chat-template profile is the narrowly scoped exception: the prompt budget includes each assistant trace and the wire encoder returns it only in the documented `reasoning_content` field. That keeps Qwen's preserved-thinking contract separate from dialects that require prior analysis to be removed.

### Estimate the complete request

The estimate covers every item that crosses the wire or consumes model context:

- The complete system turn: GOAT preamble, date/environment, Pen instructions, and the M6 memory snapshot.
- Every enabled tool's name, description, parameter-schema JSON, and request wrappers.
- Every role and content wrapper in retained chat turns.
- User and assistant text.
- Each image retained in a user turn.
- Assistant tool-call IDs, names, and argument JSON.
- Tool-result IDs, text, error text, and wrappers.

Natural text uses an adaptive UTF-8 estimate: a two-bytes-per-token floor, explicit punctuation and non-ASCII units, and byte-for-byte charging for long unbroken encoded-looking runs. Untrusted protocol fields, including tool schemas, arguments, identifiers, and results, are charged at one token per UTF-8 byte. Fixed structural overhead covers request wrappers. Images use a deterministic reserve derived from decoded pixel dimensions, with a byte-size fallback when metadata cannot be read. An image never has zero cost.

These rules are deliberately cautious across popular tokenizer families, but they are still estimates rather than tokenizer proofs. An unusual tokenizer can disagree. Exact server `usage` remains authoritative for the post-response meter, and a server may still reject a planned request that its own template expands beyond the reserve.

Thinking text is excluded because GOAT does not replay it. UI-only metadata, timestamps, display names, and Paddock rendering state are also excluded because they do not cross the inference boundary.

### Build atomic exchanges

History is normalized before selection:

- An **exchange** begins with a user turn and contains every following assistant turn up to, but not including, the next user turn.
- An assistant turn containing tool calls plus every tool result linked to those calls is an indivisible **assistant-tool group**. The budgeter never retains an orphan result, removes a call while keeping its result, or splits the group across the trim boundary.
- The in-progress user turn and any completed assistant-tool rounds that follow it form the newest exchange.
- Invalid orphan tool data is rejected before budgeting rather than repaired by trimming.

### Preserve a recent contiguous suffix

Selection proceeds in this order:

1. Reserve output and safety capacity.
2. Include the system turn and all enabled tool schemas.
3. Include the newest user exchange.
4. Walk older exchanges from newest to oldest, adding each whole exchange while it fits. At the first exchange that does not fit, drop it and every older exchange. GOAT never skips a recent large exchange to resurrect disconnected older context.

The system turn and newest exchange are therefore always represented. Older history is removed only as complete exchanges, and assistant-tool groups remain atomic inside every retained exchange.

The system turn, including the GOAT preamble and uncapped Pen instructions, is never truncated. Future memory content must arrive through its own documented cap. If the system turn, tool schemas, and the minimum valid representation of the newest exchange cannot fit together, planning fails locally with a component breakdown and an actionable suggestion, such as disabling tools or shortening Pen instructions. It does not silently discard system policy.

### Explicit oversized-newest-exchange handling

If the newest exchange is individually too large after older history has been removed, GOAT keeps its roles and protocol links but truncates payloads in this stable order until it fits:

1. Tool-result bodies, oldest first, become head-and-tail excerpts.
2. Assistant text bodies, oldest first, become head-and-tail excerpts.
3. User images are omitted as whole image parts, oldest first. A text marker records each omitted image.
4. The newest user text is truncated last as a head-and-tail excerpt.

Every excerpt or omission inserts a literal marker containing the omitted estimated-token count, and the marker itself is included in the next estimate. Tool-call IDs, tool names, tool-call argument JSON, result linkage, roles, and structural wrappers are never partially truncated. If those non-trimmable fields plus the minimum marked payload still exceed the input budget, planning fails locally rather than emitting invalid protocol history.

This is truncation, not summarization. GOAT never asks a model to invent a compressed replacement under this ADR.

### Report every trim decision

Every plan carries a report with:

- Model ID, context-window value and source, policy version.
- Requested and effective output reserve, safety reserve, and input budget.
- Estimated input tokens before and after planning.
- Retained and dropped exchange counts.
- Truncated text fields, excerpt sizes, omitted images, and estimated tokens removed.
- A failure component when no valid plan fits.

When content changes, the Shepherd emits one non-model-visible inline notice per user turn and a detailed activity-log entry. Tool rounds may produce new reports as results grow, but the transcript notice is updated rather than appended repeatedly. The report feeds the preflight context meter; final server `usage`, when present, replaces the estimate after completion.

Trim notices are metadata and are not inserted into the model conversation. The explicit excerpt and image markers are model-visible because they replace omitted content, and their cost is already part of the plan.

### Required tests

Fixture and invariant tests cover reported and fallback context windows, output clamping, canonical schemas and ordering, high-entropy protocol estimates, model mismatches, contiguous suffix selection, linked tool histories, newest-exchange truncation order, image omission, invalid histories, non-trimmable metadata failures, deterministic repeated planning, capability isolation, coder ordering, provider metadata fixtures, stale and cancelled probe rejection, hard deadlines, isolated metadata sessions, endpoint/origin validation, catalog and ID bounds, safe model-ID encoding, vision non-gating, native-field gating, conflict handling, and reasoning-delta normalization. Successful fixtures assert that their reported estimate fits the policy input budget and that protocol links remain valid.

## Consequences

- Predictable context overflow becomes a local deterministic planning result instead of an engine-specific surprise.
- Popular model families remain supported through one generic OpenAI-compatible path; a preset adapter can only add a proven capability.
- Dedicated coder variants are easier to find and become the fallback default without receiving guessed wire behavior.
- A short selected-model loading phase buys deterministic request setup. Engines without richer metadata pay only the bounded failed probe and then use the generic path.
- Tool-heavy and vision chats are budgeted honestly, including their non-text costs.
- The newest request remains useful and protocol-valid while older exchanges fall away predictably.
- The 8,192-token fallback and cautious estimates can leave some engine capacity unused, yet an unusual tokenizer or chat template can still exceed them. A future engine capability may supply a tokenizer-specific estimator behind the same plan and report surface.
- Long-chat semantic compression is still absent. Rolling summaries remain a separate post-MVP decision.

## Alternatives considered

Characters divided by four (rejected: undercounts JSON, wrappers, images, and many code-heavy prompts), letting the engine truncate (rejected: behavior varies and can split tool protocol), dropping individual messages (rejected: creates orphan tool results and incoherent exchanges), keeping any older unit that happens to fit (rejected: produces non-contiguous history), summarizing dropped history during send (rejected: adds latency, another model call, and nondeterminism), and requiring a model-specific tokenizer for MVP (rejected: incompatible with the engine-agnostic client and unavailable from many local servers).
