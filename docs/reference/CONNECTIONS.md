# Connection-policy reference

JUDAS governs GOAT’s managed connections. For an introduction, see [Connection controls](../wiki/JUDAS.md). This page defines supported addresses, preview behavior and enforcement limits.

## Choose a policy

The three policy choices explain their effect before you select one. **Service access** shows what the active policy permits for this Mac/LAN/Thunderbolt, internet services and MCP processes. Engine, Memory and MCP shortcuts open their connection settings. **Paddock previews** contains the **Off-grid previews** control and its effective access summary; this control now lives in JUDAS rather than General.

| Setting | What it permits |
|---|---|
| **Configured connections** | Your configured engine, Hindsight and MCP endpoints. Preview content follows the Off-grid previews preference. This is the default. |
| **Local networks only** | Configured HTTP endpoints on localhost, private LAN and Thunderbolt addresses. Public internet addresses and external MCP processes are blocked. |
| **Block connections** | No managed HTTP connections, network previews or external MCP process access. This includes local HTTP servers. |

Changing policy closes existing managed HTTP connections, retires preview documents and stops registered MCP processes. Reconnect your integrations when ready. It cannot recall a request already delivered or undo a tool's completed work.

Hitch's private local socket and offline files remain available. A CLI-submitted chat follows exactly the same connection policy as a chat in the app. Pronk can still store its fictional goat locally, although generating a chat response requires an allowed engine connection.

All managed HTTP redirects are blocked, including redirects within one server. Configure the server's final endpoint directly if it redirects.

## LAN and Thunderbolt services

A Hindsight server such as `http://192.168.1.20:8888` is allowed in Configured connections and Local networks only. Supported literal ranges are IPv4 loopback, private and link-local addresses, plus IPv6 loopback, unique-local and link-local addresses. DNS aliases do not automatically receive local-network authority. Connections still require the configured scheme, host and port; redirects remain blocked. Existing Loopback only preferences migrate to Local networks only.

macOS also controls local-network permission. Allow GOAT when prompted, or enable it in **System Settings → Privacy & Security → Local Network**, then reconnect Hindsight. JUDAS includes an **Open System Settings** button and the exact navigation path. It does not claim to know or change the macOS permission status. If GOAT is not listed, connect a local service to request access. GOAT connects only to services you configure; it does not scan the network. Block connections remains an explicit stop for local services too.

## Preview behavior

Off-grid previews is editable in Configured connections mode. Local networks only and Block connections override it, so the control is disabled while showing the access actually in effect. Your saved Off-grid preference is preserved when switching modes. Block connections still allows local preview content.

Restricted HTML and SVG previews disable page scripts and block script-created connections. GOAT's bundled Mermaid renderer still runs locally. Images and media may use explicit loopback addresses in Local networks only mode; Block connections permits no network resources. Native Markdown images are blocked in chat, memory and Paddock.

A deliberate web link is checked before opening your browser. JUDAS does not control what the browser does after an allowed handoff. In Configured connections mode, HTML previews with Off-grid previews turned off can use the web.

## Read the Activity Log

**Show Activity Log** opens Hoofprint, GOAT’s shared session activity panel. Retention and JUDAS log privacy are visible alongside the button. Expand **Protection details** for accepted local addresses, connection safeguards, enforcement limits and offline access. Exact server-address checks and redirect rejection are always enforced; they are not optional switches.

Entries marked **JUDAS** show policy changes, allowed and denied connections, blocked redirects, transport completions/failures, revocations, preview policy and navigation decisions, tool permission decisions and Hitch operations. A completion means the transport finished; the server may still have returned an application error.

JUDAS wakes Hoofprint when events arrive and batches publication; there is no perpetual idle polling timer. Scrolling into older activity pauses automatic following until you return to the top.

The security entries include a sequence number, timestamp, the configured engine/server or extension name, tool name where applicable, and the sanitized destination origin or operation. Oversized or unsafe names are redacted. They exclude prompts, bodies, credentials, URL paths/queries and tool arguments. Existing engine, memory and MCP log entries still appear alongside them.

The log keeps the latest **500 entries in memory**. Clear removes them, and quitting loses them. If the incoming audit queue overflows, an entry reports how many older events were omitted. Preview policy is enforced through WebKit, but WebKit does not report every blocked subresource to the Activity Log. This is not a packet capture.

## What JUDAS can enforce

JUDAS governs GOAT's own managed transports. It does not inspect independent traffic from model servers, MCP child processes or external browsers. A local server can still make its own outbound requests. Restricted modes block MCP processes because GOAT cannot confine their network behavior.

Bundled native extensions remain trusted application code. JUDAS is not a sandbox for arbitrary plugins or an operating-system firewall. GOAT does not load third-party executable extensions in Kid.

See [ADR-0045](../adrs/0045-judas-central-egress-policy.md) and [ADR-0055](../adrs/0055-local-network-service-authority.md) for the implementation boundaries, [Extensions](../wiki/Extensions.md) for GOATed, and [Hitch](../wiki/CLI-and-API.md) for the CLI/API.
