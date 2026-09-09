# Hoofprint

Bounded activity history, event-driven audit publication and local rendering signposts.

Public seams: `ActivityLog`, `RenderSignposts`.

Dependencies: JUDAS.

Bounded to 500 in-memory entries; no durable telemetry or endpoint.

Validation: JudasActivityTests; rendering and Shepherd host tests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
