# Engines: the compatibility contract

GOAT is a streaming client for compatible model engines. It does not run inference in-process. This reference describes Kid’s implemented wire contract; a preset or model name does not establish that every feature works with every server version. Use [Connect an engine](wiki/Engines.md) for setup.

## What GOAT calls

| Endpoint | Used for | Required |
|---|---|---|
| `GET /v1/models` | Model list, health probe, auth detection (401/403 ⇒ key prompt) | **Yes** |
| `GET /v1/models/{model-id}` | Explicit model metadata on generic, vMLX, and Custom profiles | No; unsupported falls back to generic chat |
| `GET /api/status` | oMLX server, queue, cache, and model-memory status | Optional for explicitly selected oMLX profiles; see ADR-0090 |
| `GET /v1/models/status` | oMLX loaded state, context window, and maximum output | Optional for explicitly selected oMLX profiles; see ADR-0090 |
| `GET /api/v1/models` | LM Studio context and capability metadata | No; LM Studio preset only |
| `POST /api/show`, `GET /api/ps` | Ollama capability and effective-context metadata | No; Ollama preset only |
| `GET /props?model=...` | llama.cpp template, modality, and context metadata | No; llama.cpp preset only |
| `POST /v1/chat/completions` (`stream: true`, SSE) | Everything else | **Yes** |

Discovery probes the saved endpoint first. Profiles with a saved credential do not probe fallback ports or forward that credential to another endpoint. Without a saved credential, discovery can probe conventional ports for that preset: `:8000`/`:8001` for oMLX or vMLX, `:11434` for Ollama, `:1234` for LM Studio, and `:8080` for llama.cpp. Custom discovery stays on the generic adapter. Selected-model metadata calls stay on the active endpoint's origin. They contain a catalog model ID and no conversation data. Cross-origin redirects are rejected. No other inference host is contacted (see the connection-policy reference for app-wide boundaries).

## Engines (Settings → Engine)

Engines are a **managed list**, like MCP Servers (ADR-0021): add several, switch which one is active, edit or remove any, all saved in hand-editable `~/.goat/config/engines.json`. **Add / Edit** is seeded from the presets below (plus **Custom…** for anything else) and offers **Test** before you commit. A preset just fills the root URL (the client appends `/v1/...`) and picks the right model-management affordance. It is **not** a second transport; every engine below speaks the one dialect. One engine is active at a time (you generate from one model).

| Preset | Root URL | Manage models |
|---|---|---|
| **oMLX** (recommended) | `http://127.0.0.1:8000` | Opens oMLX.app |
| vMLX | `http://127.0.0.1:8000` | Opens vMLX.app |
| Ollama | `http://127.0.0.1:11434` | `ollama pull <model>` (copyable) |
| LM Studio | `http://127.0.0.1:1234` | Opens LM Studio.app |
| llama.cpp server | `http://127.0.0.1:8080` | `llama-server -m <model.gguf> --port 8080` |
| Custom… | you type it | - |

Fresh installations start with no configured engines and open Engine settings with connection guidance. The first saved engine becomes active automatically. Existing profiles and legacy connections are preserved.

Choosing a preset in the editor fills the URL; use Test to check the connection. You can still edit the port by hand. Ports are conventional defaults. Change the URL if your server listens elsewhere.

### oMLX configuration ownership

GOAT uses oMLX through the same generic Chat Completions contract as other compatible engines. Configure model profiles, recipes, templates, quantization, MTP, ANE use, cache policy, memory limits, and eviction in oMLX. GOAT reads bounded status for presentation and diagnostics; it does not administer those settings.

Models settings exposes **Sampling managed by** for the active engine. oMLX profiles default to Engine; other profiles retain GOAT-managed family recommendations. Explicit per-model custom sampling survives migration and takes precedence in either mode. Clearing custom sampling returns to the selected ownership policy. Reasoning history and compatibility facts are independent of this choice. Response diagnostics record the actual request values and source. [ADR-0090](adrs/0090-omlx-capability-status-and-generation-ownership.md) defines the boundary.

Stats reads model/process memory and aggregate active/waiting request counts only while visible and active. Missing values remain unavailable. After Stop, GOAT checks for server idle for a bounded interval; counts include other clients and are not a per-request cancellation receipt. An unavailable saved endpoint stays selected and is named in the chat banner.

