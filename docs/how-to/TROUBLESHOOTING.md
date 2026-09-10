# Troubleshooting

Start with the visible symptom and inspect the relevant result. Avoid changing unrelated permissions to make an error disappear.

| Symptom | Check | Next action |
| --- | --- | --- |
| No models or an unavailable engine | Server running, correct API root, credentials and JUDAS mode | Test the saved engine, then send a small text request. |
| LAN service cannot connect | Literal address/port, service health and macOS Local Network permission | Allow the intended service path, then reconnect. |
| Model prints tool JSON as text | Model template and engine structured-tool parser | Use a compatible pairing. Printed text is never executed as a tool. |
| File creation says the path exists | The current file and intended operation | Read it and request an exact edit; creation never overwrites it. |
| Edit reports No change or a non-unique match | Current contents and proposed fragment | Use a changed, unique fragment from a fresh read. |
| Command cannot find a runtime or configuration | Resolved executable, isolated environment and supported toolchain paths | Choose a supported explicit runtime path. Do not assume your interactive shell environment is inherited. |
| Command waits for input | Generator/installer interactive prompts | Use its documented non-interactive arguments, or stop and run the interactive setup yourself outside the model task. |
| Package download is blocked | Invocation network flag, remembered command grant and JUDAS | Approve only the networking needed for the intended command. |
| Tool times out or result was interrupted | Files/service state may already have changed | Inspect the outcome before retrying. |
| Hindsight has no recent records | Selected provider/bank, extension state, connection and preview limits | Confirm scope and inspect the full bank in the service UI. |
| Statistics show an estimate or long initial wait | Engine usage/timing support, model load and prompt processing | Compare the actual model/engine configuration; a UI estimate is not an engine benchmark. |
| Hitch is unavailable | App running, extension enabled, correct socket and same-user ownership | Check status and the API reference before submitting another mutation. |

## Interrupted or quarantined work

GOAT preserves saved transcript content and completed tool results. If a result was not saved, its outcome may be unknown. Do not assume a restart rolled back an edit or cancelled a remote action.

An extension timeout can quarantine that extension for the current app session. First reconcile outstanding work. Restart only after all active chats and command jobs have finished or been deliberately stopped. A restart is not an appropriate recovery step during active work.

## Reset GOAT for a clean installation

Development builds include **Settings → General → Manage**, with a storage tree, direct reset of the listed appearance/general preferences and automatic uninstall. The preference reset keeps user data and connection/security settings. The published Kid download does not include these controls.

A full reset removes saved chats, attachments, engine connections, credentials, local memory and preferences from the active installation. Back up anything you want to keep first. Keep backups private because they can contain credentials and conversation content.

1. Finish or deliberately stop active chats and command jobs, then quit GOAT.
2. Note the configured GOAT home before clearing preferences. The default is `~/.goat`; a `GOAT_HOME` environment variable or the `goat.home` preference can select another location. You can inspect the saved preference with `defaults read dev.leet.goat goat.home`. A missing preference means no saved override.
3. In Finder, choose **Go → Go to Folder** (`Shift-Command-G`). Move `~/.goat` and `~/Library/Application Support/GOAT` to a private backup folder outside those locations. The latter contains the chat database and attachments. If you configured a different GOAT home, inspect it first: it may contain your own files or share a folder with other work. Do not remove an entire shared folder.
4. If present, move `~/Library/Saved Application State/dev.leet.goat.savedState` to the backup folder too.
5. With GOAT still closed, run `defaults delete dev.leet.goat` in Terminal to clear its preferences and saved layout. If the domain does not exist, there are no preferences to clear.
6. Open GOAT again. With the default home, no environment override and the old data moved aside, Engine settings should open with no saved connections. For an installation test, first replace the app with the build being tested.

These steps reset GOAT's local state. They do not reset macOS privacy permissions or delete remote Hindsight banks, model-engine data or external Pen folders. Do not delete those folders or services as part of a GOAT reset.

## Reset appearance and general preferences

In candidate and development builds, use **Settings → General → Manage → Reset preferences**. It applies the listed appearance and general defaults immediately, preserving data, connections, permissions and window positions. Follow the [reset guide](MANAGE-GOAT-DATA.md#reset-appearance-and-general-preferences) for the exact values and scope.

## Remove GOAT

Candidate and development builds include **Settings → General → Manage → Uninstall GOAT**. Checked options select removal; unchecked items are kept. Partial uninstall preserves user data by default. Follow the [uninstall guide](MANAGE-GOAT-DATA.md#choose-what-uninstall-removes) for the presets, final review, cancellation and recovery process. For an incomplete uninstall, inspect the [recovery report and original locations](MANAGE-GOAT-DATA.md#recover-data-or-check-an-incomplete-uninstall) before retrying.

For the published Kid download, remove the app manually:

Quit GOAT and move the installed `GOAT.app` to Trash. If you installed the optional `goat` command-line tool separately, remove that specific copy or symlink from its installation location too. Removing the app alone keeps local data available for a later reinstall.

To remove local data as well, follow the reset steps above and delete the backups only after reviewing their contents. The published Kid download has no built-in uninstall or reset action. Apple Developer certificates and notarization credentials are build tools, not GOAT app data; leave them in Keychain.

## Report a problem

Use [known issues](../KNOWN-ISSUES.md) first. A useful bug report includes the GOAT version, macOS version, relevant engine/model versions, a minimal reproduction and the visible error. Remove credentials, private prompts, project content and sensitive endpoints. Do not attach unrestricted environment dumps. Use the [security policy](../../SECURITY.md) for sensitive vulnerabilities.
