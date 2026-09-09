# Hitch

Same-user local control API, replay ledger and Unix socket.

Public seams: `HitchRequest`, `HitchReply`, `HitchDispatcher`, `HitchServer`, `LocalSocket`.

Dependencies: GOATed.

Off by default; private Unix socket, no TCP, no credentials API, no approval bypass.

Validation: HitchTests includes real temporary sockets and the built CLI.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