Server context and configured output limits join by exact model ID under the current engine revision. Request output is capped by effort, half the context window, and the reported server limit. Stats distinguishes that effective request ceiling from the server configuration. A response ending with `finish_reason=length` offers an explicit **Continue response** action.

Stable oMLX 0.6.4 is the current maintenance qualification baseline. Requalify a stable 0.7 release before adopting its recipe or MTP behavior for a GOAT release. Prerelease 0.7 trials are deferred until a proper release is selected for requalification.

## Model management and recovery

The Models settings tab is the place to inspect discovered models, mark favourites, and choose a preferred model. If no engine or model is configured, it provides setup guidance rather than showing an empty capability screen.

Model catalogs support both manual refresh and active-scene refresh. The app re-queries configured engines while the active scene is open, allowing models added or made available by an engine to appear without requiring an app restart. Discovery is not qualification: a discovered model is not treated as live-tested or compatible until the relevant engine evidence exists.

Compatibility is resolved per model at request time. The request snapshot records the selected engine and model plus the resolved capability set, while provenance and diagnostics retain sanitized information needed to explain a result. Typed load failures, unexecuted printed tool markup, and resumable file-repair progress are surfaced through recovery paths instead of being silently executed or discarded.

GOAT includes a source-backed family profile for Meta Muse-Glimmer model IDs, including local 4-bit variants. When a compatible engine omits capability fields, that profile supplies vision, tool use, reasoning, and the documented 131,072-token context as `modelFamily` evidence. Explicit engine contradictions are retained as unknown rather than overridden. The profile does not invent a native `reasoning_effort` request field; that remains gated by engine metadata.

GOAT ships source-backed family profiles for common local model families (Qwen3, GPT-OSS, GLM, DeepSeek, Llama, Gemma 3, Mistral Small, Kimi K2, MiniMax M2, Phi-4 and others) and supports optional user family rules at `~/.goat/config/model-families.json`. User rules add capability knowledge for new model families without a rebuild. They cannot select a request dialect or silently override explicit engine contradictions. See [Model capability configuration](MODEL-CAPABILITY-CONFIGURATION.md) for the schema and evidence precedence.

## Feature matrix

Optional metadata can fall back to generic chat behavior; required endpoint or protocol failures still surface as errors. Normalization happens in one place (`StreamAssembler`, ADR-0016).

| Feature | How GOAT consumes it | Without it |
|---|---|---|
| Streaming | SSE `data:` chunks, `[DONE]` terminator | Required |
| Thinking | `<think>...</think>` inline tags, `reasoning_content`, `reasoning`, or `thinking` deltas, and supported typed content parts, all normalized. Audited family policies select compatible reasoning-history scope; explicit engine denial wins. | No thinking disclosure |
| Effort dial | Every model gets budget-clamped output presets; sampling comes from a source-backed family policy, a custom override, or engine defaults. A metadata handshake can add `reasoning_effort` only when the engine explicitly proves the field and allowed value | Generic presets only |
| Tool calls | OpenAI `tool_calls` deltas, fragment reassembly by index; results sent as `role: "tool"` turns | No tools in that chat |
| Vision | User-selected images encoded as content-array `image_url` parts with `data:image/png` payloads; model-name hints never block them | The selected model or server returns its own unsupported-input error |
| Honest stats | `stream_options: {"include_usage": true}` is requested; `usage` on the final chunk gives exact token counts. oMLX generation timing and llama.cpp `timings` are preferred when present. | The client measures from the first real output to completion. Estimated speed or chunk-count tokens are marked `~` in the UI. |
| Context meter | The deterministic request plan feeds the preflight meter; complete server `usage` replaces the used-token estimate after generation and calibrates the next plan's estimate for this chat. `prompt_tokens_details.cached_tokens` (or a top-level `cached_tokens`) is shown when reported. `context_length` / `max_context_length` / `max_model_len` supplies the window | Conservative 16,384-token fallback. Exact usage and estimated window are marked independently |
| oMLX status | Read-only status shows model/process memory, configured ceiling, load state, queue counts, and server-reported limits with provenance | Unavailable; generic chat remains usable |

## Model families

If a model prints Qwen tool-call markup as text instead of returning structured calls, GOAT detects the malformed attempt and requests one corrected response. It never executes the printed markup. A corrected structured call still requires the usual permission checks; repeated malformed output stops with a parser/template error. This does not retry tool execution failures or timeouts. See [ADR-0065](adrs/0065-bounded-tool-format-recovery.md).

