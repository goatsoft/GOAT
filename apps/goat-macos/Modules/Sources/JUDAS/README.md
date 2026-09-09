# JUDAS

Host connection policy, revocation and bounded security events.

Public seams: `Judas`, `JudasHTTPClient`, `JudasRegistration`, `JudasMode`, `LocalNetworkAddress`.

Dependencies: none.

Configured / local-networks-only / blocked policy; redirects rejected. Not an OS firewall or native-code sandbox.

Validation: JudasTests, JudasMCPTests, JudasActivityTests and the network boundary checker.

See the [module catalogue](../../../../../docs/MODULES.md) and [architecture](../../../../../docs/ARCHITECTURE.md). App-specific screens and routing stay in the host; importing this module does not initialize the app.
