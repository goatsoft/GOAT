# GOAT model capability configuration

GOAT keeps model-family knowledge separate from engine request compatibility. A family rule may describe expected capabilities such as vision, tools, reasoning, and context length. It must not select a request dialect, tool-choice shape, reasoning field, or provider-specific parameter.

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

Supported capability names are `vision`, `tools`, `reasoning`, and `reasoning_history`. Unknown names are ignored by capability resolution. `architecture`, `modelType`, `format` and `parameterCount` are optional presentation facts shown in model details. User rules cannot declare request parameters or engine dialects.

## Matching rules

`matchAny` uses normalized case-insensitive model IDs and supports qualified IDs and quantized suffixes; at least one entry must match. `matchAll` entries must all match, which distinguishes variants such as a family's thinking checkpoint. `exclude` matches normalized model tokens and prevents a family rule from applying. Use precise family identifiers, not broad names such as `qwen` or `muse`.

GOAT ships built-in rules for common local families (Qwen3 and Qwen2.5, GPT-OSS, GLM, DeepSeek, Llama 3 and 4, Gemma 3, Mistral Small, Devstral and Magistral, Kimi K2, MiniMax M2, Phi-4, Seed-OSS, Granite 4). They make positive claims only and declare a context length only where the family publishes one stable figure. Packaging hints (MLX or GGUF, quantization) come from the catalog ID and are presentation only.

Built-in rules take precedence over user rules with the same model match. User rules are intended to add knowledge for models GOAT does not know yet, not to replace a built-in rule.

## Evidence precedence

GOAT resolves capability facts in this order:

1. Explicit engine metadata.
2. Built-in model-family knowledge.
3. User model-family knowledge.
4. Unknown.

Positive family evidence fills an engine's missing fields. An explicit engine contradiction does not become supported: the merged result is `unknown` with both evidence sources retained as a conflict. This prevents a family name from hiding an incompatible deployment.

## Request compatibility

Engine configuration owns request compatibility. For example, Qwen chat-template controls remain an explicit engine setting. A Muse-Glimmer family match does not enable `reasoning_effort`, change the request dialect, or change tool-choice encoding.

## Refresh behavior

The registry is read when model catalog and detail metadata are resolved. Refreshing models therefore re-reads this file, reapplies family rules, and updates capability evidence without rebuilding GOAT. Favourites continue to use the stable engine/model identity.

## Qualification

Family evidence is not behavioral proof. Live qualification must be explicit and user initiated. Qualification results should be recorded separately for tool calls, image input, reasoning output, reasoning controls, and reasoning-history replay.
