# Use the CLI

Hitch lets programs running as your macOS user work with the running GOAT app. It is off by default and uses a private Unix socket, not a network listener.

## Enable and locate the client

Enable **Settings → GOATed → Extensions → Hitch**. A packaged distribution includes `goat` beside the app; copy it to a directory already on your PATH if desired. GOAT does not edit shell configuration. To build from source:

```sh
make cli
apps/goat-macos/Modules/.build/debug/goat --help
```

The CLI checks the configured GOAT Home for `control/goat.sock`. Use `--socket /absolute/path/to/goat.sock` if needed. GOAT must already be running with Hitch enabled; the client does not start a second app instance.

## Inspect before submitting work

```sh
goat status
goat pens list
goat chats list --pen PEN_UUID
```

Replace `PEN_UUID` with an actual returned ID. Lists return up to 32 entries and a `nextCursor`; use `--cursor OFFSET` for another page.

To deliberately submit a request to an existing ready chat:

```sh
goat send --chat CHAT_UUID --text 'Summarise the project brief' --follow
```

This uses the chat’s selected engine and settings. It can start model/tool work. Approvals stay in GOAT and cannot be answered by the API. Closing the terminal does not cancel the turn; use its actual returned ID with `goat watch --turn TURN_UUID` or `goat cancel --turn TURN_UUID`.

Output is JSON. A successful CLI exit means the API request succeeded, not necessarily that a turn completed successfully; inspect its state. Watch output is bounded and omits private reasoning, credentials and raw tool arguments.

Use the [API reference](../reference/CLI-API.md) for operations, wire format, timeouts, idempotent retries and session limits. JUDAS still applies to connections made by submitted chat turns.
