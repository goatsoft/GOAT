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

## Report a problem

Use [known issues](../KNOWN-ISSUES.md) first. A useful bug report includes the GOAT version, macOS version, relevant engine/model versions, a minimal reproduction and the visible error. Remove credentials, private prompts, project content and sensitive endpoints. Do not attach unrestricted environment dumps. Use the [security policy](../../SECURITY.md) for sensitive vulnerabilities.
