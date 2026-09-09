# Architecture overview

GOAT has a native SwiftUI/AppKit application, a local Swift package containing its domain modules, and a separate Vue/VitePress web stack. The model engine is an external service.

## Follow a turn

The app collects the selected chat, Pen instructions, provider context and available tool schemas. Shepherd budgets the request and coordinates one active turn. Inference streams the engine’s response; Bleet holds display state. A structured tool request passes through host approval and capability checks before execution. Completed results are persisted and may feed another model request.

The UI does not directly own the model transport or chat database. Persistence contains SQLite access through GRDB. MCPClient contains the external MCP SDK. JUDAS admits supported connections, while GOATed coordinates scoped extension capabilities.

## Boundaries matter

A model response is data, not permission. Workspace binding, grant scope, connection policy and tool lifetime are checked independently. A successful synthetic test does not establish every model/server combination or clean-machine installation.

Start with the [architecture reference](../ARCHITECTURE.md) for diagrams and ownership, the generated [module catalogue](../MODULES.md) for interfaces, and [Contributing](Contributing.md) for build and review. Dated [architecture decisions](../adrs/README.md) explain why the design took this shape.
