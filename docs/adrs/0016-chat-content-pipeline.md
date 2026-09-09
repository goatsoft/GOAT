# ADR-0016: Chat content pipeline: normalize at the engine, typed parts in the UI

**Status:** Accepted · 2026-08-30

## Context

The chat experience is the product, and the messy truth is that models do **not** share standards for structured output. Thinking arrives as inline `<think>…</think>` tags (Qwen3 family), as a separate `reasoning_content` delta field (DeepSeek-style servers), as first-class blocks (Anthropic dialect), or not at all. Tool calls stream as fragmented deltas keyed by index, with JSON quality that varies by model size. Token accounting may or may not include a `usage` object. Meanwhile the transcript must hold 60fps while streaming (ADR-0002's cadence rule). The question was whether chat rendering should become a factory/plugin system for extensibility.

## Decision

Two extension seams, neither of them dynamic plugins:

1. **Wire normalization lives in `GoatInference`.** `StreamAssembler` folds every dialect and model convention (think-tag routing, `reasoning_content`, fragmented tool-call reassembly, usage-vs-chunk-count stats) into the canonical `GenerationEvent` stream. A new model quirk (e.g. a channel-based format) lands as an assembler/parser change with wire-shaped tests (`StreamAssemblerTests` feed raw SSE JSON). The Shepherd and every view remain dialect-blind.
2. **Typed message parts in the app.** `MessageView` composes a fixed, typed set of part views: thinking disclosure, streamed text, markdown-on-completion, tool-call cards, code blocks with Paddock hooks. New *renderable* kinds enter through `PaddockArtifact.Kind` (fence-language detection) rather than new view plumbing.

A registry of type-erased renderers (`AnyView` factories) was rejected deliberately: type erasure on the streaming hot path taxes exactly the frames we protect, and this codebase's extension model is a fork editing one `switch`, not third-party bundles loading at runtime.

## Consequences

Model variance is quarantined in one testable type; supporting a new model family should touch `GoatInference` only. Rendering stays fast and typed. The accepted cost: adding a genuinely new part kind is a code change, correct at this scale, revisitable if GOAT ever wants out-of-tree renderers.

## Alternatives considered

`AnyView` renderer registry (rejected: hot-path cost, indirection without a consumer), attributed-string pipeline (rejected: loses SwiftUI composition and the Paddock hooks), dylib/plugin loading (rejected: no stable ABI need, large security surface for a local-first app).