Model support follows the endpoint contract. Compatible models use the same generic request path when the selected engine exposes them through the endpoints above. A model family name alone does not establish compatibility.

Dedicated coder variants are the primary workflow. Devstral, Qwen Coder, DeepSeek Coder, Codestral, Code Llama, StarCoder, Granite Code, CodeGemma, OpenCoder, Kimi Dev, and similarly named dedicated variants lead the picker. If a saved default is missing, GOAT chooses a coder variant before the server's first general model. This ordering hint never changes the request body by itself. General Phi, GLM, Kimi, Llama, Gemma, Mistral, and other models remain fully selectable.

Vision-name recognition powers only the model label and a gentle composer warning. It never drops an attached image. User-selected images are always encoded on the generic content-array path, including for unknown or newly released multimodal models.

The Effort dial always works at that generic layer:

| Effort | Temperature | Requested output ceiling before context clamp |
|---|---:|---:|
| Graze | 0.7 | 2,048 (1,024 when the model explicitly cannot reason) |
| Trot | 0.7 | 4,096 (2,048) |
| Climb | 0.6 | 8,192 (4,096) |
| Summit | 0.6 | 16,384 (8,192) |

Reasoning tokens count against `max_tokens` on every compatible engine, so a model whose reasoning support is supported or unknown receives the larger ceiling (ADR-0085). The prompt budget still clamps the ceiling to half the context window.

Native controls are capability-gated additions. Startup, engine changes, and model changes show a short checking state while GOAT reads fresh bounded metadata for the selected model. The hard wall-clock deadline is two seconds; unsupported, oversized, malformed, or absent metadata falls back to the generic path and does not make the engine unhealthy. These calls use an isolated non-caching session with no cookie or shared credential state. GOAT never sends a synthetic completion to test a capability.

Capabilities are supported, unsupported, or unknown. Unknown preserves the generic request. Generic capability arrays provide positive evidence only; an omitted member is not a rejection. Explicitly unsupported tool-template metadata omits MCP schemas. Vision metadata improves the hint but does not strip attachments. `reasoning_effort` is emitted only when an explicit `supported_parameters` declaration or a documented preset adapter proves it and reasoning support is unambiguous. Audited Qwen3 hybrid policies use the published `/think` and `/no_think` soft switches; unrelated models do not receive them.

For a local server using Qwen’s chat template, the explicit per-model compatibility override sends `chat_template_kwargs.enable_thinking`. Audited Qwen3 defaults distinguish thinking/non-thinking sampling. Historical reasoning is omitted for audited older Qwen checkpoints; Qwen3.8 preserves it under its separate policy. The old preservation, template temperature and template effort fields are no longer emitted.

LM Studio's native model list reports reasoning availability and options for its native chat API, but that alone does not prove the OpenAI Chat Completions field, so GOAT records the hint without sending a native control. Ollama's documented OpenAI compatibility plus a model's `thinking` capability enables `none`, `low`, `medium`, `high`, or `max`. llama.cpp enables `none`, `low`, `medium`, or `high` only when `supports_reasoning_effort` is true. Explicit generic metadata may advertise a different allowed set, which GOAT clamps to before encoding. Graze and Summit choose the advertised extremes.

GOAT stores normalized reasoning locally. Audited policies can replay it in `reasoning_content` with all-retained or current-turn scope; unknown protocols omit replay. Engine denial or conflicting history evidence wins. See [model generation policies](MODEL-GENERATION-POLICIES.md).

## Compatibility evidence

Compatibility evidence must be captured from the actual configured engine and model. Catalog discovery alone is not sufficient evidence for a capability claim, and live candidate qualification remains a separate release activity. Verified family profiles are a bounded exception for published model facts, not a substitute for testing the configured server's wire behavior.

| Server | Status |
|---|---|
| oMLX | Stable 0.6.4 maintenance trials cover limits, continuation, cancellation and the tool workflows below. Broader chat, vision and reasoning qualification remains separate. |
| vMLX | Earlier development exercised its wire format; requalify the selected version for a release. |
| Ollama · LM Studio · llama.cpp server · vLLM · mlx-lm | Preset-provided (Ollama/LM Studio/llama.cpp) or same-dialect: expected compatible, unverified; versioned compatibility reports and PRs welcome |

## Streaming timeouts and stall detection (ADR-0089)

