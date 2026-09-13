# Model generation policies

Audited 13 September 2026. This is a record of published checkpoint guidance and GOAT request behaviour, not a live-engine compatibility scoreboard. The bundled JSON is the runtime source; matching owner rules replace it. [ADR-0086](adrs/0086-sampling-parameters-are-model-facts.md) defines resolution and recovery.

An omitted field uses the configured engine default. A configured server can apply different defaults or restrict parameters. Explicit engine parameter lists veto unsupported fields. Models settings exposes the requested values, source links and per-engine/model custom overrides.

The audit separates similarly named releases, excludes draft/base checkpoints, and leaves unidentified versions on engine defaults. The audited Llama 3/4 and Gemma 3/3n sampling files were access-gated. Their values are deliberately not inferred; the separately audited Gemma 4 31B files were accessible. GPT-OSS native reasoning and DeepSeek custom history encoding require the engine's supported adapter. A capability flag alone does not establish that adapter.

## Audited rules

Sampling abbreviations: T = temperature, P = top-p, K = top-k, minP = minimum probability, RP = repetition penalty, PP = presence penalty. History means outgoing reasoning history, not removal of stored transcript text. `currentTurn` includes only assistant reasoning after the newest user message.

| Rule | Sampling | Reasoning history | Primary sources |
| --- | --- | --- | --- |
| qwen3-coder-next | T 1.0, P 0.95, K 40 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-Coder-Next/blob/main/README.md), [Source 2](https://huggingface.co/Qwen/Qwen3-Coder-Next/blob/main/generation_config.json), [Source 3](https://huggingface.co/Qwen/Qwen3-Coder-Next/blob/main/chat_template.jinja) |
| qwen3.8-27b | T 1.0, P 0.95, K 20, minP 0.0, PP 0.0, RP 1.0 | all | [Source 1](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/README.md), [Source 2](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/generation_config.json), [Source 3](https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/chat_template.jinja) |
| glm-4.7-flash | T 1.0, P 0.95 | currentTurn | [Source 1](https://huggingface.co/zai-org/GLM-4.7-Flash/blob/main/README.md), [Source 2](https://huggingface.co/zai-org/GLM-4.7-Flash/blob/main/generation_config.json), [Source 3](https://huggingface.co/zai-org/GLM-4.7-Flash/blob/main/chat_template.jinja) |
| gemma-4-31b-it | T 1.0, P 0.95, K 64 | currentTurn | [Source 1](https://huggingface.co/google/gemma-4-31B-it/blob/main/README.md), [Source 2](https://huggingface.co/google/gemma-4-31B-it/blob/main/generation_config.json), [Source 3](https://huggingface.co/google/gemma-4-31B-it/blob/main/chat_template.jinja) |
| muse-glimmer | T 1.0, P 0.95, K 64 | all | [Source 1](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/main/generation_config.json), [Source 2](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/main/chat_template.jinja) |
| deepseek-r1 | T 0.6, P 0.95 | omit | [Source 1](https://huggingface.co/deepseek-ai/DeepSeek-R1/blob/main/generation_config.json) |
| deepseek-v3.2 | T 1.0, P 0.95 | omit | [Source 1](https://huggingface.co/deepseek-ai/DeepSeek-V3.2/blob/main/generation_config.json) |
| deepseek-v3.1 | T 0.6, P 0.95 | omit | [Source 1](https://huggingface.co/deepseek-ai/DeepSeek-V3.1/blob/main/generation_config.json) |
| deepseek-v3 | Engine default | omit | [Source 1](https://huggingface.co/deepseek-ai/DeepSeek-V3/blob/main/README.md) |
| qwen3-coder | T 0.7, P 0.8, K 20, RP 1.05 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct/blob/main/generation_config.json) |
| qwen3-vl-thinking | T 1.0, P 0.95, K 20, RP 1.0 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-VL-8B-Thinking/blob/main/generation_config.json) |
| qwen3-vl | T 0.7, P 0.8, K 20, RP 1.0 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct/blob/main/generation_config.json) |
| qwen3-thinking | T 0.6, P 0.95, K 20 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-30B-A3B-Thinking-2507/blob/main/generation_config.json) |
| qwen3-instruct | T 0.7, P 0.8, K 20 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507/blob/main/generation_config.json) |
| qwen3 | T 0.6, P 0.95, K 20, minP 0 | omit | [Source 1](https://huggingface.co/Qwen/Qwen3-32B/blob/main/generation_config.json), [Source 2](https://huggingface.co/Qwen/Qwen3-32B/blob/main/README.md) |
| qwen2.5-vl | T 1e-06, RP 1.05 | omit | [Source 1](https://huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct/blob/main/generation_config.json) |
| qwen2-vl | T 0.01, P 0.001, K 1, RP 1.0 | omit | [Source 1](https://huggingface.co/Qwen/Qwen2-VL-7B-Instruct/blob/main/generation_config.json) |
| qwen2.5 | T 0.7, P 0.8, K 20, RP 1.05 | omit | [Source 1](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/blob/main/generation_config.json) |
| gpt-oss | Engine default | omit | [Source 1](https://huggingface.co/openai/gpt-oss-20b/blob/main/README.md) |
| glm-4.1v | T 0.8, P 0.6, K 2 | omit | [Source 1](https://huggingface.co/zai-org/GLM-4.1V-9B-Thinking/blob/main/generation_config.json) |
| glm-4.5v | T 1.0, P 0.0001, K 1 | omit | [Source 1](https://huggingface.co/zai-org/GLM-4.5V/blob/main/generation_config.json) |
| glm-4.6v | T 0.8, P 0.6, K 2 | omit | [Source 1](https://huggingface.co/zai-org/GLM-4.6V/blob/main/generation_config.json) |
| glm-4.5 | Engine default | omit | [Source 1](https://huggingface.co/zai-org/GLM-4.5/blob/main/generation_config.json) |
| glm-4.6 | T 1.0 | omit | [Source 1](https://huggingface.co/zai-org/GLM-4.6/blob/main/generation_config.json) |
| glm-4.7 | T 1.0 | currentTurn | [Source 1](https://huggingface.co/zai-org/GLM-4.7/blob/main/generation_config.json), [Source 2](https://huggingface.co/zai-org/GLM-4.7/blob/main/chat_template.jinja) |
| glm-5 | T 1.0, P 0.95 | currentTurn | [Source 1](https://huggingface.co/zai-org/GLM-5/blob/main/generation_config.json), [Source 2](https://huggingface.co/zai-org/GLM-5/blob/main/chat_template.jinja) |
| llama-4 | Engine default | omit | [Source 1](https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E-Instruct/blob/main/README.md) |
| llama-3.2-vision | Engine default | omit | [Source 1](https://huggingface.co/meta-llama/Llama-3.2-11B-Vision-Instruct/blob/main/README.md) |
| llama-3 | Engine default | omit | [Source 1](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct/blob/main/README.md) |
| gemma-3-multimodal | Engine default | omit | [Source 1](https://huggingface.co/google/gemma-3-27b-it/blob/main/README.md) |
| gemma-3n | Engine default | omit | [Source 1](https://huggingface.co/google/gemma-3n-E4B-it/blob/main/README.md) |
| mistral-small-3 | T 0.15 | omit | [Source 1](https://huggingface.co/mistralai/Mistral-Small-3.2-24B-Instruct-2506/blob/main/README.md) |
| magistral | T 0.7, P 0.95 | omit | [Source 1](https://huggingface.co/mistralai/Magistral-Small-2506/blob/main/README.md) |
| devstral | Engine default | omit | [Source 1](https://huggingface.co/mistralai/Devstral-Small-2505/blob/main/README.md) |
| kimi-k2.5 | T 1.0, P 0.95 | currentTurn | [Source 1](https://huggingface.co/moonshotai/Kimi-K2.5/blob/main/README.md), [Source 2](https://huggingface.co/moonshotai/Kimi-K2.5/blob/main/chat_template.jinja) |
| kimi-k2-thinking | T 1.0 | currentTurn | [Source 1](https://huggingface.co/moonshotai/Kimi-K2-Thinking/blob/main/README.md), [Source 2](https://huggingface.co/moonshotai/Kimi-K2-Thinking/blob/main/chat_template.jinja) |
| kimi-k2 | T 0.6 | omit | [Source 1](https://huggingface.co/moonshotai/Kimi-K2-Instruct/blob/main/README.md) |
| minimax-m2 | T 1.0, P 0.95, K 40 | currentTurn | [Source 1](https://huggingface.co/MiniMaxAI/MiniMax-M2/blob/main/generation_config.json), [Source 2](https://huggingface.co/MiniMaxAI/MiniMax-M2/blob/main/chat_template.jinja) |
| phi-4-multimodal | Engine default | omit | [Source 1](https://huggingface.co/microsoft/Phi-4-multimodal-instruct/blob/main/README.md) |
| phi-4-reasoning | T 0.8, P 0.95, K 50 | omit | [Source 1](https://huggingface.co/microsoft/Phi-4-reasoning/blob/main/generation_config.json) |
| phi-4-mini-reasoning | T 0.8, P 0.95 | omit | [Source 1](https://huggingface.co/microsoft/Phi-4-mini-reasoning/blob/main/README.md) |
| phi-4-mini | Engine default | omit | [Source 1](https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/README.md) |
| seed-oss | T 1.1, P 0.95 | omit | [Source 1](https://huggingface.co/ByteDance-Seed/Seed-OSS-36B-Instruct/blob/main/generation_config.json) |
| granite-4 | Engine default | omit | [Source 1](https://huggingface.co/ibm-granite/granite-4.0-h-small/blob/main/README.md) |
| minimax-m2.1 | T 1.0, P 0.95, K 40 | omit | [Source 1](https://huggingface.co/MiniMaxAI/MiniMax-M2.1/blob/main/generation_config.json) |
| magistral-small-2509 | T 0.7, P 0.95 | omit | [Source 1](https://huggingface.co/mistralai/Magistral-Small-2509/blob/main/generation_config.json) |
| devstral-small-2 | T 0.15 | omit | [Source 1](https://huggingface.co/mistralai/Devstral-Small-2-24B-Instruct-2512/blob/main/generation_config.json) |

## Mode-specific behaviour

- Qwen3-Coder-Next has its own 1.0/0.95/40 policy. Qwen3.8-27B retains all reasoning and uses its published default thinking-mode settings; it must not inherit the older Qwen3 no-history rule. Its template accepts low, medium and xhigh, but rejects high. Family restrictions narrow an advertised native effort contract without enabling one.
- Gemma 4 31B instruction uses its own generation config and current-turn history. Unverified fine-tunes, including differently named coder derivatives, remain on engine defaults.

- Muse maps Graze/Trot/Climb/Summit to low/medium/high/xhigh through its documented system instruction. Its sampling recommendation remains the same across those effort levels.
- Qwen3 hybrid Graze requests `/no_think` with T 0.7, P 0.8, K 20 and minP 0. Other efforts request `/think` with the thinking policy. Fixed-mode Qwen checkpoints do not receive the hybrid switch. The explicit local Qwen compatibility override sends only `enable_thinking`; it does not invent preservation or effort fields.
- Kimi K2.5 uses its default thinking-mode policy. Its documented instant-mode switch is an engine-template setting, not inferred from GOAT Graze.
- GLM 4.7/5 current-turn replay follows their canonical templates. Cross-turn preserved thinking requires engine configuration; GOAT does not silently add `clear_thinking` to an unverified endpoint.
- Qwen3 VL instruct publishes different task-specific settings. The bundled policy follows its checkpoint generation config; image-specific benchmark settings are not silently selected from model name alone.

See [Transformers generation configuration](https://huggingface.co/docs/transformers/en/main_classes/text_generation) for parameter definitions. GOAT does not send Transformers-only execution, cache, beam-search or token-ID settings to a Chat Completions endpoint.

## Verification boundaries

Request fixtures cover sampling, engine veto, custom replacement, version boundaries, reasoning instructions/history, stable preparation and tool pairing. Fake-engine tests cover rejected sampling parameters. These do not measure hardware speed, prefix-cache reuse or agentic quality. Engine/runtime/checkpoint versions and live task results belong in the [engine compatibility record](ENGINES.md).
