# ADR-0021: Engines are a managed list, sharing the MCP servers' shape

**Status:** Accepted · 2026-08-30 · refines [ADR-0020](0020-engine-presets.md)

## Context

ADR-0020 gave Settings an engine preset picker plus a Custom URL. That is fine for one engine, but people keep more than one around (oMLX for daily driving, Ollama for a model it has, a remote box occasionally). A single picker can't hold several configured engines, and it looked nothing like the MCP Servers screen, which already solves "a list of pluggable things you add, configure, enable, and remove." Two pluggable subsystems, two different interfaces, is a worse app.

## Decision

Engines become a **managed list** that mirrors MCP Servers:

- Saved engines live in **`~/.goat/config/engines.json`** (`EngineProfile` list + an `active` id), hand-editable, alongside `mcp-servers.json`. First run migrates the old single endpoint (+ preset + key) into one profile.
- The Engine tab is a list with the same chrome as MCP: an action bar (Add / Edit Config) over rows with a status dot, name, URL, and a switch. **Add / Edit** is a sheet with **Test** (probes `/v1/models`) before committing, seeded from the ADR-0020 presets. The active engine's key + model list sit as sections beneath.
- **One engine is active at a time**: you generate from one model, so the switch is a radio, not a set of independent checkboxes (this is where engines and MCP legitimately differ: MCP tools all aggregate at once). Switching active re-points the live client and re-probes.
- API keys move to **per-engine** storage in `credentials.json` (`engine.<id>.apiKey`), still never in the database or logs (ADR-0012).

The shared surface is the **UX + persistence pattern**, captured in a reusable `ManagedListScaffold` both screens use, deliberately **not** a unified engine/MCP domain protocol. Engines do inference; MCP servers expose tools; forcing them under one type would be the abstraction ADR-0017's reasoning warns against. Same feel, honest separation.

## Consequences

The two pluggable systems now look and behave alike, so learning one teaches the other. Adding an engine is a row in the list or a hand-edit of `engines.json`. The transport is unchanged (ADR-0017); this is state + UI. Multiple *simultaneously live* engines with an aggregated model picker were considered and parked. It needs per-model→engine routing in generation and health, and buys little while you can still only talk to one model at a time.

## Alternatives considered

Keep the single picker (rejected: can't hold multiple engines, diverges from MCP), multiple engines enabled at once with a merged model list (rejected for now: routing complexity for little gain; one active engine covers the real need), a unified `Pluggable`/`Connector` protocol over engines and MCP (rejected: shoehorns two different domains; sharing the list *chrome* delivers the "common interface" the UX needs without the coupling).
