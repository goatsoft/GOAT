# Storage, backups and deletion

GOAT separates its home directory, chat database and user-selected workspaces. Paths below are defaults; a custom GOAT Home changes home-relative locations.

| Location | Contents |
| --- | --- |
| `~/.goat/config/` | Engine/MCP configuration, provider settings and custom themes. |
| `~/.goat/config/credentials.json` | Engine credentials, stored with owner-only file permissions. |
| `~/.goat/memory/` | Global local-provider memory, including optional LLM Wiki content. |
| `~/.goat/projects/<name>_<uuid>/` | Pen control data and that Pen’s local memory. |
| `~/Library/Application Support/GOAT/goat.sqlite` | Chats, messages, ratings and persisted grants. |
| User-selected workspace folders | Project files bound to Pens. These are separate from Pen control metadata. |
| `<GOAT_HOME>/control/goat.sock` | Temporary same-user Hitch endpoint when enabled. |

Image attachments are stored under `~/Library/Application Support/GOAT/Attachments/`, separately from GOAT Home. Local Markdown/LLM Wiki memory can be inspected in a text editor. Hindsight data lives on its configured server and is not included merely by copying a local memory folder.

## Credentials and caches

Credentials currently use an owner-readable file, not Keychain storage. GOAT does not provide an encryption-at-rest guarantee for its home or database. macOS account security, disk encryption and backup configuration are separate controls.

Rendering caches contain disposable prepared content and are bounded in memory. They are not the durable transcript. Managed HTTP sessions do not use a persistent shared response cache. The Activity Log retains the latest 500 entries in memory and is cleared when the app exits.

## Back up safely

1. Wait for active chats and command jobs to finish, or deliberately stop and reconcile them.
2. Quit GOAT only after work is idle so files and the database are no longer changing.
3. Back up the complete GOAT Home and GOAT Application Support directory, including SQLite companion files if present. Back up bound workspace folders separately.
4. Handle the backup as private data: it can include credentials, prompts, attachments, memory and grants.
5. Follow the external provider’s backup process for Hindsight or other independently managed services.

Restore to a compatible GOAT version while the app is closed. Preserve ownership and private permissions. Verify the restored workspace paths, memory provider and engine configuration before submitting a new task. Do not copy a live database file alone and assume it represents a consistent backup.

## Remove data deliberately

Use the relevant app controls for individual chats, memory entries and configuration. Removing the application bundle alone does not remove its data directories or user workspaces. For a complete local removal, first back up what you need, reconcile active work, close the app, then remove only the GOAT directories you have confirmed.

Changing a provider or bank does not migrate or delete previous records. Local deletion does not delete data already delivered to an independently managed service. Check that service’s retention and deletion controls separately. See [Privacy](../PRIVACY.md).
