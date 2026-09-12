# Engines: the compatibility contract

GOAT is a streaming client for compatible model engines. It does not run inference in-process. This reference describes Kid’s implemented wire contract; a preset or model name does not establish that every feature works with every server version. Use [Connect an engine](wiki/Engines.md) for setup.

## What GOAT calls

| Endpoint | Used for | Required |
|---|---|---|
| `GET /v1/models` | Model list, health probe, auth detection (401/403 ⇒ key prompt) | **Yes** |
| `GET /v1/models/{model-id}` | Explicit model metadata on generic, oMLX, vMLX, and Custom profiles | No; unsupported falls back to generic chat |
| `GET /api/v1/models` | LM Studio context and capability metadata | No; LM Studio preset only |
| `POST /api/show`, `GET /api/ps` | Ollama capability and effective-context metadata | No; Ollama preset only |
| `GET /props?model=...` | llama.cpp template, modality, and context metadata | No; llama.cpp preset only |
| `POST /v1/chat/completions` (`stream: true`, SSE) | Everything else | **Yes** |

Discovery always probes the saved endpoint, then only conventional ports for that preset: `:8000`/`:8001` for oMLX or vMLX, `:11434` for Ollama, `:1234` for LM Studio, and `:8080` for llama.cpp. Custom discovery stays on the generic adapter. Selected-model metadata calls stay on the active endpoint's origin. They contain a catalog model ID and no conversation data. Cross-origin redirects are rejected. No other inference host is contacted (see the connection-policy reference for app-wide boundaries).

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

## Model management and recovery

The Models settings tab is the place to inspect discovered models, mark favourites, and choose a preferred model. If no engine or model is configured, it provides setup guidance rather than showing an empty capability screen.

Model catalogs support both manual refresh and active-scene refresh. The app re-queries configured engines while the active scene is open, allowing models added or made available by an engine to appear without requiring an app restart. Discovery is not qualification: a discovered model is not treated as live-tested or compatible until the relevant engine evidence exists.

Compatibility is resolved per model at request time. The request snapshot records the selected engine and model plus the resolved capability set, while provenance and diagnostics retain sanitized information needed to explain a result. Typed load failures, unexecuted printed tool markup, and resumable file-repair progress are surfaced through recovery paths instead of being silently executed or discarded.

GOAT includes a verified family profile for Meta Muse-Glimmer model IDs, including local 4-bit variants. When a compatible engine omits capability fields, that profile supplies vision, tool use, reasoning, and the documented 131,072-token context as `modelFamily` evidence. Explicit engine contradictions are retained as unknown rather than overridden. The profile does not invent a native `reasoning_effort` request field; that remains gated by engine metadata.

GOAT ships verified family profiles for common local model families (Qwen3, GPT-OSS, GLM, DeepSeek, Llama, Gemma 3, Mistral Small, Kimi K2, MiniMax M2, Phi-4 and others) and supports optional user family rules at `~/.goat/config/model-families.json`. User rules add capability knowledge for new model families without a rebuild. They cannot select a request dialect or silently override explicit engine contradictions. See [Model capability configuration](MODEL-CAPABILITY-CONFIGURATION.md) for the schema and evidence precedence.

## Feature matrix

Optional metadata can fall back to generic chat behavior; required endpoint or protocol failures still surface as errors. Normalization happens in one place (`StreamAssembler`, ADR-0016).

| Feature | How GOAT consumes it | Without it |
|---|---|---|
| Streaming | SSE `data:` chunks, `[DONE]` terminator | Required |
| Thinking | `<think>...</think>` inline tags, `reasoning_content`, `reasoning`, or `thinking` deltas, and supported typed content parts, all normalized. An explicit local-Qwen engine profile also replays prior reasoning in its native field. | No thinking disclosure |
| Effort dial | Every model gets temperature and budget-clamped max-token presets. A metadata handshake can add `reasoning_effort` only when the engine explicitly proves the field and allowed value | Generic presets only |
| Tool calls | OpenAI `tool_calls` deltas, fragment reassembly by index; results sent as `role: "tool"` turns | No tools in that chat |
| Vision | User-selected images encoded as content-array `image_url` parts with `data:image/png` payloads; model-name hints never block them | The selected model or server returns its own unsupported-input error |
| Honest stats | `stream_options: {"include_usage": true}` is requested; `usage` on the final chunk gives exact token counts. oMLX generation timing and llama.cpp `timings` are preferred when present. | The client measures from the first real output to completion. Estimated speed or chunk-count tokens are marked `~` in the UI. |
| Context meter | The deterministic request plan feeds the preflight meter; complete server `usage` replaces the used-token estimate after generation and calibrates the next plan's estimate for this chat. `prompt_tokens_details.cached_tokens` (or a top-level `cached_tokens`) is shown when reported. `context_length` / `max_context_length` / `max_model_len` supplies the window | Conservative 16,384-token fallback. Exact usage and estimated window are marked independently |

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

