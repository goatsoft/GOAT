# Pens

Folder-backed Pen metadata, instructions and serializable colour. Native workspace file operations support the bundled GOATed Herder extension.

Public seams: `PenSpec`, `PenStore`, `PenFileRef`, `OKLCH`, `PenFileTools`, `PenCommandTools`.

Dependencies: Herd, JUDAS, Tools.

Validated identifiers, staged writes, explicit workspace binding; no UI framework or database dependency. File tools use a turn-bound workspace and descriptor-relative traversal, reject symlinks and multiple hard links, bound reads, and require host approval before writes. Commands use a deny-default macOS sandbox, isolated environment, separate owner whitelist and JUDAS network admission.

Validation: PersistenceSecurityTests, PensHomeTests and scope tests. PenFileToolsTests and AppToolRouterTests cover writes, path boundaries and approval revocation.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
