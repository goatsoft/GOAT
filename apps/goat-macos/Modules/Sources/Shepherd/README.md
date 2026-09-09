# Shepherd

Single-turn orchestration, worker execution, tool rounds and durable handover.

Public seams: `ShepherdModel`, `ShepherdEnvironment`, `ShepherdToolSource`.

Dependencies: Bleet, GOATed, Herd, Hoofprint, Inference, MCPClient, Memory, Persistence, Tools.

One active turn for GUI and Hitch; persistence and capability checks gate progress. Worker I/O stays off MainActor.

Validation: ShepherdModelTests and turn-ownership host tests.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