Capabilities are supported, unsupported, or unknown. Unknown preserves the generic request. Generic capability arrays provide positive evidence only; an omitted member is not a rejection. Explicitly unsupported tool-template metadata omits MCP schemas. Vision metadata improves the hint but does not strip attachments. `reasoning_effort` is emitted only when an explicit `supported_parameters` declaration or a documented preset adapter proves it and reasoning support is unambiguous. The Qwen name-derived `/think` and `/no_think` controls have been removed.

For a local server using Qwen's chat template, choose **Qwen local chat template** in that engine's editor. It is an explicit engine contract, never a model-name guess: GOAT sends `chat_template_kwargs.enable_thinking` and `preserve_thinking`, maps Graze/Trot/Climb/Summit to off/low/medium/xhigh, uses Qwen's recommended thinking temperature, and replays each prior assistant reasoning trace in `reasoning_content`. Use it only with a server that documents those fields; generic engines remain on the portable path.

LM Studio's native model list reports reasoning availability and options for its native chat API, but that alone does not prove the OpenAI Chat Completions field, so GOAT records the hint without sending a native control. Ollama's documented OpenAI compatibility plus a model's `thinking` capability enables `none`, `low`, `medium`, `high`, or `max`. llama.cpp enables `none`, `low`, `medium`, or `high` only when `supports_reasoning_effort` is true. Explicit generic metadata may advertise a different allowed set, which GOAT clamps to before encoding. Graze and Summit choose the advertised extremes.

GOAT stores normalized reasoning locally for transcript disclosure. Generic engines never receive it again. The explicit local-Qwen profile is the narrow exception: it returns a prior assistant trace through `reasoning_content`, rather than concatenating it into visible message content. Ordinary chat and OpenAI-style tool calls remain available.

## Compatibility evidence

Compatibility evidence must be captured from the actual configured engine and model. Catalog discovery alone is not sufficient evidence for a capability claim, and live candidate qualification remains a separate release activity. Verified family profiles are a bounded exception for published model facts, not a substitute for testing the configured server's wire behavior.

| Server | Status |
|---|---|
| oMLX | Local development has exercised authentication and discovery. Versioned release qualification for chat, tools, vision and reasoning remains separate. |
| vMLX | Earlier development exercised its wire format; requalify the selected version for a release. |
| Ollama · LM Studio · llama.cpp server · vLLM · mlx-lm | Preset-provided (Ollama/LM Studio/llama.cpp) or same-dialect: expected compatible, unverified; versioned compatibility reports and PRs welcome |

## Streaming timeouts and stall detection (ADR-0089)

The streaming `POST /v1/chat/completions` request uses a **300 second idle timeout** (reset on each received byte), so a silent connection cannot hang indefinitely. Independently, once output has started, if no further event arrives for **120 seconds** the turn fails with a stall error rather than hanging. Before the first token, prefill silence is not failed here (the idle timeout bounds it); after **10 seconds** of prefill the composer shows "Waiting for the engine (prefill)" with the elapsed clock so a long prompt evaluation does not read as a freeze. A request that fails before any output, with a transient error (HTTP 408, 429, 502, 503, 504 or a connection reset), is retried up to three times with jittered exponential backoff, honouring `Retry-After`.

## Remote engines

Configured HTTP endpoints can be on this Mac, a local network or the internet, subject to JUDAS policy. A remote endpoint receives the context submitted for its work. Local servers can also make independent outbound connections. Do not treat generic API compatibility as a local-only network restriction; see [Privacy](PRIVACY.md) and [Connection policy](reference/CONNECTIONS.md).
