# Persistence

Chat database, migrations, records and tool-grant storage.

Public seams: `ChatDatabase`, `ChatRecord`, `MessageRecord`, `ToolGrantRecord`, `PenFileGrantRecord`, `ToolEventSnapshot`.

Dependencies: Herd.

Async GRDB pool with indexed reads; cached narrow checkpoints preserve independent metadata. Durable records never depend on render caches.

Validation: DatabaseTests and PersistenceWriterTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
