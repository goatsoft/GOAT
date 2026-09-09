# Connect Hindsight

Hindsight is an optional memory service. Its server and bank configuration are separate from GOAT’s local Markdown providers.

## Before you connect

Have a running Hindsight API endpoint, any required credentials and a dedicated Global bank name. Choose a deployment suitable for the data you will retain. A local server may still have its own outbound connections and processing configuration.

## Configure and verify

1. Enable **Hindsight Memory** in **Settings → GOATed → Extensions → Built-in**.
2. Open **Settings → Memory**, configure the Hindsight connection and choose a dedicated Global bank, such as `goat-global`.
3. For a Pen, open its Memory tab and enable Hindsight there. GOAT provisions or reuses that Pen’s bank; known Pen banks cannot be selected as Global memory.
4. Verify that records can load in the selected scope. Recent records are a preview ordered by the service, not proof that all bank history has been loaded.
5. Inspect a deliberately retained non-sensitive example before using the service for important project context.

## Access and recovery

JUDAS must allow the API endpoint. LAN connections may also require **System Settings → Privacy & Security → Local Network → GOAT**. Check the API URL and credentials if the service is unavailable; do not broaden unrelated file or command permissions.

**Open in Hindsight** currently uses the configured hostname on port 9999. The web UI handles its own login. A custom UI port, reverse proxy or tunnel may require opening the correct UI address manually.

Disabling Hindsight pauses GOAT context/tools/retention and preserves saved settings. It does not undo requests already delivered. Changing a bank does not move existing memories. See the [memory reference](../reference/MEMORY.md) and [privacy notice](../PRIVACY.md).


## Connection health

The provider card reports the saved bank connection. GOAT rechecks it every 15 seconds while Memory settings is open. Testing an unchanged saved connection also refreshes the card; changing the server, bank or key remains a draft until saved.

A failed memory request can leave the connection healthy. GOAT reports the request failure and can continue the chat without that context. If the connection is unavailable, the next turn attempts recovery for its enabled memory scope. GOAT does not replay a memory write whose acknowledgement was lost. If a connection keeps failing, inspect its status tooltip, server availability, credentials, macOS Local Network permission and JUDAS policy.
