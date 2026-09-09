# Connect an engine

Use this guide to add a model server and verify a first response. GOAT uses one active engine at a time; you can keep several saved configurations.

## Before you begin

Start the server using its own controls. Note its root URL, authentication requirement and available models. Use [Models and engines](../overview/MODELS.md) for the concepts and the [engine reference](../ENGINES.md) for the exact contract.

## Add the connection

1. Open **Settings → Engine** and add an engine.
2. Choose the matching preset, or **Custom…**. Presets fill conventional URLs and choose capability metadata behavior; they do not install a server.
3. Enter the actual root URL. GOAT appends the API paths. Avoid a URL that redirects to another address.
4. Supply the API key if required. Choose **Test**, review the result and save.
5. Select the engine and a model, then send a short text request. Verify that the response completes before trying images or tools.

The engine list is stored in `~/.goat/config/engines.json` under the default GOAT Home. Credentials use an owner-only file, not the chat database. See [storage](../reference/STORAGE.md).

## If connection fails

Check that the server is running at the saved address. A 401 or 403 usually requires reviewing credentials. A working browser address may still be a dashboard rather than the model API.

JUDAS can block even a local engine in **Block connections** mode. LAN services may also need macOS Local Network permission. Changing JUDAS policy disconnects existing integrations; reconnect deliberately afterward.

If basic chat works but tools or reasoning do not, inspect the model/server capability and template settings. Do not infer support from a model name. The [compatibility table](../ENGINES.md#compatibility-evidence) distinguishes implementation coverage from live qualification.
