# GOAT model capability configuration

GOAT keeps model-family knowledge separate from engine request compatibility. A family rule describes expected capabilities, context length and source-backed generation policy. It cannot establish engine support for a request dialect or native control field.

## User configuration

Create this file to add family knowledge without rebuilding the app:

```text
~/.goat/config/model-families.json
```

The file lives in GOAT Home beside `engines.json` and the other user-owned configuration (ADR-0009). It is re-read when its modification date changes.

Example:

```json
{
  "schema": 1,
  "families": [
    {
      "id": "acme-vision",
      "matchAny": ["acme/vision-model"],
      "matchAll": [],
      "exclude": ["text"],
      "contextLength": 131072,
      "capabilities": ["vision", "tools", "reasoning"],
      "architecture": "AcmeVision",
      "modelType": "multimodal",
      "parameterCount": 30000000000
    }
  ]
}
```

Supported capability names are `vision`, `tools`, `reasoning`, and `reasoning_history`. Unknown names are ignored by capability resolution. `architecture`, `modelType`, `format` and `parameterCount` are optional presentation facts shown in model details. User rules may declare generation recommendations, but cannot advertise engine parameter support or select engine dialects.

## Matching rules

`matchAny` uses normalized case-insensitive model IDs and supports qualified IDs and quantized suffixes; at least one entry must match. `matchAll` entries must all match, which distinguishes variants such as a family's thinking checkpoint. `exclude` matches normalized substrings and prevents a family rule from applying. Use precise family identifiers, not broad names such as `qwen` or `muse`.

GOAT ships built-in rules for common local families (Qwen3, Qwen3.8 and Qwen2.5, GPT-OSS, GLM, DeepSeek, Llama 3 and 4, Gemma 3 and Gemma 4 31B instruction, Mistral Small, Devstral and Magistral, Kimi K2, MiniMax M2, Phi-4, Seed-OSS, Granite 4). They make positive claims only and declare a context length only where the family publishes one stable figure. Packaging hints (MLX or GGUF, quantization) come from the catalog ID and are presentation only.

The first matching user rule replaces the built-in match entirely. Within each file, put specific variants before broad families.

## Evidence precedence

GOAT resolves capability facts in this order:

1. Explicit engine metadata.
2. The first matching user model-family rule, if present.
3. Otherwise the first matching built-in rule.
4. Unknown.

Positive family evidence fills an engine's missing fields. An explicit engine contradiction does not become supported: the merged result is `unknown` with both evidence sources retained as a conflict. This prevents a family name from hiding an incompatible deployment.

## Request compatibility

Engine configuration owns request compatibility. For example, Qwen chat-template controls remain an explicit engine setting. A Muse-Glimmer policy can supply documented sampling and a plain-text reasoning-strength instruction, but does not invent a native `reasoning_effort` field, change the request dialect, or change tool-choice encoding.

## Refresh behavior

The registry is read when model catalog and detail metadata are resolved. Refreshing models therefore re-reads this file, reapplies family rules, and updates capability evidence without rebuilding GOAT. Favourites continue to use the stable engine/model identity.

## Qualification

Family evidence is not behavioral proof. Live qualification must be explicit and user initiated. Qualification results should be recorded separately for tool calls, image input, reasoning output, reasoning controls, and reasoning-history replay.

## Generation settings

Family rules can include a `generation` policy as specified by [ADR-0086](adrs/0086-sampling-parameters-are-model-facts.md). For example:

```json
{
  "sampling": {"temperature": 1.0, "topP": 0.95, "topK": 64},
  "reasoningPrompt": "museStrength",
  "reasoningHistory": "all",
  "sources": ["https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/main/generation_config.json"]
}
```

Place this object under a rule's `generation` key. Other optional sampling fields are `minP`, `repetitionPenalty` and `presencePenalty`. Optional `nativeReasoningEffortValues` narrows allowed values when the engine already advertises native effort support; it does not enable the field. `nonThinkingSampling` supplies an alternative only for a documented mode switch; it is not selected simply because a model is labelled reasoning-capable. History accepts `omit`, `currentTurn` or `all`. The supported reasoning prompt choices are `museStrength` and `qwenSoftSwitch`. Do not attach another model's controls to an unverified family.

Models settings shows the matched rule, requested values and evidence links. Custom sampling replaces the complete recommendation for that engine/model pairing; blank custom fields use engine defaults. Reset restores the family policy. An explicit server parameter allowlist can veto either source. A rejected sampling field can be removed for one pre-output retry and remains omitted during that turn, with revised response provenance.

The [complete policy audit](MODEL-GENERATION-POLICIES.md) distinguishes published model facts from live-engine qualification. Unknown or unaudited versions and access-gated sampling data use engine defaults.
