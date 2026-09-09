# Work on code

Use a capable model with native Herder tools to inspect files, make changes and run approved commands. Begin with a small disposable project while learning the permission controls.

## Prepare

Create a [Pen](CREATE-A-PEN.md) bound to the intended folder. In **Settings → GOATed → Extensions → Built-in**, enable Herder and the operations you need. Enable tools in the chat. The engine must return structured tool calls; a “Coder” label does not establish that capability.

## Make a small, verifiable change

1. Ask the model to list the project files and read the relevant file before proposing an edit. For example: “Read the onboarding page and shorten its introduction. Preserve the layout.”
2. Inspect the proposed path and arguments in the approval dialog. Use **Allow Once** for an individual change, or deliberately choose a chat/Pen grant.
3. Expand the tool activity group to inspect the result. Ask the model to read back the changed file. Creation cannot overwrite an existing file; edits use an exact unique fragment from the current contents.
4. Ask for the project’s documented build or test command. Review its executable, workspace, arguments and requested networking. Commands have a separate approval system from file edits.
5. Let the model check `pen_command_status` with the exact returned job ID until the process finishes. Review the exit code and output before accepting the result.

A successful final message is not proof of a successful build. Check the command result and, where relevant, the changed files or preview.

## Guide or stop work

Use [Lead](LEAD.md) to add instructions while work is active. Guidance applies after the current action; approvals remain open. Stop interrupts work but does not roll back completed changes.

Commands are non-interactive, bounded and confined to the Pen. Detached development servers are unsupported. Package downloads need separately approved networking, and host credentials or runtime configuration may be unavailable inside confinement. See the [permission reference](../reference/PERMISSIONS.md).

If a tool times out or the app loses a result, inspect the affected files before retrying. The outcome may be unknown. Text printed as JSON or a shell command is not executed as a tool; repeated text-only calls point to model-template or parser compatibility. Use [Troubleshooting](TROUBLESHOOTING.md).
