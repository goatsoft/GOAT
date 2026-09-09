# Hindsight

Optional bank-scoped memory service transport and store.

Public seams: `HindsightControlClient`, `HindsightProviderClient`, `HindsightMemoryStore`, `HindsightLimits`.

Dependencies: Herd, JUDAS, MCPClient, Memory, Tools.

Uses JUDAS and the bounded MCP adapter; bank authority and response limits are explicit. No automatic cross-Pen migration.

Validation: HindsightBrowserTests, MemoryModelTests, Hindsight configuration tests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
