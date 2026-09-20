# Inference integration audit

Reviewed 13 September 2026. This audit covers GOAT's model-family registry, request resolution, canonical preparation, HTTP encoding, tool history, reasoning replay, output limits, and the boundary to external engines. It supplements [ADR-0086](adrs/0086-sampling-parameters-are-model-facts.md) and [the model policy table](MODEL-GENERATION-POLICIES.md).

## Main finding

A model card and valid request JSON are insufficient to qualify an agent integration. The serving engine must use the checkpoint's processor/chat template, convert API messages into that template's input format, parse generated reasoning and tool calls, and apply compatible sampler settings. GOAT owns the client request and tool execution. The engine owns tokenization, model execution, attention and KV cache implementation.

[Transformers chat templates](https://huggingface.co/docs/transformers/en/chat_templating) explains why control tokens and generation prompts affect behaviour. [Tool use](https://huggingface.co/docs/transformers/en/chat_extras) distinguishes OpenAI argument strings from the dictionaries expected by template rendering. [Response parsing](https://huggingface.co/docs/transformers/en/chat_response_parsing) addresses the reverse conversion. These are separate contracts.

## Findings and corrections

| Area | Finding | Resolution or qualification limit |
| --- | --- | --- |
| Schema ordering | GOAT sorted intermediate schema strings, then parsed and encoded their objects without sorted keys at the HTTP boundary. Templates can preserve this order. | The production encoder now sorts nested keys. Tests preserve array order and compare bytes across repeated rounds. A render experiment confirms that changing schema property order changes Muse's prompt. |
| Qwen3-Coder-Next | The broad Coder rule applied the earlier checkpoint's 0.7/0.8/20 settings and repetition penalty. | A separate Next rule uses its published 1.0/0.95/40 recommendation. It remains non-thinking. |
| Qwen3.8 | The older Qwen history and effort assumptions do not apply. Its template preserves history and rejects `high`. | A separate 27B rule preserves reasoning and supplies default thinking-mode sampling. Allowed native effort values narrow engine evidence to low, medium and xhigh. Missing engine control evidence still means no native field. |
| GLM Flash and Gemma 4 | Broad or older rules did not establish the exact checkpoint's behaviour. | GLM-4.7-Flash and Gemma-4-31B-it have separate source-linked policies. Differently sized/custom Gemma derivatives do not inherit the 31B policy. |
| Sampling provenance | A client cannot confirm the engine used requested settings. oMLX has server-side forced sampling and global defaults. | Settings and diagnostics identify requested sampling. Omission means server resolution, not guaranteed use of `generation_config.json`. |
| Tool-call history | Transformers expects an argument mapping; OpenAI Chat Completions expects a JSON string. | GOAT keeps the API string. An offline test through the installed oMLX conversion code confirms one decode preserves literal JSON inside a string-typed file-content argument. Sending an unconverted API message straight to Muse's template correctly fails. |
| Muse history | Its template consumes `reasoning_content` and resolves tool-result names from call IDs. | Template fixtures verify reasoning, call/result linkage, an extending prefix and one reasoning-strength instruction. The deployed checkpoint/template still requires qualification. |
| Converted Muse templates | The published MLX 4-bit conversion includes an older template that appends reasoning strength unconditionally, defaulting to high. Meta's newer template avoids adding a second directive when the system prompt already contains one. | A caller-supplied strength can conflict with an older template's appended default. Verify the deployed template and rendered prompt before claiming that an effort selection controls execution. A matching model name or sampler is insufficient. |
| Devstral continuation | A deployed template rejected user guidance after a tool-only round with an alternation error. The current upstream Devstral Small 2 template explicitly permits a user message after tool results. | Verify the deployed processor and template revision. Preserve the actual tool history and user instruction; do not silently discard completed work or fabricate a model reply to satisfy a legacy validator. Fresh-chat recovery can continue work but does not qualify same-chat continuation. |
| Documentation precedence | The capability guide incorrectly said built-ins override user rules. | The guide now matches the resolver: the first matching user rule replaces the built-in match. |

Checkpoint evidence: [Qwen3-Coder-Next](https://huggingface.co/Qwen/Qwen3-Coder-Next/blob/main/README.md), [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/README.md), [GLM-4.7-Flash](https://huggingface.co/zai-org/GLM-4.7-Flash/blob/main/README.md), [Gemma-4-31B-it generation config](https://huggingface.co/google/gemma-4-31B-it/blob/main/generation_config.json), and [Muse's canonical template](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/main/chat_template.jinja). The policy table links the precise source for each rule.

Template comparison: [MLX conversion at eee3544](https://huggingface.co/mlx-community/Muse-Glimmer-30B-4bit/blob/eee35444e9139776cab9c25bcaa2446433ec8bce/chat_template.jinja) and [Meta template at a4e59da](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/a4e59da52a7bc87ae7251dd5545c0dd437c44b68/chat_template.jinja). This is a source-level difference, not proof that a particular running engine has either revision installed.

Continuation reference: [Devstral Small 2 upstream template](https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512/blob/main/chat_template.jinja), reviewed on the audit date, accepts `assistant`, `tool` or `user` after a tool message. This does not establish which template an installed conversion actually loads.

## Live agent qualification

Qualify a deployed model progressively: one file read followed by a grounded answer, a small edit with a read-back, a command with its observed exit code, recovery from a real failure, and a fresh-chat memory handover. Passing a read-only checkpoint does not establish editing ability or a working application. Record guidance supplied during recovery so assisted completion is distinguishable from independent completion.

Verify generated artifacts through the actual generator. A model-written file with a generated-file header is not evidence that the generation workflow works. Typecheck, bundling, tests and browser behavior are separate outcomes; a generated declaration file can exist even when bundling fails. Saved handovers must retain those limits and identify the actual failing imports or calls.

Separate first-token latency after large source reads from cached follow-up latency, generation speed, approval waits and UI-control delays. Silence alone does not identify loading, queueing, prefill or reasoning. Use engine-reported timings where available and label aggregate server statistics separately from per-request observations.

Use a bounded, reviewable checkpoint for each trial: name the expected artifact, the relevant files, the checks and the stopping condition before starting. Broad project discovery can consume most of a local model's useful time without producing an edit. Record that outcome, including time spent waiting for approvals, rather than extending the trial indefinitely or silently completing the implementation with another agent. A smaller guided retry is a separate assisted result.

For a handover, have the model save and read back the current requirements, verified state, remaining failures and next checkpoint. Start a fresh chat and require retrieval before implementation. Preserve source links and distinguish historical failures from current ones. A statement that memory was saved is insufficient without a successful tool receipt; a retrieved page is not proof that its instructions were followed.

When a model reports incorrect tool content, inspect the original call arguments and result, then the reconstructed request and serving adapter where available. Do not infer result corruption solely from the model's explanation, or dismiss a possible integration fault solely because the transcript looks correct. Keep unverified boundaries explicit in the trial record.

If native tool syntax appears as ordinary answer text without a structured API call, qualify the serving parser before judging the model's execution ability. Gemma's native `call:` syntax requires conversion into the API's tool-call objects; oMLX implements this in its [tool parser](https://github.com/jundot/omlx/blob/main/omlx/api/tool_calling.py) and [Gemma adapter](https://github.com/jundot/omlx/blob/main/omlx/adapter/gemma4.py). Source support does not prove that a deployment selected that parser. GOAT must not execute displayed prose as an improvised fallback. Record whether an actual tool event occurred and retain the raw API evidence when available.

## Paths checked

- Structured assistant calls and tool responses retain matching IDs. Canonical preparation preserves round identity, images and recovery state. The normal composer converts attachments to PNG before the image request encoder labels them as PNG.
- GOAT sends API messages, not pre-tokenized chat text. It does not add BOS/EOS tokens, `add_generation_prompt`, `do_sample`, `cache_implementation`, beam-search settings or Transformers token IDs to the generic Chat Completions API. Those belong to the serving adapter.
- Output caps include reasoning tokens. The loop detects a `length` finish, reports truncation and does not execute potentially incomplete tool calls. Increasing sampling fidelity does not remove the need for a sufficient output budget.
- The planner counts replayed reasoning conservatively and retains complete tool pairs. Dropping old content, changing mode instructions or changing the tool set can still invalidate prefixes. Sorted JSON cannot prevent those intentional changes.
- Unknown engine metadata remains distinct from explicit denial. Native effort requires advertised support; the family cannot create that support. Explicit sampling allowlists and one bounded pre-output rejection retry retain their existing authority.
- An older Qwen soft switch requires the server's thinking mode to be enabled. Newer checkpoints use their own controls. GOAT cannot infer effective server template kwargs from a checkpoint name alone.

## Verification evidence and limits

An offline rendering experiment used the installed oMLX 0.6.3 message-conversion code, its bundled Jinja 3.1.6, and downloaded official templates. It checked Muse, Qwen3.8, GLM-4.7-Flash and Gemma-4-31B-it. This ran no model weights. It proves properties of those source/template combinations, not of a differently configured remote deployment.

A read-only check of the configured engine reported API version 0.6.4 and ten catalog models. The catalog included the newer variants above. Model status was readable; administrative sampling settings required a separate authenticated admin session. The API credential did not expose those settings. No server setting was changed and no model was loaded by these checks.

The upstream [oMLX Muse tool-parser report](https://github.com/jundot/omlx/issues/2646) describes string-typed JSON being coerced into an object on an affected VLM path. It is a useful regression scenario, not evidence that the audited deployment has that bug. An end-to-end test must confirm the parser preserves argument types before attributing repeated agent failures to it.

Live qualification should record the exact engine build, checkpoint and template revision, effective mode/sampling overrides, a tool call followed by its result and final response, string-valued JSON file content, finish reasons, prompt/cached tokens, TTFT and total task time. Repeated discovery in a previous transcript does not by itself identify which boundary failed.

[Transformers cache strategies](https://huggingface.co/docs/transformers/en/kv_cache) describes execution-side tradeoffs. GOAT can stabilize its input and observe reported cache usage; it cannot select the server's cache implementation through generic client assumptions. This audit claims no measured latency improvement.

## Qualification boundary

Passing host regression tests establishes the client contract, not that every deployed model can complete a coding task. Qualify the exact checkpoint, quantization, serving runtime and template together. Distinguish structured read/edit/command success from whole-project correctness and record independently observed test, lint, typecheck and build exits. A stopped assisted repair remains incomplete even when earlier checks were green.

Memory qualification additionally requires an accurate saved checkpoint, read-back, fresh-chat retrieval and a semantic compaction check that preserves failures and unresolved work. A successful save or compaction operation alone does not establish these properties. A model's missing reasoning stream must not be replaced with invented thoughts; concise observed status remains the fallback described in ADR-0074.
