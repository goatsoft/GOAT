# Tools

Transport-neutral tool discovery, requests and results.

Public seams: `ToolProvider`, `ToolSchema`, `ToolCallRequest`, `ToolResult`.

Dependencies: none.

Contracts carry data only; no transport, database, UI or authority implementation.

Validation: GOATed, MCPClient and host router contract tests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
