# Memory

Provider-neutral memory contracts, scope and local stores.

Public seams: `MemoryStore`, `MemoryContext`, `WikiMemoryStore`, `LLMWikiMemoryStore`, `MemoryConfigurationStore`.

Dependencies: Herd, JUDAS.

Exclusive Global or Pen scope, bounded descriptor-relative filesystem operations; provider content does not grant authority.

Validation: MemoryTests and MemoryModelTests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
