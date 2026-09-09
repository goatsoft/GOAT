# Permission reference

Kid separates native file authority, native command authority, external MCP tool approval and JUDAS connection policy. Models, skills, memory and tool results do not administer these controls.

## Native Herder file tools

| Tool | Behavior |
| --- | --- |
| `pen_list_files` | Sorted, workspace-relative listing with bounded pages and `next_after`. |
| `pen_read_file` | Bounded text read with `next_start_line` for continuation. |
| `pen_search` | Literal-text search in eligible source files. |
| `pen_write_file` | Create a new file; an existing path is an error. |
| `pen_edit_file` | Replace one exact unique fragment from the current file. |

Herder is available for a turn in a configured Pen workspace when chat tools and the relevant extension operations are enabled. Native reads are bounded; creation and editing require host approval or a matching remembered grant.

| Grant | Lifetime and effect |
| --- | --- |
| Allow Once | The prepared action shown in the dialog. |
| Allow for this chat | Native creation/editing in that chat, including after reopening it. |
| Always allow for this Pen | Native creation/editing for current and future chats in the Pen. |
| Ask for approval | Require approval after removing authority applicable to the selected scope. |

A Pen-wide grant is broader than a chat grant. Selecting a narrower composer option while one is active can affect other chats, as the UI explains. Resetting file permissions from the Pen page clears all file grants in the Pen. Moving a chat clears its chat-only grant; changing the workspace clears file grants for the Pen.

Every write rechecks the prepared action, workspace and filesystem state. UTF-8 files are limited to 1 MiB. Reads return at most 200 lines and 32 KiB; directory pages at most 200 entries. Symbolic links, multiply linked files and `.git` metadata are excluded. Tool-call arguments are capped at 64 KiB by GOATed. An identical edit replacement reports No change; an intervening file change invalidates a prepared edit.

## Native command jobs

`pen_run_command` starts a permitted executable with literal `args`. `pen_command_status` reads the job identified by its exact returned ID; `pen_stop_command` stops that job. Stop is not file deletion. Shell substitutions, redirection and `~` are not expanded in literal argument fields.

A command whitelist entry authorises an executable for one chat or all Pen chats, within its filesystem and network limits. It permits any arguments and child commands inside those boundaries, not only the command line first shown. The owner can resolve and edit entries without running the program. Basic offline inspection commands are allowed; other executables require approval. Native file grants do not grant command authority.

Networking is blocked by default. A call must request it, its executable grant must permit it, and JUDAS must admit it. A network-enabled grant also permits offline invocations. Pen-wide grants are additive; a narrower chat entry does not revoke them.

Command networking is intentionally coarser than HTTP endpoint policy. **Local networks only** cannot enforce a LAN-only boundary on arbitrary child-process traffic, so network-enabled jobs require Configured connections. Offline confined jobs can remain available in restricted modes. Revocation and turn completion stop remaining registered command work; completed filesystem or remote effects are not rolled back.

Jobs use a confined working directory, isolated home/cache and read-only system/toolchain access. They are non-interactive, have bounded output and a maximum ten-minute deadline. The initial Herder default timeout is 120 seconds. Detached background services are unsupported. The model must inspect required job completion before declaring success.

Confinement currently depends on macOS `sandbox-exec`. Missing runtimes, authenticated registries and host configuration require deliberate compatibility work, not automatic access to personal files. An approved shell command can modify files even when Herder’s separate native-write option is off.

## External MCP and failure boundaries

MCP calls use configured server/tool authority and separate approvals. Remembered approval is checked against configuration identity. GOAT’s native whitelist does not configure an external shell server. Restricted JUDAS modes block external MCP processes because their own network behavior is not confined by GOAT’s HTTP policy.

A timeout or missing saved result can leave an unknown outcome. Inspect affected state before retrying. GOAT never executes tool markup printed as text and does not grant additional authority to recover from a failure.

See [Manage permissions](../how-to/PERMISSIONS.md), [Work on code](../how-to/WORK-ON-CODE.md) and [Connection policy](CONNECTIONS.md).
