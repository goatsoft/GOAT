# ADR-0017: Engine-agnostic client: any OpenAI-compatible server, oMLX recommended

**Status:** Accepted · 2026-08-30

## Context

ADR-0008 delegated inference to a local oMLX server, and the code was named accordingly (`OMLXEngine`). But the implementation always spoke the generic OpenAI `/v1/chat/completions` dialect, and day one already had a second server (vMLX) answering on the neighbouring port. Users run LM Studio, llama.cpp's server, vLLM, mlx-lm, all speaking the same dialect. Pinning the identity of the client to one vendor was false modesty in reverse: the code was more general than its name.

## Decision

The engine layer is officially **any server speaking the OpenAI chat-completions dialect**:

- `OMLXEngine` → `OpenAICompatEngine`. Same wire behavior; honest name.
- UI copy is engine-neutral; oMLX-specific affordances ("Wake oMLX", "Manage Models in oMLX…") appear only when oMLX is actually installed.
- **[docs/ENGINES.md](../ENGINES.md)** is the compatibility contract: required endpoints, how thinking/tools/vision/usage are consumed, what degrades when a server lacks a feature, and which servers have been verified. Server quirks are absorbed in `StreamAssembler` (ADR-0016), never in views.
- **oMLX remains the recommended engine**: the README's quickstart, the discovery defaults, and the docs all point there first.

Remote engines (hosted APIs) stay in the parking lot: GOAT is local-first, and a remote engine is a different privacy conversation, to be had deliberately, not a side effect of a generic client.

## Consequences

Zero wire changes; a rename plus copy and docs. The contribution surface gets clearer: "my server doesn't work" is an ENGINES.md row plus, at most, an assembler tweak with a wire-shaped test. Discovery still probes the two conventional local ports and never hardcodes an engine identity.

## Alternatives considered

Multi-dialect abstraction now (rejected: YAGNI until the Anthropic `/v1/messages` path is actually built), per-engine adapter classes (rejected: one dialect covers every known local server today), keeping the oMLX name (rejected: it misdescribes the code and discourages the herd from bringing their own server).
