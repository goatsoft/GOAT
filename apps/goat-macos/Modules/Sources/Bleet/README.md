# Bleet

Observable session and transcript state with incremental live metrics.

Public seams: `ChatSession`, `ChatMessage`, `LiveGenerationMetrics`.

Dependencies: Inference, Persistence.

No transport or tool execution; streamed display state is coalesced by Shepherd.

Validation: ComposerStatusTests, ShepherdModelTests, persistence host tests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