The streaming `POST /v1/chat/completions` request uses a **300 second transport idle timeout**, reset by received bytes. After output begins, a separate content watchdog allows **120 seconds** without further output for plain responses and **300 seconds** for requests offering tools. Some engines, including [oMLX 0.6.4](https://github.com/jundot/omlx/blob/v0.6.4/README.md#tool-calling--structured-output), buffer structured calls until the turn is fully parsed. The tool allowance prevents the shorter prose timer from cutting off an otherwise valid edit; it remains bounded even if transport keepalives continue. Silence is shown as waiting, never as invented thinking or tool progress. Before initial output, the transport idle timeout applies. A request that fails before any output with a transient error (HTTP 408, 429, 502, 503, 504 or a connection reset) is retried up to three times with jittered exponential backoff, honouring `Retry-After`.

## Context overflow (ADR-0087)

Engines report a prompt that exceeds the model's context window inconsistently, usually as an HTTP 400 (some as 413) whose body names a context-length or too-long-prompt condition. GOAT classifies such a response as `contextOverflow` when the status is 400 or 413 and the detail contains one of: `context length`, `context window`, `maximum context`, `context_length_exceeded`, `too many tokens`, `exceeds the maximum`, `reduce the length`, `maximum number of tokens`, `prompt is too long`, `input is too long`. A plain 400 without those markers stays a malformed-request classification. On a `contextOverflow` during a turn, GOAT forces one conversation compaction and retries the request once (see ADR-0087); a second overflow fails normally. If an engine phrases overflow differently, add its wording to the marker list in `EngineFailureClassification.swift`.

## Remote engines

Configured HTTP endpoints can be on this Mac, a local network or the internet, subject to JUDAS policy. A remote endpoint receives the context submitted for its work. Local servers can also make independent outbound connections. Do not treat generic API compatibility as a local-only network restriction; see [Privacy](PRIVACY.md) and [Connection policy](reference/CONNECTIONS.md).


## Template and sampler qualification

The [integration audit](INFERENCE-INTEGRATION-AUDIT.md) distinguishes client request correctness from server template/parser behaviour and executed sampler settings. Source-backed rules do not establish engine adapter support. An omitted field allows server defaults, which may be global rather than checkpoint-derived. A server can also force sampling values over explicit request values. Response provenance therefore records requested sampling.


## Maintenance qualification: 20 September 2026

Stable oMLX 0.6.4 trials ran on M1 Studio with Tahoe 26.6.2, in the order below. All four configurations reached a requested 32-token output limit, continued, and returned aggregate request counts to idle after cancellation. These observations qualify transport behavior, not general coding quality.

| Model | Disposable seven-step tool workflow |
|---|---|
| Qwen3.8-27B-MLX-4bit | Passed tool operations and independent exact-file verification, 328.5 seconds. |
| Devstral-Small-2-24B-Instruct-2512-4bit | Passed the same workflow, 320.9 seconds. |
| DeepSeek-R1-Distill-Qwen-14B-8bit | Passed after a saved model-specific oMLX template repair, 75.446 seconds. |
| GLM-4.7-Flash-4bit | Structured call/result transport and all seven operations worked with its existing template. Exact-content verification failed: missing requested semicolon and final newline. |

DeepSeek's installed template omitted tool definitions. The tested per-model `chat_template_kwargs.chat_template` override supplies schemas and serializes call/result history using `<|tool_call_start|>` and `<|tool_call_end|>`, supported by oMLX's existing parser. SHA-256: `9acab20bbbf99b2dbb36f0b6bd497f7367bb6830d4f85fdb7b8b959c02af9b51`. Streaming and non-streaming round trips passed with the saved configuration. This external engine repair is not a template installed or administered by GOAT. No weights, tokenizer files or global sampling settings changed. Do not apply the override to GLM or unrelated checkpoints.

OpenAI-compatible messages and tool schemas form the shared client contract. Model-specific templates and server parsers still determine how those structures reach a checkpoint and return structured calls. Discovery alone does not establish that mapping; printed tool markup never authorizes execution.

The same-request discrepancy between oMLX's reported 37 tok/s and GOAT's live 2–3 tok/s remains under investigation in [issue #38](https://github.com/goatsoft/GOAT/issues/38). These maintenance changes do not resolve it. Live estimates and final engine usage are distinct measurements; no conclusion that all low rates are display errors has been established.
