# ADR-0020: Engine presets: pick a known engine, or point at any custom URL

**Status:** Accepted · 2026-08-30

## Context

ADR-0017 made the client engine-agnostic: it speaks the OpenAI `/v1` dialect to whatever URL it is given. But Settings still exposed only a raw endpoint field and a single oMLX-specific button ("Manage Models in oMLX…"). A user running Ollama or LM Studio had to know the right port, know GOAT was OpenAI-compatible at all, and got no help managing models. The transport was general; the UX was not.

## Decision

Settings → Engine offers a **preset picker plus a Custom option**:

- A preset is pure data (`EnginePreset` in GoatInference): a name, the root URL its server listens on (the client still appends `/v1/...`), a one-line blurb, and how models are managed. It is **not** a second transport. Every preset speaks the one dialect.
- Shipped presets: **oMLX** (recommended), **vMLX**, **Ollama** (`:11434`), **LM Studio** (`:1234`), **llama.cpp server** (`:8080`), and **Custom…** (type any URL).
- Choosing a preset fills the URL and re-probes; the URL stays editable, so a preset is a convenience, never a cage. The chosen preset id is remembered (`engine.preset`).
- **Model management is engine-aware**, not removed: open the engine's app when the preset names one and it's installed (oMLX/vMLX/LM Studio); show a copyable command for CLI engines (`ollama pull <model>`, `llama-server …`); show nothing for bare/custom endpoints. The composer capsule and the empty-state banner use the same generalized affordance ("Wake `<engine>`").
- Discovery also probes Ollama's `:11434` alongside the MLX ports.

oMLX remains the recommended engine everywhere (picker default, discovery seed, docs).

## Consequences

Adding an engine is a row in `EnginePreset.all`: no new types, transports, or views. [docs/ENGINES.md](../ENGINES.md) carries the preset table and stays the compatibility contract. Presets are conventional defaults; an unusual port is one edit away in the same field. Remote/hosted engines remain parked (ADR-0017). Presets are local-first only.

## Alternatives considered

Raw URL only (rejected: leaves non-oMLX users to guess ports and compatibility), presets only with no free-form field (rejected: blocks unusual ports and self-hosted setups), removing model management entirely (rejected: the oMLX "manage models" jump is genuinely useful; generalizing it serves more engines than dropping it), a per-engine adapter class (rejected: still one dialect; a data preset is enough, mirroring ADR-0017's reasoning).
