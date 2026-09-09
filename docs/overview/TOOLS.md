# Tools, skills and permissions

GOAT gives a model a list of available tools. The model can request an action, but the host decides whether it is valid and authorised. Instructions, memory and generated text do not grant authority.

## Four controls with different jobs

| Control | Purpose |
| --- | --- |
| Native file permissions | Approve Herder file creation and editing once, for a chat or for a Pen. |
| Command permissions | Approve an executable within a Pen’s command boundaries, with network permission handled separately. |
| MCP tool approvals | Control calls to tools supplied by a configured external MCP server. |
| JUDAS connection policy | Admit or block supported app connections, previews and process access. |

A remembered file grant does not approve a shell command. A command grant can allow that executable to modify files within its confinement, so turning off native file writes alone does not make an enabled shell read-only. A local MCP server may have its own permissions and outbound traffic.

## Extensions and skills

Herder is the bundled extension for native Pen file and command tools. Other built-ins provide memory integration, skills, optional local control and the Pronk example. You can enable optional built-ins and inspect their configuration.

A skill is an instruction document with optional resources. Loading it does not run a script. User-installable GOATed packages contain declarative content; Kid does not load arbitrary third-party executable plugins.

## Follow an action

Consecutive tool rounds appear in a group in the conversation. Expand the group, then an action, to inspect its arguments and result. Pending, failed and denied actions remain distinguishable. A tool result is evidence about that action; a model’s confident final message is not a substitute for checking it.

Lead adds guidance for the next step after the current response and tool action finish. It leaves pending approvals open. Stop requests interruption; it does not undo completed edits or recall requests already delivered.

Next: [Work on code](../how-to/WORK-ON-CODE.md), [manage permissions](../how-to/PERMISSIONS.md), or read the [permission reference](../reference/PERMISSIONS.md).
