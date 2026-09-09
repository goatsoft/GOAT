# ADR-0006: MCP via the official Swift SDK

**Status:** Accepted · 2026-08-29

> The eight-round tool limit described below is superseded by ADR-0066. See [continuous tool work](0066-lead-and-continuous-tool-work.md).

## Context

MCP support is a headline feature: GOAT acts as an MCP **client** (host app), like Claude Desktop. The official [`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) provides client + `StdioTransport` and `HTTPClientTransport` (Streamable HTTP, SSE streaming, session management). Local models are worse at tool JSON than frontier models, and tool execution is a security boundary.

## Decision

- Official Swift SDK, pinned. `GoatMCP.ServerManager` (actor) owns lifecycle: connect enabled servers at launch, health state, backoff reconnect, `tools/list` per server.
- Transports: **stdio** (Process with cmd/args/env, npx/uvx ecosystem) and **Streamable HTTP** (URL + headers). ~~Config stored in GRDB~~ → **superseded by [ADR-0009](0009-goat-home-and-mcp-config.md)**: config lives in `~/.goat/config/mcp-servers.json` (Claude Desktop-compatible); the native-forms UI stands as an editor over that file. Grants + call log remain in GRDB.
- **Import from Claude Desktop:** parse `~/Library/Application Support/Claude/claude_desktop_config.json` → preview → import. Killer onboarding for exactly our audience.
- **Permission model:** every call passes a gate: default *ask* (sheet: server, tool, args) with "Always allow this tool" persisting a per-server+tool grant (`ask | always | never`). All calls (incl. denials) land in an inspector log. Builtin tools (memory) ride the same `ToolProvider` pipeline, pre-granted.
- **Loop safety:** max 8 tool rounds per turn; malformed tool JSON gets one low-temperature retry. Settings decides which servers are globally active. Each chat can independently disable any active server, and globally disabled servers are neither shown in the chat picker nor exposed to its model. Existing chats default to every globally active server. `MLXGuidedGeneration` constraint is the stretch upgrade.
- MVP scope: **tools only.** Resources, prompts, sampling, elicitation, roots. Parked.

## Consequences

Full compatibility with the existing MCP server ecosystem; spec churn tracked by bumping one pinned SDK. stdio servers require spawning arbitrary processes → drives ADR-0007 (no App Sandbox). Permission UX adds friction once per tool, deliberate; silent tool execution by a local 8B model is how you delete the wrong folder.

## Alternatives considered

Hand-rolled JSON-RPC client (rejected: spec is alive, SDK is official), community SDKs (rejected: official one is maintained and sufficient), tools-auto-allow default (rejected: security posture wrong for arbitrary servers).
