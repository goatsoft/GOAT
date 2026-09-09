# CLI and local API reference

Hitch API v1 uses a private Unix socket owned by the running GOAT app. Enable Hitch explicitly. For setup and first commands, see [Use the CLI](../wiki/CLI-and-API.md).

## API v1

Connect a Unix-domain stream socket to the endpoint. Send exactly one UTF-8 JSON object followed by a newline; read one JSON reply followed by a newline. The server closes the connection after the reply. Both peers must belong to the same macOS user. Do not change the private directory (0700), socket (0600) or lock-file (0600) permissions.

Request:

```json
{"version":1,"id":"45AA883C-F71C-4AE2-B492-EEC3F8806EB0","operation":"status","arguments":{}}
```

A reply contains `version`, the matching `id`, and either `result` or `error`. `result` is a JSON-encoded string: parse the outer envelope, check `error`, then parse `result` for app operations. For example:

```json
{"version":1,"id":"45AA883C-F71C-4AE2-B492-EEC3F8806EB0","result":"{\"api\":\"1\",\"state\":\"ready\",\"activeTurn\":\"\",\"permission\":\"none\"}"}
```

| Operation | Arguments (string values) | Result |
|---|---|---|
| `status` | none | API version, readiness, current turn and whether approval is waiting |
| `pens.list` | optional `cursor` | `items` with IDs, names and configured workspace paths; optional `nextCursor` |
| `chats.list` | optional `pen`, `cursor` | `items` with IDs, titles and Pen IDs; optional `nextCursor` |
| `chats.create` | optional `pen` | `chat` UUID |
| `turn.send` | required `chat`, `text` | `turn`, `chat`, `state` |
| `turn.read` | required `turn` | bounded text snapshot, state, truncation flag and approval guidance |
| `turn.cancel` | required `turn` | `cancellation_requested` or `already_ended` |

Requests are capped at 64 KiB; a text argument at 32 KiB of UTF-8; outer replies at 512 KiB. The app/service payload is capped at 256 KiB before JSON envelope encoding. Eight client connections are admitted at a time. Socket reads/writes have a ten-second timeout and an elapsed-time check. Clients should close incomplete requests promptly.

## Retries and errors

Use `--request-id UUID` or preserve the request's `id` when retrying a mutation after an uncertain reply. Within one enabled session, the same UUID and exact request replay the original result without repeating the action. Reusing it with changed content fails with `id_conflict`. This guarantee does not survive disabling control or restarting GOAT. Inspect app state before retrying across either boundary.

The ledger retains 1,024 mutations. When full, new mutations fail with `history_full`; reads and identical retries still work. The app retains at most 128 control turn records per enabled session. Disable and re-enable control to begin a new session after reconciling outstanding work; old turn handles and retry identities are then unavailable.

| Error | Action |
|---|---|
| `disabled` / connection unavailable | Start GOAT and enable control. Check GOAT Home or `--socket`. |
| `unsafe_endpoint` | Check directory/socket ownership and permissions. GOAT will not overwrite an unsafe path. |
| `unsupported_version` | Use API version 1. |
| `invalid_arguments` | Check the operation, required UUIDs, allowed fields and size limits. |
| `busy` | Wait for the current turn or stop it in GOAT; another app instance can also own the socket. |
| `unavailable` | Check the target chat/turn and engine readiness. Handles from an earlier control session do not work. |
| `id_conflict` | Reuse an ID only with its original request. |
| `history_full` | Reconcile current work, then explicitly start a new enabled session. |
| `operation_failed` | Inspect the app's state before retrying with the same request ID. Provider errors are redacted. |

Malformed or oversized transport frames can be rejected by closing the connection without a reply. Exit status 0 means the CLI received an API success; malformed commands, transport failures and API errors exit nonzero. A `failed` turn state is reported as data and should be checked by automation.

There is no shell execution, credential export, arbitrary file access or permission-granting API. Read [ADR-0043](../adrs/0043-local-goat-control-and-cli.md) for the ownership and trust decisions.

## JUDAS policy

Hitch remains available through its private socket under every [JUDAS](CONNECTIONS.md) mode. Submitted turns still require an allowed engine connection, and tool calls retain existing approvals. Local API operations are recorded in the Activity Log without arguments or message bodies. The API cannot change JUDAS settings.
