# ADR-0008: Inference delegated to a local oMLX server

**Status:** Accepted · 2026-08-29 · Supersedes [ADR-0001](0001-inference-mlx.md)

## Context

ADR-0001 embedded MLX in-process, making GOAT responsible for model downloads, residency, and RAM budgeting. Direction change from JB: **[oMLX](https://omlx.ai)** should own the model layer entirely: models become "an addon kind of thing", surfaced in GOAT's settings rather than managed by GOAT.

oMLX is a native macOS menu-bar app that downloads, manages, and serves MLX models (text LLMs, VLMs, embeddings) with continuous batching and **tiered KV caching**, exposing **OpenAI-compatible (`/v1/chat/completions`) and Anthropic-compatible (`/v1/messages`)** endpoints on localhost.

Backing this bet, MLX is now the Metal-era gold standard: 2026 benchmarks put it 30–50% ahead of llama.cpp on decode (≈3× on MoE like Qwen3-30B-A3B), Ollama switched its Apple Silicon backend to MLX in March 2026, and Apple's M5 Neural Accelerators target MLX compute graphs. The gap widens each chip generation. Riding oMLX rides all of that for free.

Ground truth on the dev machine (probed 2026-08-29): oMLX.app installed, `omlx-server` on `127.0.0.1:8001` **with API-key auth enabled**; a second MLX server (vMLX) holds `:8000` serving Qwen3-8B. Two live engines on one Mac ⇒ endpoints must be discovered and chosen, never assumed.

## Decision

- `GoatInference` ships `OMLXEngine`, an actor implementing the unchanged `InferenceEngine` protocol over HTTP + SSE against a configured localhost endpoint.
- **Primary dialect: Anthropic `/v1/messages`**: thinking, tool_use, and image blocks map 1:1 onto `GenerationEvent`. OpenAI dialect is the fallback. The M1 spike produces a per-dialect support matrix (streaming · thinking budget · tools · images), checked into docs and re-verified on oMLX updates.
- Engine settings: endpoint URL, optional API key (**Keychain only**, redacted from logs), health check showing server identity + `/v1/models`, an "Open oMLX" launcher, and an onboarding discovery probe across common local ports.
- Model list comes from the server, cached in GRDB for offline display. No download UI, no RAM guard: oMLX's department.
- Effort (Graze/Trot/Climb/Summit) maps to thinking budget + sampling in the request; knobs the server ignores degrade gracefully to sampling-only.
- **Plan B kept warm:** ADR-0001's embedded `mlx-swift-lm` engine remains the documented fallback behind the same protocol (zero-external-process mode). Not built, not deleted.

## Consequences

- Dependency tree collapses: mlx-swift-lm and swift-transformers leave; third-party deps drop to three (GRDB, MCP SDK, MarkdownUI). M1 shrinks dramatically: no download manager.
- New failure mode: engine offline (app closed, port moved, key rotated) → first-class engine-offline UX with a launch button; health is monitored, not assumed.
- Feature ceiling set by oMLX's API surface; mitigated by the spike matrix + graceful degradation. Tiered KV caching is a net win: long chats keep flat TTFT.
- Airplane Mode Guarantee unaffected: localhost only.
- The client is dialect-generic, so any OpenAI-compatible local server (vMLX, mlx-omni-server, Ollama) quietly works; **supported** target is oMLX.

## Alternatives considered

Embedded mlx-swift-lm (superseded → plan B), Ollama daemon (user chose oMLX; Ollama's MLX backend is still preview), vMLX or mlx-omni-server as primary (oMLX's menu-bar management + dual dialects + KV tiering wins).
