# Paddock

Artifact values, HTML shells, navigation policy and WebKit host.

Public seams: `PaddockArtifact`, `PaddockDocumentCache`, `PaddockHTML`, `PaddockNavigationPolicy`, `WebPreview`.

Dependencies: Caprine, JUDAS.

Bounded in-memory document preparation; ephemeral WebKit, shared immutable rules, Source-mode document retirement and JUDAS revocation.

Validation: PaddockTests, PaddockWebRenderingTests, PaddockBenchmarkTests, RenderingPerformanceTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
