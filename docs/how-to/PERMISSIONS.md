# Manage project permissions

Review file changes, command execution and networking as separate decisions. Start with [Tools and permissions](../overview/TOOLS.md) for their purpose.

## File creation and editing

1. Open the permission chip beside **+** in the composer, or respond to a native file approval dialog.
2. Choose **Ask for approval**, **Allow for this chat** or **Always allow for this Pen**. The dialog also offers **Allow Once** for its displayed action.
3. Review the scope explanation before choosing a Pen-wide grant. It covers current and future chats in that Pen.
4. Use **File permissions** on the Pen page to review/reset Pen authority. Resetting to Ask there clears file grants for the Pen.

Chat grants survive reopening a chat. A grant chosen in a Pen’s unsent composer belongs to the chat created by Send; the next draft starts fresh unless a Pen-wide grant applies. Filesystem validation still runs for every operation.

## Command permissions

1. Open **Command permissions** on the Pen page and choose **Add tool…**.
2. Enter an executable name or path and select **Check executable**. GOAT resolves it without running it.
3. Choose one chat or all chats in the Pen. Separately choose whether the executable may request networking.
4. Save, or cancel without changing authority. Existing entries support Edit, Remove and Reset.

A remembered command grant permits any arguments and child commands within the displayed filesystem/network boundaries. It is broader than approving one command line. A network-enabled grant also covers offline use, but each invocation remains offline unless it requests networking. JUDAS still has a veto.

Pen-wide grants cannot be narrowed by adding a chat-only entry. Remove the broader grant if you want a narrower scope. Revoking access does not undo completed work; use Stop for a running job.

MCP servers retain independent tool approvals. Changing native grants does not configure an external shell server. See [Permission reference](../reference/PERMISSIONS.md) for limits and precedence.
