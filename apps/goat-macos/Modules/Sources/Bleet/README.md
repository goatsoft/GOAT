# Bleet

Observable session and transcript state, incremental live metrics and Markdown reply segmentation.

Public seams: `ChatSession`, `ChatMessage`, `LiveGenerationMetrics`, `MarkdownSegmenter`, `MarkdownSegmentation`, `MarkdownSegment`.

Dependencies: Inference, Persistence.

No transport or tool execution; streamed display state is coalesced by Shepherd.

Validation: BleetTests covers message revisions, live metrics and Markdown segmentation (valid boundaries, bounded bodies, oversized and nested fences, tables and paragraphs, growth stability, linear scanner work); the Bleet test plan covers composer, transcript and status presentation. Run `make test MODULE=Bleet`.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
