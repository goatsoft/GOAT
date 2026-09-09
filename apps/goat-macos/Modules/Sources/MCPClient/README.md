# MCPClient

MCP server configuration, transport and capability-bound invocation.

Public seams: `MCPServerManager`, `MCPServerConfig`, `MCPError`.

Dependencies: JUDAS, Tools.

Only module importing the external MCP SDK. JUDAS admits transports/processes; app approvals bind to configuration identity.

Validation: MCPClientTests and MCPModelSecurityTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
