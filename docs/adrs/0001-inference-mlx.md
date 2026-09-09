# ADR-0001: On-device inference via MLX (`mlx-swift-lm`)

**Status:** Superseded by [ADR-0008](0008-inference-via-omlx.md) · 2026-08-29

> Retained as the design for the **plan-B embedded engine** behind the same `InferenceEngine` protocol. GOAT's shipping engine is an oMLX client.

## Context

GOAT is local-only by definition. The brief specified "oLMX", which we read as **MLX** (Apple's array framework for Apple Silicon) since it is the only serious native-Swift path for on-device LLMs on macOS. (If it meant Ollama, see Consequences: the engine protocol makes that a swappable backend, not a rewrite.)

Options for running LLMs locally on an M-series Mac from Swift:

1. **MLX** via [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm): first-party-adjacent (Apple ML research), pure Swift API, `MLXLLM` + `MLXVLM` + `MLXLMCommon` libraries (v3.x), models from `mlx-community` on Hugging Face, plus `MLXGuidedGeneration` for constrained output.
2. **llama.cpp** (C++ bridged): broad GGUF ecosystem, but a C interop layer, manual Metal tuning, no first-class Swift surface.
3. **Ollama as a sidecar daemon**: easy, but it's an HTTP client to a bundled server: not "native app doing inference", weaker vision/session control, extra process management.
4. **Foundation Models framework**: native, but Apple's on-device model only; no model choice, no vision flexibility. Disqualified as the core (interesting later for auto-titling).

## Decision

MLX via `mlx-swift-lm` (pinned release, currently 3.31.x), wrapped in an `InferenceEngine` actor protocol owned by `GoatInference`. UI and Shepherd know only the protocol and its `GenerationEvent` stream. `LLMModelFactory` for text models, `VLMModelFactory` for vision. One resident model; explicit unload on switch. Model downloads via the Hub API from swift-transformers into an app-managed directory.

## Consequences

- Apple Silicon only, macOS only. Fine: that is the product.
- Upstream moves fast; the protocol firewall plus a pinned version confine churn to one package. M1 begins with a spike that pins exact APIs for tool calling and thinking budgets.
- A future `OllamaEngine: InferenceEngine` is a legitimate escape hatch (and the answer if "oLMX" meant Ollama).
- `MLXGuidedGeneration` is available for constraining tool-call JSON (M4 stretch).

## Alternatives considered

llama.cpp (rejected: C interop tax, worse Swift ergonomics), Ollama sidecar (rejected as core: not native inference, daemon lifecycle), Foundation Models (rejected as core: no model choice).
