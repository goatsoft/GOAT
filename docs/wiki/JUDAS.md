# Connection controls

JUDAS controls GOAT’s supported connections to engines, memory services, tools and preview resources. It is an application policy layer, not an OS firewall.

## Choose a policy

1. Open **Settings → JUDAS**.
2. Review **Connection policy** and select the mode appropriate for your work.
3. Read **Service access** to see the effect on local services, internet services and MCP processes.
4. Reconnect integrations deliberately after changing policy; the change disconnects active managed connections.

| Mode | Effect |
| --- | --- |
| Configured connections | Permit configured services on this Mac, a local network or the internet. |
| Local networks only | Permit supported local HTTP addresses; block public internet addresses and external MCP processes. |
| Block connections | Stop managed connections, including local HTTP services. Offline files and the private Hitch socket remain available. |

Changes cannot recall delivered requests or undo completed actions. A local engine or external browser may make independent connections that GOAT cannot inspect.

## Previews and activity

In **Paddock previews**, review **Off-grid previews** and the effective access summary. Other policy modes can override the saved preference. Use **Show Activity Log** to inspect GOAT’s recorded events; it is bounded session history, not a packet capture.

macOS Local Network permission is separate. JUDAS provides the System Settings path, but does not claim to know or change the macOS permission status.

The [connection-policy reference](../reference/CONNECTIONS.md) documents supported address ranges, preview behavior, redirects, command networking and enforcement limits. Read [Privacy](../PRIVACY.md) for the wider data boundaries.
